import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public var description: String {
        "\(operation) failed (OSStatus \(status)\(fourCharacterCode.map { " '\($0)'" } ?? ""))"
    }

    private var fourCharacterCode: String? {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation(), status: status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Read a fixed-size, trivially copyable property.
    func read<T>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var address = Self.address(selector)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        try check(withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }, "read property \(selector) of \(self)")
        return result
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector, of _: T.Type) throws -> [T] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
                  "size property \(selector) of \(self)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer),
                  "read property \(selector) of \(self)")
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }, "read string property \(selector) of \(self)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static func defaultSystemOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice,
                                      default: AudioObjectID(kAudioObjectUnknown))
    }

    func deviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    /// Call `handler` on `queue` whenever a property of this object changes.
    /// Returns a token to pass to ``removeListener(_:)``.
    func addListener(
        _ selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> PropertyListener? {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(self, &address, queue, block) == noErr else {
            return nil
        }
        return PropertyListener(object: self, selector: selector, queue: queue, block: block)
    }

    func removeListener(_ listener: PropertyListener) {
        var address = Self.address(listener.selector)
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, listener.queue, listener.block)
    }
}

struct PropertyListener {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock
}
