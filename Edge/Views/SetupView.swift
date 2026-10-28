import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @EnvironmentObject private var models: ModelStore
    @State private var importing = false
    @State private var showSettings = false

    private static let gguf = UTType(filenameExtension: "gguf") ?? .data

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你好！")
                            .font(.system(size: 44, weight: .bold))
                        Text("Practice speaking Mandarin with LFM3-Audio, fully on your iPhone. It answers out loud in Mandarin and corrects you in English.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("One-time model download", systemImage: "arrow.down.circle")
                            .font(.headline)
                        Text("Two GGUF files from \(models.repo) on Hugging Face, about 1.5–2 GB in total. Use Wi-Fi and keep the app open while it downloads.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        downloadSection
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Already have the files?", systemImage: "folder")
                            .font(.headline)
                        Text("Import the model .gguf and the mmproj .gguf, or copy them into Files › On My iPhone › Edge.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Import GGUF files…") { importing = true }
                            .buttonStyle(.bordered)
                        fileStatus
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
            .fileImporter(isPresented: $importing, allowedContentTypes: [Self.gguf, .data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { models.importFiles(urls) }
            }
        }
    }

    @ViewBuilder private var downloadSection: some View {
        switch models.phase {
        case .idle:
            Button {
                Task { await models.download() }
            } label: {
                Text("Download model").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .resolving:
            ProgressView("Looking up files…")
        case .downloading(let file, let index, let count):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: models.progress)
                Text("\(file) (\(index)/\(count)) · \(Int(models.progress * 100))% of \(ByteCountFormatter.string(fromByteCount: models.downloadSizeBytes, countStyle: .file))")
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

    private var fileStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(models.modelURL?.lastPathComponent ?? "Model GGUF missing",
                  systemImage: models.modelURL == nil ? "xmark.circle" : "checkmark.circle.fill")
            Label(models.mmprojURL?.lastPathComponent ?? "mmproj GGUF missing",
                  systemImage: models.mmprojURL == nil ? "xmark.circle" : "checkmark.circle.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
