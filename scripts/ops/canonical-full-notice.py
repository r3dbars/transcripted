#!/usr/bin/env python3
"""Private frozen-cut diagnostics: emit only a bounded canonical summary notice."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path

TITLE = "Transcripted canonical full v1"
MAX_TAIL_BYTES = 65536
MAX_PAYLOAD_BYTES = 4096
CHECK_SCRIPT_SHA256 = "383ee23c7bf01ab02730654d5fa3ba350797a329a402fefea43e735329d65fce"
STEPS = (
    ('build_sources', 'Build-source list contracts'),
    ('test_shape', 'Test shape guard'),
    ('sync_selftest', 'Synced copies (self-test)'),
    ('sync', 'Synced copies'),
    ('archives', 'Dependency archive input guards'),
    ('cli_manifest', 'CLI manifest mode guards'),
    ('cli_packaging', 'CLI packaging capability guards'),
    ('fast', 'Fast tests'),
    ('e2e', 'E2E smoke'),
    ('deps', 'Build dependencies'),
    ('census', "Concurrency census (Swift 6 backlog can't grow)"),
    ('core', 'Core package tests'),
    ('integration', 'Integration smoke'),
    ('speaker_model', 'Speaker settings model smoke'),
    ('speaker_scroll', 'Speakers directory scroll smoke'),
    ('capturekit', 'Tools: CaptureKit'),
    ('cli', 'Tools: CLI'),
    ('mcp', 'Tools: MCP'),
    ('qa', 'Tools: QA'),
    ('live', 'Tools: Live'),
    ('cli_audio', 'CLI mode: audio'),
    ('cli_meeting', 'CLI mode: meeting'),
    ('cli_retrieval', 'CLI mode: retrieval'),
    ('receipt_reset', 'Invalidate previous launch receipt'),
    ('app', 'Build app'),
    ('performance', 'Premium performance budget'),
)
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
ROW = re.compile(r"(PASS|FAIL|SKIP) +([0-9]{1,9}s|-)  (.+)\Z")
ERRORS = {"identity", "script_identity", "exit_code", "summary_missing", "rows", "order", "timing", "flow", "result", "input_unavailable", "payload", "helper_failed"}


def incomplete(error: str, source: str = "", workflow: str = "", exit_code: int | None = None) -> dict:
    assert error in ERRORS
    return {"schema": 1, "complete": False, "error": error,
            "source_sha": source if HEX40.fullmatch(source) else None,
            "workflow_sha": workflow if HEX40.fullmatch(workflow) else None,
            "canonical_exit": exit_code if type(exit_code) is int and 0 <= exit_code <= 255 else None,
            "checks": []}


def parse_summary(text: str, *, source: str, checkout: str, workflow: str,
                  exit_code: int, script_sha256: str) -> dict:
    def fail(code: str) -> dict:
        return incomplete(code, source, workflow, exit_code)
    if not (HEX40.fullmatch(source) and source == checkout and HEX40.fullmatch(workflow)):
        return fail("identity")
    if script_sha256 != CHECK_SCRIPT_SHA256:
        return fail("script_identity")
    if type(exit_code) is not int or not 0 <= exit_code <= 255:
        return fail("exit_code")
    lines = text.splitlines()
    headers = [i for i, line in enumerate(lines) if line == "---- check.sh full ----"]
    if not headers:
        return fail("summary_missing")
    index = headers[-1] + 1
    rows = []
    while index < len(lines) and lines[index]:
        match = ROW.fullmatch(lines[index])
        if not match:
            return fail("rows")
        status, timing, label = match.groups()
        if len(rows) >= len(STEPS) or label != STEPS[len(rows)][1]:
            return fail("order")
        if (status == "SKIP") != (timing == "-"):
            return fail("timing")
        rows.append({"id": STEPS[len(rows)][0], "status": status,
                     "seconds": None if timing == "-" else int(timing[:-1])})
        index += 1
    # Receipt reset is mandatory. The script deliberately omits dependent rows
    # when reset wasn't PASS; absence is not an invented SKIP.
    if len(rows) < 24 or len(rows) != (26 if rows[23]["status"] == "PASS" else 24):
        return fail("rows")
    failed = False
    for row in rows:
        if failed and row["status"] != "SKIP":
            return fail("flow")
        if not failed and row["status"] == "SKIP":
            return fail("flow")
        if row["status"] == "FAIL":
            failed = True
    tail = [line for line in lines[index:] if line]
    expected = "RESULT: FAIL" if failed else "RESULT: PASS"
    if not tail or tail[-1] != expected or failed != (exit_code != 0):
        return fail("result")
    if (not failed and tail != [expected]) or (failed and tail[0] != "Re-run a failed step on its own:"):
        return fail("result")
    return {"schema": 1, "complete": True, "source_sha": source,
            "workflow_sha": workflow, "check_script_sha256": script_sha256,
            "canonical_exit": exit_code, "checks": rows}


def payload_is_safe(payload: dict) -> bool:
    if (type(payload) is not dict or type(payload.get("schema")) is not int
            or payload.get("schema") != 1 or type(payload.get("complete")) is not bool):
        return False
    identity = {"schema", "complete", "source_sha", "workflow_sha", "canonical_exit", "checks"}
    for key in ("source_sha", "workflow_sha"):
        value = payload.get(key)
        if value is not None and (type(value) is not str or not HEX40.fullmatch(value)):
            return False
    code = payload.get("canonical_exit")
    if code is not None and (type(code) is not int or not 0 <= code <= 255):
        return False
    if not payload["complete"]:
        return (set(payload) == identity | {"error"} and type(payload.get("error")) is str
                and payload.get("error") in ERRORS
                and payload.get("checks") == [])
    if (set(payload) != identity | {"check_script_sha256"}
            or payload.get("check_script_sha256") != CHECK_SCRIPT_SHA256
            or payload.get("source_sha") is None or payload.get("workflow_sha") is None
            or code is None or type(payload.get("checks")) is not list):
        return False
    rows = payload["checks"]
    if len(rows) not in (24, 26):
        return False
    failed = False
    for index, row in enumerate(rows):
        if type(row) is not dict or set(row) != {"id", "status", "seconds"} or row["id"] != STEPS[index][0]:
            return False
        status, seconds = row["status"], row["seconds"]
        if type(status) is not str or status not in {"PASS", "FAIL", "SKIP"}:
            return False
        if status == "SKIP":
            if not failed or seconds is not None:
                return False
        else:
            if failed or type(seconds) is not int or not 0 <= seconds <= 999999999:
                return False
        failed = failed or status == "FAIL"
    return len(rows) == (26 if rows[23]["status"] == "PASS" else 24) and failed == (code != 0)


def annotation(payload: dict) -> str:
    if not payload_is_safe(payload):
        payload = incomplete("payload")
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    if len(encoded.encode("utf-8")) > MAX_PAYLOAD_BYTES:
        encoded = json.dumps(incomplete("payload"), separators=(",", ":"))
    escaped = encoded.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return "::notice title=" + TITLE + "::" + escaped


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--check-script", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--checkout", required=True)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--exit-code", required=True)
    args = parser.parse_args()
    try:
        code = int(args.exit_code) if re.fullmatch(r"[0-9]{1,3}", args.exit_code) else -1
        with Path(args.log).open("rb") as handle:
            handle.seek(0, 2)
            offset = max(0, handle.tell() - MAX_TAIL_BYTES)
            handle.seek(offset)
            raw = handle.read(MAX_TAIL_BYTES)
            if offset:  # Discard a partial first line/UTF-8 character.
                raw = raw.partition(b"\n")[2]
            tail = raw.decode("utf-8", errors="strict")
        with Path(args.check_script).open("rb") as handle:
            check_bytes = handle.read(MAX_TAIL_BYTES + 1)
        digest = hashlib.sha256(check_bytes).hexdigest()
        payload = parse_summary(tail, source=args.source, checkout=args.checkout,
                                workflow=args.workflow, exit_code=code, script_sha256=digest)
    except (OSError, UnicodeError, ValueError):
        payload = incomplete("input_unavailable")
    print(annotation(payload))
    return 0  # Diagnostics never replace the real canonical result.


if __name__ == "__main__":
    raise SystemExit(main())
