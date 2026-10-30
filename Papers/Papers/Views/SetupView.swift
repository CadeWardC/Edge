import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var models: ModelStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Listen to papers")
                            .font(.system(size: 36, weight: .bold))
                        Text("Give Papers a PDF and, entirely on your iPhone, it makes a five to six minute overview (the question, why it matters, what they did, what they found), a ten to fifteen minute in-depth look at the findings, experiments, figures, limitations and open questions, and study questions with answers. The Audio tab turns recordings into transcripts and bullet-point summaries.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("One-time model download", systemImage: "arrow.down.circle")
                            .font(.headline)
                        Text("About 1.7 GB: Qwen3.5 reads the paper and writes the summary, and Kokoro reads it out. Use Wi-Fi. It keeps downloading in the background if you leave the app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        downloadSection
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("Papers")
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
