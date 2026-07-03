#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SENSITIVE_KEY_FRAGMENTS = (
    "audio",
    "authorization",
    "bearer",
    "bundle",
    "credential",
    "device",
    "dsn",
    "email",
    "error",
    "file",
    "meeting_title",
    "name",
    "password",
    "path",
    "screen",
    "screenshot",
    "speaker",
    "source_app",
    "secret",
    "text",
    "title",
    "token",
    "transcript",
    "url",
)

SAFE_PLACEHOLDERS = {
    "transcript_text": "[redacted-transcript]",
    "audio_reference": "[redacted-audio-reference]",
    "absolute_path": "[redacted-path]",
    "raw_device_name": "[redacted-device]",
    "screen_derived_text": "[redacted-screen-text]",
    "screenshot_path": "[redacted-screenshot-path]",
    "token_secret": "[redacted-secret]",
    "email": "[redacted-email]",
    "raw_url": "[redacted-url]",
    "meeting_title": "[redacted-title]",
    "speaker_name": "[redacted-speaker]",
    "source_app_identifier": "[redacted-source-app]",
    "window_title": "[redacted-title]",
    "shared_corpus": "[redacted-sensitive-value]",
}


@dataclass(frozen=True)
class LeakClass:
    id: str
    values: tuple[str, ...]
    patterns: tuple[re.Pattern[str], ...] = ()


@dataclass(frozen=True)
class Finding:
    lane: str
    surface: str
    leak_class: str
    check_id: str
    detail: str

    def as_dict(self) -> dict[str, str]:
        return {
            "lane": self.lane,
            "surface": self.surface,
            "leak_class": self.leak_class,
            "check_id": self.check_id,
            "detail": self.detail,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a deterministic synthetic privacy leak sweep for Transcripted reports and handoff surfaces."
    )
    parser.add_argument(
        "--corpus",
        default="Tests/Fixtures/ObservabilitySanitizerCorpus.json",
        help="Repo-relative sanitizer corpus to reuse for forbidden synthetic strings.",
    )
    parser.add_argument("--write-report", help="Optional path for a JSON report.")
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_corpus(root: Path, relative_path: str) -> dict[str, Any]:
    path = root / relative_path
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def flatten_corpus_forbidden(corpus: dict[str, Any]) -> tuple[str, ...]:
    values: list[str] = []
    for case in corpus.get("cases", []):
        values.extend(str(value) for value in case.get("must_not_contain", []) if value)
    return tuple(dict.fromkeys(values))


def synthetic_leak_classes(corpus: dict[str, Any]) -> tuple[LeakClass, ...]:
    shared = flatten_corpus_forbidden(corpus)
    return (
        LeakClass(
            "transcript_text",
            (
                "Synthetic private transcript words about the customer roadmap",
                "Synthetic dictated private note",
            ),
        ),
        LeakClass(
            "audio_reference",
            (
                "/Users/synthetic/Private Calls/customer-roadmap.wav",
                "file:///Users/synthetic/Private Calls/customer-roadmap.m4a",
                "system_audio_customer_room.wav",
            ),
        ),
        LeakClass(
            "absolute_path",
            (
                "/Users/synthetic/Library/Application Support/Transcripted/captures/meetings/customer.md",
                "/private/var/folders/synthetic/customer.tmp",
            ),
            (re.compile(r"/(?:Users|Volumes|private|tmp)/[^\s`\"']+"),),
        ),
        LeakClass(
            "raw_device_name",
            (
                "Synthetic User's AirPods Pro",
                "Synthetic MacBook Pro Microphone",
            ),
        ),
        LeakClass(
            "token_secret",
            (
                "sk-" + "synthetic-private-token-value",
                "Bearer " + "synthetic-private-bearer-value",
                "github_pat_" + "synthetic_private_token_value",
            ),
            (
                re.compile(r"\bsk-[A-Za-z0-9_-]{10,}\b"),
                re.compile(r"\bBearer\s+[A-Za-z0-9_.-]{10,}\b", re.IGNORECASE),
                re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
            ),
        ),
        LeakClass(
            "email",
            ("synthetic.person@example.invalid",),
            (re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),),
        ),
        LeakClass(
            "raw_url",
            ("https://meet.example.invalid/private-room?token=synthetic-token",),
            (re.compile(r"https?://[^\s`\"']+", re.IGNORECASE),),
        ),
        LeakClass(
            "meeting_title",
            ("Synthetic Customer Roadmap",),
        ),
        LeakClass(
            "speaker_name",
            ("Synthetic Alice Customer",),
        ),
        LeakClass(
            "source_app_identifier",
            (
                "Synthetic Private Notes",
                "com.synthetic.private-notes",
            ),
        ),
        LeakClass(
            "window_title",
            (
                "Synthetic Customer Roadmap - Private Notes",
                "Synthetic Browser Tab With Private URL",
            ),
        ),
        LeakClass(
            "screen_derived_text",
            (
                "Synthetic OCR text from a private roadmap screen",
                "Synthetic screen summary with customer names and decisions",
            ),
        ),
        LeakClass(
            "screenshot_path",
            (
                "/Users/synthetic/Library/Application Support/Transcripted/recordings/screenshots/2026-09-01/1788271200000.jpg",
                "file:///Users/synthetic/Library/Application%20Support/Transcripted/recordings/screenshots/private.jpg",
            ),
        ),
        LeakClass("shared_corpus", shared),
    )


