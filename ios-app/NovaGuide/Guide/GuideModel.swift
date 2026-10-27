import Foundation

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
        case unknown, connected, noKey, unreachable
    }

    /// What Nova knows about one step in this session (physical state memory).
    struct StepRecord: Equatable {
        enum Result: Equatable {
            case pending, verified, failed, uncertain, unchecked, skipped
        }

        var expected: String
        var observed: String?
        var result: Result = .pending
    }

    /// The step card's answer to "Done".
    enum Feedback: Equatable {
        case checking
        case correct
        case notDone(String)
        case unsure(String)
        case error(String)
    }

    @Published var phase: Phase = .asking
    @Published var question = ""
    @Published private(set) var plan: GuidePlan?
    @Published private(set) var stepIndex = 0
    @Published private(set) var statusLine = ""
    @Published private(set) var connection: Connection = .unknown
    @Published private(set) var records: [StepRecord] = []
    @Published private(set) var feedback: Feedback?

    enum Listening: Equatable {
        case idle, listening, transcribing, answering
    }

    @Published private(set) var listening: Listening = .idle
    /// What Nova heard last, shown briefly so a misheard sentence is visible.
    @Published private(set) var heard: String?
    /// Nova's answer to a question asked during the task.
    @Published private(set) var reply: String?

    let settings: GuideSettings
    let ar: ARGuideController
    private let speaker = Speaker()
    private var task: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    let recorder = VoiceRecorder()

    init(settings: GuideSettings, ar: ARGuideController) {
        self.settings = settings
        self.ar = ar
        recorder.onFinish = { [weak self] wav in self?.heardRecording(wav) }
    }

    var currentStep: GuideStep? {
        guard let plan, plan.steps.indices.contains(stepIndex) else { return nil }
        return plan.steps[stepIndex]
    }

    func checkConnection() async {
        do {
            connection = try await settings.client.status() ? .connected : .noKey
        } catch {
            connection = .unreachable
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
        phase = .thinking
        let settings = self.settings
        task = Task {
            let status = Task { await self.cycleStatus() }
            defer { status.cancel() }
            do {
                let plan = try await settings.client.plan(
                    jpeg: capture.jpeg, question: text, language: settings.language.serverName,
                    record: settings.record, camera: capture.cameraInfo)
                connection = .connected
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
            String(localized: "Recognizing the device…"),
            String(localized: "Planning the steps…"),
            String(localized: "Finding the controls…"),
            String(localized: "Almost there…"),
        ]
        for line in lines {
            statusLine = line
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled { return }
        }
    }

    func cancel() {
        task?.cancel()
        phase = .asking
    }

    /// The user says the step is done: check it on a close-up of the control, unless a close-up can't show it.
    func done() {
        guard let step = currentStep, feedback != .checking else { return }
        guard step.isVerifiable else {
            records[stepIndex].result = .unchecked
            next()
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
            let index = stepIndex, settings = self.settings
            checkTask = Task {
                do {
                    let check = try await settings.client.verify(
                        jpeg: jpeg, step: step, language: settings.language.serverName, record: settings.record)
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
            checkTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
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
                : String(localized: "I can't see it clearly. Move closer and check again.")))
        }
    }

    /// The user's own call: they did the step even though Nova couldn't confirm it.
    func skip() {
        guard currentStep != nil else { return }
        records[stepIndex].result = .skipped
        next()
    }

    private func say(_ feedback: Feedback) {
        self.feedback = feedback
        switch feedback {
        case .correct: speak(String(localized: "Correct."))
        case .notDone(let text), .unsure(let text): speak(text)
        case .checking, .error: break
        }
    }

    func next() {
        guard let plan else { return }
        if stepIndex + 1 < plan.steps.count {
            go(to: stepIndex + 1)
        } else {
            phase = .finished
            feedback = nil
            ar.currentStep = nil
            speak(String(localized: "Ready."))
        }
    }

    func back() {
        if phase == .finished {
            phase = .guiding
            go(to: stepIndex)
        } else if stepIndex > 0 {
            go(to: stepIndex - 1)
        }
    }

    func repeatStep() {
        if let step = currentStep { speak(step.instruction) }
    }

    func newQuestion() {
        task?.cancel()
        checkTask?.cancel()
        feedback = nil
        reply = nil
        records = []
        speaker.stop()
        ar.clear()
        plan = nil
        stepIndex = 0
        phase = .asking
    }

    // MARK: Voice

    /// The microphone button: start listening, or stop and use what was said.
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
            show(message: String(localized: "I didn't hear anything. Tap the microphone and speak."))
            return
        }
        listening = .transcribing
        let settings = self.settings
        voiceTask = Task {
            do {
                let text = try await settings.client.transcribe(wav: wav, language: settings.language.serverName)
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
        let command = VoiceCommand.match(text)
        switch phase {
        case .thinking:
            return
        case .guiding:
            switch command {
            case .done: done()
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
                let answer = try await settings.client.ask(
                    jpeg: capture.jpeg, question: text, language: settings.language.serverName, context: context,
                    record: settings.record)
                listening = .idle
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
        case .skipped: "the user said done without a check"
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
        speaker.speak(text, voice: settings.language.voice)
    }
}
