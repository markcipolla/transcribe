import SwiftUI
import TranscribeKit

/// The panel under the menu bar icon.
struct MenuView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcribe").font(.headline)
                Spacer()
                if model.isRecording {
                    Label("Recording", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }

            StatusSection()

            ModelStatusView(compact: true)

            if let error = model.lastError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.dismissError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.recentTranscripts.isEmpty {
                Divider()
                Text("Recent transcripts").font(.caption).foregroundStyle(.secondary)
                ForEach(model.recentTranscripts, id: \.self) { url in
                    MenuRow(title: url.deletingPathExtension().lastPathComponent, systemImage: "doc.text") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Divider()
            MenuRow(title: "Open Transcripts Folder", systemImage: "folder") { model.openOutputDirectory() }
                .disabled(model.settings.outputDirectory == nil)
            MenuRow(title: "Settings…", systemImage: "gearshape") { SettingsWindow.show(model: model) }
            if model.updater.isConfigured {
                MenuRow(title: "Check for Updates…", systemImage: "arrow.down.circle") { model.updater.checkForUpdates() }
                    .disabled(!model.updater.canCheckForUpdates)
            }
            MenuRow(title: "Quit Transcribe", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshRecentTranscripts() }
    }
}

/// What is happening now, and the button that changes it.
private struct StatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if model.needsSetup {
                    Text("Choose where transcripts are saved to get started.")
                        .font(.callout)
                    Button("Open Settings") { SettingsWindow.show(model: model) }
                        .buttonStyle(.borderedProminent)
                } else if let session = model.session {
                    SessionStatus(session: session)
                } else if let meeting = model.detectedMeeting {
                    Label("\(meeting.platform.rawValue) call in \(meeting.appName)", systemImage: "person.2.wave.2")
                        .font(.callout)
                    Button("Start Transcribing") {
                        Task { await model.startRecording(for: meeting) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label(model.settings.autoRecord
                          ? "Waiting for a Meet, Teams or Slack call"
                          : "Automatic transcription is off",
                          systemImage: "ear")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Start Recording Now") {
                        Task { await model.startRecording(for: nil) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

private struct SessionStatus: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession

    var body: some View {
        switch session.state {
        case .recording:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(session.metadata.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(Duration.seconds(session.duration).formatted(.time(pattern: .hourMinuteSecond)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        AudioIndicator(label: "Meeting audio", lastHeard: session.lastHeard(.system))
                        if session.capturesMicrophone {
                            AudioIndicator(label: "Microphone", lastHeard: session.lastHeard(.microphone))
                        }
                    }
                }
            }
            if let warning = session.warnings.last {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(role: .destructive) {
                Task { await model.stopRecording(declined: true) }
            } label: {
                Label("Stop and Save", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .finishing, .finished:
            HStack {
                ProgressView().controlSize(.small)
                Text("Finishing transcript…").font(.callout)
            }
        }
    }
}

/// Green while a source is delivering sound. Meeting audio that never lights
/// up usually means the System Audio Recording permission is off.
private struct AudioIndicator: View {
    let label: String
    let lastHeard: Date?

    var body: some View {
        let active = lastHeard.map { Date().timeIntervalSince($0) < 3 } ?? false
        Label {
            Text(label).font(.caption)
        } icon: {
            Circle().fill(active ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
        }
        .foregroundStyle(.secondary)
    }
}

private struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
