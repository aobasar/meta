import SwiftUI

/// What sits beside (landscape) or under (portrait) the camera: Pulse in portrait, then the card for the phase.
struct SidePanel: View {
    @EnvironmentObject private var model: GuideModel
    var land: Bool

    var body: some View {
        VStack(spacing: 10) {
            if !land && model.phase != .finished {
                PulseButton()
            }
            switch model.phase {
            case .asking:
                scrolling { ReadyCard(land: land) }
            case .thinking:
                ThinkingCard().cardStyle(land: land)
                if land { Spacer(minLength: 0) }
            case .choosing(let asked):
                scrolling { QuestionCard(asked: asked) }
            case .guiding:
                if let correcting = model.correcting {
                    scrolling { CorrectionCard(correcting: correcting) }
                } else if let plan = model.plan, let step = model.currentStep {
                    StepCard(step: step, total: plan.steps.count, land: land)
                        .cardStyle(land: land)
                        .frame(maxHeight: land ? .infinity : nil)
                }
            case .refused(let note), .failed(let note):
                scrolling { MessageCard(note: note) }
            case .confirming:
                if let correcting = model.correcting {
                    scrolling { CorrectionCard(correcting: correcting) }
                } else {
                    scrolling { ConfirmCard() }
                }
            case .finished:
                if land { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, land ? 12 : 0)
        .padding(.vertical, land ? 14 : 0)
        .frame(maxHeight: land ? .infinity : nil, alignment: .top)
    }

    /// Landscape cards scroll inside the column (the keyboard takes most of the height); portrait cards just stack.
    @ViewBuilder private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if land {
            ScrollView { content().cardStyle(land: true) }.scrollDismissesKeyboard(.interactively)
        } else {
            content().cardStyle(land: false)
        }
    }
}

private struct NovaCardModifier: ViewModifier {
    var land: Bool

    func body(content: Content) -> some View {
        if land {
            content.padding(4)  // flat on the column: no box in a box
        } else {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.novaCard.opacity(0.95), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

extension View {
    func cardStyle(land: Bool) -> some View { modifier(NovaCardModifier(land: land)) }
}

// MARK: Ready

private struct ReadyCard: View {
    @EnvironmentObject private var model: GuideModel
    var land: Bool
    @State private var typing = false
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        [String(localized: "How does this work?", bundle: .ui), String(localized: "Show me step by step", bundle: .ui)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.awaitingFirstTap ? "Nova is ready to help." : "How can I help you?").font(.title3.weight(.bold))
                Text("Tap Pulse and say it, or pick one.").font(.footnote).foregroundStyle(Color.novaText3)
            }
            VStack(spacing: 10) {
                if !(land && typing) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            model.question = suggestion
                            model.ask()
                        } label: {
                            HStack {
                                Text(suggestion).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.novaYellow)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .background(Color.novaYellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.novaLine))
                        }
                    }
                }
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { typing.toggle() }
                    focused = typing
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "keyboard")
                        Text("Type instead").frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: typing ? "chevron.up" : "chevron.down").foregroundStyle(Color.novaText3)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(white: 0.9))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(typing ? Color.novaYellow : Color.novaLine))
                }
                .accessibilityAddTraits(typing ? .isSelected : [])
            }
            if typing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Type your question").font(.caption).foregroundStyle(Color.novaText3)
                    TextField(String(localized: "I want a normal wash", bundle: .ui), text: $model.question, axis: .vertical)
                        .lineLimit(2...3)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(send)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.novaRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.novaLine))
                    // Stays readable when there is nothing to send yet (the old button disappeared when disabled).
                    Button(String(localized: "Show me", bundle: .ui), action: send)
                        .buttonStyle(PrimaryButtonStyle(enabled: !isEmpty))
                        .disabled(isEmpty)
                }
                .transition(.opacity)
            }
        }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.novaOrange)
                Text(GuideText.display(note)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.body.weight(.semibold))
            Button(String(localized: "Try again", bundle: .ui)) { model.newQuestion() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }
}

// MARK: Nova's question

/// One big row: what the device says, and what it means.
private struct ChoiceRow: View {
    var title: String
    var subtitle: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.novaYellow)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Color.novaText2)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Color.novaYellow)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .background(Color.novaYellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.novaLine))
        }
    }
}

