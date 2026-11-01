import Foundation
import UIKit

/// The guide's state: ask, think, then walk through the steps. Nova only shows; the user does every step
/// (HACKATHON.md, design rule 3).
@MainActor
final class GuideModel: ObservableObject {
    enum Phase: Equatable {
        case asking
        case thinking
        /// Nova asked one thing before planning; the user answers on the card or by voice.
        case choosing(GuidePlan.Question)
        /// Kokobubu needs to see something else; the user points the camera there and says so.
        case showing(GuidePlan.ShowRequest)
        case guiding
        /// All steps are done: Nova asks whether the problem is solved.
        case confirming
        case finished
        case refused(String)
        case failed(String)
    }

    /// "This is wrong" on the step card: the choices, tapping the right control, or saying what is wrong.
    enum Correcting: Equatable {
        case menu, moving
        case telling(kind: String)  // "step", "restart" or "outcome"
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
        /// A dial the check couldn't confirm: the user is asked, not told it failed.
        case confirmDial(String)
    }

    /// Pulse, the one round button: what it shows and what a tap does.
    enum Pulse: Equatable {
        case ready, listening, thinking, guiding
    }

    static let autoContinueSeconds = 5.0
    /// A step is planned again at most this often; after that Nova says it isn't sure instead of guessing again.
    static let maxStepCorrections = 2
    /// "Not solved" gets this many new tries; then Nova says it couldn't solve it.
    static let maxOutcomeTries = 2
    /// A task moves on to a new screen at most this often before Nova stops and asks.
    static let maxScreens = 6
    /// The next screen needs a moment to settle before the new frame.
    static let screenSettleSeconds = 1.0
    static let photoNoticeSeconds = 1.0

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
    /// Until the task's first tap: the title says Nova is ready, and Pulse pulses.
    @Published private(set) var awaitingFirstTap = true
    @Published private(set) var correcting: Correcting?
    /// The task ended without solving the problem: the last screen says so.
    @Published private(set) var unsolved = false
    /// What the finished task came to, for the completion card.
    @Published private(set) var finishLine: String?
    /// "Re-evaluate" is running; and afterwards, Nova looked again and stands by the step.
    @Published private(set) var reassessing = false
    /// How many times the marker was called wrong on each step.
    @Published private(set) var wrongSpots: [Int: Int] = [:]
    @Published private(set) var stepDefended = false
    /// How often each step failed its check; two in a row and Nova offers to look again.
    @Published private(set) var failedChecks: [Int: Int] = [:]
    /// Checks that could not tell, per step: the next one looks at the whole device, and after two the user leads.
    @Published private(set) var unsureChecks: [Int: Int] = [:]
    /// After the last step: the camera looks at the whole task, so "Did this solve it?" isn't the only check.
    enum GoalCheck: Equatable {
        case checking, waiting, unclear
    }

    @Published private(set) var goalCheck: GoalCheck?
    private var lastShowRequest: String?
    /// Live transcription: the words so far.
    @Published private(set) var liveWords: String?
    /// How often each step was planned again.
    @Published private(set) var stepCorrections: [Int: Int] = [:]
    /// The welcome screen opens every launch and comes back with Home; "Get Started" goes to the camera.
    @Published var showWelcome = true
    /// The first accepted consent shows how Nova works right after it.
    @Published var showHowNext = false

    enum Listening: Equatable {
        case idle, listening, transcribing, answering
    }

    @Published private(set) var listening: Listening = .idle
    /// What Nova heard last, shown briefly so a misheard sentence is visible.
    @Published private(set) var heard: String?
    /// Nova's answer to a question asked during the task.
    @Published private(set) var reply: String?

    /// Settings › Speed test: the current task's timings, measured on the phone.
    @Published private(set) var timings = TaskTimings()
    private var lastLookingPhrase: String?
    /// What this task's photos showed so far, and how many times Kokobubu asked to see something.
    private var findings: [String] = []
    private var shows = 0
    static let maxFindings = 6
    private var lastReadyPhrase: String?
    /// Said before the next step's instruction, when the step just left could not be checked.
    private var stepLead: String?
    /// The words of the last passed check, also shown on the step card.
    @Published private(set) var doneText: String?
    /// How long the question being handled took to transcribe; nil for a typed question.
    private var heardSeconds: Double?

    /// With Settings › I speak › Automatic: the language of what the user said last (the iPhone's at first).
    @Published private(set) var spokenLanguage: UserLanguage

    let settings: GuideSettings
    let ar: ARGuideController
    let router: ServerRouter
    private let speaker = Speaker()
    private let sounds = SoundEffects()
    private var task: Task<Void, Never>?
    private var prepared: PreparedPlan?
    private var prepareTask: Task<Void, Never>?
    /// Photos coming within a second; the camera shows a small icon while there are any.
    @Published private(set) var photoWaits = 0
    var photoSoon: Bool { photoWaits > 0 }
    /// What the final check said is missing, while Kokobubu finds the control for it.
    private var goalMiss: String?
    private var checkTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    /// The task's first sentence and the frame it was asked about; answers to Nova's questions plan on the same frame.
    private var taskQuestion = ""
    private var planCapture: CapturedFrame?
    private var answers: [GuideClient.Answer] = []
    private var greeted = false
    private var askingAloud = false
    private var outcomeTries = 0
    private var screensPassed = 0
    private var pendingCorrection: GuideClient.Correction?
    private var skipWords = false
    private var discardRecording = false
    private var live: LiveTranscriber?
    private var liveFinal: String?
    private var liveEndedAt: Date?
    private var heardLive = false
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

    /// Automatic language: a sentence in one of the listed languages switches Nova to it.
    private func heardLanguage(_ name: String?) {
        guard settings.isAutomaticLanguage, let name, let heard = UserLanguage.all.first(where: { $0.serverName == name }) else { return }
        spokenLanguage = heard
    }

    var currentStep: GuideStep? {
        guard let plan, plan.steps.indices.contains(stepIndex) else { return nil }
        return plan.steps[stepIndex]
    }

    var seemsStuck: Bool { (failedChecks[stepIndex] ?? 0) >= 2 && !stepDefended && !reassessing }

    var canCorrectStep: Bool { (stepCorrections[stepIndex] ?? 0) < Self.maxStepCorrections }

    /// Nothing comes after this step: the plan's last one, and the task doesn't go on past this screen.
    var isLastStep: Bool { plan.map { stepIndex + 1 == $0.steps.count && !$0.goesOn } ?? false }

    /// The steps are on screen, the controls are still being located: no marker yet, and nothing to check against.
    var isLocating: Bool { phase == .guiding && plan?.isLocated == false }

