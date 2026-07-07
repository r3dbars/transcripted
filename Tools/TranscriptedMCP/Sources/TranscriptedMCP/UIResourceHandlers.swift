import Foundation
import MCP

/// MCP Apps (SEP-1865, `io.modelcontextprotocol/ui`, spec 2026-01-26) surface for
/// Transcripted: a `ui://` HTML resource that renders a "recent meetings" widget
/// inline in a rendering-capable agent client, plus the `show_recent_meetings`
/// tool that returns it.
///
/// Design notes:
///   * The resource MIME is `text/html;profile=mcp-app` per the extension.
///   * The tool links to the resource via `_meta.ui.resourceUri` (official) and
///     `_meta["openai/outputTemplate"]` (OpenAI Apps SDK alias for ChatGPT).
///   * The tool result also carries the fully data-baked HTML as an inline
///     embedded resource (the mcp-ui `rawHtml` pattern) plus `structuredContent`,
///     so the widget renders whether the host inlines the embedded resource,
///     reads the template and pushes `structuredContent`, or is inspected
///     standalone. Nothing here reaches the network.
enum TranscriptedUIResources {
    static let recentMeetingsResourceName = "recent_meetings"
    static let defaultRecentCount = 5

    /// Register `resources/list`, `resources/read`, and `resources/templates/list`
    /// handlers that expose the recent-meetings widget.
    static func register(
        server: Server,
        index: TranscriptIndex,
        directories: TranscriptedDataDirectories,
        serverVersion: String
    ) async {
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [recentMeetingsResource])
        }

        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: [])
        }

        await server.withMethodHandler(ReadResource.self) { params in
            guard params.uri == RecentMeetingsWidget.resourceURI else {
                throw MCPError.invalidParams("Unknown resource: \(params.uri)")
            }
            let html = try renderRecentMeetingsHTML(
                index: index, directories: directories, serverVersion: serverVersion
            )
            return .init(contents: [
                .text(html, uri: RecentMeetingsWidget.resourceURI, mimeType: RecentMeetingsWidget.resourceMimeType)
            ])
        }
    }

    /// The resource descriptor returned by `resources/list`. The `_meta.ui` block
    /// carries the MCP Apps hints (sandbox CSP is the permissive default; the
    /// widget needs `media-src data:` for inline audio, which the default allows).
    static var recentMeetingsResource: Resource {
        Resource(
            name: recentMeetingsResourceName,
            uri: RecentMeetingsWidget.resourceURI,
            title: "Recent meetings",
            description: "Interactive card list of your most recent meetings, each with audio playback and a raw-transcript view. Renders inline in MCP Apps-capable clients.",
            mimeType: RecentMeetingsWidget.resourceMimeType,
            _meta: Metadata(additionalFields: [
                "ui": .object([
                    "preferredSize": .object(["width": .int(720), "height": .int(560)]),
                    "prefersBorder": .bool(true)
                ])
            ])
        )
    }

    /// `_meta` for the `show_recent_meetings` tool definition, linking the tool to
    /// its UI resource for both the official extension and the OpenAI Apps SDK.
    static var toolMeta: Metadata {
        Metadata(additionalFields: [
            "ui": .object([
                "resourceUri": .string(RecentMeetingsWidget.resourceURI),
                "visibility": .array([.string("model"), .string("app")])
            ]),
            "openai/outputTemplate": .string(RecentMeetingsWidget.resourceURI)
        ])
    }

    /// Build the tool result for `show_recent_meetings`: a text fallback (what a
    /// non-rendering client like the Claude Code CLI shows), the data-baked widget
    /// HTML as an inline embedded resource, and `structuredContent` for hosts that
    /// push tool output into the rendered template.
    static func showRecentMeetingsResult(
        count: Int,
        index: TranscriptIndex,
        directories: TranscriptedDataDirectories,
        serverVersion: String
    ) throws -> CallTool.Result {
        let model = try RecentMeetingsWidgetBuilder.build(
            index: index,
            meetingDirs: directories.meetingDirs,
            count: count,
            generatedDate: DateFormatter.localYYYYMMDDString(from: Date()),
            serverName: "transcripted",
            serverVersion: serverVersion
        )
        let html = RecentMeetingsWidget.html(for: model)

        let summary = textFallback(for: model)
        let embedded = Resource.Content.text(
            html, uri: RecentMeetingsWidget.resourceURI, mimeType: RecentMeetingsWidget.resourceMimeType
        )

        return try CallTool.Result(
            content: [
                .text(text: summary, annotations: nil, _meta: nil),
                .resource(resource: embedded, annotations: nil, _meta: nil)
            ],
            structuredContent: model,
            isError: false,
            _meta: Metadata(additionalFields: [
                "ui": .object(["resourceUri": .string(RecentMeetingsWidget.resourceURI)])
            ])
        )
    }

    static func renderRecentMeetingsHTML(
        index: TranscriptIndex,
        directories: TranscriptedDataDirectories,
        serverVersion: String
    ) throws -> String {
        let model = try RecentMeetingsWidgetBuilder.build(
            index: index,
            meetingDirs: directories.meetingDirs,
            count: defaultRecentCount,
            generatedDate: DateFormatter.localYYYYMMDDString(from: Date()),
            serverName: "transcripted",
            serverVersion: serverVersion
        )
        return RecentMeetingsWidget.html(for: model)
    }

    /// Plain-text rendering of the widget model for clients that don't paint
    /// inline HTML (terminals, or hosts that haven't shipped MCP Apps rendering).
    static func textFallback(for model: RecentMeetingsWidgetModel) -> String {
        guard !model.meetings.isEmpty else {
            return "No recent meetings found."
        }
        var lines = ["Recent meetings (\(model.meetings.count)):"]
        for meeting in model.meetings {
            let mins = meeting.durationSeconds / 60
            let secs = meeting.durationSeconds % 60
            let duration = String(format: "%d:%02d", mins, secs)
            let speakers = meeting.speakers.isEmpty ? "" : " · \(meeting.speakers.joined(separator: ", "))"
            let audio = meeting.audio != nil ? " · ▶ audio" : ""
            lines.append("• \(meeting.title) — \(meeting.date), \(duration)\(speakers)\(audio)")
        }
        lines.append("")
        lines.append("Open the interactive widget in an MCP Apps-capable client to play audio and read transcripts inline.")
        return lines.joined(separator: "\n")
    }
}

extension DateFormatter {
    static func localYYYYMMDDString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
