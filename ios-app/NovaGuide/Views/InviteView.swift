import SwiftUI

/// One short screen on the way in, only when the server needs an invite code and none works yet.
struct InviteView: View {
    @EnvironmentObject private var model: GuideModel
    @State private var code = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        ZStack {
            Color.sheetGround.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    KokobubuMascot(size: 64)
                    Text("Enter your invite code").font(.title2.weight(.bold))
                    Text("You only need to do this once.").foregroundStyle(Color.sheetMuted)
                    HStack(spacing: 8) {
                        TextField(String(localized: "Invite code", bundle: .ui), text: $code)
                            .font(.title3.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(check)
                            .padding(12)
                            .frame(minHeight: 52)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        PasteButton(payloadType: String.self) { pasted in
                            code = pasted.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            check()
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.roundedRectangle)
                        .frame(minHeight: 52)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.novaRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: check) {
                        Group {
                            if checking {
                                ProgressView().tint(.black)
                            } else {
                                Text("Continue")
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(fill: .novaYellow))
                    .disabled(checking || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .onAppear {
            if model.inviteRejected { problem = String(localized: "This invite code isn't valid.", bundle: .ui) }
        }
    }

    private func check() {
        guard !checking else { return }
        checking = true
        problem = nil
        Task {
            let result = await model.tryInvite(code)
            checking = false
            switch result {
            case .ok: break
            case .rejected: problem = String(localized: "This invite code isn't valid.", bundle: .ui)
            case .unreachable: problem = String(localized: "Can't reach Kokobubu. Check your internet connection and try again.", bundle: .ui)
            }
        }
    }
}
