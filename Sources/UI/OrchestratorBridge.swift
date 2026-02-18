// OrchestratorBridge.swift
// Manages the orchestrator Python subprocess and SSE communication.
//
// Spawns `python3 -m agent.main` on start(), subscribes to SSE stream,
// handles Apply/Skip POST callbacks, and terminates process on stop().

import Foundation
import SwiftUI

extension Notification.Name {
    static let promptsDidChange = Notification.Name("promptsDidChange")
}

@MainActor
class OrchestratorBridge: ObservableObject {
    @Published var insights: [InsightCard] = []
    @Published var isConnected = false
    @Published var isAnalyzing = false
    @Published var agentStatus: String = "Starting..."

    private var process: Process?
    private var sseTask: Task<Void, Never>?
    private let port = 19832

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    // MARK: - Process Lifecycle

    func start() {
        guard process == nil else { return }

        let proc = Process()

        // Working directory: Draft repo root (agent/ is a sibling of Sources/)
        // The app bundle lives at build/Draft.app/Contents/MacOS/Draft
        // Repo root is 4 levels up from the executable
        let execURL = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        let repoRoot = execURL
            .deletingLastPathComponent()  // MacOS/
            .deletingLastPathComponent()  // Contents/
            .deletingLastPathComponent()  // Draft.app/
            .deletingLastPathComponent()  // build/
        proc.currentDirectoryURL = repoRoot

        // Use venv Python if available, fall back to system python3
        let venvPython = repoRoot.appendingPathComponent("agent/.venv/bin/python3")
        if FileManager.default.fileExists(atPath: venvPython.path) {
            proc.executableURL = venvPython
            proc.arguments = ["-m", "agent.main"]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", "-m", "agent.main"]
        }

        // Pipe stderr for debug logging (stdout goes to the SSE server)
        let errPipe = Pipe()
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.isConnected = false
                self?.agentStatus = proc.terminationStatus == 0
                    ? "Agent stopped"
                    : "Agent crashed (exit \(proc.terminationStatus))"
            }
        }

        do {
            try proc.run()
            process = proc
            agentStatus = "Connecting..."
            print("🐍 AGENT | Python process spawned (pid: \(proc.processIdentifier))")

            // Read stderr in background for debugging
            Task.detached { [errPipe] in
                let handle = errPipe.fileHandleForReading
                for try await line in handle.bytes.lines {
                    print("🐍 AGENT | \(line)")
                }
            }

            // Start SSE subscription after server is ready
            sseTask = Task {
                await waitForHealth()
                await subscribeToSSE()
            }
        } catch {
            agentStatus = "Failed to start: \(error.localizedDescription)"
            print("🐍 AGENT | ❌ Failed to start: \(error)")
        }
    }

    func stop() {
        sseTask?.cancel()
        sseTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
            print("🐍 AGENT | Process terminated")
        }
        process = nil
        isConnected = false
        agentStatus = "Stopped"
    }

    // MARK: - Health Check

    private func waitForHealth() async {
        let healthURL = baseURL.appendingPathComponent("health")
        for _ in 0..<30 {  // Try for 15 seconds (30 × 0.5s)
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    agentStatus = "Connected"
                    isConnected = true
                    print("🐍 AGENT | Health check passed — connected")
                    return
                }
            } catch {
                // Server not ready yet
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        agentStatus = "Connection timeout"
        print("🐍 AGENT | ❌ Health check timed out after 15s")
    }

    // MARK: - SSE Subscription

    private func subscribeToSSE() async {
        let eventsURL = baseURL.appendingPathComponent("events")
        var request = URLRequest(url: eventsURL)
        request.timeoutInterval = TimeInterval(Int.max) // SSE is long-lived

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)

            var eventType = ""
            var dataBuffer = ""

            for try await line in bytes.lines {
                if Task.isCancelled { break }

                if line.hasPrefix("event: ") {
                    eventType = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    dataBuffer = String(line.dropFirst(6))
                } else if line.isEmpty && !dataBuffer.isEmpty {
                    // End of SSE event — process it
                    handleSSEEvent(type: eventType, data: dataBuffer)
                    eventType = ""
                    dataBuffer = ""
                }
                // Lines starting with ":" are comments (keepalive) — ignore
            }
        } catch {
            if !Task.isCancelled {
                isConnected = false
                agentStatus = "Disconnected — reconnecting..."
                print("🐍 AGENT | SSE disconnected: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    await waitForHealth()
                    await subscribeToSSE()
                }
            }
        }
    }

    private func handleSSEEvent(type: String, data: String) {
        guard let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        // Check for internal events (analyzing, analysis_complete)
        if let internalEvent = dict["_event"] as? String {
            switch internalEvent {
            case "analyzing":
                isAnalyzing = true
                agentStatus = "Analyzing feedback..."
            case "analysis_complete":
                isAnalyzing = false
                agentStatus = "Watching for feedback..."
            default:
                break
            }
            return
        }

        switch type {
        case "connected":
            isConnected = true
            agentStatus = "Watching for feedback..."

        case "insight":
            if let card = parseInsightCard(from: dict) {
                insights.append(card)
                print("🐍 AGENT | Card received: \(card.promptKeyLabel) — \(card.changeDescription.prefix(60))")
            }

        default:
            break
        }
    }

    // MARK: - User Actions

    func apply(_ card: InsightCard) {
        guard let idx = insights.firstIndex(where: { $0.id == card.id }) else { return }

        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent("apply"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "suggestion_id": card.suggestionId,
                "prompt_key": card.promptKey,
                "proposed_value": card.proposedValue,
                "saw": card.saw,
                "why": card.why,
                "change": card.changeDescription,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    insights[idx].status = .applied
                    // Trigger prompt reload in the app
                    NotificationCenter.default.post(name: .promptsDidChange, object: nil)
                    print("🐍 AGENT | ✅ Applied: \(card.promptKeyLabel)")
                }
            } catch {
                print("🐍 AGENT | ❌ Apply failed: \(error)")
            }
        }
    }

    func skip(_ card: InsightCard) {
        guard let idx = insights.firstIndex(where: { $0.id == card.id }) else { return }
        insights[idx].status = .skipped

        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent("skip"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "suggestion_id": card.suggestionId,
                "prompt_key": card.promptKey,
                "saw": card.saw,
                "why": card.why,
                "change": card.changeDescription,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            _ = try? await URLSession.shared.data(for: request)
            print("🐍 AGENT | ⏭️ Skipped: \(card.promptKeyLabel)")
        }
    }

    // MARK: - Parsing

    private func parseInsightCard(from dict: [String: Any]) -> InsightCard? {
        guard let promptKey = dict["prompt_key"] as? String else { return nil }
        return InsightCard(
            suggestionId: dict["suggestion_id"] as? String ?? UUID().uuidString,
            promptKey: promptKey,
            saw: dict["saw"] as? String ?? "",
            why: dict["why"] as? String ?? "",
            currentValue: dict["current_value"] as? String ?? "",
            proposedValue: dict["proposed_value"] as? String ?? "",
            changeDescription: dict["change_description"] as? String ?? ""
        )
    }
}
