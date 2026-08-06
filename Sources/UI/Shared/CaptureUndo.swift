// CaptureUndo.swift
// The shared "delete now, offer Undo for a few seconds" seam that replaces
// delete-confirmation dialogs across Home (meetings) and Dictations, per the
// redesign prototype's inline `.undoline` row ("Deleted "…" · Undo").
//
// Design: the destructive step always runs immediately (files move to the
// Trash, or a day file is rewritten without the deleted entry) so the row
// can disappear from the list right away. `CaptureUndoManager` then holds a
// short grace window during which the caller-supplied `id` has a pending
// `UndoOffer` the UI can render an `UndoLineView` for; `undo(_:)` reverses
// the action byte-for-byte, and `finalize(_:)` (called automatically once
// the window elapses, or explicitly) makes it permanent.
//
// This file intentionally does not know about meetings or dictations. The
// trash-planning logic for meetings already lives in `HomeMeetingDeletion`;
// the day-file entry-removal logic already lives in `DictationTranscriptStore`.
// Callers compute *what* to delete and hand this file the URLs / before-and-
// after file content; this file only performs and reverses the mechanical
// move/rewrite and runs the grace-window bookkeeping.

import Combine
import Foundation
import SwiftUI

// MARK: - Offer

/// A single reversible destructive action awaiting the user's grace window to
/// elapse. The shell looks this up by `id` (a meeting id, a dictation
/// entry id, …) and renders one `UndoLineView` in place of the deleted row
/// while it exists.
struct UndoOffer: Identifiable, Equatable, Sendable {
    let id: String
    /// e.g. `Deleted "Product review"` — see `CaptureUndoMessage.deleted(_:)`.
    let message: String
    let expiresAt: Date
}

/// Copy helper so every call site builds the same "Deleted "…"" string the
/// prototype's inline undo row uses (smart quotes, not straight ones).
enum CaptureUndoMessage {
    static func deleted(_ title: String) -> String {
        "Deleted \u{201C}\(title)\u{201D}"
    }
}

// MARK: - Manager

/// Owns every in-flight undo-offer across the app. One shared instance is
/// enough: callers key their own operations by an id from their own domain
/// (meeting id, dictation entry id), so Home and Dictations never collide.
@MainActor
final class CaptureUndoManager: ObservableObject {
    static let shared = CaptureUndoManager()

    /// Matches the redesign prototype's inline undo row (6000ms timeout).
    /// `nonisolated` because it is a plain constant used in a default
    /// argument expression, which is evaluated outside actor isolation.
    nonisolated static let defaultGraceWindow: TimeInterval = 6

    @Published private(set) var offers: [UndoOffer] = []

    private var pending: [String: PendingUndo] = [:]
    private var expirations: [String: DispatchWorkItem] = [:]
    private let graceWindow: TimeInterval
    private let now: () -> Date

    init(
        graceWindow: TimeInterval = CaptureUndoManager.defaultGraceWindow,
        now: @escaping () -> Date = Date.init
    ) {
        self.graceWindow = graceWindow
        self.now = now
    }

    /// True while `id` still has a live undo offer.
    func isPending(_ id: String) -> Bool {
        pending[id] != nil
    }

    func offer(for id: String) -> UndoOffer? {
        offers.first { $0.id == id }
    }

    // MARK: Trash-based file deletion (meetings: transcript + retained audio)

    /// Moves every URL in `urls` to the Trash immediately, then opens an
    /// undo offer for `id`. `urls` is the flat file list a caller already
    /// planned (e.g. `HomeMeetingDeletion.plan(for:)`'s transcript, summary,
    /// and audio-directory URLs) — this performs and reverses the move, it
    /// does not decide what belongs to one logical capture.
    ///
    /// `finalize` runs once the deletion becomes permanent (grace window
    /// elapses, or an explicit `finalize(id)`/next `deleteFiles`/`deleteRange`
    /// call for the same id) — use it for any additional bookkeeping the
    /// existing deletion path did alongside the file removal (cache
    /// invalidation, change notifications, etc.), not for anything that
    /// needs to be reversible: reversible state belongs in the trash move
    /// itself.
    @discardableResult
    func deleteFiles(
        id: String,
        urls: [URL],
        message: String,
        fileManager: FileManager = .default,
        finalize: @escaping () -> Void = {}
    ) throws -> UndoOffer {
        cancelExisting(id)

        let trashed = try CaptureTrashOperation.trash(urls, fileManager: fileManager)
        let revert = {
            CaptureTrashOperation.restore(trashed, fileManager: fileManager)
        }

        return register(id: id, message: message, revert: revert, finalize: finalize)
    }

    // MARK: Dictation-entry deletion (rewrite the day file in place)

    /// Rewrites `url` from `originalContent` to `newContent` immediately,
    /// then opens an undo offer for `id`. The dictation code owns the
    /// day-file entry grammar and computes both strings itself (see
    /// `DictationTranscriptStore`); this only performs the write and, on
    /// undo, restores `originalContent` verbatim.
    ///
    /// Not for the case where deleting the entry empties the whole day
    /// file — that should trash the file via `deleteFiles` instead, since
    /// this always leaves `url` on disk (as `newContent`, or restored back
    /// to `originalContent`).
    @discardableResult
    func deleteRange(
        id: String,
        in url: URL,
        originalContent: String,
        newContent: String,
        message: String,
        fileManager: FileManager = .default,
        finalize: @escaping () -> Void = {}
    ) throws -> UndoOffer {
        cancelExisting(id)

        try CaptureContentRewrite.write(newContent, to: url, fileManager: fileManager)
        let revert = {
            _ = try? CaptureContentRewrite.write(originalContent, to: url, fileManager: fileManager)
        }

        return register(id: id, message: message, revert: revert, finalize: finalize)
    }

