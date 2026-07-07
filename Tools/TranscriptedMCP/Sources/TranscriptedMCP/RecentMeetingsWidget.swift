import Foundation
import TranscriptedCaptureKit

// MARK: - Widget data model

/// One meeting rendered as a card in the recent-meetings widget. This is the
/// contract between the data builder (which reads the local capture library)
/// and the self-contained HTML renderer. It is also the `structuredContent`
/// shape a spec-compliant MCP Apps host receives via `ui/notifications/tool-result`,
/// so a template that reads `window.openai.toolOutput` renders the same view as
/// the data baked into the HTML.
struct WidgetMeeting: Codable, Hashable {
    /// Human title (frontmatter title, else a filename-derived label).
    let title: String
    /// `YYYY-MM-DD` local date.
    let date: String
    /// ISO-8601 datetime when known (used only for display/sort stability).
    let datetime: String
    /// Recording length in seconds.
    let durationSeconds: Int
    /// Speaker display names, in transcript order.
    let speakers: [String]
    /// Total word count across the transcript.
    let wordCount: Int
    /// The `read_meeting` filename (stem) — lets an agent drill in for more.
    let filename: String
    /// Full dialogue text (bounded by the same read cap the read tools use).
    let transcript: String
    /// Inline audio, when a preferred track exists and fits the size budget.
    let audio: WidgetAudio?
    /// Absolute local path to the audio directory, for the "open in Finder"
    /// fallback when audio is absent or too large to inline. Never leaves the Mac.
    let audioDirectory: String?
    /// Why inline audio is unavailable, when it is (missing vs. over budget).
    let audioNote: String?

    enum CodingKeys: String, CodingKey {
        case title, date, datetime
        case durationSeconds = "duration_seconds"
        case speakers
        case wordCount = "word_count"
        case filename, transcript, audio
        case audioDirectory = "audio_directory"
        case audioNote = "audio_note"
    }
}

/// A base64 `data:` audio payload the widget plays with a plain `<audio>`
/// element. `data:` media is allowed under the MCP Apps default sandbox CSP
/// (`media-src 'self' data:`), so this plays with no network access — the audio
/// bytes travel with the widget over the local stdio transport and never touch
/// a remote host.
struct WidgetAudio: Codable, Hashable {
    /// `data:audio/<subtype>;base64,<...>`
    let dataURI: String
    /// e.g. `audio/mp4`.
    let mimeType: String
    /// Track label ("Mix", "System", "Mic", …).
    let label: String
    /// Raw (pre-base64) size in bytes, for display.
    let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case dataURI = "data_uri"
        case mimeType = "mime_type"
        case label
        case sizeBytes = "size_bytes"
    }
}

/// The full payload rendered by the widget and returned as `structuredContent`.
struct RecentMeetingsWidgetModel: Codable, Hashable {
    let serverName: String
    let serverVersion: String
    /// `YYYY-MM-DD` the payload was generated (display only).
    let generatedDate: String
    let meetings: [WidgetMeeting]

    enum CodingKeys: String, CodingKey {
        case serverName = "server_name"
        case serverVersion = "server_version"
        case generatedDate = "generated_date"
        case meetings
    }
}

// MARK: - Renderer

enum RecentMeetingsWidget {
    /// Stable `ui://` URI for the recent-meetings surface. The `text/html;profile=mcp-app`
    /// resource and the tool's `_meta.ui.resourceUri` both point here.
    static let resourceURI = "ui://transcripted/recent-meetings.html"
    static let resourceMimeType = "text/html;profile=mcp-app"

