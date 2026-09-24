import Foundation

// MARK: - Meetings search paging

/// Paging and debounce for the Home meetings search.
enum HomeMeetingSearchPaging {
    /// Matches shown per page; "Load more" adds another page.
    static let pageSize = 50
    /// Pause after the last keystroke before searching.
    static let debounceNanoseconds: UInt64 = 150_000_000

    /// Whether the search box holds a real query (not just spaces).
    static func isActive(query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Meetings search index

/// In-memory index behind the Home meetings search, covering every saved
/// meeting rather than only the recent slice Home loads on screen.
///
/// Each entry keeps the Home row (without its audio attachment) and the
/// prepared haystack `HomeMeetingListFilter` searches: title, date words, and
/// named speakers. Building the index is the only disk work
/// (`RecentMeetingsScanner.loadSearchIndex`); each keystroke after that is an
/// in-memory scan. Rebuilds reuse entries whose file stamp is unchanged, so
/// refreshing after a save costs a directory listing, not a re-read of every
/// transcript.
struct HomeMeetingSearchIndex: Sendable {
    struct Entry: Sendable {
        let scanned: RecentMeetingIndexEntry
        let haystack: String

        var item: RecentMeetingItem { scanned.item }
    }

    struct SearchResult: Sendable {
        /// Newest first, at most the requested limit.
        let items: [RecentMeetingItem]
        /// True when more meetings match than `items` holds.
        let hasMore: Bool
    }

    /// Newest first.
    private(set) var entries: [Entry]

    /// Builds the index from a scan, reusing `previous` entries (and their
    /// prepared haystacks) when a file's stamp hasn't changed.
    init(scanned: [RecentMeetingIndexEntry], previous: HomeMeetingSearchIndex? = nil) {
        let reusable = previous?.entriesByPath ?? [:]
        entries = scanned.map { scannedEntry in
            if let existing = reusable[scannedEntry.path], existing.scanned.stamp == scannedEntry.stamp {
                return existing
            }
            return Entry(
                scanned: scannedEntry,
                haystack: HomeMeetingListFilter.haystack(
                    for: HomeMeetingListFilter.searchFields(for: scannedEntry.item)
                )
            )
        }
    }

    /// Scanned rows keyed by path, for `RecentMeetingsScanner.loadSearchIndex`
    /// to reuse on the next rebuild.
    var scannedEntriesByPath: [String: RecentMeetingIndexEntry] {
        entriesByPath.mapValues(\.scanned)
    }

    private var entriesByPath: [String: Entry] {
        Dictionary(entries.map { ($0.scanned.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Meetings matching `query`, newest first, capped at `limit`. An empty
    /// query matches nothing: the caller shows the normal list instead.
    func search(query: String, limit: Int) -> SearchResult {
        let tokens = HomeMeetingListFilter.tokens(in: query)
        guard !tokens.isEmpty, limit > 0 else {
            return SearchResult(items: [], hasMore: false)
        }

        var items: [RecentMeetingItem] = []
        for entry in entries where HomeMeetingListFilter.matches(tokens: tokens, haystack: entry.haystack) {
            if items.count == limit {
                return SearchResult(items: items, hasMore: true)
            }
            items.append(entry.item)
        }
        return SearchResult(items: items, hasMore: false)
    }

    /// Drops a meeting the user just deleted so it can't come back in results
    /// before the next rebuild.
    mutating func removeMeeting(id: String) {
        entries.removeAll { $0.item.id == id || $0.scanned.path == id }
    }
}