    // MARK: Undo / finalize

    /// Reverses the destructive action for `id` if its grace window is
    /// still open. No-op once expired, already undone, or already
    /// finalized.
    func undo(_ id: String) {
        resolve(id) { $0.revert() }
    }

    /// Makes `id`'s destructive action permanent immediately instead of
    /// waiting for the grace window. Called automatically when the window
    /// elapses; safe to call again (or call after `undo`) — a no-op once
    /// `id` is no longer pending.
    func finalize(_ id: String) {
        resolve(id) { $0.finalize() }
    }

    // MARK: Private

    private struct PendingUndo {
        let revert: () -> Void
        let finalize: () -> Void
    }

    private func register(
        id: String,
        message: String,
        revert: @escaping () -> Void,
        finalize: @escaping () -> Void
    ) -> UndoOffer {
        let offer = UndoOffer(id: id, message: message, expiresAt: now().addingTimeInterval(graceWindow))
        pending[id] = PendingUndo(revert: revert, finalize: finalize)
        offers.append(offer)

        let workItem = DispatchWorkItem { [weak self] in
            self?.finalize(id)
        }
        expirations[id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + graceWindow, execute: workItem)

        return offer
    }

    /// A second delete of an id that is still pending should not happen from
    /// well-behaved callers (the row is showing the undo line, not its
    /// normal actions), but finalize — not revert — the stale entry
    /// defensively so a previously-trashed file is never silently orphaned
    /// by a fresh `register` overwriting its bookkeeping.
    private func cancelExisting(_ id: String) {
        if pending[id] != nil {
            finalize(id)
        }
    }

    private func resolve(_ id: String, _ apply: (PendingUndo) -> Void) {
        guard let pendingUndo = pending.removeValue(forKey: id) else { return }
        expirations[id]?.cancel()
        expirations[id] = nil
        offers.removeAll { $0.id == id }
        apply(pendingUndo)
    }
}

// MARK: - Foundation-pure mechanics

/// Where a trashed file landed, so it can be moved back to exactly where it
/// came from.
struct TrashedFile: Equatable, Sendable {
    let originalURL: URL
    let trashedURL: URL
}

enum CaptureUndoError: LocalizedError {
    case trashDidNotReportLocation(URL)

    var errorDescription: String? {
        switch self {
        case .trashDidNotReportLocation(let url):
            return "Could not determine the Trash location for \(url.lastPathComponent)."
        }
    }
}

/// The reversible move/restore mechanics behind `deleteFiles`, kept
/// Foundation-pure (no `@MainActor`, no SwiftUI) so it is directly unit
/// testable without the grace-window bookkeeping around it.
enum CaptureTrashOperation {
    /// Moves every URL that exists on disk to the Trash, recording where
    /// each one landed. URLs that no longer exist are skipped (already gone
    /// is not a failure — mirrors `HomeMeetingDeletion`'s existing-only
    /// removal). On any failure partway through, moves everything already
    /// trashed back to its original location before rethrowing, so the
    /// operation is all-or-nothing.
    @discardableResult
    static func trash(_ urls: [URL], fileManager: FileManager = .default) throws -> [TrashedFile] {
        var trashed: [TrashedFile] = []
        do {
            for url in urls {
                guard fileManager.fileExists(atPath: url.path) else { continue }
                var resultingURL: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                guard let trashedURL = resultingURL as URL? else {
                    throw CaptureUndoError.trashDidNotReportLocation(url)
                }
                trashed.append(TrashedFile(originalURL: url, trashedURL: trashedURL))
            }
        } catch {
            restore(trashed, fileManager: fileManager)
            throw error
        }
        return trashed
    }

    /// Moves every trashed file back to its original location, recreating
    /// the parent directory if something else removed it in the meantime.
    /// Best-effort: a file the user emptied from the Trash out-of-band, or a
    /// destination that has since been reoccupied, silently stays as-is —
    /// `undo`/`finalize` are not throwing calls.
    static func restore(_ trashed: [TrashedFile], fileManager: FileManager = .default) {
        for file in trashed.reversed() {
            guard fileManager.fileExists(atPath: file.trashedURL.path) else { continue }
            let parent = file.originalURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try? fileManager.moveItem(at: file.trashedURL, to: file.originalURL)
        }
    }
}

/// The reversible rewrite mechanics behind `deleteRange`, kept Foundation-pure
/// for the same reason as `CaptureTrashOperation`.
enum CaptureContentRewrite {
    static func write(_ content: String, to url: URL, fileManager: FileManager = .default) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: url)
    }
}

// MARK: - UndoLineView

/// The inline "Deleted "…" · Undo" row from the redesign prototype's
/// `.undoline`. Renders in place of a deleted row for the life of its
/// `UndoOffer`.
struct UndoLineView: View {
    let offer: UndoOffer
    var onUndo: () -> Void

    @State private var isHoveringUndo = false

    var body: some View {
        HStack(spacing: 4) {
            Text(offer.message)
            Text("\u{00B7}")
            Button("Undo", action: onUndo)
                .buttonStyle(.plain)
                .foregroundStyle(LibraryTokens.accent)
                .underline(isHoveringUndo)
                .onHover { isHoveringUndo = $0 }
                .accessibilityIdentifier("transcripted.undo-line.undo.\(offer.id)")
        }
        .font(LibraryTokens.meta)
        .foregroundStyle(LibraryTokens.ink3)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("transcripted.undo-line.\(offer.id)")
    }
}

extension UndoLineView {
    /// Convenience for the common case of binding directly to the shared
    /// manager instead of wiring a standalone `onUndo` closure.
    init(offer: UndoOffer, manager: CaptureUndoManager) {
        self.init(offer: offer) { manager.undo(offer.id) }
    }
}
