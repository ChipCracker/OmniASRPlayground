@preconcurrency import AVFoundation
import Combine
import Foundation

/// Captures audio from the microphone at 16kHz mono float32.
@MainActor
final class AudioCaptureService: ObservableObject {
    private let engine = AVAudioEngine()
    private var isRecording = false

    @Published var audioLevel: Float = 0

    /// Accumulated samples for the current recording.
    private(set) var buffer = [Float]()

    /// Target format: 16kHz mono float32.
    private let targetSampleRate: Double = 16000

    func startRecording() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap with the hardware format, then convert to 16kHz
        let converter = createConverter(from: inputFormat)

        buffer.removeAll(keepingCapacity: true)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] pcmBuffer, _ in
            guard let self else { return }

            let samples: [Float]
            if let converter, inputFormat.sampleRate != self.targetSampleRate {
                guard let converted = self.convert(buffer: pcmBuffer, converter: converter) else {
                    return
                }
                samples = converted
            } else {
                guard let channelData = pcmBuffer.floatChannelData else { return }
                let frameCount = Int(pcmBuffer.frameLength)
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            }

            // Compute normalized audio level for meters/waveform
            let rms = Self.computeNormalizedLevel(samples)

            Task { @MainActor in
                self.buffer.append(contentsOf: samples)
                self.audioLevel = rms
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stopRecording() -> [Float] {
        guard isRecording else { return buffer }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            // Non-critical
        }

        isRecording = false
        audioLevel = 0
        return buffer
    }

    private func createConverter(from inputFormat: AVAudioFormat) -> AVAudioConverter? {
        guard inputFormat.sampleRate != targetSampleRate else { return nil }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        return AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    private func convert(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> [Float]? {
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        var hasData = true
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                outStatus.pointee = .haveData
                hasData = false
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard error == nil,
              let channelData = outputBuffer.floatChannelData else { return nil }
        let frameCount = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }

    /// Compute audio level from samples, normalized to 0…1 using dB scale.
    /// -50 dB floor (silence) → 0, 0 dB (full scale) → 1.
    private static func computeNormalizedLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -50
        let clamped = max(floor, min(0, db))
        return (clamped - floor) / -floor
    }
}
