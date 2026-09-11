import AVFoundation
import ServiceManagement
import SwiftUI
import TranscribeKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Transcripts") {
                LabeledContent("Save to") {
                    HStack {
                        if let directory = settings.outputDirectory {
                            Text(directory.path(percentEncoded: false).replacingOccurrences(
                                of: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
                                with: "~/"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not chosen").foregroundStyle(.orange)
                        }
                        Button("Choose…") { model.chooseOutputDirectory() }
                    }
                }
                TextField("Your name", text: $settings.speakerName, prompt: Text("Me"))
                TextField("Everyone else", text: $settings.othersLabel, prompt: Text("Others"))
            }

            Section {
                Toggle("Start transcribing when a call starts", isOn: $settings.autoRecord)
                Toggle("Transcribe my microphone", isOn: $settings.captureMicrophone)
                Toggle("Show notifications", isOn: $settings.notifications)
            } header: {
                Text("Recording")
            } footer: {
                Text("Calls are detected when Google Meet (in Chrome, Safari, Edge, Arc or Brave) or Microsoft Teams is using the microphone. Recording stops shortly after the call ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ModelStatusView()
            } header: {
                Text("Speech model")
            } footer: {
                Text("Voz by Desert Ant Labs. Audio and transcripts never leave this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Title and describe each meeting", isOn: $settings.writeTitles)
                if settings.writeTitles {
                    TitleModelStatus()
                }
            } header: {
                Text("Titles")
            } footer: {
                Text("When a call ends, Title by Desert Ant Labs reads the transcript and writes a sentence or two about it. It also names calls that have no name of their own, such as Teams calls and recordings you start yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: settings.writeTitles) { _, on in
                if on { model.downloadTitleModel() }
            }

            PermissionsSection()

            Section("General") {
                LaunchAtLoginToggle()
                if model.updater.isConfigured {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { model.updater.automaticallyChecksForUpdates },
                        set: { model.updater.automaticallyChecksForUpdates = $0 }))
                }
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                Text("Speech recognition by [Voz](https://desertant.com/models/voz/) from Desert Ant Labs, built on NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0). Titles by [Title](https://desertant.com/models/title/) from Desert Ant Labs, built on IBM Granite 4.0 350M (Apache 2.0).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

private struct TitleModelStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.titleWriter.state {
        case .notDownloaded:
            HStack {
                Label("Model not downloaded (286 MB)", systemImage: "arrow.down.circle")
                    .font(.callout)
                Spacer()
                Button("Download") { model.downloadTitleModel() }
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading title model… \(Int(progress * 100))%").font(.callout)
                ProgressView(value: progress)
            }
        case .downloaded:
            Label("Ready. Runs on this Mac's GPU.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("The title model could not download", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("Try Again") { model.downloadTitleModel() }
            }
        }
    }
}

private struct PermissionsSection: View {
    @State private var microphone = MicrophoneCapture.authorizationStatus

    var body: some View {
        Section {
            LabeledContent {
                switch microphone {
                case .authorized:
                    Text("Allowed").foregroundStyle(.secondary)
                case .notDetermined:
                    Button("Allow…") {
                        Task {
                            _ = await MicrophoneCapture.requestAccess()
                            microphone = MicrophoneCapture.authorizationStatus
                        }
                    }
                default:
                    Button("Open System Settings") { open("Privacy_Microphone") }
                }
            } label: {
                Text("Microphone")
                Text("Your side of the conversation.")
            }
            LabeledContent {
                Button("Open System Settings") { open("Privacy_AudioCapture") }
            } label: {
                Text("System audio recording")
                Text("The other participants. macOS asks the first time a call is recorded.")
            }
            LabeledContent {
                Button("Open System Settings") { open("Privacy_Automation") }
            } label: {
                Text("Browser automation")
                Text("Reads your browser's tab list to recognise a Meet or Teams call. Nothing else is read.")
            }
        } header: {
            Text("Permissions")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphone = MicrophoneCapture.authorizationStatus
        }
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { enabled }, set: { update($0) }))
        if let error {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
    }

    private func update(_ newValue: Bool) {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