private struct QuestionCard: View {
    @EnvironmentObject private var model: GuideModel
    var asked: GuidePlan.Question

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(GuideText.display(asked.text)).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(asked.options) { option in
                        ChoiceRow(title: option.title, subtitle: option.subtitle) { model.answerQuestion(option.answer) }
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack(spacing: 8) {
                Button(String(localized: "You choose", bundle: .ui)) { model.letNovaChoose() }.buttonStyle(OutlineButtonStyle())
                Button(String(localized: "Something else", bundle: .ui)) { model.microphoneTapped() }.buttonStyle(OutlineButtonStyle())
            }
        }
    }
}

// MARK: Is it solved?

private struct ConfirmCard: View {
    @EnvironmentObject private var model: GuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Did this solve it?").font(.title3.weight(.bold))
            if let reply = model.reply {
                Text(GuideText.display(reply)).font(.footnote).foregroundStyle(Color.novaText2).fixedSize(horizontal: false, vertical: true)
            }
            Button(String(localized: "Yes, solved", bundle: .ui)) { model.confirmSolved() }.buttonStyle(PrimaryButtonStyle(fill: .novaGreen))
            Button(String(localized: "No, not solved", bundle: .ui)) { model.notSolved() }.buttonStyle(OutlineButtonStyle())
            Button(String(localized: "Back to the last step", bundle: .ui)) { model.back() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.novaText2)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
    }
}

// MARK: This is wrong

private struct CorrectionCard: View {
    @EnvironmentObject private var model: GuideModel
    var correcting: GuideModel.Correcting

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch correcting {
            case .menu:
                Text("What's wrong?").font(.title3.weight(.bold))
                ChoiceRow(title: String(localized: "It's pointing at the wrong place", bundle: .ui), subtitle: nil) { model.startMovingMarker() }
                ChoiceRow(title: String(localized: "Explain it in more detail", bundle: .ui), subtitle: nil) { model.explainMore() }
                if model.canCorrectStep {
                    ChoiceRow(title: String(localized: "This step is wrong", bundle: .ui), subtitle: nil) { model.tellWhatIsWrong(kind: "step") }
                } else {
                    Text("I'm not sure about this step. Check the device's manual, or skip it.")
                        .font(.footnote).foregroundStyle(Color.novaText2).fixedSize(horizontal: false, vertical: true)
                    ChoiceRow(title: String(localized: "Skip this step", bundle: .ui), subtitle: nil) {
                        model.closeCorrection()
                        model.skip()
                    }
                }
                ChoiceRow(title: String(localized: "Start over", bundle: .ui), subtitle: nil) { model.tellWhatIsWrong(kind: "restart") }
            case .moving:
                Text("Tap the right control on the screen.").font(.headline).fixedSize(horizontal: false, vertical: true)
            case .telling(let kind):
                if kind == "outcome" {
                    Text("What happened?").font(.title3.weight(.bold))
                    Text("For example: it still doesn't turn on.").font(.footnote).foregroundStyle(Color.novaText2)
                } else {
                    Text("Tell me what's wrong.").font(.title3.weight(.bold))
                    Text("For example: there is no such button.").font(.footnote).foregroundStyle(Color.novaText2)
                }
                Button(String(localized: "Just look again", bundle: .ui)) { model.lookAgainWithoutWords() }.buttonStyle(PrimaryButtonStyle())
            }
            Button(String(localized: "Cancel", bundle: .ui)) { model.closeCorrection() }.buttonStyle(OutlineButtonStyle())
        }
    }
}

// MARK: Thinking

private struct ThinkingCard: View {
    @EnvironmentObject private var model: GuideModel

