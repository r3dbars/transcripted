import Foundation

func testAutoEnterDisplayNameResolver() {
    runSuite("AutoEnterDisplayNameResolver prefers a matching candidate name") {
        let resolved = AutoEnterDisplayNameResolver.resolve(
            bundleID: "com.example.editor",
            candidateNames: [
                ("com.example.other", "Other App"),
                ("com.example.editor", "Example Editor")
            ],
            workspaceLookup: { _ in
                assertTrue(false, "Workspace lookup should not run when a candidate matches")
                return "Should Not Be Used"
            }
        )
        assertEqual(resolved, "Example Editor", "A matching candidate name should win the fallback chain")
    }

    runSuite("AutoEnterDisplayNameResolver uses the first matching candidate") {
        let resolved = AutoEnterDisplayNameResolver.resolve(
            bundleID: "com.example.editor",
            candidateNames: [
                ("com.example.editor", "First Editor"),
                ("com.example.editor", "Second Editor")
            ],
            workspaceLookup: { _ in nil }
        )
        assertEqual(resolved, "First Editor", "The first matching candidate should win, matching first(where:) semantics")
    }

    runSuite("AutoEnterDisplayNameResolver falls back to the workspace lookup") {
        var lookedUp: String?
        let resolved = AutoEnterDisplayNameResolver.resolve(
            bundleID: "com.example.notInstalledCandidate",
            candidateNames: [
                ("com.example.other", "Other App")
            ],
            workspaceLookup: { id in
                lookedUp = id
                return "Workspace Name"
            }
        )
        assertEqual(resolved, "Workspace Name", "Without a candidate match, the workspace lookup should win")
        assertEqual(lookedUp, "com.example.notInstalledCandidate", "The workspace lookup should receive the requested bundle id")
    }

    runSuite("AutoEnterDisplayNameResolver falls back to the bundle id") {
        let resolved = AutoEnterDisplayNameResolver.resolve(
            bundleID: "com.example.ghost",
            candidateNames: [
                ("com.example.other", "Other App")
            ],
            workspaceLookup: { _ in nil }
        )
        assertEqual(resolved, "com.example.ghost", "With no candidate and no workspace hit, the bundle id is the last resort")
    }

    runSuite("AutoEnterDisplayNameResolver falls back to the bundle id with no candidates") {
        let resolved = AutoEnterDisplayNameResolver.resolve(
            bundleID: "com.example.ghost",
            candidateNames: [],
            workspaceLookup: { _ in nil }
        )
        assertEqual(resolved, "com.example.ghost", "An empty candidate list with no workspace hit should yield the bundle id")
    }
}
