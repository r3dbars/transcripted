import Foundation

func testNextSentenceSemanticCache() async {
    await runSuite("Meaning cache prunes unused keys without starting an embedding server") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            let unused = "unused-content-key"
            try fixture.seed([live, unused])
            let index = fixture.index()
            index.start()
            defer { index.stop() }
            await fixture.refresh(index)
            assertEqual(try fixture.keys(), Set([live]), "a complete corpus keeps only referenced vectors")
            assertEqual(fixture.serverCalls, 0, "prune-only refresh must not probe or launch a server")
            assertEqual(fixture.embeddingCalls, 0, "existing vectors need no embedding")
            assertEqual(try fixture.vector(live), fixture.vector, "retained vector bytes and dimensions stay unchanged")
        }
    }

    await runSuite("Meaning cache keeps a shared content vector until its final capture disappears") {
        await withMeaningCacheFixture { fixture in
            let shared = try fixture.capture("one.md")
            assertEqual(try fixture.capture("two.md"), shared, "identical passages share the existing content key")
            try fixture.seed([shared])
            let index = fixture.index()
            index.start()
            defer { index.stop() }
            await fixture.refresh(index)
            try fixture.removeCapture("one.md")
            await fixture.refresh(index)
            assertEqual(try fixture.keys(), Set([shared]), "one surviving reference keeps the shared vector")
            try fixture.removeCapture("two.md")
            await fixture.refresh(index)
            assertEqual(try fixture.keys(), Set<String>(), "a complete empty corpus removes the last unused vector")
            assertEqual(fixture.serverCalls, 0, "deleting captures does not require an embedding server")
        }
    }

    await runSuite("Meaning cache accounts for every listed capture before pruning") {
        await withMeaningCacheFixture { fixture in
            let common = try fixture.capture("000.md")
            for number in 1...70 { _ = try fixture.capture(String(format: "%03d.md", number)) }
            let last = try fixture.capture("999.md", text: "The final synthetic capture must remain in the corpus even beyond the first embedding batch of files.")
            try fixture.seed([common, last, "unused-content-key"])
            let index = fixture.index()
            index.start()
            defer { index.stop() }
            await fixture.refresh(index)
            assertEqual(try fixture.keys(), Set([common, last]), "late-file keys remain live beyond an embedding batch boundary")
            assertEqual(fixture.serverCalls, 0, "a complete cached corpus does not start a model")
        }
    }

    await runSuite("Cached meaning queries ensure readiness before embedding both search and mentions") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            try fixture.seed([live])
            fixture.ready = true
            fixture.vectorsAvailable = true
            let index = fixture.index()
            await fixture.start(index)
            defer { index.stop() }
            assertEqual(fixture.providerEvents, [], "starting a fully cached index does not launch a model")
            let hits = await index.search("synthetic context", screen: "")
            assertEqual(hits.count, 1, "a fully cached corpus remains searchable after a fresh index starts")
            assertEqual(fixture.providerEvents, ["ready", "embed"], "query embedding must follow readiness")
            fixture.providerEvents = []
            let mentions = await index.mentions(of: ["Fixture"], relatedTo: "synthetic context")
            assertEqual(mentions.count, 1, "a cached named passage remains available to mentions")
            assertEqual(fixture.providerEvents, ["ready", "embed"], "mentions query embedding must also follow readiness")
        }
    }

    await runSuite("An unavailable server prevents cached query embedding while mentions retain their lexical fallback") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            try fixture.seed([live])
            let index = fixture.index()
            await fixture.start(index)
            defer { index.stop() }
            let hits = await index.search("synthetic context", screen: "")
            assertTrue(hits.isEmpty, "search cannot rank a query without an available embedder")
            let mentions = await index.mentions(of: ["Fixture"], relatedTo: "synthetic context")
            assertEqual(mentions.count, 1, "unranked lexical mentions preserve existing fallback behavior")
            assertEqual(fixture.providerEvents, ["ready", "ready"], "neither query may embed before readiness")
            assertEqual(fixture.embeddingCalls, 0, "the unavailable control must never call the fake embedder")
        }
    }

    await runSuite("A failed prune write retries on the next complete scan without new embeddings") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            try fixture.seed([live, "unused-content-key"])
            let before = try fixture.cacheBytes()
            fixture.failingWrites = 1
            let index = fixture.index()
            await fixture.start(index)
            defer { index.stop() }
            assertEqual(fixture.cacheWrites, 1, "the initial complete scan attempts its prune write")
            assertEqual(try fixture.cacheBytes(), before, "an injected failed write leaves the old disk cache intact")
            await fixture.refresh(index)
            assertEqual(fixture.cacheWrites, 2, "the next complete scan retries the dirty cache")
            assertEqual(try fixture.keys(), Set([live]), "the retry durably removes the unused vector")
            assertEqual(fixture.serverCalls, 0, "persistence retry needs no model or new embeddings")
        }
    }

    await runSuite("A mixed incomplete scan cannot persist readable new captures") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            try fixture.seed([live, "unused-content-key"])
            let newKey = try fixture.capture("new.md", text: "A readable new synthetic file cannot authorize a cache replacement while another kind is unreadable.")
            let before = try fixture.cacheBytes()
            fixture.scanFailure = .writingListing
            fixture.ready = true
            fixture.vectorsAvailable = true
            let index = fixture.index()
            await fixture.start(index)
            defer { index.stop() }
            assertEqual(try fixture.cacheBytes(), before, "a mixed scan must preserve the entire original disk cache")
            assertEqual(fixture.cacheWrites, 0, "new readable chunks do not permit a partial-corpus write")
            assertEqual(fixture.embeddingCalls, 0, "an incomplete refresh does not start embedding new passages")
            fixture.scanFailure = nil
            await fixture.refresh(index)
            assertEqual(try fixture.keys(), Set([live, newKey]), "a later complete scan can prune and add the new vector")
            assertTrue(fixture.embeddingCalls > 0, "the complete control actually reaches the successful fake embedder")
        }
    }

    await runSuite("Meaning cache preserves disk bytes after incomplete directory metadata or Markdown scans") {
        for failure in MeaningCacheFixture.ScanFailure.allCases {
            await withMeaningCacheFixture { fixture in
                let live = try fixture.capture("live.md")
                try fixture.seed([live, "unused-content-key"])
                let before = try fixture.cacheBytes()
                fixture.scanFailure = failure
                let index = fixture.index()
                index.start()
                defer { index.stop() }
                await fixture.refresh(index)
                assertEqual(try fixture.cacheBytes(), before, "an incomplete scan cannot authorize pruning")
                assertEqual(fixture.cacheWrites, 0, "failed scan alone must not rewrite the cache")
            }
        }
    }

    await runSuite("Meaning cache confirms an absent optional kind only through its reachable library parent") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            try fixture.seed([live, "unused-content-key"])
            try fixture.removeEmptyWritingDirectory()
            let index = fixture.index()
            index.start()
            defer { index.stop() }
            await fixture.refresh(index)
            assertEqual(try fixture.keys(), Set([live]), "a missing kind under a listed library is authoritatively empty")
        }
    }

    await runSuite("Meaning cache prunes unused keys even when new embeddings are unavailable") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            try fixture.seed([live, "unused-content-key"])
            _ = try fixture.capture("new.md", text: "A different synthetic passage needs a new derived vector for this deterministic cache fixture.")
            fixture.ready = false
            let index = fixture.index()
            index.start()
            defer { index.stop() }
            await fixture.refresh(index)
            assertEqual(try fixture.keys(), Set([live]), "server availability does not gate complete-scan pruning")
            assertTrue(fixture.serverCalls > 0, "missing embeddings consult only the injected readiness provider")
            assertEqual(fixture.embeddingCalls, 0, "an unavailable server cannot be asked for vectors")
        }
    }

    await runSuite("Meaning cache persists pruning when a new embedding batch fails") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            try fixture.seed([live, "unused-content-key"])
            _ = try fixture.capture("new.md", text: "Another synthetic passage demonstrates that a failed batch cannot restore unused cached content.")
            fixture.ready = true
            let index = fixture.index()
            index.start()
            defer { index.stop() }
            await fixture.refresh(index)
            assertEqual(try fixture.keys(), Set([live]), "pruning remains durable when the fake embedder returns nil")
            assertTrue(fixture.embeddingCalls > 0, "the failing batch should actually reach the injected fake")
        }
    }

    await runSuite("Meaning cache refuses to overwrite corrupt unreadable or invalid vector data") {
        for failure in MeaningCacheFixture.CacheFailure.allCases {
            await withMeaningCacheFixture { fixture in
                _ = try fixture.capture("live.md")
                try fixture.seed(["unused-content-key"])
                if failure == .corruptJSON { try fixture.replaceCache(Data("not JSON".utf8)) }
                if failure == .invalidVector { try fixture.replaceCache(Data("{\"key\":\"aW52YWxpZA==\"}".utf8)) }
                fixture.cacheFailure = failure
                fixture.ready = true
                fixture.vectorsAvailable = true
                let before = try fixture.cacheBytes()
                let index = fixture.index()
                index.start()
                defer { index.stop() }
                await fixture.refresh(index)
                assertEqual(try fixture.cacheBytes(), before, "failed cache decoding or reading must preserve original bytes")
                assertEqual(fixture.cacheWrites, 0, "a cache that was not successfully loaded is not safe to replace")
            }
        }
    }

    await runSuite("Stopping the meaning index during a scan cannot prune the cache") {
        await withMeaningCacheFixture { fixture in
            let live = try fixture.capture("live.md")
            try fixture.seed([live, "unused-content-key"])
            let before = try fixture.cacheBytes()
            let index = fixture.index()
            fixture.duringList = { index.stop() }
            index.start()
            defer { index.stop() }
            await fixture.refresh(index)
            assertEqual(try fixture.cacheBytes(), before, "a cancelled scan cannot authorize pruning")
            assertEqual(fixture.cacheWrites, 0, "stopping leaves the persisted cache alone")
            fixture.duringList = nil
        }
    }
}

