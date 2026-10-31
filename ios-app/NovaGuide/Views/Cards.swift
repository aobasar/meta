import SwiftUI

/// The one card over the camera. It folds to a single line, so the camera can be seen in full while the user works;
/// it shows the microphone or the choices only when Nova is waiting for them.
struct SidePanel: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var settings: GuideSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var land: Bool
    @State private var folded = false
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.2))) private var dragged = CGSize.zero

    var body: some View {
        Group {
            if model.phase == .thinking {
                HStack(spacing: 10) {
                    CardMascot()
                    ThinkingCard()
                }
                .padding(.horizontal, 14).padding(.vertical, 10).sheetStyle()
            } else if model.phase == .finished {
                CompletionCard().padding(14)
                    .overlay(alignment: .topLeading) { CardMascot().padding(10) }
                    .sheetStyle()
            } else {
                if folded, let line = foldedLine {
                    FoldedBar(prefix: line.prefix, title: line.title) { folded = false }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Handle { folded = true }
                            .simultaneousGesture(moving)
                            .accessibilityAction(named: Text("Move the card")) { place(cardPlace.next(land: land)) }
                        ScrollView {
                            content.padding(.bottom, 2)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: land ? 300 : 420)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .overlay(alignment: .topTrailing) { CardMascot().padding(.top, 8).padding(.trailing, 12) }
                    .sheetStyle()
                }
            }
        }
        .offset(dragged)
        .environment(\.colorScheme, .light)
        .animation(.easeOut(duration: 0.2), value: folded)
        .onChange(of: model.phase) { _, _ in folded = false }
        .onChange(of: model.stepIndex) { _, _ in folded = false }
        .onChange(of: model.feedback) { _, feedback in
            if feedback != nil { folded = false }  // the result of a check is always seen
        }
    }

    private var cardPlace: CardPlace { land ? settings.cardLandscape : settings.cardPortrait }

    /// The card follows the finger, then settles in the nearest place. Global, because the handle moves with the card.
    private var moving: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($dragged) { value, state, _ in state = value.translation }
            .onEnded { value in
                switch cardPlace.afterDrag(value.translation, land: land) {
                case .move(let next): place(next)
                case .fold: folded = true
                case .stay: break
                }
            }
    }

    private func place(_ next: CardPlace) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            if land { settings.cardLandscape = next } else { settings.cardPortrait = next }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .asking:
            ReadyCard()
        case .choosing(let asked):
            QuestionCard(asked: asked)
        case .showing(let asked):
            ShowCard(asked: asked)
        case .guiding:
            if let correcting = model.correcting {
                CorrectionCard(correcting: correcting)
            } else if let plan = model.plan, let step = model.currentStep {
                StepCard(step: step, total: plan.steps.count)
            }
        case .confirming:
            if let correcting = model.correcting {
                CorrectionCard(correcting: correcting)
            } else {
                ConfirmCard()
            }
        case .refused(let note), .failed(let note):
            MessageCard(note: note)
        case .thinking, .finished:
            EmptyView()
        }
    }

    private var foldedLine: (prefix: String, title: String)? {
        switch model.phase {
        case .asking:
            return ("", String(localized: "Kokobubu is ready to help.", bundle: .ui))
        case .choosing(let asked):
            return ("", GuideText.display(asked.text))
        case .showing(let asked):
            return ("", GuideText.display(asked.what))
        case .guiding:
            guard model.correcting == nil, let step = model.currentStep else { return nil }
            return (String(localized: "Step \(model.stepIndex + 1)", bundle: .ui), GuideText.display(step.instruction))
        case .confirming:
            return ("", String(localized: "Did this solve it?", bundle: .ui))
        default:
            return nil
        }
    }
}

extension View {
    /// The frosted card: the camera stays visible around it, and light enough to read in a dim room.
    func sheetStyle() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

private struct Handle: View {
    var action: () -> Void

