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

## Recommendation

Keep pinning Tilde's binary. A from-source step in `build-deps.sh` would break on the next Command Line Tools update, on any machine without CLT 26.6, and whenever the web UI source can't be pinned. If Transcripted ever builds its own helper, build with `LLAMA_BUILD_UI=OFF` and pin its own hash of the stripped output instead of chasing this one.
