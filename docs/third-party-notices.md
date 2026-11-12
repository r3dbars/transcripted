# Third-party notices

`build.sh` and `build-beta.sh` copy `THIRD_PARTY_LICENSES.md` into the app's
`Contents/Resources`. It is the only notice file the app ships, so anything
bundled or linked without an entry there goes out without its notice. Texts in it
are copied from upstream at the exact version, never written from memory.

## Before a release

Check that each entry still matches what the build uses. If it doesn't, re-diff
the entry against upstream at the new version.

- **Sentry** (`SENTRY_COCOA_VERSION` in `scripts/entrypoints/build-deps.sh`): Sentry's own MIT text, plus the four SentryCrash notices from that tag's `THIRD_PARTY_NOTICES.md`.
- **FluidAudio** (`FLUID_AUDIO_VERSION`): the files in its `ThirdPartyLicenses/` directory at that tag (fastcluster, VBx, the Kokoro G2P notices).
- **Packages SwiftPM resolves on its own.** Only the top-level packages in the generated `DraftDeps` manifest are pinned. swift-huggingface, EventSource, swift-collections, swift-crypto and yyjson float with each build, and `build-deps.sh` does not keep the resolved lockfile. To see what a build will use, make a scratch package with the same dependency list, run `swift package resolve`, and compare its `Package.resolved` with the versions named in the entries.
- **llama-server:** `docs/llama-server-provenance.md` ("Notices") says what the helper is built from and which part is still a gap.
- **Models:** each model's entry names its version and license. A model swap needs a new entry.

## Open as of 2026-11-12

The notice file alone does not fix these two:

- The `.mcpb` bundle that `.github/workflows/publish-mcp-registry.yml` zips holds the helper binary, `manifest.json` and an icon. It ships none of the MCP-side notices.
- `build-beta.sh` copies the whole local diarizer model cache into the app, with no file allowlist and no hash check. `THIRD_PARTY_LICENSES.md` describes the legacy files that this could carry.