    var body: some View {
        // Not a Button: it moves with the finger, so letting go after a drag would count as a tap on it.
        Capsule().fill(Color.black.opacity(0.22)).frame(width: 38, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text("Hide the card"))
            .accessibilityAction { action() }
    }
}

/// One line with what can't wait: the microphone at the left as on the open card, and at the right the step's main
/// button, or the mascot with the way to open the card.
private struct FoldedBar: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var settings: GuideSettings
    var prefix: String
    var title: String
    var open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MicButton()
            Button(action: open) {
                HStack(spacing: 8) {
                    if !prefix.isEmpty {
                        Text(prefix).font(.footnote.weight(.semibold)).foregroundStyle(Color.sheetMuted)
                    }
                    Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if stepTitle == nil {
                        Image(systemName: "chevron.up").font(.footnote.weight(.bold)).foregroundStyle(Color.sheetMuted)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(Text("Show the card"))
            if let stepTitle {
                Button { model.primary() } label: {
                    Text(stepTitle)
                        .font(.footnote.weight(.bold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.novaYellow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(model.isLocating || model.reassessing)
            } else {
                CardMascot()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .sheetStyle()
    }

    /// The main button's words while a step is on screen. A check's result opens the card, so there is none here.
    private var stepTitle: String? {
        guard model.phase == .guiding, let step = model.currentStep else { return nil }
        return StepCard.doneTitle(step: step, verifyEach: settings.verifyEach, isLastStep: model.isLastStep)
    }
}

/// A secondary button on the light card.
private struct SheetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.horizontal, 8)
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.black.opacity(0.16), lineWidth: 1.5))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The microphone: large while Nova waits for the user to speak, small beside the main button otherwise.
private struct MicButton: View {
    @EnvironmentObject private var model: GuideModel
    var large = false
    @State private var glow = false

    var body: some View {
        Button { model.microphoneTapped() } label: {
            ZStack {
                if large {
                    Circle().fill(listening ? Color.novaRed : Color.novaYellow)
                        .shadow(color: Color.novaYellow.opacity(model.awaitingFirstTap && glow ? 0.9 : 0), radius: 14)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(listening ? Color.novaRed : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.black.opacity(0.16), lineWidth: 1.5))
                }
                if listening {
                    Waveform(recorder: model.recorder)
                } else if model.pulse == .thinking {
                    Orb(size: large ? 24 : 18)
                } else {
                    Image(systemName: "mic").font(.system(size: large ? 26 : 18, weight: .semibold)).foregroundStyle(.black)
                }
            }
            .frame(width: large ? 64 : 44, height: large ? 64 : 44)
            .scaleEffect(large && model.awaitingFirstTap && glow ? 1.08 : 1)
        }
        .disabled(model.pulse == .thinking)
        .accessibilityLabel(Text(listening ? "Listening…" : "Tap and talk"))
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true } }
    }

    private var listening: Bool { model.pulse == .listening }
}

// MARK: Ready

private struct ReadyCard: View {
    @EnvironmentObject private var model: GuideModel
    @State private var typing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(model.awaitingFirstTap ? "Kokobubu is ready to help." : "How can I help you?")
                .font(.headline)
                .multilineTextAlignment(.center)
            MicButton(large: true)
            Text(model.pulse == .listening ? "Listening…" : "Tap and talk").font(.footnote.weight(.semibold))
            if typing {
                TextField(String(localized: "I want a normal wash", bundle: .ui), text: $model.question, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Button(String(localized: "Show me", bundle: .ui), action: send)
                    .buttonStyle(PrimaryButtonStyle(enabled: !isEmpty))
                    .disabled(isEmpty)
            } else if model.pulse != .listening {
                Button(String(localized: "Type instead", bundle: .ui)) {
                    typing = true
                    focused = true
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.sheetMuted)
                .frame(minHeight: 30)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var isEmpty: Bool { model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard !isEmpty else { return }
        focused = false
        typing = false
        model.ask()
    }
}

private struct MessageCard: View {
    @EnvironmentObject private var model: GuideModel
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Bubble(icon: "exclamationmark.triangle.fill", color: .orange, title: nil, text: note)
            Button(String(localized: "Try again", bundle: .ui)) { model.newQuestion() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }
}

// MARK: Nova's question

/// One row: what the device says, and what it means.
private struct ChoiceRow: View {
    var title: String
    var subtitle: String?
    /// The button's color on the device, so it is easy to find.
    var color: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
            if let color { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 7).padding(.vertical, 6) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Color.sheetMuted)
                }
            }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Color.novaYellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.black.opacity(0.12), lineWidth: 1.5))
        }
    }
}

/// "Show me the mouse": the user points the camera there and says so; nothing is sent before that.
private struct ShowCard: View {
    @EnvironmentObject private var model: GuideModel
    var asked: GuidePlan.ShowRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GuideText.display(asked.what)).font(.headline).fixedSize(horizontal: false, vertical: true).clearsMascot()
            if !asked.why.isEmpty {
                Text(GuideText.display(asked.why)).font(.footnote).foregroundStyle(Color.sheetMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                MicButton()
                Button(String(localized: "I'm showing it", bundle: .ui)) { model.shown() }
                    .buttonStyle(PrimaryButtonStyle(fill: .novaYellow))
            }
            Button(String(localized: "I can't show this", bundle: .ui)) { model.cantShow() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.sheetMuted)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
    }
}