def replacement_for(leak_class: str) -> str:
    return SAFE_PLACEHOLDERS.get(leak_class, "[redacted-sensitive-value]")


def redact_text(text: str, leak_classes: tuple[LeakClass, ...]) -> str:
    redacted = text
    for leak_class in leak_classes:
        for value in sorted(leak_class.values, key=len, reverse=True):
            if value:
                redacted = redacted.replace(value, replacement_for(leak_class.id))

    redacted = re.sub(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----", "[redacted-secret]", redacted, flags=re.IGNORECASE | re.DOTALL)
    redacted = re.sub(r"\bsk-[A-Za-z0-9_-]{10,}\b", "[redacted-secret]", redacted)
    redacted = re.sub(r"\bBearer\s+[A-Za-z0-9_.-]{10,}\b", "Bearer ****", redacted, flags=re.IGNORECASE)
    redacted = re.sub(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b", "[redacted-secret]", redacted)
    redacted = re.sub(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", "[redacted-email]", redacted, flags=re.IGNORECASE)
    redacted = re.sub(r"https?://[^\s`\"']+", "[redacted-url]", redacted, flags=re.IGNORECASE)
    redacted = re.sub(r"/(?:Users|Volumes|private|tmp)/[^\s`\"']+", "[redacted-path]", redacted)
    return redacted


def key_is_sensitive(key: str) -> bool:
    normalized = key.lower()
    return any(fragment in normalized for fragment in SENSITIVE_KEY_FRAGMENTS)


def sanitize_mapping(mapping: dict[str, Any], leak_classes: tuple[LeakClass, ...], *, drop_sensitive_keys: bool) -> dict[str, Any]:
    sanitized: dict[str, Any] = {}
    for key, value in mapping.items():
        if key_is_sensitive(key):
            if drop_sensitive_keys:
                continue
            sanitized[key] = "[redacted-sensitive-value]"
            continue
        sanitized[key] = sanitize_value(value, leak_classes, drop_sensitive_keys=drop_sensitive_keys)
    return sanitized


def sanitize_value(value: Any, leak_classes: tuple[LeakClass, ...], *, drop_sensitive_keys: bool) -> Any:
    if isinstance(value, str):
        return redact_text(value, leak_classes)
    if isinstance(value, dict):
        return sanitize_mapping(value, leak_classes, drop_sensitive_keys=drop_sensitive_keys)
    if isinstance(value, list):
        return [sanitize_value(item, leak_classes, drop_sensitive_keys=drop_sensitive_keys) for item in value]
    return value


def json_line(payload: dict[str, Any]) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def build_synthetic_surfaces(leak_classes: tuple[LeakClass, ...]) -> dict[str, dict[str, str]]:
    secret = {item.id: item.values[0] if item.values else "" for item in leak_classes}

    local_event = {
        "timestamp": "2026-06-06T00:00:00Z",
        "level": "error",
        "engine": "meeting",
        "event": "meeting_transcript_failed",
        "message": f"Failed {secret['meeting_title']} from {secret['absolute_path']}",
        "context": {
            "duration_bucket": "10_29m",
            "failure_kind": "transcription_inference_failed",
            "trigger": "hotkey",
            "transcript_text": secret["transcript_text"],
            "audio_path": secret["audio_reference"],
            "device_name": secret["raw_device_name"],
            "token": secret["token_secret"],
            "speaker_name": secret["speaker_name"],
            "source_app_bundle": secret["source_app_identifier"],
        },
    }
    reliability_packet = {
        "feature": "meeting",
        "stage": "transcribe",
        "outcome": "failed_retryable",
        "event": "meeting_transcript_failed",
        "context": {
            "duration_bucket": "10_29m",
            "failure_kind": "transcription_inference_failed",
            "system_stream_present": "true",
            "word_count_bucket": "300_plus",
        },
    }

    sentry_context = sanitize_mapping(
        {
            "session_kind": "meeting",
            "session_stage": "transcribe",
            "title": secret["meeting_title"],
            "transcript_path": secret["absolute_path"],
            "error": secret["transcript_text"],
            "source_app_bundle": secret["source_app_identifier"],
        },
        leak_classes,
        drop_sensitive_keys=True,
    )
    posthog_properties = sanitize_mapping(
        {
            "failure_kind": "transcription_inference_failed",
            "trigger": "hotkey",
            "word_count_bucket": "300_plus",
            "meeting_title": secret["meeting_title"],
            "email": secret["email"],
            "raw_url": secret["raw_url"],
        },
        leak_classes,
        drop_sensitive_keys=True,
    )

    qa_report = "\n".join(
        [
            "PASS: tested synthetic privacy leak sweep. Good to go.",
            "",
            "## Flags",
            "",
            "- None.",
            "",
            "## Privacy",
            "",
            "Raw logs stay local. Do not upload user audio, transcript text, speaker names, tokens, absolute paths, raw private URLs, or device names.",
            "",
            "## Evidence",
            "",
            "- `synthetic-sweep/report.json`",
        ]
    )
    local_report = "\n".join(
        [
            "# Local Synthetic Privacy Report",
            "",
            f"- Failure kind: `{redact_text(secret['transcript_text'], leak_classes)}`",
            "- Artifact id: `synthetic-meeting-001`",
            "- Raw corpus, audio, device, token, URL, speaker, and path values omitted.",
        ]
    )

    pr_body = "\n".join(
        [
            "## What changed",
            "",
            "- Added a synthetic privacy leak sweep.",
            "",
            "## Risk Review",
            "",
            "- [x] Privacy / local-first behavior reviewed",
            "- [x] No private transcripts, audio, tokens, personal paths, device names, meeting titles, speaker names, emails, raw URLs, or customer data are included",
        ]
    )
    release_note = "\n".join(
        [
            "# Transcripted release note",
            "",
            "- Improves deterministic privacy coverage for local-only reports.",
            "- Release notes were checked with synthetic leak markers only.",
        ]
    )
    timeline_card_export = "\n".join(
        [
            "# Timeline - 2026-09-01",
            "",
            "1. **9:00 AM - 10:00 AM - Synthetic focused work**",
            "   - Category: Work",
            "   - Summary: [redacted-screen-text]",
            "   - App/site: [redacted-source-app]",
            "   - Window: [redacted-title]",
            "   - Screenshot: [redacted-screenshot-path]",
        ]
    )
    timeline_day = json_line(
        sanitize_value(
            {
                "timeline_day": "2026-09-01",
                "card_count": 1,
                "screen_derived_text": secret["screen_derived_text"],
                "window_title": secret["window_title"],
                "source_app_identifier": secret["source_app_identifier"],
                "screenshot_path": secret["screenshot_path"],
            },
            leak_classes,
            drop_sensitive_keys=False,
        )
    )

    scanner_report = {
        "status": "pass",
        "synthetic_only": True,
        "lanes": [
            "logs-events-reliability",
            "sentry-posthog-payloads",
            "qa-report-artifacts",
            "pr-release-docs",
            "timeline-artifacts",
            "automated-scanner-test-pr",
        ],
        "leak_classes": [item.id for item in leak_classes],
    }

    return {
        "logs-events-reliability": {
            "events.jsonl": json_line(sanitize_value(local_event, leak_classes, drop_sensitive_keys=False)),
            "reliability.jsonl": json_line(reliability_packet),
        },
        "sentry-posthog-payloads": {
            "sentry-context.json": json_line(sentry_context),
            "posthog-properties.json": json_line(posthog_properties),
        },
        "qa-report-artifacts": {
            "qa-report.md": qa_report,
            "local-report.md": local_report,
        },
        "pr-release-docs": {
            "pull-request-body.md": pr_body,
            "release-note.md": release_note,
        },
        "timeline-artifacts": {
            "timeline-card.md": timeline_card_export,
            "timeline-day.json": timeline_day,
        },
        "automated-scanner-test-pr": {
            "privacy-leak-sweep-report.json": json.dumps(scanner_report, indent=2, sort_keys=True),
        },
    }


def scan_surface(lane: str, surface: str, text: str, leak_classes: tuple[LeakClass, ...]) -> list[Finding]:
    findings: list[Finding] = []
    for leak_class in leak_classes:
        for value in leak_class.values:
            if value and value in text:
                findings.append(
                    Finding(
                        lane=lane,
                        surface=surface,
                        leak_class=leak_class.id,
                        check_id="synthetic-value-survived",
                        detail="A synthetic sensitive value survived redaction.",
                    )
                )
                break
        for pattern in leak_class.patterns:
            if pattern.search(text):
                findings.append(
                    Finding(
                        lane=lane,
                        surface=surface,
                        leak_class=leak_class.id,
                        check_id="sensitive-pattern-survived",
                        detail="A sensitive-looking pattern survived redaction.",
                    )
                )
                break
    return findings


def check_policy_anchors(root: Path) -> list[Finding]:
    required = {
        ".github/PULL_REQUEST_TEMPLATE.md": (
            "No private transcripts, audio, tokens, personal paths, or customer data are included",
        ),
        ".github/ISSUE_TEMPLATE/bug_report.md": (
            "Please redact transcripts, audio, meeting titles, speaker names, emails, tokens",
        ),
        ".github/ISSUE_TEMPLATE/feature_request.md": (
            "Please do not include private transcripts, audio, meeting titles, speaker names",
        ),
        "docs/qa-test-bench.md": (
            "Keep raw logs local. Do not upload",
        ),
        "docs/privacy-first-observability.md": (
            "never send transcript text",
            "privacy-leak-sweep.py",
        ),
        "docs/release-packaging.md": (
            "privacy-leak-sweep.py",
        ),
        "scripts/README.md": (
            "privacy-leak-sweep.py",
        ),
    }

    findings: list[Finding] = []
    for relative_path, fragments in required.items():
        path = root / relative_path
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            findings.append(
                Finding(
                    lane="automated-scanner-test-pr",
                    surface=relative_path,
                    leak_class="policy_anchor",
                    check_id="policy-file-missing",
                    detail="A privacy policy anchor file is missing.",
                )
            )
            continue
        for fragment in fragments:
            if fragment not in text:
                findings.append(
                    Finding(
                        lane="automated-scanner-test-pr",
                        surface=relative_path,
                        leak_class="policy_anchor",
                        check_id="policy-anchor-missing",
                        detail=f"Missing required privacy anchor in {relative_path}.",
                    )
                )
    return findings


def build_report(root: Path, corpus_path: str) -> dict[str, Any]:
    corpus = load_corpus(root, corpus_path)
    leak_classes = synthetic_leak_classes(corpus)
    surfaces = build_synthetic_surfaces(leak_classes)

    findings: list[Finding] = []
    lane_results: list[dict[str, Any]] = []
    for lane, lane_surfaces in surfaces.items():
        lane_findings: list[Finding] = []
        for surface, text in lane_surfaces.items():
            lane_findings.extend(scan_surface(lane, surface, text, leak_classes))
        findings.extend(lane_findings)
        lane_results.append(
            {
                "id": lane,
                "surface_count": len(lane_surfaces),
                "finding_count": len(lane_findings),
            }
        )

    policy_findings = check_policy_anchors(root)
    findings.extend(policy_findings)

    return {
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "synthetic_only": True,
        "status": "pass" if not findings else "attention",
        "corpus_path": corpus_path,
        "leak_classes": [item.id for item in leak_classes],
        "lanes": lane_results,
        "policy_finding_count": len(policy_findings),
        "finding_count": len(findings),
        "findings": [finding.as_dict() for finding in findings],
    }


def print_report(report: dict[str, Any]) -> None:
    status = "PASS" if report["status"] == "pass" else "ATTENTION"
    print(f"Privacy leak sweep: {status}")
    print(f"- synthetic_only: {str(report['synthetic_only']).lower()}")
    print(f"- leak classes covered: {', '.join(report['leak_classes'])}")
    for lane in report["lanes"]:
        print(f"- {lane['id']}: {lane['surface_count']} surfaces, {lane['finding_count']} findings")
    if report["findings"]:
        print("Findings:")
        for finding in report["findings"]:
            print(f"- {finding['check_id']} [{finding['lane']} / {finding['surface']}]: {finding['detail']}")


def main() -> int:
    args = parse_args()
    root = repo_root()
    report = build_report(root, args.corpus)
    print_report(report)

    if args.write_report:
        report_path = Path(args.write_report)
        if not report_path.is_absolute():
            report_path = root / report_path
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
