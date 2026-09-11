import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class Settings {
    private enum Key {
        static let outputDirectory = "outputDirectory"
        static let autoRecord = "autoRecord"
        static let captureMicrophone = "captureMicrophone"
        static let speakerName = "speakerName"
        static let othersLabel = "othersLabel"
        static let notifications = "notifications"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Where transcripts are saved. Chosen by the user during setup.
    var outputDirectory: URL? {
        didSet { defaults.set(outputDirectory?.path, forKey: Key.outputDirectory) }
    }
    /// Start transcribing as soon as a Meet or Teams call is detected.
    var autoRecord: Bool {
        didSet { defaults.set(autoRecord, forKey: Key.autoRecord) }
    }
    /// Transcribe your own microphone as well as the meeting audio.
    var captureMicrophone: Bool {
        didSet { defaults.set(captureMicrophone, forKey: Key.captureMicrophone) }
    }
    /// How you appear in transcripts.
    var speakerName: String {
        didSet { defaults.set(speakerName, forKey: Key.speakerName) }
    }
    /// How everyone else appears in transcripts.
    var othersLabel: String {
        didSet { defaults.set(othersLabel, forKey: Key.othersLabel) }
    }
    var notifications: Bool {
        didSet { defaults.set(notifications, forKey: Key.notifications) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputDirectory = defaults.string(forKey: Key.outputDirectory).map { URL(fileURLWithPath: $0, isDirectory: true) }
        autoRecord = defaults.object(forKey: Key.autoRecord) as? Bool ?? true
        captureMicrophone = defaults.object(forKey: Key.captureMicrophone) as? Bool ?? true
        speakerName = defaults.string(forKey: Key.speakerName) ?? Self.defaultSpeakerName
        othersLabel = defaults.string(forKey: Key.othersLabel) ?? "Others"
        notifications = defaults.object(forKey: Key.notifications) as? Bool ?? true
    }

    /// Your first name, from your macOS account.
    static var defaultSpeakerName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
    }
}
