# Transcripted companion for ChatGPT

The companion connects ChatGPT to the Transcripted application running on the same Mac. It exposes saved context, meeting controls, and provisional live text produced by the existing on-device speech engine. It does not join calls as a bot.

## Use it

1. Finish any active meeting and quit your current Transcripted copy. Open the companion-enabled build with `bash script/build_and_run.sh --launch-only` from this checkout. This launcher preserves a running copy and never stops a meeting to restart the app.
2. In **Settings → Agent**, enable companion access. Enable meeting controls and live sharing only for the capabilities you want.
3. Enable **Transcripted** in a new local ChatGPT Work or Codex conversation, then ask **“Open the Transcripted companion.”**
4. Start a meeting in the panel or in Transcripted. Turn on **Share live text with ChatGPT** for that meeting to follow its transcript and make a bounded recent window available as model context.
5. Ask a question such as **“What did they just decide?”** or **“What should I follow up on?”** Stop the meeting when finished. The normal pipeline then produces the final saved transcript.

The local process integration requires a desktop host that can run local plugin MCP tools. Ordinary hosted ChatGPT chats need a separately configured private MCP connection, such as [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels), before they can reach the Mac. Uploading a plugin package alone does not provide that connection. [Official connection guidance](https://developers.openai.com/plugins/deploy/connect-chatgpt) describes both connection paths.

## What is shared

Audio capture, live speech inference, and final transcription run on the Mac. The companion never uploads audio. Saved text requested through a context tool and live text shared through the session switch are sent to ChatGPT. The panel's recent live context replaces a bounded window; refreshing the panel does not send a new user message or imply continuous model reasoning.

Live text is provisional and may lag, omit speech, or change in the final transcript. Microphone/system labels identify audio sources, not people. The finished meeting and its speaker labels remain authoritative. Live processing uses bounded queues and drops delayed preview work rather than interrupting durable audio recording.

The preview uses four-second audio windows with half-second overlap and the selected on-device meeting model. Model loading and inference add latency. Dictation and final meeting transcription take priority, and the panel reports when live processing is waiting, paused, or unavailable.

## Native connection

The app hosts a versioned JSON-lines Unix-domain socket in its private companion directory. The directory is mode `0700`; the socket and connection file are mode `0600`. A random rotating connection token is never returned by an MCP tool or written to logs. The app creates this surface only after companion access is enabled. Meeting controls and live sharing have separate permissions, and live sharing also requires the current session's explicit switch.

Start and stop use the existing meeting controller so capture permission checks, audio finalization, and final transcription remain intact. Stop requests include the exact current session identifier; stale requests fail. There is no discard endpoint, generic command execution, arbitrary file path endpoint, or dependency on the lab-only control channel.

The local boundary protects against accidental access and other OS users. A process running as the same Mac user with access to the private connection directory is within that user's trust boundary.

## Build and package

```sh
bash build-deps.sh --force
bash build.sh --no-open
swift test --package-path Tools/TranscriptedMCP
python3 Tools/TranscriptedCompanion/package.py --no-build
python3 Tools/TranscriptedCompanion/test-launcher.py
```

The portable source plugin is `Tools/TranscriptedCompanion/plugin/transcripted`; the archive is generated under `build/companion/Transcripted-plugin.zip`. Packaging also generates `build/companion/local/transcripted`, a compatibility-only install used by the local marketplace. Codex 0.154.0 and the desktop-bundled 0.159.2 returned no MCP servers for the portable format; the compatibility export is verified through its actual `plugin/read` API. Do not point that runtime directly at the portable source or edit its installed cache.

The launcher verifies the packaged helper's SHA-256 before starting and enables the text-only companion mode. The older MCP audio widget remains available to ordinary MCP clients but is excluded from this plugin. No connection tokens, capture files, SQLite indexes, logs, model caches, or app credentials are packaged.

The repository's local marketplace exposes `transcripted@transcripted-local`. Register and install it using the supported local plugin commands:

```sh
codex plugin marketplace add /absolute/path/to/this/checkout
codex plugin add transcripted@transcripted-local
```

After updating source, regenerate the package and reinstall the plugin to refresh its cached helper. A new conversation or desktop restart may be needed before newly added tools are discovered.

Run `python3 Tools/TranscriptedCompanion/test-discovery.py` to check discovery with the installed Codex runtime. Add `--check-installed-startup` to start configured MCP servers and verify the installed Transcripted tools load without calling them. The legacy config uses `cwd: "."` and `./scripts/launch.sh`; the desktop runtime did not expand the prior `${CLAUDE_PLUGIN_ROOT}` placeholder. Server discovery and valid UI metadata do not prove that a particular host renders MCP Apps. The sidebar/panel integration still requires a compatible host and visual verification.
