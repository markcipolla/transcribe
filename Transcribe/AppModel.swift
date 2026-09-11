import AppKit
import Foundation
import Observation
import os
import TranscribeKit

/// The app's state and the decisions about when to record.
///
/// Every couple of seconds it asks the detector whether a Meet, Teams or Slack
/// call is going on. A call that shows up on two polls in a row starts a
/// recording (if automatic recording is on), and a recording made for a call
/// stops once the call has let go of the microphone for ``meetingEndGrace``.
@MainActor
@Observable
final class AppModel {
    let settings: Settings
    let engine = TranscriptionEngine()
    let titleWriter = TitleWriter()
    let updater: Updater

    /// The call currently happening, whether or not it is being recorded.
    private(set) var detectedMeeting: DetectedMeeting?
    /// The recording in progress or finishing, if any.
    private(set) var session: RecordingSession?
    /// The call `session` is recording, or nil for a recording started by hand
    /// with no call detected, which only stops by hand.
    private(set) var sessionMeeting: DetectedMeeting?
    private(set) var recentTranscripts: [URL] = []
    private(set) var lastError: String?

    @ObservationIgnored private let detector = MeetingDetector()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The stop in progress. Every caller awaits this one, so quitting while a
    /// transcript is finishing waits for it instead of cutting it off.
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var detectionStreak = 0
    @ObservationIgnored private var meetingGoneSince: Date?
    /// A call whose recording you stopped by hand. It is not recorded again
    /// automatically until it ends.
    @ObservationIgnored private var declinedMeeting: DetectedMeeting?
    @ObservationIgnored private let log = Logger(subsystem: "Transcribe", category: "App")

    static let pollInterval: Duration = .seconds(2)
    /// How long a call must be off the microphone before it counts as over.
    /// Rides out device switches and apps briefly reopening the microphone.
    static let meetingEndGrace: TimeInterval = 20

    init(settings: Settings = Settings()) {
        self.settings = settings
        updater = Updater()
        updater.isBusy = { [weak self] in self?.isRecording ?? false }
        refreshRecentTranscripts()
    }

    var isRecording: Bool { session?.state == .recording }
    var isFinishing: Bool { session?.state == .finishing }
    var needsSetup: Bool { settings.outputDirectory == nil }

    func start() {
        notifier.requestAuthorization()
        if case .downloaded = engine.state {
            Task { try? await engine.load() }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    // MARK: - Detection

    private func poll() async {
        if let session, session.state == .recording {
            if let meeting = sessionMeeting { checkMeetingStillActive(meeting) }
            return
        }
        guard session == nil else { return }

        let meeting = await detector.detect()
        detectedMeeting = meeting
        detectionStreak = meeting == nil ? 0 : detectionStreak + 1

        if let declined = declinedMeeting, meeting?.isSameMeeting(as: declined) != true {
            declinedMeeting = nil
        }
        guard let meeting, detectionStreak >= 2, declinedMeeting == nil,
              settings.autoRecord, !needsSetup
        else { return }
        await startRecording(for: meeting)
    }

    private func checkMeetingStillActive(_ meeting: DetectedMeeting) {
        if detector.isStillActive(meeting) {
            meetingGoneSince = nil
            return
        }
        let since = meetingGoneSince ?? Date()
        meetingGoneSince = since
        if Date().timeIntervalSince(since) >= Self.meetingEndGrace {
            log.info("\(meeting.platform.rawValue, privacy: .public) call ended")
            Task { await stopRecording() }
        }
    }

    // MARK: - Recording

    /// Start recording `meeting`, or a manual recording when nil.
    func startRecording(for meeting: DetectedMeeting?) async {
        guard session == nil else { return }
        guard let directory = settings.outputDirectory else {
            lastError = "Choose a folder for transcripts in Settings first."
            return
        }
        let metadata = TranscriptMetadata(
            title: meeting?.title,
            platform: meeting?.platform ?? .manual,
            startedAt: Date(),
            microphoneLabel: settings.speakerName.isEmpty ? "Me" : settings.speakerName,
            systemLabel: settings.othersLabel.isEmpty ? "Others" : settings.othersLabel)
        let session = RecordingSession(metadata: metadata, directory: directory,
                                       captureMicrophone: settings.captureMicrophone, engine: engine,
                                       titleWriter: settings.writeTitles ? titleWriter : nil)
        do {
            try await session.start()
        } catch {
            lastError = "Could not start recording: \(error)"
            log.error("Start failed: \(String(describing: error), privacy: .public)")
            return
        }
        self.session = session
        sessionMeeting = meeting
        meetingGoneSince = nil
        lastError = nil
        // The first time, the title model downloads during the meeting, in
        // plenty of time for its end.
        if settings.writeTitles { downloadTitleModel() }
        if settings.notifications, meeting != nil {
            notifier.post(title: "Transcribing \(metadata.displayTitle)",
                          body: "Saving to \(session.fileURL.lastPathComponent)")
        }
    }

    /// Stop the current recording and finish its transcript. Returns once the
    /// transcript is saved, including when another caller started the stop.
    func stopRecording(declined: Bool = false) async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard let session, session.state == .recording else { return }
        if declined, let meeting = sessionMeeting { declinedMeeting = meeting }
        let task = Task { await finish(session) }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func finish(_ session: RecordingSession) async {
        await session.stop()
        self.session = nil
        sessionMeeting = nil
        detectionStreak = 0
        refreshRecentTranscripts()
        if let warning = session.warnings.last { lastError = warning }
        if settings.notifications, !session.wasDiscarded {
            notifier.post(title: "Transcript saved",
                          body: session.fileURL.lastPathComponent,
                          fileURL: session.fileURL)
        }
        updater.recordingFinished()
    }

    func downloadTitleModel() {
        guard !titleWriter.isDownloaded else { return }
        Task { try? await titleWriter.download() }
    }

    // MARK: - Files

    func refreshRecentTranscripts() {
        guard let directory = settings.outputDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else {
            recentTranscripts = []
            return
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        recentTranscripts = files
            .filter { $0.pathExtension == "md" }
            .sorted { modified($0) > modified($1) }
            .prefix(5)
            .map { $0 }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Transcribe saves meeting transcripts."
        panel.directoryURL = settings.outputDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.outputDirectory = url
        lastError = nil
        refreshRecentTranscripts()
    }

    func openOutputDirectory() {
        guard let directory = settings.outputDirectory else { return }
        NSWorkspace.shared.open(directory)
    }

    func dismissError() {
        lastError = nil
    }

    /// Finish any transcript before quitting.
    func prepareForTermination() async {
        pollTask?.cancel()
        await stopRecording()
    }
}
