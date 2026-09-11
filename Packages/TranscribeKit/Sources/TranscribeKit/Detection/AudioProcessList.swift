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
    public let isUsingMicrophone: Bool
    public let isPlayingAudio: Bool

    public init(pid: pid_t, bundleID: String, appBundleID: String,
                isUsingMicrophone: Bool, isPlayingAudio: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.appBundleID = appBundleID
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
            return AudioProcess(pid: pid,
                                bundleID: bundleID,
                                appBundleID: containingAppBundleID(pid: pid) ?? bundleID,
                                isUsingMicrophone: input != 0,
                                isPlayingAudio: output != 0)
        }
    }

    public static func usingMicrophone(excluding excludedPID: pid_t = getpid()) -> [AudioProcess] {
        current().filter { $0.isUsingMicrophone && $0.pid != excludedPID }
    }

    /// The bundle identifier of the outermost `.app` the process runs from.
    static func containingAppBundleID(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return AppBundlePath.outermostApp(in: path).flatMap { Bundle(path: $0)?.bundleIdentifier }
    }
}