private struct QuestionCard: View {
    @EnvironmentObject private var model: GuideModel
    var asked: GuidePlan.Question

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(GuideText.display(asked.text)).font(.headline).fixedSize(horizontal: false, vertical: true).clearsMascot()
            ForEach(asked.options) { option in
                ChoiceRow(title: option.title, subtitle: option.subtitle, color: Color(hex: option.color)) { model.answerQuestion(option.answer) }
            }
            HStack(spacing: 8) {
                Button(String(localized: "You choose", bundle: .ui)) { model.letNovaChoose() }.buttonStyle(SheetButtonStyle())
                MicButton()
            }
        }
    }
}

// MARK: Is it solved?

private struct ConfirmCard: View {
    @EnvironmentObject private var model: GuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.goalCheck == .checking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking the result…").font(.headline)
                }
                .clearsMascot()
            } else {
                choices
            }
        }
    }

    @ViewBuilder private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Did this solve it?").font(.headline).clearsMascot()
            if let reply = model.reply {
                Text(GuideText.display(reply)).font(.footnote).foregroundStyle(Color.sheetMuted).fixedSize(horizontal: false, vertical: true)
            }
            if model.goalCheck == .waiting {
                Button(String(localized: "Check now", bundle: .ui)) { model.checkGoal() }.buttonStyle(PrimaryButtonStyle(fill: .novaYellow))
                Button(String(localized: "Yes, solved", bundle: .ui)) { model.confirmSolved() }.buttonStyle(SheetButtonStyle())
            } else {
                Button(String(localized: "Yes, solved", bundle: .ui)) { model.confirmSolved() }.buttonStyle(PrimaryButtonStyle(fill: .novaGreen))
                if model.goalCheck == .unclear {
                    Button(String(localized: "Check now", bundle: .ui)) { model.checkGoal() }.buttonStyle(SheetButtonStyle())
                }
            }
            HStack(spacing: 8) {
                Button(String(localized: "No, not solved", bundle: .ui)) { model.notSolved() }.buttonStyle(SheetButtonStyle())
                MicButton()
            }
            Button(String(localized: "Back to the last step", bundle: .ui)) { model.back() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.sheetMuted)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
    }
}

// MARK: This is wrong

private struct CorrectionCard: View {
    @EnvironmentObject private var model: GuideModel
    var correcting: GuideModel.Correcting

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch correcting {
            case .menu:
                Text("What's wrong?").font(.headline)
                ChoiceRow(title: String(localized: "It's pointing at the wrong place", bundle: .ui), subtitle: nil) { model.startMovingMarker() }
                ChoiceRow(title: String(localized: "Explain it in more detail", bundle: .ui), subtitle: nil) { model.explainMore() }
                if model.canCorrectStep {
                    ChoiceRow(title: String(localized: "This step is wrong", bundle: .ui), subtitle: nil) { model.tellWhatIsWrong(kind: "step") }
                } else {
                    Text("I'm not sure about this step. Check the device's manual, or use the button below to go on.")
                        .font(.footnote).foregroundStyle(Color.sheetMuted).fixedSize(horizontal: false, vertical: true)
                    ChoiceRow(title: String(localized: "Skip this step", bundle: .ui), subtitle: nil) {
                        model.closeCorrection()
                        model.skip()
                    }
                }
                ChoiceRow(title: String(localized: "Start over", bundle: .ui), subtitle: nil) { model.tellWhatIsWrong(kind: "restart") }
            case .moving:
                Text("Tap the right control on the screen.").font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            case .telling(let kind):
                HStack(spacing: 10) {
                    MicButton()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind == "outcome" ? "What happened?" : "Tell me what's wrong.").font(.headline)
                        Text(kind == "outcome" ? "For example: it still doesn't turn on." : "For example: there is no such button.")
                            .font(.caption).foregroundStyle(Color.sheetMuted)
                    }
                }
                Button(String(localized: "Just look again", bundle: .ui)) { model.lookAgainWithoutWords() }.buttonStyle(PrimaryButtonStyle())
            }
            HStack(spacing: 8) {
                if case .telling("outcome") = correcting {
                    Button(String(localized: "Go back", bundle: .ui)) {
                        model.closeCorrection()
                        model.back()
                    }
                    .buttonStyle(SheetButtonStyle())
                }
                Button(String(localized: "Cancel", bundle: .ui)) { model.closeCorrection() }.buttonStyle(SheetButtonStyle())
            }
        }
    }
}

