import Foundation

/// The CI contract is asserted on a parsed view of swift-ci.yml (jobs, triggers,
/// needs, runs-on, env names, step commands), not on substrings of the file.
func testCIWorkflowContract() {
    let swiftCIText = (try? String(contentsOf: repoFixtureURL(".github/workflows/swift-ci.yml"), encoding: .utf8)) ?? ""
    let workflow = WorkflowNode.parse(swiftCIText)

    runSuite("CI workflow contract - parser reads a small fixture") {
        let fixture = WorkflowNode.parse("""
        # comment
        on:
          push:
            branches: [main]
        jobs:
          a:
            runs-on: "x"
            steps:
              - name: One
                env:
                  FOO: "1"
                run: |
                  echo hi
                  echo there
              - run: single
        """)
        assertEqual(fixture.child("on")?.child("push")?.child("branches")?.list ?? [], ["main"], "inline list parses")
        let steps = fixture.child("jobs")?.child("a")?.child("steps")?.children ?? []
        assertEqual(steps.count, 2, "two list items become two step nodes")
        assertEqual(steps.first?.child("run")?.commandLines ?? [], ["echo hi", "echo there"], "block scalar lines are kept")
        assertEqual(steps.last?.child("run")?.commandLines ?? [], ["single"], "inline scalar is one command")
        assertEqual(fixture.child("jobs")?.child("a")?.child("runs-on")?.scalar, "x", "quotes are stripped")
        assertEqual(fixture.descendants(named: "env").flatMap { $0.children.map(\.key) }, ["FOO"], "env names are found at any depth")
    }

    runSuite("CI workflow contract - swift-ci stays a blocking gate") {
        let jobs = workflow.child("jobs")?.children ?? []
        assertTrue(jobs.count >= 4, "swift-ci should parse into its jobs")
        assertTrue(
            workflow.descendants(named: "continue-on-error").isEmpty,
            "swift-ci must not use continue-on-error anywhere — it is a required, blocking gate"
        )
    }

    runSuite("CI workflow contract - swift-ci verifies merged main") {
        let triggers = workflow.child("on")
        assertEqual(
            triggers?.child("push")?.child("branches")?.list ?? [],
            ["main"],
            "swift-ci should run on pushes to main so merged code is verified"
        )
        let triggerNames = Set((triggers?.children ?? []).map(\.key))
        assertTrue(triggerNames.contains("pull_request"), "swift-ci should keep the pull_request trigger")
        assertTrue(triggerNames.contains("workflow_dispatch"), "swift-ci should keep the manual dispatch trigger")
    }

    runSuite("CI workflow contract - swift-ci runs the full suite") {
        let checks = workflow.job("checks")?.commands ?? []
        let spm = workflow.job("spm-tests")?.commands ?? []

        let sourceLists = checks.firstIndex(of: "python3 scripts/dev/check-build-source-lists.py")
        let fastTests = checks.firstIndex(of: "bash run-tests.sh")
        assertNotNil(sourceLists, "swift-ci should validate raw swiftc source lists before the expensive build")
        assertNotNil(fastTests, "swift-ci should keep running the fast tests")
        if let sourceLists, let fastTests {
            assertTrue(sourceLists < fastTests, "source-list validation should run before the fast tests")
        }
        assertTrue(checks.contains("bash run-e2e-smoke.sh"), "swift-ci should run the E2E smoke")
        assertTrue(spm.contains("bash run-integration-smoke.sh"), "swift-ci should run the integration smoke")
        assertTrue(
            spm.contains { $0 == "swift test" || $0.hasSuffix(" swift test") },
            "swift-ci should keep running the Core package tests"
        )
        let toolPackages = Set(spm.compactMap { line -> String? in
            let prefix = "swift test --package-path "
            return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        })
        assertTrue(
            toolPackages.isSuperset(of: [
                "Tools/TranscriptedCaptureKit",
                "Tools/TranscriptedCLI",
                "Tools/TranscriptedMCP",
                "Tools/TranscriptedQA"
            ]),
            "swift-ci should run the Tools package tests, got \(toolPackages.sorted())"
        )
    }

    runSuite("CI workflow contract - checks, spm-tests and app-build can use the owner's Mac") {
        // pick-runner routes these three jobs to the owner's Mac when it is idle.
        // Fork PRs must stay hosted. app-build's launch smoke runs there only
        // inside the throwaway job VM (scripts/ops/native-smoke-isolation.py).
        let pickEnv = workflow.job("pick-runner")?.descendants(named: "env").flatMap(\.children) ?? []
        assertEqual(
            pickEnv.first { $0.key == "HEAD_REPO" }?.scalar,
            "${{ github.event.pull_request.head.repo.full_name }}",
            "pick-runner should see the PR head repo so fork PRs stay on hosted runners"
        )
        let pickedRunnerExpression = "${{ fromJSON(needs.pick-runner.outputs.runs-on) }}"
        let jobsOnPickedRunner = Set(
            (workflow.child("jobs")?.children ?? [])
                .filter { $0.child("runs-on")?.scalar == pickedRunnerExpression }
                .map(\.key)
        )
        assertEqual(
            jobsOnPickedRunner,
            ["checks", "spm-tests", "app-build"],
            "checks, spm-tests and app-build should take their runner from pick-runner"
        )
        assertEqual(
            workflow.job("app-build")?.child("needs")?.scalar,
            "pick-runner",
            "app-build should wait for pick-runner to choose its runner"
        )
        assertEqual(
            workflow.job("build-and-test")?.child("needs")?.list ?? [],
            ["pick-runner", "checks", "spm-tests", "app-build"],
            "the build-and-test umbrella should fail when pick-runner fails"
        )
    }

    runSuite("CI workflow contract - launch smoke is no longer skipped") {
        // The launch smoke runs on hosted runners now, so the skip env must be
        // gone. The only allowed skip env is the wall-clock timing one. Collect
        // every env var name and every command token so a skip set in either place counts.
        let envNames = workflow.descendants(named: "env").flatMap { $0.children.map(\.key) }
        let commandTokens = workflow.descendants(named: "run").flatMap { run in
            run.commandLines.flatMap { $0.split(whereSeparator: { " \t=\"'".contains($0) }).map(String.init) }
        }
        let skipEnvVars = Set((envNames + commandTokens).filter { $0.hasPrefix("TRANSCRIPTED_SKIP_") })
        assertEqual(
            skipEnvVars,
            ["TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS"],
            "the only skip env var in swift-ci should be TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS so new silent skips cannot creep in"
        )
    }

    runSuite("CI workflow contract - clipboard timing skip set stays locked") {
        let clipboardTests = (try? String(
            contentsOf: repoFixtureURL("Tests/ClipboardRestoringTextPasterTests.swift"),
            encoding: .utf8
        )) ?? ""
        assertFalse(clipboardTests.isEmpty, "ClipboardRestoringTextPasterTests.swift should be readable")

        // The no-read readiness proof now uses an hour-long fallback and checks
        // completion, so it runs on CI too. Only these four remaining real-time
        // pasteboard observer proofs may opt out under shared-runner jitter.
        let expectedTimingProofs: Set<String> = [
            "ClipboardRestoringTextPaster stops waiting and reports a likely paste after a target reads",
            "ClipboardRestoringTextPaster.paste — confirmed target read restores clipboard",
            "ClipboardRestoringTextPaster.paste — Auto Enter target read skips the dead confirmation wait",
            "ClipboardRestoringTextPaster.paste — early observer reads do not race slow consumers"
        ]
        let timingGuard = "if ProcessInfo.processInfo.environment[\"TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS\"] == \"1\" {"
        let guardedProofs = clipboardTests.components(separatedBy: "runSuite(\"").dropFirst().compactMap { suite -> String? in
            guard suite.contains(timingGuard) else { return nil }
            return suite.components(separatedBy: "\"").first
        }
        assertEqual(Set(guardedProofs), expectedTimingProofs, "only the named clipboard observer timing proofs may skip")
        assertEqual(occurrences(of: timingGuard, in: clipboardTests), expectedTimingProofs.count, "each timing proof has exactly one skip guard")
        assertEqual(occurrences(of: "    SKIPPED: wall-clock timing proof", in: clipboardTests), expectedTimingProofs.count, "each timing proof reports its skip")
    }
}

