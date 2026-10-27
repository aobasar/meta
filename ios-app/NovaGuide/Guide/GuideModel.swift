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

    @Published var phase: Phase = .asking
    @Published var question = ""
    @Published private(set) var plan: GuidePlan?
    @Published private(set) var stepIndex = 0
    @Published private(set) var statusLine = ""
    @Published private(set) var connection: Connection = .unknown

    let settings: GuideSettings
    let ar: ARGuideController
    private let speaker = Speaker()
    private var task: Task<Void, Never>?

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

    func next() {
        guard let plan else { return }
        if stepIndex + 1 < plan.steps.count {
            go(to: stepIndex + 1)
        } else {
            phase = .finished
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
        speaker.stop()
        ar.clear()
        plan = nil
        stepIndex = 0
        phase = .asking
    }

    private func go(to index: Int) {
        stepIndex = index
        ar.currentStep = index
        repeatStep()
    }

    private func speak(_ text: String) {
        speaker.speak(text, voice: settings.language.voice)
    }
}
