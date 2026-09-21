# Home deletion / real Core reservation smoke

Run after `build-deps.sh` and `swift test`, with no other compiler active:

```bash
bash scripts/dev/test-home-deletion-reservation.sh
```

The runner reuses the actual test-enabled SwiftPM debug package artifacts at
`.build/debug/libTranscriptedCore.a` and
`.build/debug/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule`.
Set `TRANSCRIPTED_CORE_BUILD_DIR` only when those artifacts are in a different
known debug-products directory. Missing artifacts or newer Core sources fail
closed; the runner never implicitly rebuilds dependencies. It does not link the
release app's `libDraftDeps.a` or claim release-binary validation.

This compiles the real app deletion planner/transaction, app-to-Core serializer
and error adapter, audio resolver, and Trash/restore mechanics. `@testable` is
used solely to acquire/release and inspect a real Core replacement reservation.
Nothing copies or mocks the reservation registry or its enforcement.

The only test substitutions are the row value carrier (`transcriptURL`) and a
FileManager subclass that redirects the OS Trash destination into the unique
temporary fixture root. This is not Home scanning/UI, OS Trash permissions, or
end-to-end retranscription coverage. All fixture content and opaque `.wav` bytes
are synthetic. Real user files, the real Trash, application settings, audio
devices, network, and model inference are not involved. Cleanup of the unique
temporary fixture is attempted on normal success or thrown failure.

## Oracles

- Assert the real Core reservation is active before attempts and inactive before
  recovery. Test both item deletion and Trash for the exact app-domain error,
  and precomputed-plan deletion for the exact adapter error.
- Verify transcript, owned summary, both audio files and an unrelated sentinel
  byte-for-byte after each denied operation; assert zero Trash/removal calls.
  Success, a wrong error, or partial destructive effects therefore fails.
- Use independently constructed expected ownership paths, not the plan itself
  as the expected value. After release, Trash must move exactly the three owned
  roots and leave actual reversible files behind.
- Undo restores every original byte; synthetic Trash empties; repeated Undo is
  harmless. Permanent deletion then succeeds and preserves the unrelated file.
- Any assertion or unexpected error exits 1. Success prints the assertion count.

The fallback fast-test serializer has no Core replacement registry. A harness
accidentally using it would allow deletion during the acquired Core reservation
and fail the exact-error oracle, rather than reporting an empty pass. Compilation
also requires a real test-enabled Core module; there is no fake-Core include path.

Coordinator verification (2026-09-21): compiled and executed against the actual
debug Core package, **47 assertions passed**, exit 0. The clean run log is
retained locally by the coordinator and is not uploaded with the patch.
The coordinator and an independent reviewer checked the test oracles. This
remains helper/Core integration proof, not native Home UI or OS Trash proof.
