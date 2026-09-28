import Foundation

/// Blends a scene-level intent prior with the live, text-conditioned futures.
/// The prior keeps Tilde's original read of the conversation alive across
/// successive word-boundary requests; the live plan gets more weight so what
/// the user actually starts writing can quickly override the prior.
public enum IntentFutureFusion {
    public static func fuse(
        prior: [IntentFuture],
        live: [IntentFuture],
        priorWeight: Double = 0.35,
        maximumFutures: Int = IntentFuturesPlanner.maximumFutures
    ) -> [IntentFuture] {
        guard maximumFutures > 0 else { return [] }
        let p = min(max(priorWeight, 0), 1)
        let l = 1 - p
        var scores: [IntentFuture.Kind: Double] = [:]
        for future in prior { scores[future.kind, default: 0] += future.weight * p }
        for future in live { scores[future.kind, default: 0] += future.weight * l }

        let ranked = scores
            .filter { $0.value > 0 }
            .sorted {
                if $0.value == $1.value { return $0.key.rawValue < $1.key.rawValue }
                return $0.value > $1.value
            }
            .prefix(maximumFutures)
        let total = ranked.reduce(0.0) { $0 + $1.value }
        guard total > 0 else { return [] }
        return ranked.map { IntentFuture(kind: $0.key, weight: $0.value / total) }
    }
}
