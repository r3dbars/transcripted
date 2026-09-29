import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// The orphan reap kills only this app's own llama helper after launchd
/// adopted it (its app crashed). Any other listener on the port is someone
/// else's process and survives.
@Suite("Llama orphan reap picks only our re-parented helper")
struct LlamaOrphanReapTests {
    private let binary = "/Applications/Transcripted.app/Contents/Helpers/llama-server"

    private func target(
        listeners: [Int32],
        paths: [Int32: String],
        parents: [Int32: String]
    ) -> Int32? {
        LlamaServerProcessHost.orphanToReap(
            listeners: listeners,
            binary: binary,
            executablePath: { paths[$0] },
            parentProcess: { parents[$0] }
        )
    }

    @Test("Our helper adopted by launchd is reaped")
    func adoptedHelperIsReaped() {
        #expect(target(listeners: [4242], paths: [4242: binary], parents: [4242: "1"]) == 4242)
    }

    @Test("Our helper still owned by a running app is left alone")
    func ownedHelperSurvives() {
        #expect(target(listeners: [4242], paths: [4242: binary], parents: [4242: "977"]) == nil)
    }

    @Test("Another program on the port is left alone, even adopted by launchd")
    func foreignListenerSurvives() {
        #expect(target(
            listeners: [4242],
            paths: [4242: "/opt/homebrew/bin/llama-server"],
            parents: [4242: "1"]
        ) == nil)
    }

    @Test("A process whose path or parent can't be read is left alone")
    func unreadableProcessSurvives() {
        #expect(target(listeners: [4242], paths: [:], parents: [4242: "1"]) == nil)
        #expect(target(listeners: [4242], paths: [4242: binary], parents: [:]) == nil)
    }

    @Test("Several listeners on the port are never guessed between")
    func multipleListenersSurvive() {
        #expect(target(
            listeners: [4242, 4343],
            paths: [4242: binary, 4343: binary],
            parents: [4242: "1", 4343: "1"]
        ) == nil)
    }
}
