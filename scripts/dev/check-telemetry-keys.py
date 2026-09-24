#!/usr/bin/env python3
"""Fail when an allowlisted telemetry key would be silently dropped.

The off-device sanitizers drop any key whose lowercased form contains a
sensitive fragment (``PayloadSanitizationCore.shouldDrop``). An allowlist entry
that happens to contain one of those fragments (``start_profile`` contains
``file``) is allowlisted on paper and never arrives, which looks exactly like
working code from both sides. This checker reads the Swift sources as text and
mirrors the matching rules:

* Analytics (``AnalyticsPayloadSanitizer.shouldDrop``): drop when
  ``key.lowercased()`` contains any ``baseSensitiveKeyFragments`` entry. There
  is no explicit-safe escape hatch and no ``_bucket`` special case.
* Sentry (``SentryPayloadSanitizer.shouldDrop``): keep when the key is in
  ``explicitlySafeKeys`` (exact, case-sensitive ``Set.contains``); otherwise
  drop when ``key.lowercased()`` contains any of ``baseSensitiveKeyFragments``
  plus Sentry's own ``sensitiveKeyFragments`` additions.

Keys checked:

* analytics: every property in ``Resources/analytics-events.psv``, every name in
  ``Resources/analytics-reviewed-properties.psv``, and
  ``PayloadSanitizationCore.commonTelemetryKeys`` (TelemetryContext.keys, which
  AnalyticsReporter unions into every event's allowlist).
* sentry: ``SentryEventPolicy.allowedDiagnosticTagKeys``, the derived
  ``tags["..."] =`` keys written inside SentryEventPolicy,
  ``commonTelemetryKeys`` (unioned into the diagnostic tag filter),
  ``SentryPayloadSanitizer.crashRuntimeTagKeys``, and literal dictionary keys
  passed straight to ``SentryPayloadSanitizer.sanitizeTags([...])`` in Sources.

Dependency-free (python3 stdlib). Usage:

    python3 scripts/dev/check-telemetry-keys.py
    python3 scripts/dev/check-telemetry-keys.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

CORE_SWIFT = "Sources/Observability/PayloadSanitizationCore.swift"
SENTRY_SANITIZER_SWIFT = "Sources/Observability/SentryPayloadSanitizer.swift"
ANALYTICS_SANITIZER_SWIFT = "Sources/Observability/AnalyticsPayloadSanitizer.swift"
SENTRY_POLICY_SWIFT = "Sources/Observability/SentryEventPolicy.swift"
ANALYTICS_EVENTS_PSV = "Resources/analytics-events.psv"
ANALYTICS_REVIEWED_PSV = "Resources/analytics-reviewed-properties.psv"

STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


class ParseError(Exception):
    pass


def bracket_body(text: str, anchor_regex: str, what: str) -> str:
    """Return the text between the ``[`` following ``anchor_regex`` and its match."""
    match = re.search(anchor_regex, text)
    if not match:
        raise ParseError(f"could not find {what} (pattern {anchor_regex!r})")
    start = text.find("[", match.end())
    if start < 0:
        raise ParseError(f"no '[' after {what}")
    depth = 0
    i = start
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == "/" and text.startswith("//", i):
            newline = text.find("\n", i)
            i = len(text) if newline < 0 else newline
            continue
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return text[start + 1 : i]
        i += 1
    raise ParseError(f"unbalanced brackets in {what}")


def strip_line_comments(body: str) -> str:
    """Drop ``// ...`` comments that start outside a string literal."""
    out_lines = []
    for line in body.splitlines():
        in_string = False
        i = 0
        cut = len(line)
        while i < len(line):
            ch = line[i]
            if in_string:
                if ch == "\\":
                    i += 2
                    continue
                if ch == '"':
                    in_string = False
            elif ch == '"':
                in_string = True
            elif line.startswith("//", i):
                cut = i
                break
            i += 1
        out_lines.append(line[:cut])
    return "\n".join(out_lines)


def string_list(body: str) -> list[str]:
    return STRING_LITERAL.findall(strip_line_comments(body))


def dict_literal_keys(body: str) -> list[str]:
    """Keys of a ``["k": v, ...]`` literal: string literals followed by ``:``."""
    return re.findall(r'"((?:[^"\\\n]|\\.)*)"\s*:', strip_line_comments(body))


@dataclass
class Rules:
    base_fragments: list[str]
    sentry_extra_fragments: list[str]
    sentry_safe_keys: set[str]

    @property
    def sentry_fragments(self) -> list[str]:
        return self.base_fragments + self.sentry_extra_fragments


def analytics_should_drop(rules: Rules, key: str) -> list[str]:
    return [f for f in rules.base_fragments if f in key.lower()]


def sentry_should_drop(rules: Rules, key: str) -> list[str]:
    if key in rules.sentry_safe_keys:
        return []
    return [f for f in rules.sentry_fragments if f in key.lower()]


def parse_rules(core: str, sentry_sanitizer: str, analytics_sanitizer: str) -> Rules:
    base = string_list(bracket_body(core, r"static\s+let\s+baseSensitiveKeyFragments\s*:\s*\[String\]\s*=", "baseSensitiveKeyFragments"))
    if not base:
        raise ParseError("baseSensitiveKeyFragments parsed empty")

    sentry_decl = re.search(
        r"static\s+let\s+sensitiveKeyFragments\s*=\s*PayloadSanitizationCore\.baseSensitiveKeyFragments\s*(\+)?",
        sentry_sanitizer,
    )
    if not sentry_decl:
        raise ParseError("SentryPayloadSanitizer.sensitiveKeyFragments no longer starts from the shared base list; update this checker")
    extra: list[str] = []
    if sentry_decl.group(1):
        extra = string_list(bracket_body(sentry_sanitizer[sentry_decl.start():], r"\+", "Sentry sensitiveKeyFragments additions"))

    safe = set(string_list(bracket_body(sentry_sanitizer, r"static\s+let\s+explicitlySafeKeys\s*:\s*Set<String>\s*=", "explicitlySafeKeys")))
    if not re.search(r"explicitlySafeKeys\.contains\(key\)", sentry_sanitizer):
        raise ParseError("SentryPayloadSanitizer.shouldDrop no longer checks explicitlySafeKeys.contains(key); update this checker")

    analytics_decl = re.search(
        r"static\s+let\s+sensitiveKeyFragments\s*=\s*PayloadSanitizationCore\.baseSensitiveKeyFragments\s*$",
        analytics_sanitizer,
        re.MULTILINE,
    )
    if not analytics_decl:
        raise ParseError("AnalyticsPayloadSanitizer.sensitiveKeyFragments is no longer exactly the shared base list; update this checker")
    if "explicitlySafe" in analytics_sanitizer:
        raise ParseError("AnalyticsPayloadSanitizer grew an explicit-safe list; update this checker to mirror it")

    if not re.search(r"key\.lowercased\(\)", core) or not re.search(r"normalized\.contains\(\$0\)", core):
        raise ParseError("PayloadSanitizationCore.shouldDrop no longer lowercases + substring-matches; update this checker")

    return Rules(base_fragments=base, sentry_extra_fragments=extra, sentry_safe_keys=safe)


def parse_psv_properties(text: str) -> list[str]:
    props: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "|" not in line:
            continue
        name, rest = line.split("|", 1)
        if not name.strip():
            continue
        props.extend(p.strip() for p in rest.split(",") if p.strip())
    return props


def parse_reviewed(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]


@dataclass
class KeySource:
    destination: str  # "analytics" or "sentry"
    origin: str
    keys: list[str] = field(default_factory=list)


def collect_sources(read) -> tuple[Rules, list[KeySource]]:
    core = read(CORE_SWIFT)
    sentry_sanitizer = read(SENTRY_SANITIZER_SWIFT)
    analytics_sanitizer = read(ANALYTICS_SANITIZER_SWIFT)
    sentry_policy = read(SENTRY_POLICY_SWIFT)
    rules = parse_rules(core, sentry_sanitizer, analytics_sanitizer)

    common = string_list(bracket_body(core, r"static\s+let\s+commonTelemetryKeys\s*:\s*Set<String>\s*=", "commonTelemetryKeys"))
    diagnostic = string_list(bracket_body(sentry_policy, r"static\s+let\s+allowedDiagnosticTagKeys\s*:\s*Set<String>\s*=", "allowedDiagnosticTagKeys"))
    if len(diagnostic) < 10:
        raise ParseError(f"allowedDiagnosticTagKeys parsed only {len(diagnostic)} keys")
    derived = sorted(set(re.findall(r'\btags\["([A-Za-z0-9_]+)"\]\s*=', sentry_policy)))
    crash_runtime = string_list(bracket_body(sentry_sanitizer, r"static\s+let\s+crashRuntimeTagKeys\s*:\s*Set<String>\s*=", "crashRuntimeTagKeys"))

    events = parse_psv_properties(read(ANALYTICS_EVENTS_PSV))
    reviewed = parse_reviewed(read(ANALYTICS_REVIEWED_PSV))
    if not events:
        raise ParseError(f"{ANALYTICS_EVENTS_PSV} parsed no properties")

    sources = [
        KeySource("analytics", ANALYTICS_EVENTS_PSV, events),
        KeySource("analytics", ANALYTICS_REVIEWED_PSV, reviewed),
        KeySource("analytics", f"{CORE_SWIFT} commonTelemetryKeys", common),
        KeySource("sentry", f"{SENTRY_POLICY_SWIFT} allowedDiagnosticTagKeys", diagnostic),
        KeySource("sentry", f"{SENTRY_POLICY_SWIFT} derived tags[...] keys", derived),
        KeySource("sentry", f"{CORE_SWIFT} commonTelemetryKeys", common),
        KeySource("sentry", f"{SENTRY_SANITIZER_SWIFT} crashRuntimeTagKeys", crash_runtime),
    ]
    return rules, sources


def literal_sanitize_tags_keys(root: Path) -> list[KeySource]:
    out: list[KeySource] = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in re.finditer(r"SentryPayloadSanitizer\.sanitizeTags\(\s*\[", text):
            try:
                body = bracket_body(text[match.start():], r"sanitizeTags\(", "sanitizeTags literal")
            except ParseError:
                continue
            keys = dict_literal_keys(body)
            if keys:
                line = text.count("\n", 0, match.start()) + 1
                out.append(KeySource("sentry", f"{path.relative_to(root)}:{line} sanitizeTags literal", keys))
    return out


def find_violations(rules: Rules, sources: list[KeySource]) -> list[str]:
    problems: list[str] = []
    for source in sources:
        for key in source.keys:
            hits = analytics_should_drop(rules, key) if source.destination == "analytics" else sentry_should_drop(rules, key)
            if hits:
                hint = (
                    "rename the key, or add it to SentryPayloadSanitizer.explicitlySafeKeys if it is genuinely categorical"
                    if source.destination == "sentry"
                    else "rename the key (analytics has no explicit-safe escape hatch)"
                )
                problems.append(
                    f"{source.destination}: '{key}' from {source.origin} contains sensitive fragment(s) "
                    f"{', '.join(repr(h) for h in hits)} and would be silently dropped; {hint}"
                )
    return problems


def run(root: Path) -> int:
    def read(rel: str) -> str:
        return (root / rel).read_text(encoding="utf-8")

    try:
        rules, sources = collect_sources(read)
    except (ParseError, OSError) as error:
        print(f"check-telemetry-keys: parse error: {error}", file=sys.stderr)
        return 2
    sources += literal_sanitize_tags_keys(root)
    problems = find_violations(rules, sources)
    counts = {"analytics": set(), "sentry": set()}
    for source in sources:
        counts[source.destination].update(source.keys)
    print(
        f"check-telemetry-keys: {len(rules.base_fragments)} base fragments, "
        f"{len(rules.sentry_extra_fragments)} Sentry-only fragments, {len(rules.sentry_safe_keys)} Sentry explicit-safe keys; "
        f"checked {len(counts['analytics'])} analytics keys and {len(counts['sentry'])} Sentry keys"
    )
    if problems:
        print(f"FAIL: {len(problems)} allowlisted key(s) would be dropped by the sanitizer:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("PASS: every allowlisted telemetry key survives its sanitizer.")
    return 0


# --------------------------------------------------------------------------- self-test

SELF_TEST_CORE = '''
enum PayloadSanitizationCore {
    static let commonTelemetryKeys: Set<String> = [
        "session_id", "app_version", // trailing comment "not_a_key"
    ]
    static let baseSensitiveKeyFragments: [String] = [
        "file",
        "name",
        "path",
    ]
    static func shouldDrop(key: String, sensitiveFragments: [String]) -> Bool {
        let normalized = key.lowercased()
        return sensitiveFragments.contains(where: { normalized.contains($0) })
    }
}
'''

SELF_TEST_SENTRY_SANITIZER = '''
enum SentryPayloadSanitizer {
    private static let crashRuntimeTagKeys: Set<String> = [
        "build_channel",
    ]
    private static let explicitlySafeKeys: Set<String> = [
        "mic_file_available",
    ]
    private static let sensitiveKeyFragments = PayloadSanitizationCore.baseSensitiveKeyFragments + [
        "context",
    ]
    private static func shouldDrop(key: String) -> Bool {
        if explicitlySafeKeys.contains(key) {
            return false
        }
        return PayloadSanitizationCore.shouldDrop(key: key, sensitiveFragments: sensitiveKeyFragments)
    }
}
'''

SELF_TEST_ANALYTICS_SANITIZER = '''
enum AnalyticsPayloadSanitizer {
    private static let sensitiveKeyFragments = PayloadSanitizationCore.baseSensitiveKeyFragments
}
'''


def self_test_policy(keys: list[str], derived: tuple[str, ...] | list[str] = ()) -> str:
    lines = "\n".join(f'        "{k}",' for k in keys)
    derived_lines = "\n".join(f'        tags["{k}"] = "x"' for k in derived)
    return f'''
struct SentryEventPolicy {{
    static func diagnosticTags() {{
{derived_lines}
    }}
    private static let allowedDiagnosticTagKeys: Set<String> = [
{lines}
    ]
}}
'''


GOOD_POLICY_KEYS = [f"good_key_{i}" for i in range(10)] + ["mic_file_available"]


def self_test() -> int:
    failures: list[str] = []

    def check(files: dict[str, str], expect_keys: list[str], label: str) -> None:
        try:
            rules, sources = collect_sources(lambda rel: files[rel])
        except ParseError as error:
            failures.append(f"{label}: unexpected parse error {error}")
            return
        problems = find_violations(rules, sources)
        found = sorted({re.search(r"'([^']+)'", p).group(1) for p in problems})
        if found != sorted(expect_keys):
            failures.append(f"{label}: expected violations {sorted(expect_keys)}, got {found}: {problems}")

    base_files = {
        CORE_SWIFT: SELF_TEST_CORE,
        SENTRY_SANITIZER_SWIFT: SELF_TEST_SENTRY_SANITIZER,
        ANALYTICS_SANITIZER_SWIFT: SELF_TEST_ANALYTICS_SANITIZER,
        SENTRY_POLICY_SWIFT: self_test_policy(GOOD_POLICY_KEYS, ["wait_bucket"]),
        ANALYTICS_EVENTS_PSV: "# comment with file_path\nev_a|duration_bucket,result\nev_b|\n",
        ANALYTICS_REVIEWED_PSV: "# header\nresult\n",
    }
    check(base_files, [], "clean tree")

    # Sentry: explicit-safe keeps an exact match only (case-sensitive), fragments are substring + lowercased.
    files = dict(base_files)
    files[SENTRY_POLICY_SWIFT] = self_test_policy(
        GOOD_POLICY_KEYS + ["start_profile", "Mic_File_Available", "call_context_kind", "Display_NAME"],
        ["pending_path_bucket"],
    )
    check(files, ["start_profile", "Mic_File_Available", "call_context_kind", "Display_NAME", "pending_path_bucket"], "sentry drops")

    # Analytics: base fragments only (Sentry-only 'context' is fine), no explicit-safe list.
    files = dict(base_files)
    files[ANALYTICS_EVENTS_PSV] = "ev|context_kind,mic_file_available,profile_bucket\n"
    files[ANALYTICS_REVIEWED_PSV] = "Source_Filename\n"
    check(files, ["mic_file_available", "profile_bucket", "Source_Filename"], "analytics drops")

    # commonTelemetryKeys flows to both destinations.
    files = dict(base_files)
    files[CORE_SWIFT] = SELF_TEST_CORE.replace('"app_version",', '"app_version", "device_name",')
    check(files, ["device_name"], "common keys")

    # Structural drift must be a parse error, never a silent pass.
    files = dict(base_files)
    files[ANALYTICS_SANITIZER_SWIFT] = SELF_TEST_ANALYTICS_SANITIZER.replace(
        "baseSensitiveKeyFragments", "baseSensitiveKeyFragments + [\"x\"]"
    )
    try:
        collect_sources(lambda rel: files[rel])
        failures.append("analytics drift: expected a parse error")
    except ParseError:
        pass

    # Dictionary-literal key extraction for sanitizeTags([...]) call sites.
    keys = dict_literal_keys('\n  "unrecognized_selector": parsed.selector,\n  "selector_file": x["ignored"],\n')
    if keys != ["unrecognized_selector", "selector_file"]:
        failures.append(f"dict_literal_keys: got {keys}")

    if failures:
        print("check-telemetry-keys self-test FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("check-telemetry-keys self-test passed.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--self-test", action="store_true", help="run inline fixture tests and exit")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="repo root (default: this checkout)")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    return run(args.root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