    /// True while Nova waits for a model: screen recording pauses so the video holds only the action.
    var isWaiting: Bool {
        phase == .thinking || feedback == .checking || reassessing || listening == .transcribing || listening == .answering
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

    /// A request to the server, with the address and code from Settings.
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

    /// The server turned the invite code down, so the user has to enter another one.
    var inviteRejected: Bool {
        if case .rejected = connection { return true }
        return false
    }

    /// Asks the server about a code before keeping it.
    func tryInvite(_ code: String) async -> ServerRouter.Probe {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: settings.publicURL.trimmingCharacters(in: .whitespaces)), !code.isEmpty else { return .rejected("") }
        let probe = await ServerRouter.liveProbe(Route(kind: .internet, baseURL: url, inviteCode: code))
        if case .ok = probe {
            settings.inviteCode = code
            settings.inviteSkipped = false
            await checkConnection()
        }
        return probe
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
        ar.clear()
        plan = nil
        taskID = UUID().uuidString  // a new plan is a new task
        startedAt = startedAt ?? Date()
        finishedAt = nil
        phase = .thinking
        timings = TaskTimings(transcript: heardSeconds, liveVoice: heardLive, setting: settings.sparkLabel)
        awaitingFirstTap = false
        askingAloud = false
        outcomeTries = 0
        screensPassed = 0
        pendingCorrection = nil
        unsolved = false
        taskQuestion = text
        answers = []
        findings = []
        shows = 0
        stepCorrections = [:]
        failedChecks = [:]
        unsureChecks = [:]
        correcting = nil
        acknowledge(text)
        task = Task {
            await warnOfPhoto()
            if Task.isCancelled { return }
            guard let capture = takePhoto() else {
                phase = .failed(String(localized: "The camera isn't ready yet. Point it at the device and try again.", bundle: .ui))
                return
            }
            planCapture = capture
            requestPlan(capture: capture)
        }
    }

    private func takePhoto() -> CapturedFrame? {
        guard let capture = ar.capture() else { return nil }
        if settings.depthScan { ar.flashDepthMesh() }
        return capture
    }

    /// A second's warning before a photo, when Settings has it on. Callers check for cancellation afterwards.
    private func warnOfPhoto() async {
        guard settings.photoNotice else { return }
        photoWaits += 1
        defer { photoWaits -= 1 }
        try? await Task.sleep(for: .seconds(Self.photoNoticeSeconds))
    }

    /// Says the fixed greeting once per task, with no model call.
    func greet() {
        guard phase == .asking, plan == nil, !greeted else { return }
        greeted = true
        speak(language.phrase("Kokobubu is ready to help."))
    }

    /// The task's first tap: Nova asks, and the microphone opens when it has finished, so it doesn't hear itself.
    private func askBeforeListening() {
        awaitingFirstTap = false
        guard settings.speakAloud else {
            startListening()
            return
        }
        askingAloud = true
        speaker.speak(language.phrase("How can I help you?"), voice: language.voice) { [weak self] in
            self?.stopAskingThenListen()
        }
        Task {
            try? await Task.sleep(for: .seconds(4))  // in case the voice never finishes
            stopAskingThenListen()
        }
    }

    private func stopAskingThenListen() {
        guard askingAloud else { return }
        askingAloud = false
        if settings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        startListening()
    }

    /// Answers Nova's question and plans again on the same frame, so the markers stay right.
    func answerQuestion(_ text: String) {
        guard case .choosing(let asked) = phase, let capture = planCapture else { return }
        answers.append(GuideClient.Answer(question: asked.text, answer: text))
        plan = nil
        phase = .thinking
        timings = TaskTimings(setting: settings.sparkLabel)
        acknowledge("")
        requestPlan(capture: capture, correction: pendingCorrection)
    }

    /// The camera now shows what Kokobubu asked for; `said` is what the user added, or why they can't show it.
    func shown(said: String? = nil) {
        guard case .showing(let asked) = phase else { return }
        lastShowRequest = asked.what
        remember("You asked them: \(asked.what)")
        if let said { remember("They said: \(said)") }
        shows += 1
        phase = .thinking
        timings = TaskTimings(setting: settings.sparkLabel)
        acknowledge("")
        let earlier = plan?.steps ?? []
        let correction = earlier.isEmpty ? pendingCorrection : GuideClient.Correction(
            kind: "continue", wrongStep: "", said: plan?.remaining ?? "", done: earlier.map(\.instruction))
        task = Task {
            try? await Task.sleep(for: .seconds(Self.screenSettleSeconds))
            await warnOfPhoto()
            if Task.isCancelled { return }
            guard let capture = takePhoto() else {
                if let plan, let asked = plan.showRequest { phase = .showing(asked) }
                show(message: String(localized: "The camera isn't ready yet. Point it at the device and try again.", bundle: .ui))
                return
            }
            planCapture = capture
            requestPlan(capture: capture, correction: correction, from: earlier.count)
        }
    }

    func cantShow() {
        shown(said: "I can't show this.")
    }

    /// The user doesn't know the way to what Kokobubu asked to see, so the next plan has to lead there.
    func showTheWay() {
        shown(said: "I don't know how to get there. Give me the step that leads there.")
    }