private func withMeaningCacheFixture(_ body: (MeaningCacheFixture) async throws -> Void) async {
    do {
        let fixture = try MeaningCacheFixture()
        do { try await body(fixture) } catch { assertTrue(false, "owned meaning-cache fixture operation failed") }
        do { try fixture.cleanup() } catch { assertTrue(false, "owned meaning-cache fixture cleanup failed") }
    } catch {
        assertTrue(false, "owned meaning-cache fixture setup failed")
    }
}

private final class MeaningCacheFixture: @unchecked Sendable {
    enum ScanFailure: CaseIterable, Equatable { case listing, offlineLibrary, metadata, markdown, writingListing }
    enum CacheFailure: CaseIterable, Equatable { case unreadable, corruptJSON, invalidVector }
    let parent: URL
    let root: URL
    let library: URL
    let cacheURL: URL
    let vector = [Float](repeating: 0.0625, count: 256)
    var scanFailure: ScanFailure?
    var cacheFailure: CacheFailure?
    var duringList: (() -> Void)?
    var ready = false
    var vectorsAvailable = false
    var serverCalls = 0
    var embeddingCalls = 0
    var cacheWrites = 0
    var failingWrites = 0
    var providerEvents: [String] = []

    init() throws {
        parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        root = parent.appendingPathComponent("MeaningCacheFixture-\(UUID().uuidString)", isDirectory: true)
        library = root.appendingPathComponent("captures", isDirectory: true)
        cacheURL = root.appendingPathComponent("cache/embeddings-256.json")
        for kind in ["meetings", "dictations", "writing"] {
            try FileManager.default.createDirectory(at: library.appendingPathComponent(kind), withIntermediateDirectories: true)
        }
    }

