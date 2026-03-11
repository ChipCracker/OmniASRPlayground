import CoreML
import Foundation

/// Manages CoreML model loading, inference, and CTC decoding.
final class CoreMLASRService: Sendable {
    struct ModelInfo: Identifiable, Hashable, Codable, Sendable {
        let id: String
        let name: String
        let vocabFile: String
        let postProcessorType: PostProcessorType

        enum PostProcessorType: String, Codable, Sendable {
            case identity
            case syllable
        }
    }

    private let model: MLModel
    private let vocabulary: [String]
    private let postProcessor: any TokenizerPostProcessor

    init(modelURL: URL, vocabularyURL: URL, postProcessorType: ModelInfo.PostProcessorType = .identity) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // CPU + GPU + Neural Engine

        self.model = try MLModel(contentsOf: modelURL, configuration: config)

        let data = try Data(contentsOf: vocabularyURL)
        self.vocabulary = try JSONDecoder().decode([String].self, from: data)

        switch postProcessorType {
        case .identity:
            self.postProcessor = IdentityPostProcessor()
        case .syllable:
            self.postProcessor = SyllablePostProcessor()
        }
    }

    /// Transcribe normalized audio samples.
    ///
    /// - Parameter audio: Raw audio samples (will be normalized internally).
    /// - Returns: Transcribed text.
    private static let sampleRate = 16000
    /// The wav2vec2 feature extractor reduces T by a factor of ~320.
    private static let featureStride = 320

    func transcribe(audio: [Float]) throws -> String {
        // 1. Normalize audio
        let normalized = AudioNormalizer.normalize(audio)

        // 2. Pad to the next full-second boundary (model uses EnumeratedShapes: 16000, 32000, ...)
        let paddedLength = max(
            Self.sampleRate,
            ((normalized.count + Self.sampleRate - 1) / Self.sampleRate) * Self.sampleRate
        )

        // 3. Create MLMultiArray input (model expects Float16)
        let input = try MLMultiArray(
            shape: [1, NSNumber(value: paddedLength)],
            dataType: .float16
        )

        // Copy data efficiently, remaining elements stay zero-initialized
        let ptr = input.dataPointer.assumingMemoryBound(to: Float16.self)
        for (i, sample) in normalized.enumerated() {
            ptr[i] = Float16(sample)
        }

        // 3. CoreML inference
        let inputFeatures = try MLDictionaryFeatureProvider(
            dictionary: ["audio": MLFeatureValue(multiArray: input)]
        )
        let prediction = try model.prediction(from: inputFeatures)

        // 4. CTC decode — only process frames for actual audio, not zero-padded tail
        guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue else {
            throw ASRError.missingOutput
        }

        let actualFrames = normalized.count / Self.featureStride

        let text: String
        if logits.dataType == .float16 {
            text = CTCDecoder.decode(logits: logits, vocabulary: vocabulary, maxTimeSteps: actualFrames)
        } else {
            text = CTCDecoder.decodeFloat32(logits: logits, vocabulary: vocabulary, maxTimeSteps: actualFrames)
        }

        // 5. Post-process
        return postProcessor.process(text)
    }

    enum ASRError: Error, LocalizedError {
        case missingOutput

        var errorDescription: String? {
            switch self {
            case .missingOutput:
                return "CoreML model did not return logits output"
            }
        }
    }
}
