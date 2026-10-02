import Foundation

/// Drops "you" lines that are the mic hearing the call through the speakers.
///
/// On a call without headphones the mic picks up the other side, so the same
/// sentence arrives on both streams, in either order. System audio is the clean
/// copy, so a mic utterance waits a few seconds of system audio, then is dropped
/// when most of its words were just said on the system stream.
final class EchoFilter {
    /// Mic lines wait this much system audio before they can be judged.
    static let holdSeconds: Double = 3
    /// System lines within this many seconds of a mic line count as its echo source.
    static let windowSeconds: Double = 20
    /// Share of a mic line's words that must appear on the system side.
    static let overlapThreshold: Double = 0.6
    /// Short replies ("yeah", "got it") are kept even when the other side said them.
    static let minimumWords = 4

    private var recentThem: [(t: Double, words: Set<String>)] = []
    private var pendingYou: [(utterance: LiveUtterance, readyAt: Double)] = []
    private(set) var droppedCount = 0

    func addThem(_ utterance: LiveUtterance) {
        recentThem.append((utterance.t, Self.words(utterance.text)))
        recentThem.removeAll { $0.t < utterance.t - 180 }
    }

    func holdYou(_ utterance: LiveUtterance, micPosition: Double) {
        pendingYou.append((utterance, micPosition + Self.holdSeconds))
    }

    /// Mic lines whose hold is over and that are not echoes. With no system
    /// stream there is nothing to echo, so everything goes out at once.
    func release(systemPosition: Double?, themPartial: String = "", force: Bool = false) -> [LiveUtterance] {
        var released: [LiveUtterance] = []
        var kept: [(utterance: LiveUtterance, readyAt: Double)] = []
        for entry in pendingYou {
            guard force || systemPosition == nil || systemPosition! >= entry.readyAt else {
                kept.append(entry)
                continue
            }
            if isEcho(entry.utterance.text, near: entry.utterance.t, extraThem: themPartial) {
                droppedCount += 1
            } else {
                released.append(entry.utterance)
            }
        }
        pendingYou = kept
        return released
    }

    /// Whether `text` (heard on the mic around `t`) was just said on the system side.
    func isEcho(_ text: String, near t: Double, extraThem: String = "") -> Bool {
        let mine = Self.wordList(text)
        guard mine.count >= Self.minimumWords else { return false }
        var theirs = Self.words(extraThem)
        for entry in recentThem where abs(entry.t - t) <= Self.windowSeconds {
            theirs.formUnion(entry.words)
        }
        guard !theirs.isEmpty else { return false }
        let shared = mine.filter { theirs.contains($0) }.count
        return Double(shared) / Double(mine.count) >= Self.overlapThreshold
    }

    static func wordList(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func words(_ text: String) -> Set<String> {
        Set(wordList(text))
    }
}
