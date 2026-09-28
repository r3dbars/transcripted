import Foundation

func testAudioImportQueue() {
    let fileManager = FileManager.default

    func makeRoot() -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "AudioImportQueueTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func touch(_ url: URL) {
        try? Data("bytes".utf8).write(to: url, options: [.atomic])
    }

    runSuite("AudioImportQueue keeps order and skips files already waiting") {
        var queue = AudioImportQueue()
        let a = URL(fileURLWithPath: "/tmp/a.m4a")
        let b = URL(fileURLWithPath: "/tmp/b.mp3")
        let c = URL(fileURLWithPath: "/tmp/c.wav")

        assertEqual(queue.add([a, b]), 2, "both new files should be added")
        assertEqual(queue.add([b, c, URL(fileURLWithPath: "/tmp/./a.m4a")]), 1, "a file already waiting should not be added twice")
        assertEqual(queue.count, 3, "three distinct files should be waiting")
        assertEqual(queue.popFirst(), a, "files should come out in the order they were added")
        assertEqual(queue.popFirst(), b, "files should come out in the order they were added")
        assertEqual(queue.popFirst(), c, "files should come out in the order they were added")
        assertNil(queue.popFirst(), "an empty queue should return nil")
        assertTrue(queue.isEmpty, "the queue should be empty after draining")
    }

    runSuite("AudioImportQueue puts a refused file back at the front") {
        var queue = AudioImportQueue()
        let a = URL(fileURLWithPath: "/tmp/a.m4a")
        let b = URL(fileURLWithPath: "/tmp/b.m4a")
        queue.add([a, b])

        let first = queue.popFirst()
        assertEqual(first, a, "the first file should be handed out first")
        queue.pushFront(a)
        assertEqual(queue.pending, [a, b], "a refused file should go back to the head of the line")

        queue.add([b])
        queue.pushFront(b)
        assertEqual(queue.pending, [b, a], "pushing a file that is already waiting should move it, not duplicate it")
    }

    runSuite("AudioImportQueue only takes audio and video files") {
        let root = makeRoot()
        defer { try? fileManager.removeItem(at: root) }

        let audio = root.appendingPathComponent("standup.m4a")
        let mp3 = root.appendingPathComponent("call.MP3")
        let video = root.appendingPathComponent("zoom.mp4")
        let text = root.appendingPathComponent("notes.txt")
        let folder = root.appendingPathComponent("recordings.m4a", isDirectory: true)
        for url in [audio, mp3, video, text] { touch(url) }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let remote = URL(string: "https://example.com/talk.mp3")!

        assertEqual(
            AudioImportQueue.importableFiles(from: [text, audio, folder, mp3, remote, video]),
            [audio, mp3, video],
            "only audio and video files should be importable, in the order given"
        )
        assertEqual(
            AudioImportQueue.importableFiles(from: [text, folder]),
            [],
            "text files and folders should never be imported"
        )
    }
}
