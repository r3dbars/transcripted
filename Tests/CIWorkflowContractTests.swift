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

    runSuite("CI workflow contract - parser tolerates comments, quoted lists and flow env") {
        let fixture = WorkflowNode.parse("""
        on:
          push:
            branches: ["main", 'dev'] # quoted inline list
        jobs:
          a:
            runs-on: macos-26 # hosted isolation
            needs: ["x", y]
            steps:
              - run: bash run-tests.sh # fast suite
              - run: "echo keep # this"
              - run: echo "cut # here"
              - run: | # block with comment
                  echo block
              - env: { SKIP: "1", BAZ: 'a, b' } # flow mapping
        """)
        let job = fixture.child("jobs")?.child("a")
        assertEqual(fixture.child("on")?.child("push")?.child("branches")?.list ?? [], ["main", "dev"], "inline list elements are unquoted")
        assertEqual(job?.child("needs")?.list ?? [], ["x", "y"], "needs elements are unquoted")
        assertEqual(job?.child("runs-on")?.scalar, "macos-26", "inline comment is stripped from a scalar")
        let steps = job?.child("steps")?.children ?? []
        assertEqual(steps.count, 5, "comments do not add or drop steps")
        assertEqual(steps[0].child("run")?.commandLines ?? [], ["bash run-tests.sh"], "inline comment is stripped from a run command")
        assertEqual(steps[1].child("run")?.commandLines ?? [], ["echo keep # this"], "a # inside a quoted scalar is kept")
        assertEqual(steps[2].child("run")?.commandLines ?? [], ["echo \"cut"], "a plain scalar ends at ' #' even between inner quotes, as YAML reads it")
        assertEqual(steps[3].child("run")?.commandLines ?? [], ["echo block"], "block scalar header comment is ignored")
        assertEqual(steps[4].child("env")?.children.map(\.key) ?? [], ["SKIP", "BAZ"], "flow-style env mappings expose their names")
        assertEqual(steps[4].child("env")?.child("BAZ")?.scalar, "a, b", "commas inside quoted flow values stay together")
        assertEqual(WorkflowNode.stripComment("'it''s # kept' # note"), "'it''s # kept'", "an escaped single quote does not close the scalar")
        assertEqual(WorkflowNode.stripComment("\"a \\\" # kept\" # note"), "\"a \\\" # kept\"", "an escaped double quote does not close the scalar")
        assertEqual(WorkflowNode.stripComment("a#b # note"), "a#b", "a # with no space before it is part of the value")

        let apostrophe = WorkflowNode.parse("env: { A: it's, SKIP: \"1\" }")
        assertEqual(apostrophe.child("env")?.children.map(\.key) ?? [], ["A", "SKIP"], "an apostrophe in a plain flow value does not hide the next key")

        let unreadable = WorkflowNode.parse("env: { SKIP: \"1\"")
        assertEqual(unreadable.descendants(named: "!unparsed").count, 1, "an unclosed flow mapping fails closed with a marker")
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
        assertTrue(
            checks.contains("python3 scripts/dev/check-synced-copies.py --self-test")
                && checks.contains("python3 scripts/dev/check-synced-copies.py"),
            "swift-ci should run the synced-copies check so merged main keeps the CaptureLibraryPathSafety copies identical"
        )
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
        assertTrue(
            workflow.descendants(named: "!unparsed").isEmpty,
            "every env mapping in swift-ci must be readable so a skip variable cannot hide in one"
        )
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

    // release-candidate.yml: the job that compiles repository code never holds
    // signing, notarization or Sparkle secrets, and the job that holds them
    // never runs a build script.
    let releaseText = (try? String(contentsOf: repoFixtureURL(".github/workflows/release-candidate.yml"), encoding: .utf8)) ?? ""
    let release = WorkflowNode.parse(releaseText)

    runSuite("CI workflow contract - release candidate splits build from signing") {
        assertEqual(
            release.child("jobs")?.children.map(\.key) ?? [],
            ["build-unsigned", "sign-and-notarize", "verify-candidate"],
            "the release candidate should build unsigned, sign in the release environment, then verify"
        )
        assertEqual(release.child("permissions")?.child("contents")?.scalar, "read", "the workflow token should stay read-only")

        for name in ["build-unsigned", "verify-candidate"] {
            let job = release.job(name)
            assertNotNil(job, "\(name) should exist")
            assertNil(job?.child("environment"), "\(name) runs repository code and must not use the release environment")
            assertFalse(job.map(workflowMentionsSecret) ?? true, "\(name) must not reference any secret")
        }

        let sign = release.job("sign-and-notarize")
        assertEqual(sign?.child("environment")?.scalar, "release", "signing happens only in the release environment")
        assertEqual(sign?.child("needs")?.scalar, "build-unsigned", "signing consumes the unsigned build")
        let signCommands = (sign?.commands ?? []).joined(separator: "\n")
        for forbidden in ["build.sh", "build-beta.sh", "build-deps.sh", "swift build", "swift run", "swift test", "swiftc"] {
            assertFalse(signCommands.contains(forbidden), "the signing job must not run \(forbidden)")
        }
        for required in ["sign-release.sh", "notarytool", "generate-sparkle-appcast.sh", "sign-appcast.sh", "fetch-sparkle-tools.sh"] {
            assertTrue(signCommands.contains(required), "the signing job should run \(required)")
        }

        let build = release.job("build-unsigned")
        let buildCommands = (build?.commands ?? []).joined(separator: "\n")
        assertTrue(buildCommands.contains("build-beta.sh"), "the build job should run build-beta.sh")
        let buildEnv = build?.descendants(named: "env").flatMap(\.children) ?? []
        assertEqual(
            buildEnv.first { $0.key == "TRANSCRIPTED_UNSIGNED_APP_ONLY" }?.scalar,
            "1",
            "build-beta.sh must stop before signing in the build job"
        )
        for forbidden in ["sign-release.sh", "notarytool", "sign-appcast.sh", "security import", "security create-keychain"] {
            assertFalse(buildCommands.contains(forbidden), "the build job must not sign or notarize (\(forbidden))")
        }
    }

    runSuite("CI workflow contract - release candidate never publishes or commits the feed") {
        let allCommands = (release.child("jobs")?.children ?? []).flatMap(\.commands).joined(separator: "\n")
        for forbidden in ["gh release create", "gh release upload", "gh release edit", "git push", "git commit", "gh workflow run"] {
            assertFalse(allCommands.contains(forbidden), "the release candidate workflow must not run \(forbidden)")
        }
        let uploads = release.descendants(named: "path").compactMap(\.scalar) + release.descendants(named: "path").flatMap(\.block)
        assertTrue(
            uploads.contains { $0.contains("build/appcast.xml") },
            "the generated appcast.xml should travel in the candidate artifact"
        )
        assertFalse(
            uploads.contains { $0.contains("docs/appcast.xml") },
            "docs/appcast.xml is the frozen legacy feed and must not be part of a candidate"
        )
    }
}