    /// Render a self-contained HTML document for the given model. Inline CSS/JS,
    /// no external network, theme-aware (honors `prefers-color-scheme` and a
    /// host-provided theme). The data is baked into a `<script type="application/json">`
    /// block so the page renders identically standalone, from `resources/read`,
    /// or inline in a tool result; when a spec-compliant host later pushes fresh
    /// data via `ui/notifications/tool-result` or `window.openai.toolOutput`, the
    /// widget re-renders from that instead.
    static func html(for model: RecentMeetingsWidgetModel) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let jsonData = (try? encoder.encode(model)) ?? Data("{}".utf8)
        var json = String(decoding: jsonData, as: UTF8.self)
        // Neutralize any "</script" so the JSON cannot break out of the script tag.
        json = json.replacingOccurrences(of: "</", with: "<\\/")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Recent meetings — Transcripted</title>
        <style>\(css)</style>
        </head>
        <body>
        <main id="tx-root" aria-live="polite"></main>
        <script id="tx-data" type="application/json">\(json)</script>
        <script>\(js)</script>
        </body>
        </html>
        """
    }

    // MARK: Inline CSS

    private static let css = """
        :root {
          color-scheme: light dark;
          --bg: transparent;
          --card: #ffffff;
          --card-border: #e6e6e9;
          --text: #1a1a1e;
          --muted: #6b6b76;
          --accent: #2f6df6;
          --accent-contrast: #ffffff;
          --chip: #f1f2f5;
          --pre-bg: #f7f7f9;
          --shadow: 0 1px 2px rgba(0,0,0,.05), 0 1px 8px rgba(0,0,0,.04);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --card: #1c1c20;
            --card-border: #313138;
            --text: #ececf1;
            --muted: #9a9aa6;
            --accent: #5b8cff;
            --accent-contrast: #0d0d10;
            --chip: #2a2a31;
            --pre-bg: #141417;
            --shadow: 0 1px 2px rgba(0,0,0,.4), 0 1px 8px rgba(0,0,0,.3);
          }
        }
        :root[data-theme="dark"] {
          --card: #1c1c20; --card-border: #313138; --text: #ececf1; --muted: #9a9aa6;
          --accent: #5b8cff; --accent-contrast: #0d0d10; --chip: #2a2a31; --pre-bg: #141417;
          --shadow: 0 1px 2px rgba(0,0,0,.4), 0 1px 8px rgba(0,0,0,.3);
        }
        :root[data-theme="light"] {
          --card: #ffffff; --card-border: #e6e6e9; --text: #1a1a1e; --muted: #6b6b76;
          --accent: #2f6df6; --accent-contrast: #ffffff; --chip: #f1f2f5; --pre-bg: #f7f7f9;
          --shadow: 0 1px 2px rgba(0,0,0,.05), 0 1px 8px rgba(0,0,0,.04);
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          background: var(--bg);
          color: var(--text);
          font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        main { padding: 12px; max-width: 720px; margin: 0 auto; }
        .head { display: flex; align-items: baseline; justify-content: space-between; margin: 2px 4px 12px; gap: 8px; }
        .head h1 { font-size: 15px; font-weight: 650; margin: 0; letter-spacing: -.01em; }
        .head .sub { font-size: 12px; color: var(--muted); }
        .card {
          background: var(--card);
          border: 1px solid var(--card-border);
          border-radius: 12px;
          padding: 12px 14px;
          margin-bottom: 10px;
          box-shadow: var(--shadow);
        }
        .card h2 { font-size: 14px; font-weight: 620; margin: 0 0 4px; letter-spacing: -.01em; }
        .meta { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px; }
        .chip {
          font-size: 11px; color: var(--muted); background: var(--chip);
          padding: 2px 8px; border-radius: 999px; white-space: nowrap;
        }
        .actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
        button {
          font: inherit; font-size: 12.5px; font-weight: 550;
          border: 1px solid var(--card-border); background: var(--card); color: var(--text);
          padding: 5px 11px; border-radius: 8px; cursor: pointer; line-height: 1.2;
        }
        button:hover { border-color: var(--accent); }
        button.play { background: var(--accent); color: var(--accent-contrast); border-color: transparent; }
        button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
        .note { font-size: 12px; color: var(--muted); }
        .note code { background: var(--chip); padding: 1px 5px; border-radius: 5px; font-size: 11px; }
        audio { width: 100%; margin-top: 10px; display: block; }
        .transcript { margin-top: 10px; }
        .transcript pre {
          background: var(--pre-bg); border: 1px solid var(--card-border); border-radius: 8px;
          padding: 10px 12px; margin: 0; max-height: 320px; overflow: auto;
          white-space: pre-wrap; word-break: break-word; font-size: 12.5px; line-height: 1.55;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        .empty { color: var(--muted); text-align: center; padding: 28px 12px; }
        [hidden] { display: none !important; }
        """

    // MARK: Inline JS

    private static let js = #"""
        (function () {
          "use strict";
          var root = document.getElementById("tx-root");

          function fmtDuration(s) {
            s = Math.max(0, Math.round(s || 0));
            var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
            function p(n) { return (n < 10 ? "0" : "") + n; }
            return h > 0 ? h + ":" + p(m) + ":" + p(sec) : m + ":" + p(sec);
          }
          function fmtBytes(b) {
            if (!b) return "";
            if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB";
            if (b >= 1024) return Math.round(b / 1024) + " KB";
            return b + " B";
          }
          function fmtDate(d) {
            if (!d) return "";
            var parts = String(d).split("-");
            if (parts.length !== 3) return d;
            var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
            var mo = months[parseInt(parts[1], 10) - 1] || parts[1];
            return mo + " " + parseInt(parts[2], 10) + ", " + parts[0];
          }
          function el(tag, cls, text) {
            var e = document.createElement(tag);
            if (cls) e.className = cls;
            if (text != null) e.textContent = text;
            return e;
          }

          function renderCard(m) {
            var card = el("div", "card");
            card.appendChild(el("h2", null, m.title || m.filename || "Untitled meeting"));

            var meta = el("div", "meta");
            [fmtDate(m.date), fmtDuration(m.duration_seconds),
             (m.speakers && m.speakers.length ? m.speakers.join(", ") : null),
             (m.word_count ? m.word_count.toLocaleString() + " words" : null)
            ].forEach(function (v) { if (v) meta.appendChild(el("span", "chip", v)); });
            card.appendChild(meta);

            var actions = el("div", "actions");

            // Play control
            if (m.audio && m.audio.data_uri) {
              var playBtn = el("button", "play", "▶ Play" + (m.audio.label ? " (" + m.audio.label + ")" : ""));
              var audio = null;
              playBtn.addEventListener("click", function () {
                if (!audio) {
                  audio = document.createElement("audio");
                  audio.controls = true;
                  audio.preload = "none";
                  audio.src = m.audio.data_uri;
                  card.appendChild(audio);
                }
                audio.hidden = false;
                audio.play().catch(function () { /* gesture/autoplay policy: controls remain usable */ });
                playBtn.textContent = "⏸ Playing" + (m.audio.label ? " (" + m.audio.label + ")" : "");
                playBtn.disabled = false;
              });
              actions.appendChild(playBtn);
            } else if (m.audio_directory) {
              var noAudio = el("span", "note");
              noAudio.appendChild(document.createTextNode((m.audio_note || "Audio not embedded") + " — "));
              var code = el("code", null, m.audio_directory);
              noAudio.appendChild(code);
              actions.appendChild(noAudio);
            }

            // Transcript toggle
            if (m.transcript) {
              var tBtn = el("button", null, "View raw transcript");
              var wrap = el("div", "transcript");
              wrap.hidden = true;
              var pre = el("pre");
              pre.textContent = m.transcript;
              wrap.appendChild(pre);
              tBtn.addEventListener("click", function () {
                wrap.hidden = !wrap.hidden;
                tBtn.textContent = wrap.hidden ? "View raw transcript" : "Hide transcript";
              });
              actions.appendChild(tBtn);
              card.appendChild(actions);
              card.appendChild(wrap);
            } else {
              card.appendChild(actions);
            }
            return card;
          }

          function render(model) {
            root.textContent = "";
            var meetings = (model && model.meetings) || [];
            var head = el("div", "head");
            head.appendChild(el("h1", null, "Recent meetings"));
            head.appendChild(el("span", "sub", meetings.length + (meetings.length === 1 ? " meeting" : " meetings")));
            root.appendChild(head);
            if (!meetings.length) {
              root.appendChild(el("div", "empty", "No recent meetings found."));
              return;
            }
            meetings.forEach(function (m) { root.appendChild(renderCard(m)); });
          }

          function applyTheme(theme) {
            if (theme === "dark" || theme === "light") {
              document.documentElement.setAttribute("data-theme", theme);
            }
          }

          // 1) Baked data — the default, works standalone and self-contained.
          var baked = {};
          try {
            var node = document.getElementById("tx-data");
            baked = node ? JSON.parse(node.textContent) : {};
          } catch (e) { baked = {}; }
          render(baked);

          // 2) Progressive enhancement for spec-compliant MCP Apps hosts:
          //    prefer live tool output / theme when the host provides it.
          try {
            if (window.openai) {
              if (window.openai.theme) applyTheme(window.openai.theme);
              if (window.openai.toolOutput && window.openai.toolOutput.meetings) {
                render(window.openai.toolOutput);
              }
            }
          } catch (e) { /* ignore */ }

          window.addEventListener("message", function (event) {
            var d = event && event.data;
            if (!d) return;
            var method = d.method || (d.type);
            if (method && String(method).indexOf("tool-result") !== -1) {
              var payload = (d.params && (d.params.structuredContent || d.params.result)) || d.payload || d.structuredContent;
              if (payload && payload.meetings) render(payload);
            }
            if (d.params && d.params.theme) applyTheme(d.params.theme);
          });
        })();
        """#
}