    func index() -> NextSentenceSemanticIndex {
        var dependencies = NextSentenceSemanticIndex.Dependencies()
        dependencies.directories = { [self] in
            [("meeting", library.appendingPathComponent("meetings")),
             ("dictation", library.appendingPathComponent("dictations")),
             ("writing", library.appendingPathComponent("writing"))]
        }
        dependencies.cacheURL = { [self] in cacheURL }
        dependencies.listDirectory = { [self] url in
            try requireOwned(url)
            duringList?()
            if scanFailure == .listing || (scanFailure == .writingListing && url.lastPathComponent == "writing") {
                throw CocoaError(.fileReadNoPermission)
            }
            if scanFailure == .offlineLibrary { throw CocoaError(.fileReadNoSuchFile) }
            return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        }
        dependencies.modifiedDate = { [self] url in
            try requireOwned(url)
            if scanFailure == .metadata { throw CocoaError(.fileReadNoPermission) }
            return try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? .distantPast
        }
        dependencies.readMarkdown = { [self] url in
            try requireOwned(url)
            if scanFailure == .markdown { throw CocoaError(.fileReadNoPermission) }
            return try String(contentsOf: url, encoding: .utf8)
        }
        dependencies.readCache = { [self] url in
            try requireOwned(url)
            if cacheFailure == .unreadable { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        dependencies.writeCache = { [self] data, url in
            try requireOwned(url)
            cacheWrites += 1
            if failingWrites > 0 {
                failingWrites -= 1
                throw CocoaError(.fileWriteNoPermission)
            }
            try replaceCache(data)
        }
        dependencies.serverReady = { [self] in
            serverCalls += 1
            providerEvents.append("ready")
            return ready
        }
        dependencies.embeddings = { [self] inputs in
            embeddingCalls += 1
            providerEvents.append("embed")
            return vectorsAvailable ? inputs.map { _ in vector } : nil
        }
        return NextSentenceSemanticIndex(dependencies: dependencies)
    }

    func start(_ index: NextSentenceSemanticIndex) async {
        await withCheckedContinuation { continuation in index.start { continuation.resume() } }
    }

    func refresh(_ index: NextSentenceSemanticIndex) async {
        await withCheckedContinuation { continuation in index.refresh { continuation.resume() } }
    }

    @discardableResult
    func capture(_ name: String, text: String = "This synthetic passage contains enough ordinary words to form a deterministic indexed meeting chunk.") throws -> String {
        let url = library.appendingPathComponent("meetings").appendingPathComponent(name)
        try requireOwned(url)
        let markdown = "---\ncapture_type: meeting\ntitle: Synthetic\ndate: 2026-11-10\n---\n\n**00:00** [System/Fixture]\n\(text)\n"
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        guard let chunk = NextSentenceChunker.chunks(markdown: markdown, kind: "meeting").first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return NextSentenceSemanticIndex.key(chunk)
    }

    func removeCapture(_ name: String) throws {
        let url = library.appendingPathComponent("meetings").appendingPathComponent(name)
        try requireOwned(url)
        try FileManager.default.removeItem(at: url)
    }

    func removeEmptyWritingDirectory() throws {
        let url = library.appendingPathComponent("writing")
        try requireOwned(url)
        try FileManager.default.removeItem(at: url)
    }

    func seed(_ keys: [String]) throws {
        let encoded = vector.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        try replaceCache(JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: keys.map { ($0, encoded) })))
    }

    func replaceCache(_ bytes: Data) throws {
        try requireOwned(cacheURL)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: cacheURL, options: .atomic)
    }

    func cacheBytes() throws -> Data { try Data(contentsOf: cacheURL) }

    func keys() throws -> Set<String> {
        let stored = try JSONSerialization.jsonObject(with: cacheBytes()) as? [String: String] ?? [:]
        return Set(stored.keys)
    }

    func vector(_ key: String) throws -> [Float] {
        let stored = try JSONSerialization.jsonObject(with: cacheBytes()) as? [String: String] ?? [:]
        guard let encoded = stored[key], let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func requireOwned(_ url: URL) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
    }

    func cleanup() throws {
        let prefix = "MeaningCacheFixture-"
        let leaf = root.lastPathComponent
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard leaf.hasPrefix(prefix), UUID(uuidString: String(leaf.dropFirst(prefix.count))) != nil,
              canonical == root.standardizedFileURL, canonical.deletingLastPathComponent() == parent,
              values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: root)
    }
}
