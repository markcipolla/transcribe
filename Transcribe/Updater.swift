import AppKit
import Observation
import Sparkle

/// Automatic updates through Sparkle.
///
/// Updates are published as GitHub releases with an `appcast.xml` asset (see
/// `scripts/release.sh`) and verified with the EdDSA public key baked into
/// Info.plist. A build without that key, such as a local debug build before
/// signing is set up, leaves the updater off rather than showing Sparkle's
/// misconfiguration alert on every launch.
@MainActor
@Observable
final class Updater: NSObject {
    /// Whether an update may relaunch the app right now. A relaunch during a
    /// meeting would cut the recording short, so it waits until it finishes.
    @ObservationIgnored var isBusy: () -> Bool = { false }

    /// Extra work to run whenever the user asks to check for updates. Set by
    /// ``AppModel`` so a manual check also asks the Hub whether the bundled
    /// speech and title models have newer revisions available.
    @ObservationIgnored var onCheck: () -> Void = {}

    private(set) var canCheckForUpdates = false
    let isConfigured: Bool

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var postponedInstall: (() -> Void)?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    override init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        isConfigured = !key.isEmpty && !feed.isEmpty
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
        guard isConfigured else { return }
        controller.startUpdater()
        // Sparkle changes this on the main thread, and `.initial` fires inside
        // `observe` itself, so the handler always runs on the main actor.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { isConfigured && controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
        onCheck()
    }

    /// Called when a recording ends, to let a postponed update install.
    func recordingFinished() {
        let install = postponedInstall
        postponedInstall = nil
        install?()
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater,
                 shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        postponedInstall = installHandler
        return true
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    /// A menu bar app is never frontmost, so bring update windows forward
    /// rather than letting Sparkle open them behind everything else.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        NSApp.activate()
    }
}
