import AVKit
import Photos
import SwiftUI

/// Settings › Share the last recording: watch it, then save it to Photos, share it, or delete it.
struct RecordingPreview: View {
    let video: RecordedVideo
    @EnvironmentObject private var screenRecorder: ScreenRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saved = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Label(String(localized: "Before you share, check that no faces or personal details are in the video.", bundle: .ui),
                      systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Color.novaText2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let message {
                    Text(message).font(.footnote.weight(.semibold)).foregroundStyle(Color.novaOrange)
                }
                HStack(spacing: 10) {
                    Button(action: save) {
                        Label(saved ? String(localized: "Saved", bundle: .ui) : String(localized: "Save to Photos", bundle: .ui),
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .buttonStyle(PrimaryButtonStyle(enabled: !saved))
                    .disabled(saved)
                    ShareLink(item: video.url) {
                        Label(String(localized: "Share", bundle: .ui), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                Button(role: .destructive) {
                    screenRecorder.deleteLast()
                    dismiss()
                } label: {
                    Text("Delete")
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .padding(16)
            .background(Color.novaGround.ignoresSafeArea())
            .navigationTitle(Text("Last recording"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Close", bundle: .ui)) { dismiss() }
                }
            }
        }
        .onAppear { player = AVPlayer(url: video.url) }
        .onDisappear { player?.pause() }
    }

    private func save() {
        Task {
            // Add-only access: Nova can put the video in Photos but can't see the library.
            guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
                message = String(localized: "Allow Kokobubu to add to Photos in Settings, then try again.", bundle: .ui)
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: video.url, options: nil)
                }
                saved = true
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
