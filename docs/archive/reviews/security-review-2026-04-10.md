# Security Review

Date: 2026-04-10

This document captures a read-only static security review of the macOS app, updater, shared storage layer, and beta backend.

## Highest-Risk Findings

1. Embedded beta bearer tokens are compiled into shipped builds, validated as plaintext on the backend, and echoed during packaging. Any extracted token can be used directly against the proxy.
2. The backend forwards arbitrary `/v1/messages` requests with no effective server-side quota enforcement, model allowlisting, or strong request limits, which creates cost-abuse risk after token leakage.
3. The admin usage endpoint returns raw user tokens, and the backend seed script appears to contain committed beta credentials.
4. The updater verifies only Team ID, not the app's bundle identifier or designated requirement, so another app signed by the same team could satisfy the current trust check.
5. SQLite `-wal` and `-shm` sidecars for sensitive local databases are not covered by the owner-only permission hardening applied to the main `*.sqlite` files.

## Medium-Risk Findings

1. The updater relaunch path is interpolated into `bash -c`, which introduces command-injection risk if the install path contains shell metacharacters.
2. Dictation transcripts are persisted without the owner-only file-permission hardening used for other sensitive artifacts.
3. Failed-transcription cleanup trusts a raw home-directory prefix check on deserialized paths before deleting them.
4. Clipboard fallback can leave dictated text on the global pasteboard when Accessibility is unavailable or synthetic paste fails.
5. `/logs` stores raw client log payloads and returns recent entries through the admin endpoint without strong size limits or server-side redaction.
6. The beta build enables JIT and disables library validation while remaining unsandboxed, increasing post-exploitation leverage.

## Lower-Risk Findings

1. Sensitive storage paths are written to unified logging with public formatting.
2. The recent-meetings UI trusts any `.md` entry in the meetings folder and does not fully enforce regular-file checks.

## Positive Controls

1. Model downloads validate remote filenames and support SHA-256 integrity checks before installation.
2. The backend uses parameterized D1 queries for token lookup and ingestion.
3. Accessibility-sensitive automation paths are gated before use.

## Recommended Remediation Order

1. Replace embedded beta tokens with revocable server-managed credentials and enforce server-side quotas.
2. Tighten updater trust verification and remove shell-based relaunch.
3. Harden local sensitive storage permissions, including SQLite sidecars and dictation exports.
4. Reduce telemetry and admin exposure of raw logs, events, and tokens.
5. Revisit beta entitlements and runtime hardening before broader distribution.
