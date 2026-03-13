@preconcurrency import AVFoundation
import Foundation

/// Loads audio files and converts them to 16kHz mono float32 samples.
enum AudioFileService {
    private static let targetSampleRate: Double = 16000

    enum AudioFileError: Error, LocalizedError {
        case cannotOpenFile
        case conversionFailed
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .cannotOpenFile: "Die Audiodatei konnte nicht geöffnet werden"
            case .conversionFailed: "Die Audio-Konvertierung ist fehlgeschlagen"
            case .emptyFile: "Die Audiodatei ist leer"
            }
        }
    }

    /// Load an audio file and return its samples as 16kHz mono float32.
    static func loadAudioFile(url: URL) throws -> [Float] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioFileError.cannotOpenFile
        }

        guard file.length > 0 else {
            throw AudioFileError.emptyFile
        }

        let sourceFormat = file.processingFormat

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileError.conversionFailed
        }

        // Read entire file into a buffer
        let sourceFrameCount = AVAudioFrameCount(file.length)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw AudioFileError.conversionFailed
        }

        do {
            try file.read(into: sourceBuffer)
        } catch {
            throw AudioFileError.cannotOpenFile
        }

        // If already in target format, extract directly
        if sourceFormat.sampleRate == targetSampleRate
            && sourceFormat.channelCount == 1
            && sourceFormat.commonFormat == .pcmFormatFloat32 {
            guard let channelData = sourceBuffer.floatChannelData else {
                throw AudioFileError.conversionFailed
            }
            let count = Int(sourceBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        }

        // Convert to 16kHz mono float32
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileError.conversionFailed
        }

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(sourceFrameCount) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw AudioFileError.conversionFailed
        }

        var error: NSError?
        var hasData = true
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                outStatus.pointee = .haveData
                hasData = false
                return sourceBuffer
            }
            outStatus.pointee = .endOfStream
            return nil
        }

        if let error {
            throw error
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw AudioFileError.conversionFailed
        }

        let count = Int(outputBuffer.frameLength)
        guard count > 0 else {
            throw AudioFileError.emptyFile
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
