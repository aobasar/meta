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

    let settings: GuideSettings
    let ar: ARGuideController
    private let speaker = Speaker()
    private var task: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?

    init(settings: GuideSettings, ar: ARGuideController) {
        self.settings = settings
        self.ar = ar
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
        records = []
        speaker.stop()
        ar.clear()
        plan = nil
        stepIndex = 0
        phase = .asking
    }

    private func go(to index: Int) {
        checkTask?.cancel()
        feedback = nil
        stepIndex = index
        ar.currentStep = index
        repeatStep()
    }

    private func speak(_ text: String) {
        speaker.speak(text, voice: settings.language.voice)
    }
}