    var body: some View {
        HStack(spacing: 14) {
            Orb(size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.statusLine).font(.headline)
                Text("No need to hold the phone still.").font(.caption).foregroundStyle(Color.novaText2)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Step

private struct StepCard: View {
    @EnvironmentObject private var model: GuideModel
    @EnvironmentObject private var settings: GuideSettings
    var step: GuideStep
    var total: Int
    var land: Bool
    @State private var nudge = false

    private var index: Int { model.stepIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: land ? 8 : 10) {
            HStack(spacing: 8) {
                Text(model.knownDevice?.uppercased() ?? "")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.novaText2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    arrow("chevron.left", label: index == 0 ? String(localized: "Back to the question", bundle: .ui) : String(localized: "Previous step", bundle: .ui)) {
                        model.back()
                    }
                    Text(verbatim: "\(index + 1)/\(total)")
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.novaYellow)
                        .frame(minWidth: 34)
                    arrow("chevron.right", label: String(localized: "Next step", bundle: .ui)) { model.forward() }
                        .disabled(!model.canGoForward)
                        .opacity(model.canGoForward ? 1 : 0.35)
                }
            }
            HStack(spacing: 4) {
                ForEach(model.records.indices, id: \.self) { i in
                    Capsule().fill(segmentColor(i)).frame(height: 5)
                }
            }
            .accessibilityHidden(true)
            Text(GuideText.display(step.instruction))
                .font(.system(size: land ? 17 : 22, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let motion = step.motionKind {
                Label(motion.title, systemImage: motion.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.novaCyan)
            }
            if let detail = step.detail, !detail.isEmpty, !land || (resultBox == nil && model.reply == nil) {
                Text(GuideText.display(detail))
                    .font(.system(size: land ? 13 : 14))
                    .foregroundStyle(Color.novaText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reply = model.reply {
                Bubble(icon: "bubble.left", color: .novaCyan, title: nil, text: reply)
            }
            if let box = resultBox {
                Bubble(icon: box.icon, color: box.color, title: box.title, text: box.text)
            }
            if land { Spacer(minLength: 0) }
            VStack(spacing: 8) {
                if model.seemsStuck {
                    Bubble(icon: "arrow.triangle.2.circlepath", color: .novaOrange, title: nil,
                           text: String(localized: "We seem stuck. Shall I look at this again?", bundle: .ui))
                }
                Text("AI-generated guidance. Check before you press.")
                    .font(.caption2)
                    .foregroundStyle(Color.novaText3)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button { model.repeatStep() } label: {
                        Image(systemName: "speaker.wave.2").font(.system(size: 18)).foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.novaLine))
                    }
                    .accessibilityLabel(Text("Repeat"))
                    Button { model.primary() } label: {
                        HStack(spacing: 8) {
                            if model.feedback == .checking || model.isLocating { ProgressView().tint(.black) }
                            Text(primaryTitle)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(fill: model.feedback == .correct ? .novaGreen : .novaYellow))
                    .scaleEffect(nudge ? 1.03 : 1)
                    .disabled(model.feedback == .checking || model.isLocating || model.reassessing)
                }
                HStack(spacing: 8) {
                    Button { model.reassess() } label: {
                        HStack(spacing: 6) {
                            if model.reassessing { ProgressView().tint(.white) }
                            Text(model.reassessing ? String(localized: "Looking again…", bundle: .ui) : String(localized: "Re-evaluate", bundle: .ui))
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.feedback == .checking || model.isLocating || model.reassessing)
                    Button(model.stepDefended ? String(localized: "Still wrong", bundle: .ui) : String(localized: "More options", bundle: .ui)) {
                        model.openCorrection()
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.feedback == .checking || model.reassessing)
                }
                if let secondary = secondaryTitle {
                    Button(secondary) { model.secondary() }.buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .onChange(of: model.feedback) { _, feedback in
            // After a verified check the Continue button pulses; with auto-continue it moves on by itself, silently.
            if feedback == .correct {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { nudge = true }
            } else {
                withAnimation(.default) { nudge = false }
            }
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(Color.novaLine))
        }
        .accessibilityLabel(Text(label))
    }

    private func segmentColor(_ i: Int) -> Color {
        let result = model.records[i].result
        if i == index && result == .pending { return .novaYellow }
        return StepCardColors.color(result)
    }

    private var resultBox: (icon: String, color: Color, title: String?, text: String)? {
        switch model.feedback {
        case .correct: ("checkmark", .novaGreen, String(localized: "Verified.", bundle: .ui), "")
        case .notDone(let text): ("xmark", .novaRed, String(localized: "Needs correction.", bundle: .ui), text)
        case .unsure(let text): ("questionmark.circle", .novaOrange, String(localized: "Not sure.", bundle: .ui), text)
        case .error(let text): ("exclamationmark.triangle", .novaOrange, nil, text)
        case .checking, nil: nil
        }
    }

    private var primaryTitle: String {
        if model.isLocating { return String(localized: "Finding the control…", bundle: .ui) }
        switch model.feedback {
        case .checking: return String(localized: "Checking…", bundle: .ui)
        case .correct: return model.isLastStep ? String(localized: "Finish", bundle: .ui) : String(localized: "Continue →", bundle: .ui)
        case .notDone, .error: return String(localized: "Check again", bundle: .ui)
        case .unsure: return String(localized: "Show closer", bundle: .ui)
        case nil:
            if step.isVerifiable && settings.verifyEach { return String(localized: "I've done it →", bundle: .ui) }
            return model.isLastStep ? String(localized: "Finish", bundle: .ui) : String(localized: "Continue →", bundle: .ui)
        }
    }

    private var secondaryTitle: String? {
        switch model.feedback {
        case .notDone, .error: String(localized: "Skip, I did it", bundle: .ui)
        case .unsure: String(localized: "I did it, confirm", bundle: .ui)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.subheadline.weight(.bold)).padding(.top, 1)
            (Text(title.map { $0 + (text.isEmpty ? "" : " ") } ?? "").bold() + Text(GuideText.display(text)))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: Completion

struct CompletionView: View {
    @EnvironmentObject private var model: GuideModel
    @State private var showSummary = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
            Color(white: 0.02).opacity(0.86).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    let tone: Color = model.unsolved ? .novaOrange : .novaGreen
                    Image(systemName: model.unsolved ? "exclamationmark" : "checkmark")
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(tone)
                        .frame(width: 68, height: 68)
                        .background(tone.opacity(0.16), in: Circle())
                        .overlay(Circle().stroke(tone.opacity(0.5), lineWidth: 2))
                    Text(model.unsolved ? "Not solved" : "Task completed").font(.title2.weight(.heavy))
                    if model.unsolved {
                        Text("I couldn't solve this. Check the device's manual or contact service.")
                            .font(.footnote).foregroundStyle(Color.novaText2).multilineTextAlignment(.center)
                    }
                    if let device = model.knownDevice {
                        Text(device).font(.subheadline).foregroundStyle(Color.novaText2)
                    }
                    HStack(spacing: 8) {
                        stat(Text(verbatim: "\(done)/\(model.records.count)"), String(localized: "Steps", bundle: .ui), .white)
                        stat(Text(verbatim: "\(count(.verified))"), String(localized: "Verified", bundle: .ui), .novaGreen)
                        stat(Text(verbatim: "\(count(.confirmed) + count(.skipped))"), String(localized: "You confirmed", bundle: .ui), .novaCyan)
                        stat(Text(verbatim: duration), String(localized: "Time", bundle: .ui), .white)
                    }
                    if showSummary, let plan = model.plan {
                        VStack(spacing: 6) {
                            ForEach(Array(zip(plan.steps, model.records).enumerated()), id: \.offset) { _, pair in
                                HStack(spacing: 10) {
                                    Circle().fill(StepCardColors.color(pair.1.result)).frame(width: 10, height: 10)
                                    Text(GuideText.display(pair.0.instruction)).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(StepCardColors.label(pair.1.result)).font(.caption).foregroundStyle(Color.novaText2)
                                }
                                .font(.footnote)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.novaRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    Button(String(localized: "New task here", bundle: .ui)) { model.newTask(keepDevice: true) }
                        .buttonStyle(PrimaryButtonStyle())
                    HStack(spacing: 8) {
                        Button(String(localized: "Something else", bundle: .ui)) { model.newTask(keepDevice: false) }
                        Button(showSummary ? String(localized: "Hide summary", bundle: .ui) : String(localized: "View summary", bundle: .ui)) {
                            withAnimation { showSummary.toggle() }
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                .padding(22)
                .frame(maxWidth: 420)
                .background(Color.novaCard, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var done: Int { model.records.filter { $0.result != .pending }.count }

    private func count(_ result: GuideModel.StepRecord.Result) -> Int { model.records.filter { $0.result == result }.count }

    private var duration: String {
        guard let start = model.startedAt else { return "0:00" }
        let seconds = max(Int((model.finishedAt ?? Date()).timeIntervalSince(start)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func stat(_ value: Text, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            value.font(.title3.weight(.heavy)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(Color.novaText2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(Color.novaRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
