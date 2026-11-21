import Foundation
import SwiftUI

/// Runs Find on the Dictations page over every saved dictation, not just the
/// loaded page of ten. Typing is debounced; the library is read once off the
/// main thread and reused until the page says it changed (a save, a delete,
/// an undo, a refresh). Matching is `DictationSearch`.
@MainActor
final class DictationSearchModel: ObservableObject {
    @Published private(set) var sections: [HomeDaySection<SavedDictationEntry>] = []
    @Published private(set) var isSearching = false
    @Published private(set) var canLoadMore = false

    /// Far above any real library; `recentSavedDictations` stops early when
    /// the files run out.
    private static let libraryReadLimit = 1_000_000

    private var query = ""
    private var limit = DictationSearch.pageSize
    private var matches: [SavedDictationEntry] = []
    private var library: [SavedDictationEntry]?
    private var task: Task<Void, Never>?

    var isActive: Bool { DictationSearch.isActive(query: query) }

    func update(query newQuery: String) {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        limit = DictationSearch.pageSize
        // The old results stay up until this pass lands, but their Load more
        // belonged to the old query.
        canLoadMore = false
        run(debounce: true)
    }

    func loadMore() {
        guard isActive, !isSearching, canLoadMore else { return }
        limit += DictationSearch.pageSize
        publish()
    }

    /// Something on disk changed; read the library again on the next pass.
    func libraryChanged() {
        library = nil
        if isActive {
            run(debounce: false)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        query = ""
        library = nil
        matches = []
        sections = []
        isSearching = false
        canLoadMore = false
    }

    private func run(debounce: Bool) {
        task?.cancel()
        guard isActive else {
            task = nil
            matches = []
            sections = []
            isSearching = false
            canLoadMore = false
            return
        }
        isSearching = true
        let passQuery = query
        let cached = library
        let readLimit = Self.libraryReadLimit
        task = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            guard !Task.isCancelled else { return }
            let entries: [SavedDictationEntry]
            if let cached {
                entries = cached
            } else {
                entries = await Task.detached(priority: .userInitiated) {
                    DictationTranscriptStore.recentSavedDictations(limit: readLimit)
                }.value
            }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                DictationSearch.matches(entries, query: passQuery)
            }.value
            guard let self, !Task.isCancelled, passQuery == self.query else { return }
            self.library = entries
            self.matches = found
            self.isSearching = false
            self.publish()
        }
    }

    private func publish() {
        let visible = Array(matches.prefix(limit))
        sections = HomeViewModel.groupByDay(visible, dateForItem: \.createdAt)
        canLoadMore = matches.count > limit
    }
}
