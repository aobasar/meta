import Foundation
import UIKit

/// The guide's state: ask, think, then walk through the steps. Nova only shows; the user does every step
/// (HACKATHON.md, design rule 3).
@MainActor
final class GuideModel: ObservableObject {
    enum Phase: Equatable {
        case asking
        case thinking
        case guiding
        case finished
        case refused(String)
        case failed(String)
    }

    enum Connection: Equatable {
        case unknown, connected(Route.Kind), noKey, unreachable, rejected(String)
    }

    /// What Nova knows about one step in this session (physical state memory).
    struct StepRecord: Equatable {
        enum Result: Equatable {
            /// `confirmed`: Nova couldn't tell, and the user confirmed it themselves.
            /// `skipped`: Nova saw it wasn't done, and the user moved on anyway.
            case pending, verified, failed, uncertain, unchecked, confirmed, skipped
        }

        var expected: String
        var observed: String?
        var result: Result = .pending
    }

    /// The step card's answer to "I've done it".
    enum Feedback: Equatable {
        case checking
        case correct
        case notDone(String)
        case unsure(String)
        case error(String)
    }

    /// Pulse, the one round button: what it shows and what a tap does.
    enum Pulse: Equatable {
        case ready, listening, thinking, guiding
    }

    static let autoContinueSeconds = 5.0

    @Published var phase: Phase = .asking
    @Published var question = ""
    @Published private(set) var plan: GuidePlan?
    @Published private(set) var stepIndex = 0
    @Published private(set) var statusLine = ""
    @Published private(set) var connection: Connection = .unknown
    @Published private(set) var records: [StepRecord] = []
    @Published private(set) var feedback: Feedback?
    /// The device Nova recognized last; kept for "New task here", cleared by "Something else".
    @Published private(set) var knownDevice: String?
    /// When the task's first question was asked and when its last step was done.
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    /// Home shows the welcome screen again; "Get Started" returns to the camera.
    @Published var showWelcome = false

    enum Listening: Equatable {
        case idle, listening, transcribing, answering
    }

    @Published private(set) var listening: Listening = .idle
    /// What Nova heard last, shown briefly so a misheard sentence is visible.
    @Published private(set) var heard: String?
    /// Nova's answer to a question asked during the task.
    @Published private(set) var reply: String?

    /// With Settings › I speak › Automatic: the language of what the user said last (the iPhone's at first).
    @Published private(set) var spokenLanguage: UserLanguage

    let settings: GuideSettings
    let ar: ARGuideController
    let router: ServerRouter
    private let speaker = Speaker()
    private var task: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    let recorder = VoiceRecorder()

    init(settings: GuideSettings, ar: ARGuideController) {
        self.settings = settings
        self.ar = ar
        spokenLanguage = settings.language
        router = ServerRouter()
        recorder.onFinish = { [weak self] wav in self?.heardRecording(wav) }
    }

    /// The language Nova speaks and answers in now.
    var language: UserLanguage { settings.isAutomaticLanguage ? spokenLanguage : settings.language }

    /// Automatic language: a Turkish sentence switches Nova to Turkish, an English one to English.
    private func heardLanguage(_ name: String?) {
        guard settings.isAutomaticLanguage, let name, let heard = UserLanguage.all.first(where: { $0.serverName == name }) else { return }
        spokenLanguage = heard
    }

    var currentStep: GuideStep? {
        guard let plan, plan.steps.indices.contains(stepIndex) else { return nil }
        return plan.steps[stepIndex]
    }

    var isLastStep: Bool { plan.map { stepIndex + 1 == $0.steps.count } ?? false }

    /// True while Nova waits for a model: screen recording pauses so the video holds only the action.
    var isWaiting: Bool {
        phase == .thinking || feedback == .checking || listening == .transcribing || listening == .answering
    }

    var pulse: Pulse {
        if listening == .listening { return .listening }
        if phase == .thinking || listening == .transcribing || listening == .answering { return .thinking }
        return phase == .guiding ? .guiding : .ready
    }

    /// The step card's arrows: forward only to a step the user already reached.
    var canGoForward: Bool {
        guard let plan, stepIndex + 1 < plan.steps.count, records.indices.contains(stepIndex) else { return false }
        return records[stepIndex].result != .pending
    }

    /// Usage ids sent with every request: this app launch, and the current task (a new one per plan).
    private let sessionID = UUID().uuidString
    private var taskID = UUID().uuidString

