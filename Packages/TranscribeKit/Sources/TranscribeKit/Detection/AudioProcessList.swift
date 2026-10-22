import CoreAudio
import Darwin
import Foundation

/// A process Core Audio knows about, reduced to what meeting detection needs.
public struct AudioProcess: Sendable, Equatable {
    public let pid: pid_t
    /// The process's own bundle identifier, e.g. `com.google.Chrome.helper`.
    public let bundleID: String
    /// The outermost app bundle containing the executable, e.g.
    /// `com.google.Chrome` for a Chrome helper. Empty when not inside an app.
    public let appBundleID: String
    /// The app process this one belongs to: a Chrome helper's own browser,
    /// not just any Chrome. Two instances of one browser — yours and a
    /// WebDriver's — share a bundle ID but not this. `pid` when standalone.
    public let appPID: pid_t
    public let isUsingMicrophone: Bool
    public let isPlayingAudio: Bool

    public init(pid: pid_t, bundleID: String, appBundleID: String, appPID: pid_t,
                isUsingMicrophone: Bool, isPlayingAudio: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.appBundleID = appBundleID
        self.appPID = appPID
        self.isUsingMicrophone = isUsingMicrophone
        self.isPlayingAudio = isPlayingAudio
    }
}

/// Which processes are using audio devices right now.
///
/// This is how meetings are noticed: a call keeps the microphone open for its
/// whole length, including while you are muted (Meet and Teams both listen in
/// order to tell you that you are talking while muted). Reading it needs no
/// permission.
public enum AudioProcessList {
    public static func current() -> [AudioProcess] {
        guard let objects = try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        else { return [] }
        return objects.compactMap { object in
            guard let pid = try? object.read(kAudioProcessPropertyPID, default: pid_t(0)), pid > 0 else {
                return nil
            }
            let bundleID = (try? object.readString(kAudioProcessPropertyBundleID)) ?? ""
            let input = (try? object.read(kAudioProcessPropertyIsRunningInput, default: UInt32(0))) ?? 0
            let output = (try? object.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            let appPath = executablePath(of: pid).flatMap(AppBundlePath.outermostApp(in:))
            return AudioProcess(pid: pid,
                                bundleID: bundleID,
                                appBundleID: appPath.flatMap { Bundle(path: $0)?.bundleIdentifier } ?? bundleID,
                                appPID: appPath.map { appProcessPID(of: pid, in: $0) } ?? pid,
                                isUsingMicrophone: input != 0,
                                isPlayingAudio: output != 0)
        }
    }

    public static func usingMicrophone(excluding excludedPID: pid_t = getpid()) -> [AudioProcess] {
        current().filter { $0.isUsingMicrophone && $0.pid != excludedPID }
    }

    /// The bundle identifier of the outermost `.app` the process runs from.
    static func containingAppBundleID(pid: pid_t) -> String? {
        executablePath(of: pid)
            .flatMap(AppBundlePath.outermostApp(in:))
            .flatMap { Bundle(path: $0)?.bundleIdentifier }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The topmost ancestor of `pid` still running from `appPath`, which is
    /// the app process itself: a browser helper resolves to the browser that
    /// spawned it rather than to whichever copy of that browser is running.
    /// Resolving the instance rather than the bundle also means a helper that
    /// respawns mid-call still answers to the same app.
    static func appProcessPID(of pid: pid_t, in appPath: String) -> pid_t {
        var app = pid
        // Bounded because a cycle in the parent chain would hang the poll, and
        // no helper nests anywhere near this deep.
        for _ in 0..<16 {
            guard let parent = parentPID(of: app), parent > 1,
                  let path = executablePath(of: parent),
                  AppBundlePath.outermostApp(in: path) == appPath
            else { return app }
            app = parent
        }
        return app
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbsi_ppid)
    }
}