private func workflowMentionsSecret(_ node: WorkflowNode) -> Bool {
    if (node.scalar ?? "").contains("secrets.") || node.block.contains(where: { $0.contains("secrets.") }) { return true }
    return node.children.contains(where: workflowMentionsSecret)
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
        return WorkflowNode.splitTopLevel(String(scalar.dropFirst().dropLast())).map {
            WorkflowNode.unquote($0.trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
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
                flat.append((indent, WorkflowNode(key: "-", scalar: unquote(stripComment(content)))))
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
        let value = stripComment(rest.trimmingCharacters(in: .whitespaces))
        if value.hasPrefix("{") {
            return flowMapping(key: key, value: value)
        }
        return WorkflowNode(key: key, scalar: value.isEmpty ? nil : unquote(value))
    }

    /// `key: { A: "1", B: 2 }` becomes a node with children A and B. Anything
    /// that is not a closed, parseable mapping gets an "!unparsed" child so
    /// checks over `env:` blocks can fail closed instead of missing a variable.
    private static func flowMapping(key: String, value: String) -> WorkflowNode {
        var node = WorkflowNode(key: key)
        guard value.hasSuffix("}") else {
            node.children.append(WorkflowNode(key: "!unparsed", scalar: value))
            return node
        }
        for pair in splitTopLevel(String(value.dropFirst().dropLast())) {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let entry = keyValue(trimmed) {
                node.children.append(entry)
            } else {
                node.children.append(WorkflowNode(key: "!unparsed", scalar: trimmed))
            }
        }
        return node
    }

    /// Splits on commas outside quotes and nested `[]` / `{}`. A quote only
    /// counts when it opens an element (after `[`, `{`, `,` or `:`), so an
    /// apostrophe inside a plain value like `it's` cannot swallow the next pair.
    fileprivate static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        var atStart = true
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
            } else if (character == "\"" || character == "'") && atStart {
                quote = character
            } else if "[{".contains(character) {
                depth += 1
            } else if "]}".contains(character) {
                depth -= 1
            } else if character == ",", depth == 0 {
                parts.append(current)
                current = ""
                atStart = true
                continue
            }
            if character != " " && character != "\t" {
                atStart = quote == nil && "[{,:".contains(character)
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }

    /// Drops a trailing YAML comment: a `#` after whitespace that is not inside
    /// a quoted scalar. As in YAML, a quote only counts when it opens the value
    /// or a flow element (after `[`, `{`, `,` or `:`), so in a plain scalar such as
    /// `echo "a # b"` the ` #` still starts a comment, the same as Actions reads it.
    fileprivate static func stripComment(_ value: String) -> String {
        let flow = value.first == "[" || value.first == "{"
        var quote: Character?
        var previous: Character = " "
        var atStart = true
        var end = value.endIndex
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if let open = quote {
                if open == "\"", character == "\\", next < value.endIndex {
                    index = value.index(after: next)
                    previous = "x"
                    continue
                }
                if character == open {
                    if open == "'", next < value.endIndex, value[next] == "'" {
                        index = value.index(after: next)
                        previous = "x"
                        continue
                    }
                    quote = nil
                }
            } else if (character == "\"" || character == "'") && atStart {
                quote = character
            } else if character == "#", previous == " " || previous == "\t" {
                end = index
                break
            }
            if character != " " && character != "\t" {
                atStart = quote == nil && flow && "[{,:".contains(character)
            }
            previous = character
            index = next
        }
        return String(value[..<end]).trimmingCharacters(in: .whitespaces)
    }

    fileprivate static func unquote(_ value: String) -> String {
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
