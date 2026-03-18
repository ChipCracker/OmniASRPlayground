import Accelerate
import CoreML
import Foundation
import os

/// Manages CoreML model loading, inference, and CTC decoding.
final class CoreMLASRService: Sendable {
    enum ComputeUnitOption: String, CaseIterable, Identifiable, Sendable {
        case all = "Alle"
        case cpuAndGPU = "CPU + GPU"
        case cpuAndNeuralEngine = "CPU + ANE"
        case cpuOnly = "Nur CPU"

        var id: String { rawValue }

        var mlComputeUnits: MLComputeUnits {
            switch self {
            case .all: .all
            case .cpuAndGPU: .cpuAndGPU
            case .cpuAndNeuralEngine: .cpuAndNeuralEngine
            case .cpuOnly: .cpuOnly
            }
        }
    }

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

    private static let log = Logger(subsystem: "omni-asr", category: "CoreMLASRService")

    private let model: MLModel
    private let vocabulary: [String]
    private let postProcessor: any TokenizerPostProcessor
    private let allowedLengths: [Int]
    let maxInputLength: Int

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
        postProcessorType: ModelInfo.PostProcessorType = .identity,
        computeUnits: MLComputeUnits = .all
    ) async throws -> CoreMLASRService {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

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

    /// RMS energy threshold below which a chunk is treated as silence and skipped.
    private static let silenceRMSThreshold: Float = 0.01

    /// Compute RMS energy of a signal using vDSP.
    private static func rmsEnergy(_ samples: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    func transcribe(
        audio: [Float],
        onProgress: (@Sendable (Double) async -> Void)? = nil,
        onChunkResult: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        guard !audio.isEmpty else { return "" }

        Self.log.debug("transcribe: audio.count=\(audio.count), maxInputLength=\(self.maxInputLength), singleChunk=\(audio.count <= self.maxInputLength)")

        // Single-chunk path: global normalization (unchanged behavior)
        if audio.count <= maxInputLength {
            let normalized = AudioNormalizer.normalize(audio)
            let result = try transcribeChunk(normalized)
            Self.log.debug("transcribe single-chunk result: \"\(result.prefix(80))\"")
            await onChunkResult?(result)
            await onProgress?(1.0)
            return result
        }

        // --- Multi-chunk path: overlapping chunks with per-chunk normalization ---

        // Overlap = maxInputLength / 6 (matches HuggingFace default stride ratio)
        let overlapSamples = maxInputLength / 6
        // Stride = distance between chunk starts, aligned to featureStride
        let strideLength = ((maxInputLength - overlapSamples) / Self.featureStride) * Self.featureStride

        // Build chunk descriptors: (offset, length, leftOverlap, rightOverlap) in samples
        struct ChunkDescriptor {
            let offset: Int
            let length: Int
            let leftOverlap: Int
            let rightOverlap: Int
        }

        var chunks = [ChunkDescriptor]()
        var offset = 0
        while offset < audio.count {
            let chunkEnd = min(offset + maxInputLength, audio.count)
            let length = chunkEnd - offset
            let isFirst = offset == 0
            let isLast = chunkEnd == audio.count

            // Left overlap: half the overlap region (except first chunk)
            let leftOverlap = isFirst ? 0 : overlapSamples / 2
            // Right overlap: half the overlap region (except last chunk)
            let rightOverlap = isLast ? 0 : overlapSamples / 2

            chunks.append(ChunkDescriptor(
                offset: offset,
                length: length,
                leftOverlap: leftOverlap,
                rightOverlap: rightOverlap
            ))

            if isLast { break }
            offset += strideLength
        }

        let totalChunks = chunks.count
        Self.log.debug("transcribe multi-chunk: totalChunks=\(totalChunks), stride=\(strideLength), overlap=\(overlapSamples)")

        var results = [String]()
        for (chunkIndex, desc) in chunks.enumerated() {
            let rawChunk = Array(audio[desc.offset..<(desc.offset + desc.length)])

            // Silence detection: skip chunks with very low energy
            let rms = Self.rmsEnergy(rawChunk)
            Self.log.debug("chunk[\(chunkIndex)]: offset=\(desc.offset), len=\(desc.length), rms=\(rms), leftOvl=\(desc.leftOverlap), rightOvl=\(desc.rightOverlap)")

            if rms < Self.silenceRMSThreshold {
                Self.log.debug("chunk[\(chunkIndex)]: skipped (silence, rms=\(rms))")
                await onProgress?(Double(chunkIndex + 1) / Double(totalChunks))
                continue
            }

            // Per-chunk normalization (each chunk gets its own zero-mean/unit-variance scaling)
            let normalizedChunk = AudioNormalizer.normalize(rawChunk)

            // Convert overlap from samples to logit timesteps for trimming
            let trimLeft = desc.leftOverlap / Self.featureStride
            let trimRight = desc.rightOverlap / Self.featureStride

            let text = try transcribeChunk(normalizedChunk, trimLeft: trimLeft, trimRight: trimRight)
            Self.log.debug("chunk[\(chunkIndex)]: text=\"\(text.prefix(80))\", empty=\(text.isEmpty)")

            if !text.isEmpty {
                results.append(text)
                await onChunkResult?(text)
            }
            await onProgress?(Double(chunkIndex + 1) / Double(totalChunks))
        }

        let joined = results.joined(separator: " ")
        Self.log.debug("transcribe done: \(results.count) results, joined=\"\(joined.prefix(120))\"")
        return joined
    }

    /// Find the smallest allowed input length that fits the given sample count.
    private func bestAllowedLength(for count: Int) -> Int {
        allowedLengths.first(where: { $0 >= count }) ?? maxInputLength
    }

    /// Transcribe a single chunk of normalized audio (must fit within maxInputLength).
    private func transcribeChunk(
        _ samples: [Float],
        trimLeft: Int = 0,
        trimRight: Int = 0
    ) throws -> String {
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
            text = CTCDecoder.decode(
                logits: logits,
                vocabulary: vocabulary,
                maxTimeSteps: actualFrames,
                trimLeft: trimLeft,
                trimRight: trimRight
            )
        } else {
            text = CTCDecoder.decodeFloat32(
                logits: logits,
                vocabulary: vocabulary,
                maxTimeSteps: actualFrames,
                trimLeft: trimLeft,
                trimRight: trimRight
            )
        }

        return postProcessor.process(text)
    }

    /// Run dummy predictions for all enumerated shapes to warm up Metal shaders
    /// and Neural Engine. Reports progress per shape.
    func warmUp(onProgress: (@Sendable (Double) -> Void)? = nil) throws {
        for (index, length) in allowedLengths.enumerated() {
            let input = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
            let features = try MLDictionaryFeatureProvider(
                dictionary: ["audio": MLFeatureValue(multiArray: input)]
            )
            _ = try model.prediction(from: features)
            onProgress?(Double(index + 1) / Double(allowedLengths.count))
        }
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