/// A deliberately small indentation-based reader for the YAML subset swift-ci.yml
/// uses: mappings, `- ` list items, inline `[a, b]` lists, `|` / `>` block
/// scalars, and comments. A list item becomes a node with key "-".
private struct WorkflowNode {
    var key: String
    var scalar: String?
    var block: [String] = []
    var children: [WorkflowNode] = []

    func child(_ name: String) -> WorkflowNode? { children.first { $0.key == name } }
    func job(_ name: String) -> WorkflowNode? { child("jobs")?.child(name) }

    func descendants(named name: String) -> [WorkflowNode] {
        children.flatMap { ($0.key == name ? [$0] : []) + $0.descendants(named: name) }
    }

    /// An inline `[a, b]` list, as strings. Block lists (`- a`) nest as "-" nodes
    /// and come back empty here, so an assert on them fails closed.
    var list: [String] {
        guard let scalar, scalar.hasPrefix("["), scalar.hasSuffix("]") else { return children.compactMap(\.scalar) }
        return scalar.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Non-empty command lines of a `run:` value (block or inline).
    var commandLines: [String] {
        let lines = block.isEmpty ? [scalar ?? ""] : block
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Every `run:` command line in the job's steps, in order.
    var commands: [String] {
        (child("steps")?.children ?? []).flatMap { $0.child("run")?.commandLines ?? [] }
    }

    static func parse(_ text: String) -> WorkflowNode {
        let lines = text.components(separatedBy: "\n")
        var root = WorkflowNode(key: "")
        // Flat list of (indent, node) in file order; folded into a tree below.
        var flat: [(indent: Int, node: WorkflowNode)] = []
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var indent = raw.prefix { $0 == " " }.count
            var content = trimmed
            while content.hasPrefix("- ") {
                flat.append((indent, WorkflowNode(key: "-")))
                indent += 2
                content = String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard let node = keyValue(content) else {
                flat.append((indent, WorkflowNode(key: "-", scalar: unquote(content))))
                continue
            }
            var parsed = node
            if let value = parsed.scalar, let marker = value.first, marker == "|" || marker == ">" {
                parsed.scalar = nil
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if !nextTrimmed.isEmpty, next.prefix(while: { $0 == " " }).count <= indent { break }
                    parsed.block.append(next)
                    index += 1
                }
            }
            flat.append((indent, parsed))
        }
        var stack: [(indent: Int, path: [Int])] = []
        for entry in flat {
            while let last = stack.last, last.indent >= entry.indent { stack.removeLast() }
            let parentPath = stack.last?.path ?? []
            let newPath = root.append(entry.node, at: parentPath)
            stack.append((entry.indent, newPath))
        }
        return root
    }

    private mutating func append(_ node: WorkflowNode, at path: [Int]) -> [Int] {
        if let first = path.first {
            return [first] + children[first].append(node, at: Array(path.dropFirst()))
        }
        children.append(node)
        return [children.count - 1]
    }

    private static func keyValue(_ content: String) -> WorkflowNode? {
        guard let colon = content.firstIndex(of: ":") else { return nil }
        let key = String(content[..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else { return nil }
        let rest = content[content.index(after: colon)...]
        guard rest.isEmpty || rest.first == " " else { return nil }
        let value = rest.trimmingCharacters(in: .whitespaces)
        return WorkflowNode(key: key, scalar: value.isEmpty ? nil : unquote(value))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = found.upperBound..<haystack.endIndex
    }
    return count
}
