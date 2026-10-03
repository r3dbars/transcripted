# llama-server provenance

Writing's inference helper (`Contents/Helpers/llama-server`) is Tilde 0.1.0 beta 1's helper.

- **Where build-deps gets it:** `build-deps.sh` fetches it from `Tilde.zip` on the r3dbars/tilde v0.1.0-beta.1 release (zip SHA-256 `12b7f14ae31abea7d5cecf236d2e4de3b0facad89fa580877dec391336b26a50`).
- **How it's pinned:** by its code bytes with the signature removed, SHA-256 `3f6895ab8d077b02803761fb8cc254073d2c7b4006fbacbef4c844879333fffc`.
- **Signing:** the build re-signs it with Transcripted's identity.

## Verified from source (2026-09-25)

The pinned bytes were rebuilt independently and matched exactly, twice, from fresh clones:

- **Source:** `ggml-org/llama.cpp` at `2115b73d8ebdbd659075cce66c609506863bc826` (2026-08-22, "model : support DSpark for bailingmoe3 (#27508)"). A shallow clone without tags gives `version: 0.2.0-dev (build 1, commit 2115b73)`.
- **Toolchain:** Command Line Tools 26.6 (AppleClang 21.0.0.21000101, ld-1267, macOS SDK 26.5). Xcode 27 produces different bytes.
- **Configure:** `cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_OPENSSL=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0`, with `-ffile-prefix-map` mapping the source path onto Tilde's original temporary build path (235 absolute paths are embedded).
- **Build:** `cmake --build build --target llama-server`, then `strip -S -x`.
- **Web UI:** the embedded web UI assets (70 gzipped files) came from Hugging Face's `ggml-org/llama-ui` "latest" at build time (built 2026-08-24, likely release b10612). They aren't pinned by the llama.cpp commit.
- **Hash comparison:** `codesign --remove-signature` leaves `__LINKEDIT` sized for the removed signature. To compare, ad-hoc sign with `--digest-algorithm=sha1,sha256`, then remove the signature again. That yields `3f6895ab…`.

Conclusion: the shipped helper is upstream llama.cpp `2115b73` plus that web UI snapshot, and nothing else.

Reproduced again on 2026-10-03 (CLT 26.6, CMake 4.4.3 from PyPI, `npm` kept off `PATH` so the UI comes from Hugging Face, `HF_UI_VERSION=b10612`, `DEVELOPER_DIR=/Library/Developer/CommandLineTools`, `-ffile-prefix-map=<src>=/var/folders/rm/99g7pxgn6d72plzypdcy18j40000gn/T/tilde-llama-static.ZlYSXG/llama.cpp` in the C, C++, ObjC and ASM flags). The normalized hash came out `3f6895ab…` again.

## Owned build: parked residency heartbeat (verified, not shipped yet)

Upstream's Metal backend keeps a heartbeat thread that wakes every 5 ms for the life of the process, including after the 180 s keep-alive window has lapsed and it has nothing to do. On the idle helper that's about 145 interrupt wakeups a second, the biggest idle energy item in Transcripted's process tree.

[`llama-server-patches/ggml-metal-rsets-park.patch`](llama-server-patches/ggml-metal-rsets-park.patch) changes only `ggml/src/ggml-metal/ggml-metal-device.m`:

- When the window has lapsed (`d_loop <= 0`), the heartbeat blocks on a dispatch semaphore instead of sleeping 5 ms and checking again.
- `ggml_metal_device_rsets_keep_alive` signals it only on the idle-to-armed edge.
- `ggml_metal_rsets_free` signals it after setting `d_stop`. That signal is required: without it, a parked heartbeat never returns and shutdown hangs.

While armed, the cadence, the `requestResidency` calls and the window length are unchanged, so memory stays wired exactly as long as before. No env var changes (`GGML_METAL_NO_RESIDENCY` stays unset).

Built from `2115b73` plus that patch with the same recipe as above (2026-10-03). Results against the reproduced upstream binary, Qwen 3.5 9B, the host's launch arguments:

- **Code:** only `_ggml_metal_rsets_init` (with its block), `_ggml_metal_rsets_free` and `_ggml_metal_device_rsets_keep_alive` differ; everything else is address shifts.
- **Output:** 7 of 7 greedy `/completion` requests identical (`content`, `tokens`, `prompt_n`, `cache_n`), including a cached-restore pair (`cache_n` 177).
- **Idle wakeups after the window lapses:** 164/s upstream, 1.3/s patched. `sample` shows the heartbeat in `semaphore_wait_trap`; upstream sits in `usleep`.
- **Re-arm:** after one more request the patched heartbeat runs again (about 163 wakeups/s, same as upstream while armed).
- **Shutdown:** SIGTERM exits with status 0 within 1 s, both inside the armed window and after it lapsed, for both binaries.

The host's launch arguments include a RAM-tiered `--cache-ram` (no flag at 64 GiB and up, so the build's 8 GiB default; 4096 MiB at 32 GiB and up; 1024 MiB below). Small Macs avoid swap; big Macs keep today's revisit speed (a cache hit restores in 0.08-0.6 s where a re-prefill takes about 1.2 s).

Pins for the owned build, once hosted (ad-hoc signed with `--digest-algorithm=sha1,sha256`, so `codesign --remove-signature` in `build-deps.sh` works on it unchanged):

- Ad-hoc signed asset: `dc5e138a9c7a0ea949084e16e92cd1c13da549d5f4f176358a8202428531f0cf`
- Signature removed (the `LLAMA_SERVER_UNSIGNED_SHA256` value): `5ad7c05f1eb4529e48539afae09085fb156ada9beb2cc0d034953c240d90f255`

What's left before `build-deps.sh` moves off Tilde's zip: the owner OKs leaving the Tilde pin, the binary goes up as an owned release asset, `download_llama_server` fetches it and both SHAs are re-pinned, and the writing-plan decision 9 and port-ledger rows get updated. The patch should also go upstream; master still polls.

## Recommendation

Don't build from source in `build-deps.sh`. It would break on the next Command Line Tools update, on any machine without CLT 26.6, and whenever the web UI source can't be pinned. Ship prebuilt bytes instead: today Tilde's, and once it's hosted, the owned build above. Any later owned build should also use `LLAMA_BUILD_UI=OFF` (the host passes `--no-webui`) and pin its own hash of the stripped output.
