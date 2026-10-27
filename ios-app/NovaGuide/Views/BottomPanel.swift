import SwiftUI

/// The bottom of the screen: the question bar, the thinking status, the step card, or a message.
struct BottomPanel: View {
    @EnvironmentObject private var model: GuideModel

    var body: some View {
        Group {
            switch model.phase {
            case .asking:
                QuestionBar()
            case .thinking:
                Card {
                    HStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text(model.statusLine).font(.title3.weight(.semibold))
                        Spacer()
                        Button(String(localized: "Cancel")) { model.cancel() }.buttonStyle(.bordered)
                    }
                }
            case .guiding:
                if let plan = model.plan, let step = model.currentStep {
                    StepCard(step: step, index: model.stepIndex, total: plan.steps.count)
                }
            case .finished:
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                        Text("Ready.").font(.title.weight(.bold))
                        Spacer()
                        Button(String(localized: "Back")) { model.back() }.buttonStyle(.bordered)
                        Button(String(localized: "New question")) { model.newQuestion() }.buttonStyle(.borderedProminent)
                    }
                }
            case .refused(let note), .failed(let note):
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
                        Text(note).font(.title3).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(String(localized: "Try again")) { model.newQuestion() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .frame(maxWidth: 760)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct QuestionBar: View {
    @EnvironmentObject private var model: GuideModel
    @FocusState private var focused: Bool

    private let suggestions = [
        String(localized: "I want a normal wash"),
        String(localized: "How does this device work?"),
    ]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if !focused {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                model.question = suggestion
                                model.ask()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                HStack(spacing: 10) {
                    TextField(String(localized: "What do you want to do?"), text: $model.question)
                        .font(.title3)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit { model.ask() }
                    Button {
                        focused = false
                        model.ask()
                    } label: {
                        Label(String(localized: "Show me"), systemImage: "hand.point.up.left.fill")
                            .font(.title3.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .foregroundStyle(.black)
                    .disabled(model.question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct StepCard: View {
    @EnvironmentObject private var model: GuideModel
    var step: GuideStep
    var index: Int
    var total: Int

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Step \(index + 1) / \(total)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.yellow)
                    Spacer()
                    Text("AI-generated guidance. Check before you press.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(step.instruction)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { model.back() } label: { Label(String(localized: "Back"), systemImage: "chevron.left") }
                        .buttonStyle(.bordered)
                        .disabled(index == 0)
                    Button { model.repeatStep() } label: { Label(String(localized: "Repeat"), systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(.bordered)
                    Button { model.newQuestion() } label: { Label(String(localized: "New question"), systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { model.next() } label: {
                        Text(index + 1 == total ? String(localized: "Finish") : String(localized: "Done"))
                            .font(.title3.weight(.bold))
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .foregroundStyle(.black)
                    .controlSize(.large)
                }
            }
        }
    }
}
