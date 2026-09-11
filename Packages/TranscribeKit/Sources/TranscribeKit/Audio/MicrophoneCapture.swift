@preconcurrency import AVFoundation
import Foundation
import os

/// Captures the default input device: your side of the meeting.
///
/// Restarts itself when the input device changes (headset plugged in, AirPods
/// switching to their microphone), which AVAudioEngine reports as a
/// configuration change and otherwise answers by stopping.
public final class MicrophoneCapture: @unchecked Sendable {
    public typealias SamplesHandler = @Sendable ([Float]) -> Void

    private let sampleRate: Double
    private let onSamples: SamplesHandler
    private let onRestart: @Sendable () -> Void
    private let onFailure: @Sendable (Error) -> Void
    /// Delays between attempts to rebuild after a device change. A device that
    /// has just appeared (AirPods reconnecting) often is not usable at once.
    private static let restartDelays: [TimeInterval] = [0, 0.5, 1, 2, 4]
    private let queue = DispatchQueue(label: "Transcribe.MicrophoneCapture")
    private let log = Logger(subsystem: "Transcribe", category: "Microphone")

    // Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var running = false

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

    public static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() throws {
        try queue.sync {
            guard !running else { return }
            try startEngine()
            running = true
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            stopEngine()
        }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneError.noInputDevice
        }
        guard let converter = MonoConverter(from: format, sampleRate: sampleRate) else {
            throw MicrophoneError.unsupportedFormat(format.description)
        }
        let onSamples = self.onSamples
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.restartAfterConfigurationChange() }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            throw error
        }
        self.engine = engine
        log.info("Capturing microphone: \(format.sampleRate) Hz, \(format.channelCount) ch")
    }

    private func stopEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func restartAfterConfigurationChange(attempt: Int = 0) {
        guard running else { return }
        log.info("Input configuration changed; restarting the microphone (attempt \(attempt + 1))")
        stopEngine()
        do {
            try startEngine()
            onRestart()
        } catch {
            log.error("Could not restart the microphone: \(String(describing: error))")
            let next = attempt + 1
            if next < Self.restartDelays.count {
                queue.asyncAfter(deadline: .now() + Self.restartDelays[next]) { [weak self] in
                    self?.restartAfterConfigurationChange(attempt: next)
                }
            } else {
                onFailure(error)
            }
        }
    }
}

public enum MicrophoneError: Error, CustomStringConvertible {
    case noInputDevice
    case unsupportedFormat(String)

    public var description: String {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .unsupportedFormat(let format): "The microphone's format is not supported: \(format)"
        }
    }
}
