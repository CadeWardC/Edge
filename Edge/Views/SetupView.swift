import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var models: ModelStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你好！")
                            .font(.system(size: 44, weight: .bold))
                        Text("Practice speaking Mandarin, fully on your iPhone. Your tutor answers out loud in Mandarin and corrects you in English.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("One-time model download", systemImage: "arrow.down.circle")
                            .font(.headline)
                        Text("About 1.9 GB in total: SenseVoice hears you, Qwen3.5 writes the replies and Kokoro speaks them. Use Wi-Fi. It keeps downloading in the background if you leave the app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        downloadSection
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("Edge")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    @ViewBuilder private var downloadSection: some View {
        switch models.phase {
        case .idle:
            Button {
                Task { await models.download() }
            } label: {
                Text("Download models").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .resolving:
            ProgressView("Looking up files…")
        case .downloading(let remaining):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: models.progress)
                Text("\(Int(models.progress * 100))% of \(ByteCountFormatter.string(fromByteCount: models.downloadSizeBytes, countStyle: .file)) · \(remaining) file\(remaining == 1 ? "" : "s") left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("You can leave the app. The download keeps going and you'll get a notification when it's done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { models.cancelDownload() }
                    .font(.caption)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try again") { Task { await models.download() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
