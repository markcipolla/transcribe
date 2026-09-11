@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures what the Mac is playing (the other people in the meeting) with a
/// Core Audio process tap.
///
/// A tap needs only the "System Audio Recording" permission, not Screen
/// Recording, and it hears the meeting app directly rather than through the
/// speakers, so it works the same with headphones. The tap is global: meeting
/// apps and browsers play call audio from helper processes that come and go, and
/// following them is more fragile than hearing everything.
///
/// The tap is rebuilt when the default output device changes, because the
/// aggregate device it lives in is clocked by the output device and goes quiet
/// when that device disappears (AirPods disconnecting, say).
public final class SystemAudioCapture: @unchecked Sendable {
    public typealias SamplesHandler = @Sendable ([Float]) -> Void

    private let sampleRate: Double
    private let onSamples: SamplesHandler
    private let onRestart: @Sendable () -> Void
    private let onFailure: @Sendable (Error) -> Void
    /// Delays between attempts to rebuild after a device change. A device that
    /// has just appeared (AirPods reconnecting) often is not usable at once.
    private static let restartDelays: [TimeInterval] = [0, 0.5, 1, 2, 4]
    /// Serialises start, stop and device changes.
    private let queue = DispatchQueue(label: "Transcribe.SystemAudioCapture")
    /// Where the IO block runs. Separate from `queue`, because stopping the device
    /// waits for the IO block to finish and would deadlock on a shared queue.
    private let ioQueue = DispatchQueue(label: "Transcribe.SystemAudioCapture.io", qos: .userInitiated)
    private let log = Logger(subsystem: "Transcribe", category: "SystemAudio")

    // Everything below is only touched on `queue`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputListener: PropertyListener?
    private var running = false

    /// - Parameters:
    ///   - sampleRate: rate of the mono samples handed to `onSamples`.
    ///   - onSamples: called on a private queue with each converted buffer.
    ///   - onRestart: called after the tap is rebuilt, when there may be a gap.
    ///   - onFailure: called when the tap could not be rebuilt and capture has stopped.
    public init(
        sampleRate: Double,
        onSamples: @escaping SamplesHandler,
        onRestart: @escaping @Sendable () -> Void = {},
        onFailure: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.sampleRate = sampleRate
        self.onSamples = onSamples
        self.onRestart = onRestart
        self.onFailure = onFailure
    }

    public func start() throws {
        try queue.sync {
            guard !running else { return }
            try startTap()
            running = true
            outputListener = AudioObjectID.system.addListener(
                kAudioHardwarePropertyDefaultSystemOutputDevice, queue: queue
            ) { [weak self] in
                self?.restartAfterDeviceChange()
            }
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            if let outputListener { AudioObjectID.system.removeListener(outputListener) }
            outputListener = nil
            stopTap()
        }
    }

    // MARK: - Tap lifecycle (on `queue`)

    private func restartAfterDeviceChange(attempt: Int = 0) {
        guard running else { return }
        log.info("Default output device changed; rebuilding the tap (attempt \(attempt + 1))")
        stopTap()
        do {
            try startTap()
            onRestart()
        } catch {
            log.error("Could not rebuild the tap: \(String(describing: error))")
            let next = attempt + 1
            if next < Self.restartDelays.count {
                queue.asyncAfter(deadline: .now() + Self.restartDelays[next]) { [weak self] in
                    self?.restartAfterDeviceChange(attempt: next)
                }
            } else {
                onFailure(error)
            }
        }
    }

    private func startTap() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Transcribe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        do {
            let outputUID = try AudioObjectID.defaultSystemOutputDevice().deviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Transcribe Meeting Audio",
                kAudioAggregateDeviceUIDKey: "Transcribe-\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device),
                      "AudioHardwareCreateAggregateDevice")
            aggregateID = device

            var streamDescription = try tapID.read(kAudioTapPropertyFormat,
                                                   default: AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &streamDescription),
                  let converter = MonoConverter(from: format, sampleRate: sampleRate)
            else { throw CoreAudioError(operation: "read tap format", status: kAudioHardwareUnspecifiedError) }
            log.info("Tapping system audio: \(format.sampleRate) Hz, \(format.channelCount) ch via \(outputUID)")

            var procID: AudioDeviceIOProcID?
            let onSamples = self.onSamples
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
                _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                                    bufferListNoCopy: inputData,
                                                    deallocator: nil)
                else { return }
                let samples = converter.convert(buffer)
                if !samples.isEmpty { onSamples(samples) }
            }, "AudioDeviceCreateIOProcIDWithBlock")
            ioProcID = procID
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        } catch {
            stopTap()
            throw error
        }
    }

    private func stopTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
