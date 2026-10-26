import Foundation

// MARK: - Retroactive Speaker Updates: "(likely)" hedge
//
// Used by `applyRetroactiveRename` in RetroactiveSpeakerUpdater.swift, which
// profile renames and merges (Settings > Speakers) run across saved transcripts.

extension TranscriptSaver {

    /// A row written by `--name-likely-speakers` carries `Name (likely)` and was
    /// never confirmed by the user. A profile rename or merge must keep that
    /// hedge rather than make the guess look confirmed.
    static func hedgedName(_ newName: String, replacing oldName: String?) -> String {
        guard let oldName,
              oldName.hasSuffix(SpeakerMapping.likelyNameSuffix),
              !newName.hasSuffix(SpeakerMapping.likelyNameSuffix) else { return newName }
        return newName + SpeakerMapping.likelyNameSuffix
    }
}
