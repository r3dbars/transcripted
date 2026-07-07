import Accelerate
import Foundation

public enum SpeakerVectorMath {
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0

        vDSP_dotpr(lhs, 1, rhs, 1, &dotProduct, vDSP_Length(lhs.count))
        vDSP_dotpr(lhs, 1, lhs, 1, &lhsNorm, vDSP_Length(lhs.count))
        vDSP_dotpr(rhs, 1, rhs, 1, &rhsNorm, vDSP_Length(rhs.count))

        let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
        guard denominator > 0 else { return 0 }

        return Double(dotProduct / denominator)
    }

    /// Best cosine of `candidate` against a profile's representative vectors: its blended `average`
    /// (`SpeakerProfile.embedding`) plus any stored multi-exemplar voiceprints. Representatives whose
    /// dimension differs from `candidate` are skipped.
    ///
    /// With an empty `exemplars` set this returns exactly `cosineSimilarity(candidate, average)`, so
    /// legacy single-average profiles match identically. With exemplars it returns the max, so a
    /// returning voice is scored against its best-fitting capture condition rather than a single
    /// blended-across-conditions centroid. Because it only ever *adds* candidate vectors, the score
    /// is monotonically non-decreasing versus the single-average path.
    public static func bestSimilarity(candidate: [Float], average: [Float], exemplars: [[Float]]) -> Double {
        var best = candidate.count == average.count ? cosineSimilarity(candidate, average) : -1
        for exemplar in exemplars where exemplar.count == candidate.count {
            best = max(best, cosineSimilarity(candidate, exemplar))
        }
        return best
    }

    public static func l2Normalize(_ values: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_dotpr(values, 1, values, 1, &norm, vDSP_Length(values.count))
        norm = sqrt(norm)
        guard norm > 0 else { return values }

        var result = [Float](repeating: 0, count: values.count)
        var divisor = norm
        vDSP_vsdiv(values, 1, &divisor, &result, 1, vDSP_Length(values.count))
        return result
    }
}