// MARK: Thinking

private struct ThinkingCard: View {
    @EnvironmentObject private var model: GuideModel
    @State private var askingToStop = false

    var body: some View {
        HStack(spacing: 10) {
            Orb(size: 22)
            Text(model.statusLine).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Button { askingToStop = true } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .foregroundStyle(Color.sheetMuted)
            .accessibilityLabel(String(localized: "Stop", bundle: .ui))
        }
        .alert(String(localized: "Stop and start over?", bundle: .ui), isPresented: $askingToStop) {
            Button(String(localized: "Start over", bundle: .ui), role: .destructive) { model.newTask(keepDevice: true) }
            Button(String(localized: "Keep going", bundle: .ui), role: .cancel) {}
        }
    }
}

// MARK: Step

private struct StepCard: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var settings: GuideSettings
    var step: GuideStep
    var total: Int

    private var index: Int { model.stepIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Step \(index + 1)").font(.caption.weight(.bold)).foregroundStyle(Color.sheetMuted)
                HStack(spacing: 3) {
                    ForEach(model.records.indices, id: \.self) { i in
                        Capsule().fill(segmentColor(i)).frame(height: 4)
                    }
                }
                .clearsMascot()
                .accessibilityHidden(true)
            }
            Text(GuideText.display(step.instruction))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if step.motionKind != nil || step.setTo != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let motion = step.motionKind {
                        Label(motion.title, systemImage: motion.symbol)
                    }
                    if let setTo = step.setTo {
                        Text(verbatim: setTo.meaning.isEmpty ? setTo.label : "\(setTo.label) = \(setTo.meaning)")
                    }
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(.blue)
            }
            if let detail = step.detail, !detail.isEmpty, resultBox == nil, model.reply == nil {
                Text(GuideText.display(detail)).font(.footnote).foregroundStyle(Color.sheetMuted).fixedSize(horizontal: false, vertical: true)
            }
            if let remaining = model.plan?.remaining, !remaining.isEmpty, index + 1 == total {
                Text("Next: \(GuideText.display(remaining))").font(.caption).foregroundStyle(Color.sheetMuted).lineLimit(2)
            }
            if let reply = model.reply {
                Bubble(icon: "bubble.left", color: .blue, title: nil, text: reply)
            }
            if let box = resultBox {
                Bubble(icon: box.icon, color: box.color, title: box.title, text: box.text)
            }
            if model.seemsStuck {
                Bubble(icon: "arrow.triangle.2.circlepath", color: .orange, title: nil,
                       text: String(localized: "We seem stuck. Shall I look at this again?", bundle: .ui))
            }
            if index == 0 && resultBox == nil {
                Text("AI-generated guidance. Check before you press.").font(.caption2).foregroundStyle(Color.sheetMuted).lineLimit(2)
            }
            HStack(spacing: 8) {
                MicButton()
                Button { model.primary() } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(.black) }
                        Text(primaryTitle)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(fill: model.feedback == .correct ? .novaGreen : .novaYellow))
                .disabled(busy)
            }
            let extras = extraButtons
            if !extras.isEmpty {
                HStack(spacing: 8) {
                    ForEach(extras, id: \.title) { extra in
                        Button(extra.title, action: extra.action).buttonStyle(SheetButtonStyle())
                    }
                }
            }
        }
    }

    private var busy: Bool { model.feedback == .checking || model.isLocating || model.reassessing }

    /// Shown only when something went wrong; everything else is in the ⋯ menu.
    private var extraButtons: [(title: String, action: () -> Void)] {
        var buttons: [(title: String, action: () -> Void)] = []
        if model.seemsStuck { buttons.append((String(localized: "Re-evaluate", bundle: .ui), { model.reassess() })) }
        if model.stepDefended { buttons.append((String(localized: "Still wrong", bundle: .ui), { model.openCorrection() })) }
        if let secondary = secondaryTitle { buttons.append((secondary, { model.secondary() })) }
        return buttons
    }

    private func segmentColor(_ i: Int) -> Color {
        let result = model.records[i].result
        if i == index && result == .pending { return .novaYellow }
        return result == .pending ? Color.black.opacity(0.14) : StepCardColors.color(result)
    }

    private var resultBox: (icon: String, color: Color, title: String?, text: String)? {
        switch model.feedback {
        case .correct: ("checkmark", .green, model.doneText.map(GuideText.display) ?? String(localized: "Verified.", bundle: .ui), "")
        case .notDone(let text): ("xmark", .red, nil, text)
        case .unsure(let text): ("questionmark.circle", .orange, nil, text)
        case .error(let text): ("exclamationmark.triangle", .orange, nil, text)
        case .checking, nil: nil
        }
    }

    private var primaryTitle: String {
        if model.isLocating { return String(localized: "Finding the control…", bundle: .ui) }
        if model.reassessing { return String(localized: "Looking again…", bundle: .ui) }
        switch model.feedback {
        case .checking: return String(localized: "Checking…", bundle: .ui)
        case .correct: return model.isLastStep ? String(localized: "Finish", bundle: .ui) : String(localized: "Continue →", bundle: .ui)
        case .notDone, .error: return String(localized: "Check again", bundle: .ui)
        case .unsure:
            if model.userLeadsCheck { return String(localized: "I did it, continue →", bundle: .ui) }
            return (model.unsureChecks[index] ?? 0) > 0 ? String(localized: "Check again", bundle: .ui) : String(localized: "Show closer", bundle: .ui)
        case nil:
            return Self.doneTitle(step: step, verifyEach: settings.verifyEach, isLastStep: model.isLastStep)
        }
    }

    static func doneTitle(step: GuideStep, verifyEach: Bool, isLastStep: Bool) -> String {
        if step.isVerifiable && verifyEach { return String(localized: "I've done it →", bundle: .ui) }
        return isLastStep ? String(localized: "Finish", bundle: .ui) : String(localized: "Continue →", bundle: .ui)
    }

    private var secondaryTitle: String? {
        switch model.feedback {
        case .notDone, .error: String(localized: "Skip, I did it", bundle: .ui)
        case .unsure: model.userLeadsCheck ? String(localized: "Check again", bundle: .ui) : String(localized: "I did it, confirm", bundle: .ui)
        default: nil
        }
    }
}