    nonisolated static func sameRequest(_ new: String, _ old: String?) -> Bool {
        guard let old else { return false }
        func plain(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return plain(new) == plain(old)
    }

    private func remember(_ finding: String) {
        let text = String(finding.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        guard !text.isEmpty, !findings.contains(text) else { return }
        findings.append(text)
        if findings.count > Self.maxFindings { findings.removeFirst() }
    }

    func letNovaChoose() { answerQuestion("You choose the most common option and tell me which one you chose.") }

    /// Plans from a frame. A correction keeps the steps before `start`, and doesn't ask anything first.
    private func requestPlan(capture: CapturedFrame, correction: GuideClient.Correction? = nil, from start: Int = 0,
                             prepared: PreparedPlan? = nil) {
        let text = taskQuestion, answers = self.answers, findings = self.findings, shows = self.shows
        let allowQuestions = correction == nil || (correction?.kind == "outcome" && answers.isEmpty)
        let settings = self.settings
        task = Task {
            let status = Task { await self.cycleStatus() }
            defer { status.cancel() }
            do {
                let language = self.language.serverName, auto = settings.isAutomaticLanguage, record = settings.record
                let spark = settings.sparkChoice, started = Date()
                let arrived: @MainActor (GuidePlan) -> Void = { steps in
                    status.cancel()
                    self.timings.steps = Date().timeIntervalSince(started)
                    self.heardLanguage(steps.language)
                    self.received(steps, capture: capture, from: start, correction: correction)
                }
                let plan: GuidePlan
                if let prepared {
                    plan = try await prepared.result(onSteps: arrived)
                } else {
                    plan = try await send {
                        try await $0.plan(jpeg: capture.jpeg, question: text, language: language, autoLanguage: auto,
                                          record: record, camera: capture.cameraInfo, spark: spark, answers: answers,
                                          correction: correction, allowQuestions: allowQuestions, findings: findings, shows: shows,
                                          onSteps: arrived)
                    }
                }
                let elapsed = Date().timeIntervalSince(started)
                if timings.steps == nil { timings.steps = elapsed }
                if !plan.steps.isEmpty { timings.markers = elapsed }
                connection = Self.connection(await router.state)
                if phase == .guiding, self.plan?.isLocated == false {
                    located(merged(plan, from: start), capture: capture, from: start)
                } else {
                    heardLanguage(plan.language)
                    received(plan, capture: capture, from: start, correction: correction)
                }
            } catch is CancellationError {
                phase = .asking
            } catch where Task.isCancelled {
                // Home or a new task canceled the request (URLSession reports it as its own error).
            } catch {
                if prepared != nil, let correction {  // the background try failed: the user is waiting, so ask again now
                    requestPlan(capture: capture, correction: correction, from: start)
                } else if correction != nil, self.plan?.isLocated == true {
                    phase = correction?.kind == "outcome" ? .confirming : .guiding  // the old steps are still there
                    reply = error.localizedDescription
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Said after a passed check when the model gave no confirmation.
    static let readyPhrases = ["Okay.", "Done.", "Good."]

    static func readyPhrase(after last: String?) -> String {
        readyPhrases.filter { $0 != last }.randomElement() ?? readyPhrases[0]
    }

    /// What a passed check says: what is now set, then how far there is to go. Calm, without praise.
    static func doneLine(confirmation: String?, ready: String, stepsLeft: Int, goesOn: Bool, phrase: (String) -> String) -> String {
        let said = confirmation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let first = said.isEmpty ? phrase(ready) : said
        guard !goesOn else { return first }
        switch stepsLeft {
        case 2: return first + " " + phrase("Two steps left.")
        case 1: return first + " " + phrase("Last step.")
        default: return first
        }
    }

    /// Spoken variations of "I'm looking", so the same words don't come back every time.
    static let lookingPhrases = ["Let me look…", "Let me see…", "One moment…", "Looking at it now…", "Give me a second…"]

    /// Any phrase but the last one said.
    static func lookingPhrase(after last: String?) -> String {
        lookingPhrases.filter { $0 != last }.randomElement() ?? lookingPhrases[0]
    }

    private func nextLookingPhrase() -> String {
        let phrase = Self.lookingPhrase(after: lastLookingPhrase)
        lastLookingPhrase = phrase
        return phrase
    }

    /// Said the moment a question is asked, in the language it was asked in, so the wait isn't silent.
    var isSpeaking: Bool { speaker.isSpeaking }

    private func acknowledge(_ question: String) {
        if settings.isAutomaticLanguage { heardLanguage(UserLanguage.guess(question)?.serverName) }
        guard settings.speakAloud else { return }
        speaker.speak(language.phrase(nextLookingPhrase()), voice: language.voice)
    }

    /// The located plan, after its steps are already on screen: the markers appear and "I've done it" works.
    private func located(_ plan: GuidePlan, capture: CapturedFrame, from start: Int) {
        guard plan.steps.count == self.plan?.steps.count else {
            show(plan, capture: capture, from: start)
            return
        }
        self.plan = plan
        ar.place(plan, from: capture, startingAt: start)
        ar.currentStep = stepIndex
    }

    private func received(_ part: GuidePlan, capture: CapturedFrame, from start: Int, correction: GuideClient.Correction?) {
        if correction?.kind == "outcome", !part.safe || (part.steps.isEmpty && part.question == nil && part.showRequest == nil) {
            finishUnsolved(note: part.uncertainty)
            return
        }
        if correction?.kind == "continue", part.safe, part.steps.isEmpty, part.question == nil, part.showRequest == nil {
            lookForResult(part)
            return
        }
        if correction != nil, !part.safe || (part.steps.isEmpty && part.question == nil && part.showRequest == nil) {
            phase = .guiding  // a wrong step is worse than none: the steps stay, and Nova says what it can't tell
            let note = part.uncertainty.isEmpty ? String(localized: "I'm not sure about this step. Check the device's manual, or use the button below to go on.", bundle: .ui) : part.uncertainty
            reply = note
            speak(note)
            return
        }
        show(merged(part, from: start), capture: capture, from: start)
    }

    /// Nothing is left to do on the device: it is working on the task, or it is done. The last step isn't asked again;
    /// the camera looks for the end of the task, and says so while the device is still busy.
    private func lookForResult(_ part: GuidePlan) {
        guard phase != .confirming, var whole = plan else { return }
        if let miss = goalMiss {  // no step for it: the words are all there is, and looking again would only repeat them
            goalMiss = nil
            ar.currentStep = nil
            feedback = nil
            phase = .confirming
            goalCheck = .unclear
            reply = miss
            speak(miss + " " + language.phrase("Did this solve it?"))
            return
        }
        let goal = part.goal ?? ""
        whole.goal = goal.isEmpty ? (part.remaining ?? "the task is finished") : goal
        plan = whole
        ar.currentStep = nil
        feedback = nil
        reply = nil
        phase = .confirming
        goalCheck = nil
        if settings.verifyEach { checkGoal() } else { askIfSolved() }
    }

    /// The steps already done, followed by a corrected plan's steps.
    private func merged(_ part: GuidePlan, from start: Int) -> GuidePlan {
        guard start > 0, let plan else { return part }
        var whole = part
        whole.steps = Array(plan.steps.prefix(start)) + part.steps
        return whole
    }

    /// A plan, or the steps of a plan whose controls are still being located (no markers until `located`).
    private func show(_ plan: GuidePlan, capture: CapturedFrame, from start: Int = 0) {
        self.plan = plan
        if !plan.device.type.isEmpty { knownDevice = plan.deviceLabel }
        if plan.isLocated, let finding = plan.finding { remember(finding) }
        if var asked = plan.showRequest, plan.safe {
            ar.currentStep = nil
            // The same words again would leave the user where they were.
            if Self.sameRequest(asked.what, lastShowRequest) {
                asked = GuidePlan.ShowRequest(what: language.phrase("Bring the phone closer, then show me again."), why: "")
            }
            phase = .showing(asked)
            sound(.question)
            speak(asked.what)
            return
        }
        if let asked = plan.question, plan.safe {
            phase = .choosing(asked)
            sound(.question)
            speak(asked.text)
            return
        }
        guard plan.safe else {
            let note = plan.safetyNote.isEmpty ? String(localized: "Kokobubu can't guide this safely.", bundle: .ui) : plan.safetyNote
            phase = .refused(note)
            speak(note)
            return
        }
        guard !plan.steps.isEmpty else {
            let note = plan.uncertainty.isEmpty ? String(localized: "Kokobubu couldn't find the controls for this.", bundle: .ui) : plan.uncertainty
            phase = .refused(note)
            speak(note)
            return
        }
        ar.keepAnchors(first: start)
        if plan.isLocated { ar.place(plan, from: capture, startingAt: start) }
        records = Array(records.prefix(start)) + plan.steps.dropFirst(start).map { StepRecord(expected: $0.success) }
        wrongSpots = wrongSpots.filter { $0.key < start }
        goalMiss = nil
        phase = .guiding
        go(to: start)
    }

    // MARK: The next screen

    /// The steps this photo could show are done, and the task goes on: look at where the user is now.
    private func nextScreen() {
        guard let plan else { return }
        guard screensPassed < Self.maxScreens else {
            // Stops here: "No" on the card looks again from where they are.
            screensPassed = 0
            let note = String(localized: "We've come a long way. Did this solve it, or shall I keep going?", bundle: .ui)
            checkTask?.cancel()
            feedback = nil
            reply = note
            phase = .confirming
            speak(note)
            return
        }
        screensPassed += 1
        checkTask?.cancel()
        feedback = nil
        reply = nil
        phase = .thinking
        timings = TaskTimings(setting: settings.sparkLabel)
        let start = plan.steps.count
        if let ready = takePrepared(from: start) {
            if !ready.isReady { acknowledge("") }
            planCapture = ready.capture
            requestPlan(capture: ready.capture, correction: ready.correction, from: start, prepared: ready)
            return
        }
        acknowledge("")
        let correction = Self.continuing(plan)
        task = Task {
            try? await Task.sleep(for: .seconds(Self.screenSettleSeconds))
            await warnOfPhoto()
            if Task.isCancelled { return }
            guard let capture = takePhoto() else {  // tracking is lost, for example the screen went dark
                phase = .guiding
                show(message: String(localized: "The camera isn't ready yet. Point it at the device and try again.", bundle: .ui))
                return
            }
            planCapture = capture
            requestPlan(capture: capture, correction: correction, from: start)
        }
    }

    private static func continuing(_ plan: GuidePlan) -> GuideClient.Correction {
        GuideClient.Correction(kind: "continue", wrongStep: "", said: plan.remaining ?? "", done: plan.steps.map(\.instruction))
    }

    /// The last step passed and the task goes on: start on the next screen now, while the user reads the check.
    private func prepareNextScreen() {
        discardPrepared()
        guard let plan, plan.goesOn, stepIndex == plan.steps.count - 1, screensPassed < Self.maxScreens else { return }
        let index = stepIndex
        prepareTask = Task {
            await warnOfPhoto()
            guard !Task.isCancelled, index == stepIndex, feedback == .correct, let capture = takePhoto() else { return }
            let waiting = PreparedPlan(capture: capture, correction: Self.continuing(plan), start: plan.steps.count)
            let text = taskQuestion, answers = self.answers, findings = self.findings, shows = self.shows, settings = self.settings
            let language = self.language.serverName
            waiting.task = Task {
                defer { waiting.finished() }
                return try await send {
                    try await $0.plan(jpeg: capture.jpeg, question: text, language: language, autoLanguage: settings.isAutomaticLanguage,
                                      record: settings.record, camera: capture.cameraInfo, spark: settings.sparkChoice, answers: answers,
                                      correction: waiting.correction, allowQuestions: false, findings: findings, shows: shows) { steps in
                        waiting.received(steps: steps)
                    }
                }
            }
            prepared = waiting
        }
    }

    /// The prepared plan if it fits this screen and still stands; one that doesn't is dropped and the camera looks again.
    private func takePrepared(from start: Int) -> PreparedPlan? {
        prepareTask?.cancel()
        guard let waiting = prepared else { return nil }
        prepared = nil
        if waiting.start == start, let now = ar.cameraTransform {
            let change = PreparedPlan.change(from: waiting.capture.cameraTransform, to: now)
            if PreparedPlan.isFresh(age: Date().timeIntervalSince(waiting.asked), moved: change.moved, turned: change.turned) {
                return waiting
            }
        }
        waiting.task?.cancel()
        return nil
    }

    private func discardPrepared() {
        prepareTask?.cancel()
        prepared?.task?.cancel()
        prepared = nil
    }

    // MARK: Is the problem solved?

    func confirmSolved() {
        guard phase == .confirming else { return }
        let line = language.phrase("Done. It should be working now.")
        finish()
        finishLine = line
        note("solved")
        sound(.done)
        speak(line)
    }

    /// The completion card's way back: the check can pass on a cached page, and only the user knows it's still broken.
    func problemContinues() {
        guard phase == .finished, !unsolved else { return }
        finishLine = nil
        finishedAt = nil
        phase = .confirming
        notSolved()
    }

    func notSolved() {
        guard phase == .confirming else { return }
        checkTask?.cancel()
        goalCheck = nil
        note("not_solved")
        guard outcomeTries < Self.maxOutcomeTries else {
            finishUnsolved(note: "")
            return
        }
        tellWhatIsWrong(kind: "outcome")
    }

    private func finishUnsolved(note text: String) {
        unsolved = true
        finish()
        note("gave_up")
        sound(.notSolved)
        speak(text.isEmpty ? language.phrase("I couldn't solve this. Check the device's manual or contact service.") : text)
    }

    private func finish() {
        checkTask?.cancel()
        discardPrepared()
        correcting = nil
        reply = nil
        phase = .finished
        feedback = nil
        finishedAt = Date()
        ar.currentStep = nil
        ar.taskEnded()
    }

    private func note(_ kind: String) {
        Task { try? await send { try await $0.noteCorrection(kind: kind) } }
    }

    // MARK: Corrections

    /// "Re-evaluate": one tap, no choices. Nova looks at the step again from a new frame: it locates the control again,
    /// plans again if the step doesn't fit, or says what it can't tell.
    func reassess() {
        reassess(markerWrong: false)
    }

    /// "Wrong spot": the mistake is Kokobubu's, so it looks again and moves the marker itself. Only after that has
    /// failed twice can the user show the place by hand.
    func wrongSpot() {
        reassess(markerWrong: true)
    }

    var canShowByHand: Bool { (wrongSpots[stepIndex] ?? 0) >= 2 }

    private func reassess(markerWrong: Bool) {
        discardPrepared()
        guard phase == .guiding, !reassessing, !isLocating, let step = currentStep else { return }
        checkTask?.cancel()
        correcting = nil
        feedback = nil
        reply = nil
        stepDefended = false
        reassessing = true
        speak(language.phrase(nextLookingPhrase()))
        if markerWrong { wrongSpots[stepIndex, default: 0] += 1 }
        let index = stepIndex, context = taskContext(), settings = self.settings
        voiceTask = Task {
            await warnOfPhoto()
            guard !Task.isCancelled, let capture = takePhoto() else {
                reassessing = false
                if !Task.isCancelled { show(message: String(localized: "The camera isn't ready yet. Point it at the device and try again.", bundle: .ui)) }
                return
            }
            let wrongPoint = markerWrong ? ar.markerPoint(step: index, in: capture) : nil
            do {
                let language = self.language.serverName, record = settings.record, spark = settings.sparkChoice
                let review = try await send {
                    try await $0.reassess(jpeg: capture.jpeg, target: step.target, language: language, context: context,
                                          record: record, spark: spark, wrongPoint: wrongPoint)
                }
                reassessing = false
                guard phase == .guiding, index == stepIndex else { return }
                switch review.verdict {
                case .stepOK:
                    if let point = review.point {
                        var located = step
                        located.point = point
                        located.box = review.box
                        located.boxMethod = review.boxMethod
                        located.setTo?.point = nil  // measured on the old frame
                        plan?.steps[index] = located
                        ar.relocate(step: index, to: located, from: capture)
                    }
                    if markerWrong {
                        haptic(.success)
                        sound(.moved)
                    } else {
                        stepDefended = true
                    }
                    failedChecks[index] = 0
                    reply = review.explanation
                    speak(review.explanation)
                case .wrongStep:
                    runCorrection(kind: "step", said: review.explanation)
                case .unsure:
                    reply = review.explanation
                    speak(review.explanation)
                }
            } catch {
                reassessing = false
                reply = error.localizedDescription
            }
        }
    }

    func openCorrection() {
        guard phase == .guiding else { return }
        discardPrepared()
        checkTask?.cancel()
        speaker.stop()
        correcting = .menu
    }

    func closeCorrection() {
        correcting = nil
        if recorder.isRecording {
            discardRecording = true
            recorder.finish()
        }
    }

    func startMovingMarker() {
        correcting = .moving
        speak(language.phrase("Tap the right control on the screen."))
    }

    /// The user tapped the control the marker should have been on; no model call.
    func markerTapped(at point: CGPoint) {
        guard correcting == .moving else { return }
        correcting = nil
        guard ar.moveMarker(step: stepIndex, toScreen: point) else {
            show(message: String(localized: "The camera isn't ready yet. Point it at the device and try again.", bundle: .ui))
            return
        }
        haptic(.success)
        sound(.moved)
        reply = String(localized: "Marker moved.", bundle: .ui)
        Task { try? await send { try await $0.noteCorrection(kind: "moved") } }
    }

    func explainMore() {
        correcting = nil
        askDuringTask("Explain the current step in more detail: where exactly the control is, how to move it, and what I should see when it is done.",
                      correction: "detail")
    }

    /// "This step is wrong" and "Start over": the microphone opens because the user just tapped; words are optional.
    func tellWhatIsWrong(kind: String) {
        correcting = .telling(kind: kind)
        skipWords = false
        microphoneTapped()
    }

    func lookAgainWithoutWords() {
        guard case .telling(let kind) = correcting else { return }
        if recorder.isRecording {
            skipWords = true
            recorder.finish()
        } else {
            runCorrection(kind: kind, said: "")
        }
    }

    private func runCorrection(kind: String, said: String) {
        correcting = nil
        listening = .idle
        task = Task {
            await warnOfPhoto()
            if Task.isCancelled { return }
            guard let plan, let step = currentStep, let capture = takePhoto() else {
                show(message: String(localized: "The camera isn't ready yet. Point it at the device and try again.", bundle: .ui))
                return
            }
            correct(kind: kind, said: said, plan: plan, step: step, capture: capture)
        }
    }

    private func correct(kind: String, said: String, plan: GuidePlan, step: GuideStep, capture: CapturedFrame) {
        if kind == "outcome" {
            outcomeTries += 1
            answers = []
            findings = []
            shows = 0
            let correction = GuideClient.Correction(kind: kind, wrongStep: "", said: said, done: plan.steps.map(\.instruction))
            pendingCorrection = correction
            planCapture = capture
            phase = .thinking
            timings = TaskTimings(setting: settings.sparkLabel)
            acknowledge(said)
            requestPlan(capture: capture, correction: correction)
            return
        }
        pendingCorrection = nil
        let restart = kind == "restart"
        if restart {
            stepCorrections = [:]
        } else {
            guard canCorrectStep else {
                let note = String(localized: "I'm not sure about this step. Check the device's manual, or use the button below to go on.", bundle: .ui)
                reply = note
                speak(note)
                return
            }
            stepCorrections[stepIndex, default: 0] += 1
        }
        failedChecks[stepIndex] = 0
        unsureChecks[stepIndex] = 0
        let start = restart ? 0 : stepIndex
        let done = restart ? [] : plan.steps.prefix(start).map(\.instruction)
        checkTask?.cancel()
        feedback = nil
        reply = nil
        planCapture = capture
        phase = .thinking
        timings = TaskTimings(setting: settings.sparkLabel)
        acknowledge(said)
        requestPlan(capture: capture,
                    correction: GuideClient.Correction(kind: kind, wrongStep: step.instruction, said: said, done: done),
                    from: start)
    }

    private func cycleStatus() async {
        let lines = [
            String(localized: "Working out what this is…", bundle: .ui),
            String(localized: "Planning the steps…", bundle: .ui),
            String(localized: "Finding the controls…", bundle: .ui),
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
        guard !isLocating else { return }
        switch feedback {
        case .checking: return
        case .correct: next()
        case .unsure where userLeadsCheck: mark(.confirmed)
        case .confirmDial: mark(.confirmed)
        case .notDone, .unsure, .error: done()  // check again
        case nil: done()
        }
    }

    /// Two checks couldn't tell: going on becomes the main action, so the user isn't stuck on the step.
    var userLeadsCheck: Bool { (unsureChecks[stepIndex] ?? 0) >= 2 }

    /// The step card's second button, shown after a check that didn't pass.
    func secondary() {
        switch feedback {
        case .unsure:
            if userLeadsCheck { done() } else { mark(.confirmed) }
        case .notDone, .error: mark(.skipped)
        case .confirmDial: done()  // look again
        default: break
        }
    }

    /// The user says the step is done: check it on a close-up of the control, or on the whole device when the result
    /// shows elsewhere or a close-up couldn't tell.
    func done() {
        guard let step = currentStep, feedback != .checking, !isLocating else { return }
        guard settings.verifyEach else {
            mark(.confirmed)
            return
        }
        guard step.isVerifiable else {
            stepLead = language.phrase("Okay, next step.")
            mark(.unchecked)
            return
        }
        feedback = .checking
        reply = nil
        let index = stepIndex
        checkTask = Task {
            await warnOfPhoto()
            guard !Task.isCancelled, index == stepIndex else { return }
            look(at: step)
        }
    }

    private func look(at step: GuideStep) {
        if step.checksWholeView || (unsureChecks[stepIndex] ?? 0) > 0 {
            guard let capture = takePhoto() else {
                say(.unsure(language.phrase("Hold the phone steady, then check again.")))
                return
            }
            check(step, jpeg: capture.jpeg, wholeView: true)
            return
        }
        switch ar.closeUp(step: stepIndex) {
        case .offScreen:
            say(.unsure(language.phrase("Point the camera at the control, then check again.")))
        case .tooSmall:
            say(.unsure(language.phrase("Move the phone closer to the control, then check again.")))
        case .notReady:
            say(.unsure(language.phrase("Hold the phone steady, then check again.")))
        case .jpeg(let jpeg):
            if settings.depthScan { ar.flashDepthMesh() }
            check(step, jpeg: jpeg, wholeView: false)
        }
    }

    private func check(_ step: GuideStep, jpeg: Data, wholeView: Bool) {
        feedback = .checking
        reply = nil
        let index = stepIndex, settings = self.settings
        checkTask = Task {
            do {
                let language = self.language.serverName, record = settings.record
                let spark = settings.sparkChoice, started = Date(), task = question
                let check = try await send {
                    try await $0.verify(jpeg: jpeg, step: step, language: language, record: record, spark: spark,
                                        wholeView: wholeView, task: task)
                }
                guard !Task.isCancelled, index == stepIndex else { return }
                timings.check = Date().timeIntervalSince(started)
                timings.setting = settings.sparkLabel
                apply(check, to: index)
            } catch is CancellationError {
            } catch {
                guard index == stepIndex else { return }
                feedback = .error(error.localizedDescription)
            }
        }
    }

    private func apply(_ check: StepCheck, to index: Int) {
        records[index].observed = check.observed
        switch check.status {
        case .done:
            records[index].result = .verified
            let ready = Self.readyPhrase(after: lastReadyPhrase)
            lastReadyPhrase = ready
            let line = Self.doneLine(confirmation: check.confirmation, ready: ready,
                                     stepsLeft: (plan?.steps.count ?? 0) - index - 1, goesOn: plan?.goesOn ?? false,
                                     phrase: language.phrase)
            doneText = line
            say(.correct, line: line)
            prepareNextScreen()
            guard settings.autoContinue else { return }
            checkTask = Task {
                try? await Task.sleep(for: .seconds(Self.autoContinueSeconds))
                if !Task.isCancelled, index == stepIndex, feedback == .correct { next() }
            }
        case .notDone, .unsure, .inProgress:
            // A dial's pointer is often a small mark on the rim, and Spark misreads it on a setting that is right. A red
            // failure would be wrong there, so the user is asked instead. A photo too small to read says so as before.
            if let label = plan?.steps[index].setTo?.label, check.reason != "too_small" {
                records[index].result = .uncertain
                let question = language.phrase("I can't read it clearly. Is the pointer on %@? Hold the phone straight in front of the dial.")
                say(.confirmDial(question.replacingOccurrences(of: "%@", with: "«\(label)»")))
                return
            }
            applyMiss(check, to: index)
        }
    }

    private func applyMiss(_ check: StepCheck, to index: Int) {
        switch check.status {
        case .done: break
        case .notDone:
            records[index].result = .failed
            let correction = check.correction.isEmpty
                ? String(localized: "Not yet. Check the marker and try again.", bundle: .ui) : check.correction
            failedChecks[index, default: 0] += 1
            // A second miss stays on the step, in a softer voice.
            let retry = failedChecks[index, default: 0] > 1
            say(.notDone(retry ? language.phrase("No problem, let's try again.") + " " + correction : correction))
            if seemsStuck { speak(correction + " " + language.phrase("We seem stuck. Shall I look at this again?")) }
        case .unsure, .inProgress:
            records[index].result = .uncertain
            unsureChecks[index, default: 0] += 1
            say(.unsure(check.reason == "too_small"
                ? String(localized: "Move the phone closer to the control, then check again.", bundle: .ui)
                : String(localized: "I can't see it clearly. Hold the phone still, move closer, or confirm it yourself.", bundle: .ui)))
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

    private func say(_ feedback: Feedback, line: String? = nil) {
        self.feedback = feedback
        switch feedback {
        case .correct:
            haptic(.success)
            sound(.correct)
            speak(line ?? language.phrase("Okay."))
        case .notDone(let text):
            haptic(.error)
            sound(.wrong)
            speak(text)
        case .unsure(let text):
            haptic(.warning)
            sound(.wrong)
            speak(text)
        case .confirmDial(let text):
            sound(.question)
            speak(text)
        case .checking, .error: break
        }
    }

    func next() {
        guard let plan else { return }
        if stepIndex + 1 < plan.steps.count {
            go(to: stepIndex + 1)
        } else if plan.goesOn {
            nextScreen()
        } else {
            checkTask?.cancel()
            feedback = nil
            reply = nil
            phase = .confirming
            goalCheck = nil
            if settings.verifyEach, plan.goal?.isEmpty == false {
                checkGoal()
            } else {
                askIfSolved()
            }
        }
    }

    private func askIfSolved() {
        sound(.question)
        speak(language.phrase("Did this solve it?"))
    }

    /// The camera looks for the task's end state. Only a clear "done" ends the task without asking.
    func checkGoal() {
        guard phase == .confirming, goalCheck != .checking, let goal = plan?.goal, !goal.isEmpty else { return }
        goalCheck = .checking
        reply = nil
        let settings = self.settings, task = question.isEmpty ? goal : question
        checkTask = Task {
            await warnOfPhoto()
            if Task.isCancelled { return }
            guard let capture = takePhoto() else {
                goalCheck = .unclear
                reply = language.phrase("Hold the phone steady, then check again.")
                return
            }
            do {
                let language = self.language.serverName, record = settings.record, spark = settings.sparkChoice
                let check = try await send {
                    try await $0.verifyGoal(jpeg: capture.jpeg, task: task, goal: goal, language: language, record: record,
                                            spark: spark)
                }
                guard !Task.isCancelled, phase == .confirming else { return }
                applyGoal(check)
            } catch is CancellationError {
            } catch {
                guard phase == .confirming else { return }
                goalCheck = .unclear
                askIfSolved()
            }
        }
    }

    private func applyGoal(_ check: StepCheck) {
        switch check.status {
        case .done:
            goalCheck = nil
            let line = check.confirmation?.isEmpty == false ? check.confirmation! : language.phrase("Done. It should be working now.")
            finish()
            finishLine = line
            note("solved")
            sound(.done)
            speak(line)
        case .inProgress:
            goalCheck = .waiting
            let line = language.phrase("It's still working. When it finishes, point the camera here and check again.")
            reply = line
            speak(line)
        case .notDone where !check.correction.isEmpty && goalMiss == nil && screensPassed < Self.maxScreens:
            // It says what to do, so it shows where: a new step with its marker, not a sentence on the card.
            goalCheck = nil
            goalMiss = check.correction
            plan?.remaining = check.correction
            nextScreen()
        case .notDone, .unsure:
            goalCheck = .unclear
            let line = check.correction.isEmpty ? language.phrase("I can't confirm the result from here.") : check.correction
            reply = line
            sound(.question)
            speak(line + " " + language.phrase("Did this solve it?"))
        }
    }

    /// Back one step; from the first step, back to the question with the same thing in view.
    func back() {
        discardPrepared()
        if phase == .finished || phase == .confirming {
            checkTask?.cancel()
            goalCheck = nil
            finishLine = nil
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
        discardPrepared()
        checkTask?.cancel()
        greeted = false
        awaitingFirstTap = true
        askingAloud = false
        outcomeTries = 0
        screensPassed = 0
        pendingCorrection = nil
        unsolved = false
        finishLine = nil
        correcting = nil
        reassessing = false
        stepDefended = false
        failedChecks = [:]
        unsureChecks = [:]
        wrongSpots = [:]
        goalMiss = nil
        goalCheck = nil
        lastShowRequest = nil
        answers = []
        findings = []
        shows = 0
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
        if askingAloud {  // a tap during the question: no need to hear the rest
            speaker.stop()
            stopAskingThenListen()
        } else if phase == .asking, awaitingFirstTap {
            askBeforeListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        speaker.stop()
        voiceTask = Task {
            guard await VoiceRecorder.requestPermission() else {
                show(message: String(localized: "Allow the microphone in Settings to talk to Kokobubu.", bundle: .ui))
                return
            }
            if settings.soundEffects {  // over before the microphone opens, so it isn't taken for speech
                sounds.play(.micOn)
                try? await Task.sleep(for: .seconds(0.22))
            }
            do {
                startLive()
                try recorder.start()
                listening = .listening
            } catch {
                closeLive()
                show(message: String(localized: "The microphone couldn't start.", bundle: .ui))
            }
        }
    }

    // MARK: Live transcription

    /// The WAV is still recorded: if the live route fails, it goes through the file route.
    private func startLive() {
        closeLive()
        heardSeconds = nil
        heardLive = false
        recorder.silenceSeconds = VoiceRecorder.silenceSeconds
        guard settings.liveTranscription else { return }
        let live = LiveTranscriber()
        self.live = live
        recorder.silenceSeconds = VoiceRecorder.liveSilenceSeconds
        recorder.onPCM = { [weak live] in live?.send(pcm: $0) }
        live.onEvent = { [weak self, weak live] event in
            guard let self, let live, live === self.live else { return }
            switch event {
            case .partial(let words):
                self.liveWords = words
            case .speechEnded:
                self.liveEndedAt = self.liveEndedAt ?? Date()
            case .final(let words):
                guard !words.isEmpty else { return }
                self.liveFinal = words
                self.recorder.finish()  // Meta found the end of the sentence
            case .failed:
                self.closeLive()
            }
        }
        let languages = Array(Set([language.serverName, "English", settings.isAutomaticLanguage ? "Turkish" : "English"]))
        Task {
            do {
                let client = try await send { $0 }
                live.connect(try client.listenTask(), languages: languages)
            } catch {
                live.fail()
            }
        }
    }

    private func closeLive() {
        live?.close()
        live = nil
        recorder.onPCM = nil
        recorder.silenceSeconds = VoiceRecorder.silenceSeconds
        liveFinal = nil
        liveEndedAt = nil
        liveWords = nil
    }

    private func heardRecording(_ wav: Data?) {
        if discardRecording {
            discardRecording = false
            listening = .idle
            closeLive()
            return
        }
        sound(.micOff)
        if case .telling(let kind) = correcting, skipWords {
            skipWords = false
            closeLive()
            runCorrection(kind: kind, said: "")
            return
        }
        let stoppedAt = Date()
        if let live, wav != nil || liveFinal != nil {
            listening = .transcribing
            voiceTask = Task {
                if liveFinal == nil {  // the recorder stopped first: a tap, the backstop or the time limit
                    live.finish()
                    let deadline = Date().addingTimeInterval(2.5)
                    while liveFinal == nil, self.live === live, Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                if let text = liveFinal {
                    heardSeconds = Date().timeIntervalSince(liveEndedAt ?? stoppedAt)
                    heardLive = true
                    closeLive()
                    listening = .idle
                    handle(spoken: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    closeLive()
                    transcribeFile(wav)
                }
            }
            return
        }
        closeLive()
        transcribeFile(wav)
    }

    /// The recording, in one request: the route without live transcription, and the fallback when it fails.
    private func transcribeFile(_ wav: Data?) {
        if case .telling(let kind) = correcting, wav == nil {
            runCorrection(kind: kind, said: "")
            return
        }
        guard let wav else {
            listening = .idle
            show(message: String(localized: "I didn't hear anything. Tap the microphone and speak.", bundle: .ui))
            return
        }
        listening = .transcribing
        let settings = self.settings
        voiceTask = Task {
            do {
                let language = settings.isAutomaticLanguage && !self.language.experimental ? "Turkish" : self.language.serverName
                let started = Date()
                let text = try await send { try await $0.transcribe(wav: wav, language: language) }
                listening = .idle
                heardSeconds = Date().timeIntervalSince(started)
                timings.transcript = heardSeconds
                handle(spoken: text.trimmingCharacters(in: .whitespacesAndNewlines))
                heardSeconds = nil
            } catch {
                listening = .idle
                if case .telling(let kind) = correcting {
                    runCorrection(kind: kind, said: "")
                } else {
                    show(message: error.localizedDescription)
                }
            }
        }
    }

    private func handle(spoken text: String) {
        if case .telling(let kind) = correcting {
            runCorrection(kind: kind, said: text)
            return
        }
        guard !text.isEmpty else {
            show(message: String(localized: "I didn't catch that. Please say it again.", bundle: .ui))
            return
        }
        heard = text
        Task {
            try? await Task.sleep(for: .seconds(5))
            if heard == text { heard = nil }
        }
        let matched = VoiceCommand.matchWithLanguage(text, preferring: language.serverName)
        let command = matched?.command
        heardLanguage(matched?.language)
        switch phase {
        case .thinking:
            return
        case .choosing:
            command == .newQuestion ? newQuestion() : answerQuestion(text)
        case .showing:
            if command == .newQuestion {
                newQuestion()
            } else {
                shown(said: command == .done ? nil : text)
            }
        case .confirming:
            switch VoiceCommand.confirmation(text) {
            case true?: confirmSolved()
            case false?: notSolved()
            case nil:  // they said what happened
                note("not_solved")
                outcomeTries < Self.maxOutcomeTries ? runCorrection(kind: "outcome", said: text) : finishUnsolved(note: "")
            }
        case .guiding:
            switch command {
            case .done: primary()
            case .repeatStep: repeatStep()
            case .back: back()
            case .skip: skip()
            case .newQuestion: newQuestion()
            case .wrong: reassess()
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
    private func askDuringTask(_ text: String, correction: String? = nil) {
        guard plan != nil else {
            show(message: String(localized: "The camera isn't ready yet. Point it at the device and try again.", bundle: .ui))
            return
        }
        let context = taskContext()
        listening = .answering
        let settings = self.settings
        voiceTask = Task {
            await warnOfPhoto()
            guard !Task.isCancelled, let capture = takePhoto() else {
                listening = .idle
                if !Task.isCancelled { show(message: String(localized: "The camera isn't ready yet. Point it at the device and try again.", bundle: .ui)) }
                return
            }
            do {
                // The "more detail" request is written by the app, so its language says nothing about the user's.
                let language = self.language.serverName, auto = settings.isAutomaticLanguage && correction == nil, record = settings.record
                let spark = settings.sparkChoice, started = Date()
                let answer = try await send {
                    try await $0.ask(jpeg: capture.jpeg, question: text, language: language, autoLanguage: auto,
                                     context: context, record: record, spark: spark, correction: correction)
                }
                timings.answer = Date().timeIntervalSince(started)
                timings.setting = settings.sparkLabel
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
                case .wrong:
                    runCorrection(kind: "step", said: text)
                }
            } catch {
                listening = .idle
                show(message: error.localizedDescription)
            }
        }
    }

    private func taskContext() -> GuideClient.TaskContext {
        GuideClient.TaskContext(
            device: plan?.deviceLabel ?? "", current: stepIndex + 1,
            steps: zip(plan?.steps ?? [], records).map { step, record in
                GuideClient.TaskContext.Step(instruction: step.instruction, success: step.success,
                                             result: Self.describe(record.result))
            })
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
        discardPrepared()
        stepDefended = false
        feedback = nil
        reply = nil
        stepIndex = index
        ar.currentStep = index
        sound(.ready)
        if let lead = stepLead, let step = currentStep {
            speak(lead + " " + step.instruction)
        } else {
            repeatStep()
        }
        stepLead = nil
    }

    private func sound(_ effect: SoundEffects.Effect) {
        if settings.soundEffects { sounds.play(effect) }
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
    func holdPhotoNotice() { photoWaits = 1 }

    /// Simulator screenshots only (launch argument `-NovaDemo <screen>`): a fixed plan without the server.
    func loadDemo(_ screen: String, plan: GuidePlan, correction: String) {
        self.plan = plan
        knownDevice = plan.deviceLabel
        records = plan.steps.map { StepRecord(expected: $0.success) }
        startedAt = Date().addingTimeInterval(-192)
        timings = TaskTimings(transcript: 1.9, steps: 3.4, markers: 7.1, check: 1.6, setting: settings.sparkLabel)
        switch screen {
        case "screens":
            stepIndex = 0
            records = plan.steps.map { StepRecord(expected: $0.success) }
            phase = .guiding
        case "confirm":
            phase = .confirming
            stepIndex = plan.steps.count - 1
        case "unsolved":
            stepIndex = plan.steps.count - 1
            unsolved = true
            finishedAt = Date()
            phase = .finished
        case "question":
            self.plan = nil
            phase = .choosing(GuidePlan.Question(kind: "choice", text: "Hangi programı kullanmak istersin?", options: [
                .init(label: "normal", meaning: "Normal günlük çamaşırlar"), .init(label: "delicate", meaning: "Hassas çamaşırlar"),
                .init(label: "heavy duty", meaning: "Ağır kirli çamaşırlar")]))
        case "show":
            self.plan = nil
            phase = .showing(GuidePlan.ShowRequest(what: "Lütfen fareyi yakından gösterin.", why: "Altındaki ışığa ve açma düğmesine bakacağım."))
        case "wrong":
            phase = .guiding
            stepIndex = 1
            correcting = .menu
        case "thinking":
            self.plan = nil
            statusLine = String(localized: "Planning the steps…", bundle: .ui)
            phase = .thinking
        case "guiding", "verified", "correction", "dialconfirm":
            phase = .guiding
            stepIndex = 1
            records[0].result = .verified
            if screen == "verified" {
                records[1].result = .verified
                feedback = .correct
            } else if screen == "correction" {
                records[1].result = .failed
                feedback = .notDone(correction)
            } else if screen == "dialconfirm" {
                records[1].result = .uncertain
                feedback = .confirmDial("Net okuyamadım. İbre «regular soil» üzerinde mi? Telefonu düğmeye tam karşıdan tut.")
            }
        case "finished":
            records = records.enumerated().map { index, record in
                var record = record
                record.result = [.verified, .verified, .confirmed, .unchecked][min(index, 3)]
                return record
            }
            stepIndex = plan.steps.count - 1
            finishedAt = Date()
            finishLine = "Wi-Fi çalışıyor: video listesi yüklendi."
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