    /// A request on the current route (internet first, then Tailscale), with the routes from Settings.
    private func send<T>(_ request: @escaping (GuideClient) async throws -> T) async throws -> T {
        await router.update(settings.routes)
        let session = sessionID, task = taskID
        return try await router.perform { client in
            var client = client
            client.sessionID = session
            client.taskID = task
            return try await request(client)
        }
    }

    func checkConnection() async {
        await router.update(settings.routes)
        connection = Self.connection(await router.resolve())
    }

    private static func connection(_ state: ServerRouter.State) -> Connection {
        switch state {
        case .connected(let kind, let keyLoaded): keyLoaded ? .connected(kind) : .noKey
        case .rejected(let message): .rejected(message)
        case .unreachable, .unknown: .unreachable
        }
    }

    func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase != .thinking else { return }
        guard let capture = ar.capture() else {
            phase = .failed(String(localized: "The camera isn't ready yet. Point it at the device and try again."))
            return
        }
        speaker.stop()
        ar.clear()
        plan = nil
        taskID = UUID().uuidString  // a new plan is a new task
        startedAt = startedAt ?? Date()
        finishedAt = nil
        phase = .thinking
        let settings = self.settings
        task = Task {
            let status = Task { await self.cycleStatus() }
            defer { status.cancel() }
            do {
                let language = self.language.serverName, auto = settings.isAutomaticLanguage, record = settings.record
                let plan = try await send {
                    try await $0.plan(jpeg: capture.jpeg, question: text, language: language, autoLanguage: auto,
                                      record: record, camera: capture.cameraInfo)
                }
                connection = Self.connection(await router.state)
                heardLanguage(plan.language)
                show(plan, capture: capture)
            } catch is CancellationError {
                phase = .asking
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func show(_ plan: GuidePlan, capture: CapturedFrame) {
        self.plan = plan
        if !plan.device.type.isEmpty { knownDevice = plan.deviceLabel }
        guard plan.safe else {
            let note = plan.safetyNote.isEmpty ? String(localized: "Nova can't guide this safely.") : plan.safetyNote
            phase = .refused(note)
            speak(note)
            return
        }
        guard !plan.steps.isEmpty else {
            let note = plan.uncertainty.isEmpty ? String(localized: "Nova couldn't find the controls for this.") : plan.uncertainty
            phase = .refused(note)
            speak(note)
            return
        }
        ar.place(plan, from: capture)
        records = plan.steps.map { StepRecord(expected: $0.success) }
        phase = .guiding
        go(to: 0)
    }

    private func cycleStatus() async {
        let lines = [
            String(localized: "Working out what this is…"),
            String(localized: "Planning the steps…"),
            String(localized: "Finding the controls…"),
        ]
        for line in lines {
            statusLine = line
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled { return }
        }
    }

    // MARK: Steps

    /// The step card's main button; its meaning follows the last check.
    func primary() {
        switch feedback {
        case .checking: return
        case .correct: next()
        case .notDone, .unsure, .error: done()  // check again, closer
        case nil: done()
        }
    }

    /// The step card's second button, shown after a check that didn't pass.
    func secondary() {
        switch feedback {
        case .unsure: mark(.confirmed)
        case .notDone, .error: mark(.skipped)
        default: break
        }
    }

    /// The user says the step is done: check it on a close-up of the control, unless a close-up can't show it.
    func done() {
        guard let step = currentStep, feedback != .checking else { return }
        guard settings.verifyEach else {
            mark(.confirmed)
            return
        }
        guard step.isVerifiable else {
            mark(.unchecked)
            return
        }
        switch ar.closeUp(step: stepIndex) {
        case .offScreen:
            say(.unsure(String(localized: "Point the camera at the control, then check again.")))
        case .tooSmall:
            say(.unsure(String(localized: "Move the phone closer to the control, then check again.")))
        case .notReady:
            say(.unsure(String(localized: "Hold the phone steady, then check again.")))
        case .jpeg(let jpeg):
            feedback = .checking
            reply = nil
            let index = stepIndex, settings = self.settings
            checkTask = Task {
                do {
                    let language = self.language.serverName, record = settings.record
                    let check = try await send {
                        try await $0.verify(jpeg: jpeg, step: step, language: language, record: record)
                    }
                    guard !Task.isCancelled, index == stepIndex else { return }
                    apply(check, to: index)
                } catch is CancellationError {
                } catch {
                    guard index == stepIndex else { return }
                    feedback = .error(error.localizedDescription)
                }
            }
        }
    }

    private func apply(_ check: StepCheck, to index: Int) {
        records[index].observed = check.observed
        switch check.status {
        case .done:
            records[index].result = .verified
            say(.correct)
            guard settings.autoContinue else { return }
            checkTask = Task {
                try? await Task.sleep(for: .seconds(Self.autoContinueSeconds))
                if !Task.isCancelled, index == stepIndex, feedback == .correct { next() }
            }
        case .notDone:
            records[index].result = .failed
            let correction = check.correction.isEmpty
                ? String(localized: "Not yet. Check the marker and try again.") : check.correction
            say(.notDone(correction))
        case .unsure:
            records[index].result = .uncertain
            say(.unsure(check.reason == "too_small"
                ? String(localized: "Move the phone closer to the control, then check again.")
                : String(localized: "I can't see it clearly. Move closer, or confirm it yourself.")))
        }
    }

    /// Records the user's own call for this step and moves on.
    private func mark(_ result: StepRecord.Result) {
        guard currentStep != nil else { return }
        records[stepIndex].result = result
        next()
    }

    /// The voice command "skip": the user did it, whatever the check said.
    func skip() {
        if case .notDone = feedback {
            mark(.skipped)
        } else {
            mark(.confirmed)
        }
    }

    private func say(_ feedback: Feedback) {
        self.feedback = feedback
        switch feedback {
        case .correct:
            haptic(.success)
            speak(String(localized: "Correct."))
        case .notDone(let text):
            haptic(.error)
            speak(text)
        case .unsure(let text):
            haptic(.warning)
            speak(text)
        case .checking, .error: break
        }
    }

    func next() {
        guard let plan else { return }
        if stepIndex + 1 < plan.steps.count {
            go(to: stepIndex + 1)
        } else {
            checkTask?.cancel()
            phase = .finished
            feedback = nil
            finishedAt = Date()
            ar.currentStep = nil
            ar.taskEnded()
            speak(String(localized: "Task completed."))
        }
    }

    /// Back one step; from the first step, back to the question with the same thing in view.
    func back() {
        if phase == .finished {
            phase = .guiding
            go(to: stepIndex)
        } else if stepIndex > 0 {
            go(to: stepIndex - 1)
        } else {
            newTask(keepDevice: true)
        }
    }

    func forward() {
        if canGoForward { go(to: stepIndex + 1) }
    }

    func repeatStep() {
        if let step = currentStep { speak(step.instruction) }
    }

    /// Home, "New task here" and "Something else": back to "What do you want to do?".
    func newTask(keepDevice: Bool) {
        task?.cancel()
        checkTask?.cancel()
        feedback = nil
        reply = nil
        records = []
        speaker.stop()
        ar.clear()
        ar.taskEnded()
        plan = nil
        stepIndex = 0
        question = ""
        startedAt = nil
        finishedAt = nil
        if !keepDevice { knownDevice = nil }
        phase = .asking
    }

    func newQuestion() { newTask(keepDevice: true) }

    /// Home: the task and the recognized device are dropped, and the welcome screen comes back.
    func goHome() {
        newTask(keepDevice: false)
        showWelcome = true
    }

    // MARK: Voice

    /// Pulse: start listening, or stop and use what was said.
    func microphoneTapped() {
        if recorder.isRecording {
            recorder.finish()
            return
        }
        guard listening == .idle, phase != .thinking else { return }
        speaker.stop()
        voiceTask = Task {
            guard await VoiceRecorder.requestPermission() else {
                show(message: String(localized: "Allow the microphone in Settings to talk to Nova."))
                return
            }
            do {
                try recorder.start()
                listening = .listening
            } catch {
                show(message: String(localized: "The microphone couldn't start."))
            }
        }
    }

    private func heardRecording(_ wav: Data?) {
        guard let wav else {
            listening = .idle
            show(message: String(localized: "I didn't hear anything. Tap Pulse and speak."))
            return
        }
        listening = .transcribing
        let settings = self.settings
        voiceTask = Task {
            do {
                let language = settings.isAutomaticLanguage ? "Turkish" : settings.language.serverName
                let text = try await send { try await $0.transcribe(wav: wav, language: language) }
                listening = .idle
                handle(spoken: text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                listening = .idle
                show(message: error.localizedDescription)
            }
        }
    }

    private func handle(spoken text: String) {
        guard !text.isEmpty else {
            show(message: String(localized: "I didn't catch that. Please say it again."))
            return
        }
        heard = text
        Task {
            try? await Task.sleep(for: .seconds(5))
            if heard == text { heard = nil }
        }
        let matched = VoiceCommand.matchWithLanguage(text)
        let command = matched?.command
        heardLanguage(matched?.language)
        switch phase {
        case .thinking:
            return
        case .guiding:
            switch command {
            case .done: primary()
            case .repeatStep: repeatStep()
            case .back: back()
            case .skip: skip()
            case .newQuestion: newQuestion()
            case nil: askDuringTask(text)
            }
        case .asking, .finished, .refused, .failed:
            if command == .newQuestion || (phase == .finished && command == .back) {
                command == .back ? back() : newQuestion()
                return
            }
            if phase != .asking { newQuestion() }
            question = text
            ask()
        }
    }

    /// A question in the middle of the task: answer it and keep the user's place, or start the new task they asked for.
    private func askDuringTask(_ text: String) {
        guard let plan, let capture = ar.capture() else {
            show(message: String(localized: "The camera isn't ready yet. Point it at the device and try again."))
            return
        }
        let context = GuideClient.TaskContext(
            device: plan.deviceLabel, current: stepIndex + 1,
            steps: zip(plan.steps, records).map { step, record in
                GuideClient.TaskContext.Step(instruction: step.instruction, success: step.success,
                                             result: Self.describe(record.result))
            })
        listening = .answering
        let settings = self.settings
        voiceTask = Task {
            do {
                let language = self.language.serverName, auto = settings.isAutomaticLanguage, record = settings.record
                let answer = try await send {
                    try await $0.ask(jpeg: capture.jpeg, question: text, language: language, autoLanguage: auto,
                                     context: context, record: record)
                }
                listening = .idle
                heardLanguage(answer.language)
                switch answer.kind {
                case .answer:
                    reply = answer.answer
                    speak(answer.answer)
                case .newTask:
                    newQuestion()
                    question = text
                    ask()
                    speak(answer.answer)  // after ask(), which silences the voice
                }
            } catch {
                listening = .idle
                show(message: error.localizedDescription)
            }
        }
    }

    private static func describe(_ result: StepRecord.Result) -> String {
        switch result {
        case .pending: "not done yet"
        case .verified: "verified done"
        case .failed: "checked: not done"
        case .uncertain: "checked: unclear"
        case .unchecked: "done, not checked"
        case .confirmed: "the user confirmed it was done"
        case .skipped: "the user said done although the check said not done"
        }
    }

    /// A short spoken message: on the step card while guiding, otherwise as the error card.
    private func show(message: String) {
        if phase == .guiding {
            reply = message
            speak(message)
        } else if phase == .asking {
            phase = .failed(message)
            speak(message)
        } else {
            speak(message)
        }
    }

    private func go(to index: Int) {
        checkTask?.cancel()
        feedback = nil
        reply = nil
        stepIndex = index
        ar.currentStep = index
        repeatStep()
    }

    private func speak(_ text: String) {
        guard settings.speakAloud else { return }
        speaker.speak(text, voice: language.voice, labelVoice: UserLanguage.voice(forLanguageNamed: plan?.labelLanguage))
    }

    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard settings.haptics else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    #if DEBUG
    /// Simulator screenshots only (launch argument `-NovaDemo <screen>`): a fixed plan without the server.
    func loadDemo(_ screen: String, plan: GuidePlan, correction: String) {
        self.plan = plan
        knownDevice = plan.deviceLabel
        records = plan.steps.map { StepRecord(expected: $0.success) }
        startedAt = Date().addingTimeInterval(-192)
        switch screen {
        case "thinking":
            self.plan = nil
            statusLine = String(localized: "Planning the steps…")
            phase = .thinking
        case "guiding", "verified", "correction":
            phase = .guiding
            stepIndex = 1
            records[0].result = .verified
            if screen == "verified" {
                records[1].result = .verified
                feedback = .correct
            } else if screen == "correction" {
                records[1].result = .failed
                feedback = .notDone(correction)
            }
        case "finished":
            records = records.enumerated().map { index, record in
                var record = record
                record.result = [.verified, .verified, .confirmed, .unchecked][min(index, 3)]
                return record
            }
            stepIndex = plan.steps.count - 1
            finishedAt = Date()
            phase = .finished
        default:
            knownDevice = nil
            self.plan = nil
            records = []
            phase = .asking
        }
    }
    #endif
}
