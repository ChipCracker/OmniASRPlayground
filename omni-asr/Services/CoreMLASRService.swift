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
    private let allowedLengths: [Int]
    private let maxInputLength: Int

    private init(model: MLModel, vocabulary: [String], postProcessorType: ModelInfo.PostProcessorType) {
        self.model = model
        self.vocabulary = vocabulary

        switch postProcessorType {
        case .identity:
            self.postProcessor = IdentityPostProcessor()
        case .syllable:
            self.postProcessor = SyllablePostProcessor()
        }

        // Read allowed input shapes from the model's enumerated shapes constraint
        if let constraint = model.modelDescription
               .inputDescriptionsByName["audio"]?
               .multiArrayConstraint,
           constraint.shapeConstraint.type == .enumerated {
            let shapes = constraint.shapeConstraint.enumeratedShapes
            let lengths = shapes.compactMap { shape -> Int? in
                shape.count == 2 ? shape[1].intValue : nil
            }.sorted()
            self.allowedLengths = lengths
            self.maxInputLength = lengths.last ?? 640_000
        } else {
            self.allowedLengths = stride(from: 16_000, through: 640_000, by: 16_000).map { $0 }
            self.maxInputLength = 640_000
        }
    }

    /// Asynchronously load a CoreML model without blocking the main thread.
    static func load(
        modelURL: URL,
        vocabularyURL: URL,
        postProcessorType: ModelInfo.PostProcessorType = .identity
    ) async throws -> CoreMLASRService {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model = try await MLModel.load(contentsOf: modelURL, configuration: config)

        let data = try Data(contentsOf: vocabularyURL)
        let vocabulary = try JSONDecoder().decode([String].self, from: data)

        return CoreMLASRService(model: model, vocabulary: vocabulary, postProcessorType: postProcessorType)
    }

    /// Transcribe audio samples. Automatically chunks long audio that exceeds the model's
    /// maximum input length.
    ///
    /// - Parameter audio: Raw audio samples (will be normalized internally).
    /// - Returns: Transcribed text.
    private static let sampleRate = 16000
    /// The wav2vec2 feature extractor reduces T by a factor of ~320.
    private static let featureStride = 320

    func transcribe(
        audio: [Float],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> String {
        let normalized = AudioNormalizer.normalize(audio)
        guard !normalized.isEmpty else { return "" }

        if normalized.count <= maxInputLength {
            let result = try transcribeChunk(normalized)
            onProgress?(1.0)
            return result
        }

        // Split long audio into chunks
        let totalChunks = (normalized.count + maxInputLength - 1) / maxInputLength
        var results = [String]()
        var chunkIndex = 0
        var offset = 0
        while offset < normalized.count {
            let end = min(offset + maxInputLength, normalized.count)
            let chunk = Array(normalized[offset..<end])
            let text = try transcribeChunk(chunk)
            if !text.isEmpty {
                results.append(text)
            }
            chunkIndex += 1
            onProgress?(Double(chunkIndex) / Double(totalChunks))
            offset = end
        }
        return results.joined(separator: " ")
    }

    /// Find the smallest allowed input length that fits the given sample count.
    private func bestAllowedLength(for count: Int) -> Int {
        allowedLengths.first(where: { $0 >= count }) ?? maxInputLength
    }

    /// Transcribe a single chunk of normalized audio (must fit within maxInputLength).
    private func transcribeChunk(_ samples: [Float]) throws -> String {
        let paddedLength = bestAllowedLength(for: max(samples.count, Self.sampleRate))

        let input = try MLMultiArray(
            shape: [1, NSNumber(value: paddedLength)],
            dataType: .float16
        )

        // Copy data efficiently, remaining elements stay zero-initialized
        let ptr = input.dataPointer.assumingMemoryBound(to: Float16.self)
        for (i, sample) in samples.enumerated() {
            ptr[i] = Float16(sample)
        }

        let inputFeatures = try MLDictionaryFeatureProvider(
            dictionary: ["audio": MLFeatureValue(multiArray: input)]
        )
        let prediction = try model.prediction(from: inputFeatures)

        guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue else {
            throw ASRError.missingOutput
        }

        let actualFrames = samples.count / Self.featureStride

        let text: String
        if logits.dataType == .float16 {
            text = CTCDecoder.decode(logits: logits, vocabulary: vocabulary, maxTimeSteps: actualFrames)
        } else {
            text = CTCDecoder.decodeFloat32(logits: logits, vocabulary: vocabulary, maxTimeSteps: actualFrames)
        }

        return postProcessor.process(text)
    }

    /// Run a minimal dummy prediction to warm up Metal shaders and Neural Engine.
    /// Call once after loading to avoid slow first real prediction.
    func warmUp() throws {
        let minLength = allowedLengths.first ?? 16_000
        let input = try MLMultiArray(shape: [1, NSNumber(value: minLength)], dataType: .float16)
        let features = try MLDictionaryFeatureProvider(
            dictionary: ["audio": MLFeatureValue(multiArray: input)]
        )
        _ = try model.prediction(from: features)
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
