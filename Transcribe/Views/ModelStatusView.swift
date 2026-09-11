import SwiftUI
import TranscribeKit

/// The speech model's state, with a way to fetch it. In the menu (`compact`)
/// it only appears while something needs attention.
struct ModelStatusView: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.engine.state {
            case .notDownloaded:
                HStack {
                    Label("Speech model not downloaded (467 MB)", systemImage: "arrow.down.circle")
                        .font(.callout)
                    Spacer()
                    Button("Download") { load() }
                }
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading speech model… \(Int(progress * 100))%").font(.callout)
                    ProgressView(value: progress)
                }
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing speech model. The first time takes about 20 seconds.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("The speech model could not load", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Button("Try Again") { load() }
                }
            case .downloaded where !compact:
                Label("Downloaded. Loads when first needed.", systemImage: "checkmark.circle")
                    .font(.callout)
            case .ready where !compact:
                Label("Ready. Runs on this Mac's Neural Engine.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .downloaded, .ready:
                EmptyView()
            }
            if let newer = model.engine.newerRevision {
                Label("Speech model \(newer) is available in a newer Transcribe.",
                      systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        Task { try? await model.engine.load() }
    }
}
