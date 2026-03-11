import CoreML
import Foundation

/// Greedy CTC decoder: argmax → consecutive dedup → blank removal.
/// Matches the Python CTC decoding logic from pipeline.py:318-330.
struct CTCDecoder {
    /// Special token indices to skip during decoding.
    /// Matches Python's `skip_special_tokens=True` (pipeline.py:249).
    /// 0=<s> (CTC blank), 1=<pad>, 2=</s>, 3=<unk>
    static let specialTokenIndices: Set<Int> = [0, 1, 2, 3]

    /// SentencePiece word boundary marker.
    static let wordBoundary = "\u{2581}"

    /// Decode CTC logits into text.
    ///
    /// - Parameters:
    ///   - logits: MLMultiArray with shape [1, T, vocab_size]
    ///   - vocabulary: Array mapping token index to string
    /// - Returns: Decoded text string
    static func decode(logits: MLMultiArray, vocabulary: [String], maxTimeSteps: Int? = nil) -> String {
        let totalSteps = logits.shape[1].intValue
        let timeSteps = min(maxTimeSteps ?? totalSteps, totalSteps)
        let vocabSize = logits.shape[2].intValue

        // Argmax per timestep
        var tokenIds = [Int]()
        tokenIds.reserveCapacity(timeSteps)

        let ptr = logits.dataPointer.assumingMemoryBound(to: Float16.self)
        let stride0 = logits.strides[1].intValue
        let stride1 = logits.strides[2].intValue

        for t in 0..<timeSteps {
            var maxIdx = 0
            var maxVal: Float = -.infinity
            let baseOffset = t * stride0
            for v in 0..<vocabSize {
                let val = Float(ptr[baseOffset + v * stride1])
                if val > maxVal {
                    maxVal = val
                    maxIdx = v
                }
            }
            tokenIds.append(maxIdx)
        }

        // Consecutive dedup + special token removal
        var decoded = [Int]()
        var prev = -1
        for id in tokenIds {
            if id != prev {
                if !specialTokenIndices.contains(id) {
                    decoded.append(id)
                }
                prev = id
            }
        }

        // Token IDs → text
        let text = decoded.map { idx in
            idx < vocabulary.count ? vocabulary[idx] : ""
        }.joined()

        return text
            .replacingOccurrences(of: wordBoundary, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Decode CTC logits with Float32 data type.
    static func decodeFloat32(logits: MLMultiArray, vocabulary: [String], maxTimeSteps: Int? = nil) -> String {
        let totalSteps = logits.shape[1].intValue
        let timeSteps = min(maxTimeSteps ?? totalSteps, totalSteps)
        let vocabSize = logits.shape[2].intValue

        var tokenIds = [Int]()
        tokenIds.reserveCapacity(timeSteps)

        let ptr = logits.dataPointer.assumingMemoryBound(to: Float.self)
        let stride0 = logits.strides[1].intValue
        let stride1 = logits.strides[2].intValue

        for t in 0..<timeSteps {
            var maxIdx = 0
            var maxVal: Float = -.infinity
            let baseOffset = t * stride0
            for v in 0..<vocabSize {
                let val = ptr[baseOffset + v * stride1]
                if val > maxVal {
                    maxVal = val
                    maxIdx = v
                }
            }
            tokenIds.append(maxIdx)
        }

        var decoded = [Int]()
        var prev = -1
        for id in tokenIds {
            if id != prev {
                if !specialTokenIndices.contains(id) {
                    decoded.append(id)
                }
                prev = id
            }
        }

        let text = decoded.map { idx in
            idx < vocabulary.count ? vocabulary[idx] : ""
        }.joined()

        return text
            .replacingOccurrences(of: wordBoundary, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