private struct Bubble: View {
    var icon: String
    var color: Color
    var title: String?
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).foregroundStyle(color).font(.footnote.weight(.bold)).padding(.top, 1)
            (Text(title.map { $0 + (text.isEmpty ? "" : " ") } ?? "").bold() + Text(GuideText.display(text)))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Completion

struct CompletionCard: View {
    @EnvironmentObject private var model: GuideModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: model.unsolved ? "exclamationmark" : "checkmark")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(model.unsolved ? Color.orange : Color.green)
            Text(model.unsolved ? "Not solved" : "Task completed").font(.headline)
            if model.unsolved {
                Text("I couldn't solve this. Check the device's manual or contact service.")
                    .font(.footnote).foregroundStyle(Color.sheetMuted).multilineTextAlignment(.center)
            }
            Text(verbatim: summary).font(.caption.monospacedDigit()).foregroundStyle(Color.sheetMuted).multilineTextAlignment(.center)
            Button(String(localized: "New task here", bundle: .ui)) { model.newTask(keepDevice: true) }
                .buttonStyle(PrimaryButtonStyle())
            Button(String(localized: "Something else", bundle: .ui)) { model.newTask(keepDevice: false) }
                .buttonStyle(SheetButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    /// "Maytag · washing machine · 4/4 · 3:12"
    private var summary: String {
        let done = model.records.filter { $0.result != .pending }.count
        let seconds = model.startedAt.map { max(Int((model.finishedAt ?? Date()).timeIntervalSince($0)), 0) } ?? 0
        return ([model.knownDevice, "\(done)/\(model.records.count)", String(format: "%d:%02d", seconds / 60, seconds % 60)] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Step result colors and names, shared by the step card's progress bar and the completion summary.
enum StepCardColors {
    static func color(_ result: GuideModel.StepRecord.Result) -> Color {
        switch result {
        case .verified: .novaGreen
        case .failed: .novaRed
        case .uncertain: .novaOrange
        case .confirmed: .novaCyan
        case .unchecked, .skipped: Color(white: 0.56)
        case .pending: .novaLine
        }
    }

    static func label(_ result: GuideModel.StepRecord.Result) -> String {
        switch result {
        case .verified: String(localized: "verified", bundle: .ui)
        case .confirmed: String(localized: "you confirmed", bundle: .ui)
        case .unchecked: String(localized: "can't be checked", bundle: .ui)
        case .skipped: String(localized: "skipped", bundle: .ui)
        case .pending, .failed, .uncertain: String(localized: "pending", bundle: .ui)
        }
    }
}
