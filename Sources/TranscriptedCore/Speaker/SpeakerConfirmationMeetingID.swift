// SpeakerConfirmationMeetingID.swift
// Which "meeting" a user confirmation counts toward.
//
// Silent naming waits until someone has been confirmed in enough distinct
// meetings (`SpeakerNamingPolicy.requiredConfirmedMeetings`). The ledger keeps
// one row per (profile, meeting id), so the meeting id decides what "distinct"
// means. A live meeting uses its transcript id. An imported file gets a new
// transcript id every time it's imported, so importing the same recording five
// times would look like five meetings. For imports the id is derived from the
// file's content key instead: every import of identical audio maps to the same
// id and counts once.
//
// The id is only ever a ledger key. It never names a transcript file, and it's
// never logged or sent anywhere.

import CryptoKit
import Foundation

public enum SpeakerConfirmationMeetingID {
    /// The meeting id confirmations from this transcript should be recorded under.
    /// `importedContentKey` is the imported source file's content key (hex
    /// SHA-256 of its bytes); nil for live recordings and re-transcriptions,
    /// which keep their transcript id.
    public static func resolve(transcriptId: UUID, importedContentKey: String?) -> UUID {
        guard let key = importedContentKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return transcriptId
        }
        return forImportedContent(key: key)
    }

    /// A stable, name-based UUID (RFC 4122 version 5 layout, SHA-256 digest)
    /// for one imported audio content key. Same key in, same id out, across
    /// launches and installs.
    public static func forImportedContent(key: String) -> UUID {
        let digest = SHA256.hash(data: Data((namespace + key.lowercased()).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static let namespace = "transcripted.speaker-confirmation.imported-audio.v1:"
}
