import AppKit
import SwiftUI

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.session == nil ? "waveform" : "waveform.circle.fill")
                .accessibilityLabel(appDelegate.model.isRecording ? "Transcribe: recording" : "Transcribe")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        if model.needsSetup {
            SettingsWindow.show(model: model)
        }
    }

    /// Quitting mid-meeting finishes the transcript first rather than losing
    /// the last chunk.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.session != nil else { return .terminateNow }
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The settings window, opened from the menu and on first launch. Hosted by
/// hand because SwiftUI's `Settings` scene cannot be opened reliably from a
/// menu bar app that has no main window.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environment(model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Transcribe Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
