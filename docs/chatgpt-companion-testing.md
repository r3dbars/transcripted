# Test the Transcripted companion

The private account plugin is version 0.1.2. The local marketplace copy is now version 0.1.5, with a compatibility packaging fix: Both Codex 0.154.0 and the desktop-bundled 0.159.2 discover its MCP server, where the portable package returned zero servers. Version 0.1.4 also replaces unsupported legacy launch-path placeholders with plugin-relative paths. The desktop runtime now starts the installed server and lists all 28 tools, including `show_companion`, without a startup error. Version 0.1.5 addresses the panel-specific handshake: Swift SDK 0.12 only decodes string-valued experimental capabilities, while the panel sends objects. A narrow initialize transport adapter omits declarations the helper does not consume; all other messages pass through unchanged. Run `python3 Tools/TranscriptedCompanion/test-handshake.py` against the packaged helper to replay that handshake and read the HTML resource. This remains distinct from visual panel verification. Use the **Transcripted Local** entry for this Mac test. The account package has not received a fix for this runtime.

The companion-enabled Mac app is built. Direct MCP calls verified its connection with recording and live sharing off. The actual Codex visual panel remains unverified; neither a successful native connection nor the installed skill alone proves that UI is available.

[Open the private plugin](https://chatgpt.com/plugins/plugins_6abdbb6de6088191bd1ebfe05a9a7450).

## First test on this Mac

1. Finish any active recording and quit the current Transcripted app.
2. From this checkout, run `bash script/build_and_run.sh --launch-only`. This opens `build/Transcripted.app`. It refuses to launch while another Transcripted copy is running.
3. In **Settings → Agent → ChatGPT companion**, enable **Allow a local companion**, **Start and stop meetings**, and **Allow live transcript sharing**. The native status should say **Ready on this Mac**. Check that your selected meeting model is downloaded and ready.
4. Open a new local ChatGPT Work or Codex conversation, enable **Transcripted**, and ask: **“Open the Transcripted companion and check its connection.”** If the plugin is absent, restart the desktop host so it discovers the installed plugin.
5. Choose an ordinary Zoom, Meet, Teams, or in-person meeting. Start recording from the panel. Its sharing switch should begin off. Turn on **Share live text with ChatGPT** when ready. Allow the speech model to load, then speak a few complete sentences.
6. Check that provisional microphone/system text appears. Ask **“What did we just decide? Cite the live transcript and mention any gaps.”** The live context is a recent partial window, with timing and processing status. The model does not continuously reason without a question.
7. Turn sharing off. New live text should stop entering the conversation and the attached preview should clear. Text already sent remains in ChatGPT. Recording should continue in Transcripted.
8. Stop recording. Wait for normal final transcription, then find the saved meeting in the context tab. Select one passage, attach it, and ask a question about it. Confirm that the final transcript and normal audio playback still work in Transcripted.

An ordinary hosted ChatGPT conversation needs a separately configured private MCP connection before it can reach the Mac. Uploading this private plugin does not create that connection. See [connection guidance](https://developers.openai.com/plugins/deploy/connect-chatgpt) and [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels).

## When something needs attention

| What you see | What to check |
| --- | --- |
| Disconnected | The companion-enabled app is running and **Allow a local companion** is enabled. Use **Reconnect** in native settings, then refresh the panel. |
| Recording controls disabled | Enable **Start and stop meetings**. The host must support local plugin tools. |
| Sharing unavailable | Enable the native live-sharing permission and start a meeting. Each meeting needs its own sharing switch. |
| Waiting or model unavailable | Check the selected on-device model and its download. The app does not switch to cloud speech recognition. |
| Paused for another task | Dictation and final transcription take priority. Live preview resumes when the local model is available. |
| Lag or preview gaps | The preview has bounded queues. Silence can increase the displayed lag. Final saved transcription uses the durable recording separately. |

## Verification completed

- Native application built successfully; the app bundle and refreshed MCP helper passed Developer ID signature verification. This local build is not a notarized public release.
- MCP package: 230 tests passed. Native companion checks: 66 passed. Live state checks: 38 passed. Revocation mutations failed the relevant tests as expected.
- Core XCTest: 593 tests, zero failures, one skip. Swift Testing: 944 tests passed. Fast tests, integration and deterministic E2E smoke, synthetic audio, imported audio, release-health fixtures, and PostHog fixtures passed.
- Packaging rejects stray transcript, audio, credential, and index files. The launch guard preserves running app copies. The installed plugin launcher was exercised through MCP initialization, tool listing, and the companion UI resource.
- All 26 rendered panel checks passed. They cover selected-passage attachment, sharing defaults, delayed replies after revocation, live freshness and gap metadata, recovered errors, disconnected controls, unsupported hosts, dark mode, and mobile overflow. These use invented samples, a real MCP binary, and a simulated host.
- Repository quick checks: 60 passed, zero failures. The concurrency warning census stayed at its existing baseline of 119 warnings.
- The full QA benchmark reported **INCOMPLETE**, with zero failed steps: its app-build step was skipped because the real build ran separately, and existing saved-library validation reported a nonblocking warning. Those existing artifacts were preserved.

Real call capture, permissions, Bluetooth/AirPods behavior, native companion controls in the running app, and a live ChatGPT conversation remain device tests. Automated fixture success does not establish those results.

## Artifacts and review

- Native build: `build/Transcripted.app`.
- Portable plugin archive: `build/companion/Transcripted-plugin.zip`.
- Sample screenshots: `.agent-review/visuals/companion-*.png`.
- Full QA report: `/private/tmp/transcripted-companion-qa/final/qa-report.md`; raw logs remain local.
- Implementation and connection contract: [companion guide](chatgpt-companion.md).

Independent owner reviews covered the full change against `85bbcc09`, including native access/revocation, PCM delivery, live inference, the MCP boundary, panel behavior, and packaging. Their context-freshness and recovered-error findings were corrected before the final package. Final review found no remaining actionable issues.
