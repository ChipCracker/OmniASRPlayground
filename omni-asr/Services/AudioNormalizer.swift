import Foundation
import Accelerate

/// Normalizes audio samples to zero mean and unit variance.
/// Matches Python's `layer_norm(waveform, waveform.shape)` from audio.py.
struct AudioNormalizer {
    /// LayerNorm epsilon, matching PyTorch's default.
    private static let epsilon: Float = 1e-5

    static func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let count = Float(samples.count)

        // Compute mean using Accelerate
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))

        // Compute variance: mean((x - mean)^2)
        var negMean = -mean
        var centered = [Float](repeating: 0, count: samples.count)
        vDSP_vsadd(samples, 1, &negMean, &centered, 1, vDSP_Length(samples.count))

        var squaredSum: Float = 0
        vDSP_dotpr(centered, 1, centered, 1, &squaredSum, vDSP_Length(samples.count))
        let variance = squaredSum / count

        // Normalize: (x - mean) / sqrt(variance + epsilon)
        let std = sqrt(variance + epsilon)
        var invStd = 1.0 / std
        var result = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(centered, 1, &invStd, &result, 1, vDSP_Length(samples.count))

        return result
    }
}
