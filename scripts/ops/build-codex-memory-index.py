#!/usr/bin/env python3
"""Build a safe metadata index from local Codex session archives.

Goals:
- transcripted-first filtering
- metadata-only output (no raw prompts/chat dumps)
- secret/token/email/path redaction
- rollups by date/cwd/repo/project
- CEO-ready digest: shipped, broke, repeated patterns, unfinished, next moves
- optional local MLX summarization for intent labels
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

TRANSCRIPTED_KEYWORDS = (
    "transcripted",
    "r3dbars/transcripted",
    "transcripted.app",
)

CODE_FILE_EXTENSIONS = {
    ".swift",
    ".md",
    ".txt",
    ".sh",
    ".py",
    ".json",
    ".yml",
    ".yaml",
    ".plist",
    ".toml",
    ".rb",
    ".js",
    ".ts",
    ".tsx",
    ".jsx",
    ".go",
    ".rs",
    ".c",
    ".h",
    ".cpp",
    ".m",
    ".mm",
}

URL_RE = re.compile(r"https?://[^\s\]\)\"'>]+")
PR_RE = re.compile(r"https?://github\.com/[^\s/]+/[^\s/]+/pull/[^\s\]\)\"'>]+")
ISSUE_RE = re.compile(r"https?://github\.com/[^\s/]+/[^\s/]+/issues/[^\s\]\)\"'>]+")
RELEASE_RE = re.compile(r"https?://github\.com/[^\s/]+/[^\s/]+/releases/[^\s\]\)\"'>]+")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
AWS_KEY_RE = re.compile(r"\bAKIA[0-9A-Z]{16}\b")
PATH_USER_RE = re.compile(r"/Users/[^/]+")
TOKEN_PATTERNS = [
    re.compile(r"\bsk-[A-Za-z0-9_-]{10,}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{30,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    re.compile(r"\bBearer\s+[A-Za-z0-9._=-]{10,}\b", re.IGNORECASE),
]

MAX_SNIPPETS_PER_SESSION = 6
MAX_SNIPPET_CHARS = 360

THEME_RULES: list[tuple[str, tuple[str, ...]]] = [
    ("release-packaging", ("build-beta.sh", "sparkle", "appcast", "release", "cask", "notariz")),
    ("meeting-pipeline", ("meeting", "diariz", "speaker", "transcriptedcore", "capture")),
    ("dictation-flow", ("dictation", "paste", "overlay")),
    ("observability", ("sentry", "analytics", "event", "crashreport")),
    ("tests-verification", ("run-tests", "swift test", "integration-smoke", "xctest", "failing test")),
    ("docs-policy", ("agents.md", "readme", "docs/", "contributing")),
    ("ops-tooling", ("script", "ops/", "health-probe", "automation")),
]

FOLLOWUP_EXCLUDE_TERMS = (
    "paperclip setup",
    "companies, roles, agents",
    "create a custom api token",
    "create a personal api key",
    "strategy translation",
    "**coding work**",
    "coding work",
    "codex does:",
    "codex does",
    "create a prioritized backlog",
    "what did i promise to follow up on",
)

FOLLOWUP_INCLUDE_TERMS = (
    "transcripted",
    "meeting",
    "dictation",
    "sentry",
    "sparkle",
    "appcast",
    "cask",
    "build",
    "test",
    "release",
    "run-tests",
    "swift test",
    "sources/",
    "tests/",
    "docs/",
    "fix",
    "implement",
    "verify",
    "merge",
    "pr",
    "issue",
)

TASK_SEED_VERBS = ("fix", "implement", "verify", "add", "update", "run", "create", "release", "harden", "merge")
TASK_SEED_EXCLUDE = (
    "if the main agent",
    "if you add",
    "update local transcripted checkout",
    "commented the full live snapshot",
    "created a new high-priority follow-up issue",
    "run the safe transcripted memory indexing",
    "add `project:releases`",
)


def parse_iso_datetime(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


@dataclass
class SessionAccumulator:
    source_file: Path
    source_kind: str
    session_id: str | None = None
    started_at: str | None = None
    cwd: str | None = None
    repo_url: str | None = None
    commit_hash: str | None = None
    branch: str | None = None
    models: set[str] = field(default_factory=set)
    command_categories: Counter[str] = field(default_factory=Counter)
    tool_categories: Counter[str] = field(default_factory=Counter)
    git_ops: Counter[str] = field(default_factory=Counter)
    files_touched: set[str] = field(default_factory=set)
    pull_links: set[str] = field(default_factory=set)
    issue_links: set[str] = field(default_factory=set)
    release_links: set[str] = field(default_factory=set)
    follow_ups: set[str] = field(default_factory=set)
    user_snippets: list[str] = field(default_factory=list)
    had_errors: bool = False
    completed: bool = False
    total_lines: int = 0
    total_tool_calls: int = 0
    total_exec_commands: int = 0
    inferred_project: str = "unknown"
    inferred_repo: str = "unknown"
    inferred_cwd_hint: str = "unknown"
    date: str = "unknown"
    intent_summary: str = "No safe summary available."
    themes: list[str] = field(default_factory=list)

    def session_key(self) -> str:
        if self.session_id:
            return self.session_id
        return self.source_file.stem

    def infer_metadata(self) -> None:
        self.inferred_cwd_hint = cwd_hint(self.cwd)
        self.inferred_repo = infer_repo_name(self.repo_url, self.cwd)
        self.inferred_project = infer_project(self)
        self.date = infer_date(self.started_at)
        self.themes = infer_themes(self)

    def to_index_entry(self) -> dict[str, Any]:
        outcome = infer_outcome(self)
        return {
            "session_id": self.session_key(),
            "date": self.date,
            "started_at": self.started_at or "unknown",
            "project": self.inferred_project,
            "repo": self.inferred_repo,
            "cwd_hint": self.inferred_cwd_hint,
            "repo_url": self.repo_url,
            "branch": self.branch,
            "commit_hash": self.commit_hash,
            "intent_summary": self.intent_summary,
            "themes": self.themes,
            "models": sorted(self.models),
            "command_categories": dict(self.command_categories.most_common()),
            "tool_categories": dict(self.tool_categories.most_common()),
            "git_ops": dict(self.git_ops.most_common()),
            "files_changed": sorted(self.files_touched),
            "links": {
                "pulls": sorted(self.pull_links),
                "issues": sorted(self.issue_links),
                "releases": sorted(self.release_links),
            },
            "outcome": outcome,
            "follow_up_tasks": sorted(self.follow_ups),
            "stats": {
                "line_count": self.total_lines,
                "tool_calls": self.total_tool_calls,
                "exec_commands": self.total_exec_commands,
                "had_errors": self.had_errors,
                "completed": self.completed,
            },
        }


class MlxSummarizer:
    def __init__(
        self,
        enabled: bool,
        endpoint: str,
        model: str,
        timeout_seconds: float,
        max_sessions: int,
        verbose: bool,
    ):
        self.enabled = enabled
        self.endpoint = endpoint.rstrip("/")
        self.model = model
        self.timeout_seconds = timeout_seconds
        self.max_sessions = max_sessions
        self.verbose = verbose
        self._used = 0
        self._failures = 0
        self._cache: dict[str, str] = {}

    def summarize(self, session: SessionAccumulator) -> str | None:
        if not self.enabled:
            return None
        if self.max_sessions >= 0 and self._used >= self.max_sessions:
            return None
        if not session.user_snippets:
            return None

        compact = {
            "repo": session.inferred_repo,
            "project": session.inferred_project,
            "cwd_hint": session.inferred_cwd_hint,
            "user_snippets": session.user_snippets[:4],
            "themes": session.themes[:4],
            "top_command_categories": [k for k, _ in session.command_categories.most_common(4)],
            "top_files": sorted(session.files_touched)[:8],
        }
        compact_json = json.dumps(compact, ensure_ascii=True, separators=(",", ":"))
        cache_key = hashlib.sha256(compact_json.encode("utf-8")).hexdigest()
        if cache_key in self._cache:
            return self._cache[cache_key]

        body = {
            "model": self.model,
            "temperature": 0.1,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "Summarize engineering intent in <=16 words. "
                        "Do not quote raw chat. No secrets, names, emails, or absolute paths."
                    ),
                },
                {"role": "user", "content": compact_json},
            ],
        }
        request = urllib.request.Request(
            f"{self.endpoint}/chat/completions",
            method="POST",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )

        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            if self.verbose:
                print(f"[mlx] summarize failed: {exc}", file=sys.stderr)
            self._failures += 1
            if self._failures >= 3:
                self.enabled = False
                if self.verbose:
                    print("[mlx] disabled after repeated failures; using heuristic summaries", file=sys.stderr)
            return None

        text = (
            payload.get("choices", [{}])[0]
            .get("message", {})
            .get("content", "")
            .strip()
        )
        text = sanitize_text(text)
        text = text.replace("\n", " ").strip(" \"'")
        if not text:
            return None

        text = " ".join(text.split())
        if len(text) > 180:
            text = text[:177].rstrip() + "..."

        self._used += 1
        self._cache[cache_key] = text
        return text


def sanitize_text(value: str) -> str:
    text = value
    text = text.replace(str(Path.home()), "~")
    text = PATH_USER_RE.sub("~", text)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?", text):
        text = EMAIL_RE.sub("[redacted-email]", text)
    text = AWS_KEY_RE.sub("[redacted-secret]", text)
    for pattern in TOKEN_PATTERNS:
        text = pattern.sub("[redacted-secret]", text)
    return text.strip()


def cwd_hint(cwd: str | None) -> str:
    if not cwd:
        return "unknown"
    raw = sanitize_text(cwd)
    try:
        p = Path(raw)
        parts = list(p.parts)
        if len(parts) <= 4:
            return raw
        if parts[0] == "/" and parts[1] == "Users":
            tail = "/".join(parts[-4:])
            return f"~/{tail}"
        tail = "/".join(parts[-4:])
        return f".../{tail}"
    except Exception:
        return raw


def infer_repo_name(repo_url: str | None, cwd: str | None) -> str:
    if repo_url:
        cleaned = sanitize_text(repo_url)
        m = re.search(r"github\.com[:/]+([^/]+)/([^/.]+)", cleaned)
        if m:
            return f"{m.group(1)}/{m.group(2)}".lower()
        return cleaned
    if cwd:
        lower = cwd.lower()
        if "transcripted" in lower:
            return "r3dbars/transcripted"
        return Path(cwd).name.lower()
    return "unknown"


def infer_project(session: SessionAccumulator) -> str:
    corpus = "\n".join(
        [
            session.cwd or "",
            session.repo_url or "",
            session.source_file.name,
            " ".join(session.files_touched),
            " ".join(session.pull_links),
            " ".join(session.issue_links),
            " ".join(session.release_links),
        ]
    ).lower()
    if any(keyword in corpus for keyword in TRANSCRIPTED_KEYWORDS):
        return "transcripted"
    return "other"


def infer_date(started_at: str | None) -> str:
    parsed = parse_iso_datetime(started_at)
    if parsed:
        return parsed.date().isoformat()
    if started_at:
        return started_at[:10] if len(started_at) >= 10 else "unknown"
    return "unknown"


def command_category(command: str) -> str:
    base = Path(command.strip().split()[0] if command.strip() else "").name.lower()
    if base in {"git", "gh"}:
        return "git"
    if base in {"rg", "grep", "find", "ls", "fd"}:
        return "search"
    if base in {"sed", "awk", "cat", "head", "tail", "jq"}:
        return "read"
    if base in {"swift", "xcodebuild", "make", "cmake"}:
        return "build"
    if base in {"bash", "zsh", "sh"}:
        return "script"
    if base in {"python", "python3", "node", "ruby", "perl"}:
        return "automation"
    if base in {"cp", "mv", "rm", "touch", "mkdir", "chmod", "chown"}:
        return "filesystem"
    if base == "curl":
        return "network"
    if not base:
        return "unknown"
    return base


def extract_git_ops(command: str) -> list[str]:
    tokens = command.strip().split()
    if not tokens:
        return []
    base = Path(tokens[0]).name.lower()
    if base == "git":
        if len(tokens) >= 2:
            sub = tokens[1].lower()
            if sub in {"commit", "push", "merge", "rebase", "switch", "checkout", "add"}:
                return [sub]
            if sub == "tag":
                return ["release"]
    if base == "gh":
        joined = " ".join(tokens[1:]).lower()
        ops: list[str] = []
        if "pr create" in joined:
            ops.append("pr_create")
        if "pr merge" in joined:
            ops.append("pr_merge")
        if "release create" in joined:
            ops.append("release")
        if "issue create" in joined:
            ops.append("issue_create")
        return ops
    return []


def extract_paths_from_text(text: str) -> set[str]:
    candidates: set[str] = set()
    for token in re.split(r"\s+", text):
        cleaned = token.strip("\"'`,;()[]{}")
        if not cleaned:
            continue
        if cleaned.startswith(("http://", "https://", "-")):
            continue
        if cleaned.startswith(("{", "[")) or "\"cmd\"" in cleaned:
            continue
        if "//" in cleaned:
            continue
        if cleaned.startswith("/"):
            cleaned = sanitize_text(cleaned)
        if cleaned.startswith("./"):
            cleaned = cleaned[2:]
        if any(ch in cleaned for ch in "{}$|><!"):
            continue
        if ":" in cleaned and not cleaned.startswith("HEAD:") and not re.search(r"\.swift:\d+$", cleaned):
            continue
        p = Path(cleaned)
        suffix = p.suffix.lower()
        top_level_hint = ("Sources/", "Tests/", "docs/", "scripts/", "Tools/", "archive/", "config/", "Resources/", "Casks/")
        looks_like_file = (
            suffix in CODE_FILE_EXTENSIONS
            or cleaned.endswith("Package.swift")
            or cleaned.endswith("Info.plist")
            or cleaned.startswith(top_level_hint)
        )
        if not looks_like_file:
            continue
        if len(cleaned) > 240:
            continue
        if cleaned.startswith("~"):
            parts = cleaned.split("/")
            cleaned = "/".join(parts[-4:]) if len(parts) > 4 else cleaned
        candidates.add(cleaned)
    return candidates


def extract_follow_ups(text: str) -> set[str]:
    follow_ups: set[str] = set()
    for raw_line in text.splitlines():
        line = sanitize_text(raw_line)
        if not line:
            continue
        if not (re.match(r"^\d+\.\s+", line) or line.startswith("- ")):
            continue
        lower = line.lower()
        if any(
            kw in lower
            for kw in (
                "next",
                "follow",
                "run ",
                "add ",
                "update ",
                "verify ",
                "publish ",
                "merge ",
                "fix ",
                "implement ",
                "create ",
            )
        ):
            normalized = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)
            normalized = re.sub(r"^\s*(?:-\s+|\d+\.\s+)", "", normalized).strip()
            lowered = normalized.lower()
            if any(term in lowered for term in FOLLOWUP_EXCLUDE_TERMS):
                continue
            if not any(term in lowered for term in FOLLOWUP_INCLUDE_TERMS):
                continue
            follow_ups.add(normalized[:400])
    return follow_ups


def extract_links(text: str) -> tuple[set[str], set[str], set[str]]:
    pulls: set[str] = set()
    issues: set[str] = set()
    releases: set[str] = set()
    for url in URL_RE.findall(text):
        clean = sanitize_text(url)
        if PR_RE.match(clean):
            pulls.add(clean)
        if ISSUE_RE.match(clean):
            issues.add(clean)
        if RELEASE_RE.match(clean):
            releases.add(clean)
    return pulls, issues, releases


def infer_themes(session: SessionAccumulator) -> list[str]:
    source = " ".join(
        [
            " ".join(session.command_categories.keys()),
            " ".join(session.tool_categories.keys()),
            " ".join(session.files_touched),
            " ".join(session.user_snippets),
            session.inferred_repo,
        ]
    ).lower()
    themes: list[str] = []
    for theme, needles in THEME_RULES:
        if any(needle in source for needle in needles):
            themes.append(theme)
    if not themes:
        themes.append("general-dev")
    return themes


def infer_outcome(session: SessionAccumulator) -> str:
    shipped = bool(
        session.pull_links
        or session.release_links
        or session.git_ops.get("commit", 0)
        or session.git_ops.get("push", 0)
        or session.git_ops.get("pr_create", 0)
    )
    if shipped and session.had_errors:
        return "shipped_with_issues"
    if shipped:
        return "shipped"
    if session.completed and session.had_errors:
        return "completed_with_errors"
    if session.completed:
        return "completed"
    if session.had_errors:
        return "partial_or_failed"
    if session.follow_ups:
        return "unfinished_followups"
    return "in_progress_or_unknown"


def heuristic_intent_summary(session: SessionAccumulator) -> str:
    topics = []
    for theme in session.themes:
        if theme == "release-packaging":
            topics.append("release/update flow")
        elif theme == "meeting-pipeline":
            topics.append("meeting capture/transcription")
        elif theme == "dictation-flow":
            topics.append("dictation UX")
        elif theme == "observability":
            topics.append("observability and crash/event reporting")
        elif theme == "tests-verification":
            topics.append("build/test reliability")
        elif theme == "docs-policy":
            topics.append("docs and repo policy")
        elif theme == "ops-tooling":
            topics.append("ops/tooling automation")
        elif theme == "general-dev":
            topics.append("general engineering work")

    ordered_topics = list(dict.fromkeys(topics))
    primary = [t for t in ordered_topics if t not in {"docs and repo policy", "ops/tooling automation"}]
    if primary:
        topic_pool = primary[:3]
    else:
        topic_pool = ordered_topics[:2] if ordered_topics else ["general engineering work"]
    topic_text = ", ".join(topic_pool)
    mode = [k for k, _ in session.command_categories.most_common(2)]
    mode_text = ", ".join(mode) if mode else "mixed commands"

    if session.user_snippets:
        first = session.user_snippets[0]
        short = " ".join(first.split()[:10]).strip()
        if short:
            return sanitize_text(f"{topic_text}; intent from user request: {short}. Mode: {mode_text}.")

    return sanitize_text(f"{topic_text}; mode: {mode_text}.")


def safe_branch_for_cwd(cwd: str | None, cache: dict[str, str | None]) -> str | None:
    if not cwd:
        return None
    key = str(cwd)
    if key in cache:
        return cache[key]

    raw_path = str(cwd).replace("~", str(Path.home()))
    path = Path(raw_path)
    if not path.exists() or not path.is_dir():
        cache[key] = None
        return None

    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=0.8,
            check=False,
        )
    except Exception:
        cache[key] = None
        return None

    if result.returncode == 0:
        branch = sanitize_text(result.stdout.strip())
        cache[key] = branch or None
    else:
        cache[key] = None
    return cache[key]


def session_is_transcripted(session: SessionAccumulator) -> bool:
    corpus = "\n".join(
        [
            (session.cwd or ""),
            (session.repo_url or ""),
            session.source_file.name,
            " ".join(session.files_touched),
            " ".join(session.pull_links),
            " ".join(session.issue_links),
            " ".join(session.release_links),
        ]
    ).lower()
    return any(keyword in corpus for keyword in TRANSCRIPTED_KEYWORDS)


def find_session_files(archived_dir: Path, sessions_dir: Path, limit: int | None) -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    if archived_dir.exists():
        files.extend((path, "archived") for path in sorted(archived_dir.glob("*.jsonl")))
    if sessions_dir.exists():
        files.extend((path, "sessions") for path in sorted(sessions_dir.rglob("*.jsonl")))
    files.sort(key=lambda item: item[0].stat().st_mtime if item[0].exists() else 0, reverse=True)
    if limit is not None and limit > 0:
        files = files[:limit]
    return files


def extract_text_blocks(content: Any) -> list[str]:
    out: list[str] = []
    if not isinstance(content, list):
        return out
    for block in content:
        if not isinstance(block, dict):
            continue
        text = block.get("text")
        if isinstance(text, str) and text.strip():
            out.append(text.strip())
        input_text = block.get("input_text")
        if isinstance(input_text, str) and input_text.strip():
            out.append(input_text.strip())
    return out


def maybe_add_user_snippet(session: SessionAccumulator, raw: str) -> None:
    if len(session.user_snippets) >= MAX_SNIPPETS_PER_SESSION:
        return
    text = sanitize_text(raw)
    if not text:
        return
    lower = text.lower()
    if (
        "agents.md instructions for" in lower
        or "<instructions>" in lower
        or "<environment_context>" in lower
        or "paperclip wake payload" in lower
        or "execution contract:" in lower
    ):
        return
    text = " ".join(text.split())
    if len(text) > MAX_SNIPPET_CHARS:
        text = text[: MAX_SNIPPET_CHARS - 3].rstrip() + "..."
    if text:
        session.user_snippets.append(text)


def process_session_file(path: Path, source_kind: str, branch_cache: dict[str, str | None]) -> SessionAccumulator:
    session = SessionAccumulator(source_file=path, source_kind=source_kind)

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            session.total_lines += 1
            line = line.strip()
            if not line:
                continue

            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            event_type = event.get("type")
            payload = event.get("payload") or {}

            if event_type == "session_meta":
                session.session_id = sanitize_text(str(payload.get("id") or "")) or session.session_id
                session.started_at = sanitize_text(str(payload.get("timestamp") or "")) or session.started_at
                cwd = payload.get("cwd")
                if isinstance(cwd, str) and cwd:
                    session.cwd = sanitize_text(cwd)
                git_data = payload.get("git") if isinstance(payload.get("git"), dict) else {}
                repo_url = git_data.get("repository_url")
                commit_hash = git_data.get("commit_hash")
                if isinstance(repo_url, str) and repo_url:
                    session.repo_url = sanitize_text(repo_url)
                if isinstance(commit_hash, str) and commit_hash:
                    session.commit_hash = sanitize_text(commit_hash[:16])
                model_provider = payload.get("model_provider")
                if isinstance(model_provider, str) and model_provider:
                    session.models.add(sanitize_text(model_provider))

            elif event_type == "turn_context":
                model = payload.get("model")
                if isinstance(model, str) and model:
                    session.models.add(sanitize_text(model))
                cwd = payload.get("cwd")
                if isinstance(cwd, str) and cwd and session.cwd is None:
                    session.cwd = sanitize_text(cwd)

            elif event_type == "response_item":
                item_type = payload.get("type")
                if item_type == "function_call":
                    session.total_tool_calls += 1
                    namespace = payload.get("namespace")
                    name = payload.get("name")
                    if isinstance(name, str) and name:
                        tool_name = f"{namespace}.{name}" if isinstance(namespace, str) and namespace else name
                        session.tool_categories[tool_name] += 1
                        if name == "exec_command":
                            session.total_exec_commands += 1

                    arguments = payload.get("arguments")
                    command_texts: list[str] = []
                    if isinstance(arguments, dict):
                        cmd = arguments.get("cmd")
                        if isinstance(cmd, str) and cmd:
                            command_texts.append(cmd)
                    elif isinstance(arguments, str):
                        raw_arguments = arguments.strip()
                        try:
                            parsed_args = json.loads(raw_arguments)
                            cmd = parsed_args.get("cmd")
                            if isinstance(cmd, str) and cmd:
                                command_texts.append(cmd)
                        except json.JSONDecodeError:
                            command_texts.append(raw_arguments)
                        for patch_match in re.findall(r"\*\*\* (?:Add|Update|Delete) File: ([^\n]+)", arguments):
                            session.files_touched.add(sanitize_text(patch_match.strip()))

                    for text in command_texts:
                        session.command_categories[command_category(text)] += 1
                        session.files_touched.update(extract_paths_from_text(text))
                        for op in extract_git_ops(text):
                            session.git_ops[op] += 1
                        pulls, issues, releases = extract_links(text)
                        session.pull_links.update(pulls)
                        session.issue_links.update(issues)
                        session.release_links.update(releases)

                role = payload.get("role")
                content = payload.get("content")
                if role == "user":
                    for text in extract_text_blocks(content):
                        maybe_add_user_snippet(session, text)
                if role == "assistant":
                    for text in extract_text_blocks(content):
                        pulls, issues, releases = extract_links(text)
                        session.pull_links.update(pulls)
                        session.issue_links.update(issues)
                        session.release_links.update(releases)
                        session.follow_ups.update(extract_follow_ups(text))

            elif event_type == "event_msg":
                payload_type = payload.get("type")
                if payload_type == "exec_command_end":
                    command = payload.get("command")
                    if isinstance(command, list):
                        if len(command) >= 3 and str(command[1]) == "-lc":
                            command = str(command[2])
                        else:
                            command = " ".join(str(part) for part in command)
                    if isinstance(command, str) and command:
                        session.command_categories[command_category(command)] += 1
                        session.files_touched.update(extract_paths_from_text(command))
                        for op in extract_git_ops(command):
                            session.git_ops[op] += 1
                        pulls, issues, releases = extract_links(command)
                        session.pull_links.update(pulls)
                        session.issue_links.update(issues)
                        session.release_links.update(releases)

                    parsed_cmd = payload.get("parsed_cmd")
                    if isinstance(parsed_cmd, list):
                        for part in parsed_cmd:
                            if isinstance(part, str):
                                session.command_categories[command_category(part)] += 1
                                session.files_touched.update(extract_paths_from_text(part))
                                for op in extract_git_ops(part):
                                    session.git_ops[op] += 1
                            elif isinstance(part, dict):
                                cmd = part.get("cmd")
                                path_value = part.get("path")
                                if isinstance(cmd, str):
                                    session.command_categories[command_category(cmd)] += 1
                                    session.files_touched.update(extract_paths_from_text(cmd))
                                    for op in extract_git_ops(cmd):
                                        session.git_ops[op] += 1
                                if isinstance(path_value, str):
                                    session.files_touched.update(extract_paths_from_text(path_value))

                    exit_code = payload.get("exit_code")
                    if isinstance(exit_code, int) and exit_code != 0:
                        session.had_errors = True

                elif payload_type == "task_complete":
                    session.completed = True
                    last_message = payload.get("last_agent_message")
                    if isinstance(last_message, str):
                        pulls, issues, releases = extract_links(last_message)
                        session.pull_links.update(pulls)
                        session.issue_links.update(issues)
                        session.release_links.update(releases)
                        session.follow_ups.update(extract_follow_ups(last_message))

                elif payload_type == "agent_message":
                    message = payload.get("message")
                    if isinstance(message, str):
                        pulls, issues, releases = extract_links(message)
                        session.pull_links.update(pulls)
                        session.issue_links.update(issues)
                        session.release_links.update(releases)
                        session.follow_ups.update(extract_follow_ups(message))

                elif payload_type == "user_message":
                    message = payload.get("message")
                    if isinstance(message, str):
                        maybe_add_user_snippet(session, message)

    session.branch = safe_branch_for_cwd(session.cwd, branch_cache)
    session.files_touched = {sanitize_text(path) for path in session.files_touched if path and len(path) <= 240}
    session.pull_links = {sanitize_text(url) for url in session.pull_links}
    session.issue_links = {sanitize_text(url) for url in session.issue_links}
    session.release_links = {sanitize_text(url) for url in session.release_links}
    session.follow_ups = {sanitize_text(item) for item in session.follow_ups if item}
    session.infer_metadata()
    return session


def build_rollups(session_entries: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    by_date: Counter[str] = Counter()
    by_cwd: Counter[str] = Counter()
    by_repo: Counter[str] = Counter()
    by_project: Counter[str] = Counter()
    by_outcome: Counter[str] = Counter()
    theme_counter: Counter[str] = Counter()
    command_counter: Counter[str] = Counter()
    tool_counter: Counter[str] = Counter()
    file_counter: Counter[str] = Counter()
    followup_counter: Counter[str] = Counter()

    for session in session_entries:
        by_date[str(session.get("date") or "unknown")] += 1
        by_cwd[str(session.get("cwd_hint") or "unknown")] += 1
        by_repo[str(session.get("repo") or "unknown")] += 1
        by_project[str(session.get("project") or "unknown")] += 1
        by_outcome[str(session.get("outcome") or "unknown")] += 1
        for theme in session.get("themes") or []:
            theme_counter[theme] += 1
        for name, count in (session.get("command_categories") or {}).items():
            command_counter[name] += int(count)
        for name, count in (session.get("tool_categories") or {}).items():
            tool_counter[name] += int(count)
        for path in session.get("files_changed") or []:
            file_counter[path] += 1
        for task in session.get("follow_up_tasks") or []:
            followup_counter[task] += 1

    return {
        "by_date": dict(by_date.most_common()),
        "by_cwd": dict(by_cwd.most_common()),
        "by_repo": dict(by_repo.most_common()),
        "by_project": dict(by_project.most_common()),
        "by_outcome": dict(by_outcome.most_common()),
        "themes": dict(theme_counter.most_common()),
        "command_categories": dict(command_counter.most_common()),
        "tool_categories": dict(tool_counter.most_common()),
        "files_changed": dict(file_counter.most_common()),
        "follow_up_tasks": dict(followup_counter.most_common()),
    }


def normalize_task_text(text: str) -> str:
    normalized = text.strip().strip(".")
    normalized = re.sub(r"\s+", " ", normalized)
    return normalized


def task_seed_title(task: str) -> str:
    lower = task.lower()
    if "parakeetengine.startrecording" in lower:
        return "Harden Parakeet startRecording failure path"
    if "parakeetrecoverystate" in lower:
        return "Tighten ParakeetRecoveryState start-failure transitions"
    if "transcriptedconstants" in lower:
        return "Align recording retry delay constants for start failures"
    if "tests to add or update" in lower:
        return "Add tests for Parakeet start-failure and Sentry sanitization"
    if "create the github release" in lower:
        return "Publish pending GitHub release for Transcripted"
    if "verify `apple-macos-v`" in lower or "verify apple-macos-v" in lower:
        return "Verify APPLE-MACOS-V on latest Transcripted release"
    words = re.sub(r"[*`]", "", task).split()
    if not words:
        return "Follow-up action"
    title = " ".join(words[:9]).strip()
    return title[0].upper() + title[1:]


def build_task_seeds(followup_rollup: dict[str, int]) -> list[dict[str, Any]]:
    seeds: list[dict[str, Any]] = []
    for task, count in followup_rollup.items():
        normalized = normalize_task_text(task)
        lower = normalized.lower()
        if any(ex in lower for ex in TASK_SEED_EXCLUDE):
            continue
        if not any(v in lower for v in TASK_SEED_VERBS):
            continue
        if len(normalized) < 20:
            continue
        seeds.append(
            {
                "title": task_seed_title(normalized),
                "task": normalized,
                "count": int(count),
                "suggested_project": "Transcripted",
                "suggested_priority": "high" if int(count) > 1 else "medium",
            }
        )
        if len(seeds) >= 20:
            break
    return seeds


def filter_sessions_by_since_hours(
    sessions: list[SessionAccumulator],
    since_hours: float | None,
    now: dt.datetime,
) -> tuple[list[SessionAccumulator], int]:
    if since_hours is None or since_hours <= 0:
        return sessions, 0
    cutoff = now - dt.timedelta(hours=since_hours)
    kept: list[SessionAccumulator] = []
    excluded_count = 0
    for session in sessions:
        started = parse_iso_datetime(session.started_at)
        if started is None:
            excluded_count += 1
            continue
        if started >= cutoff:
            kept.append(session)
        else:
            excluded_count += 1
    return kept, excluded_count


def build_nightly_actionable_followups(payload: dict[str, Any]) -> list[dict[str, Any]]:
    followup_counts = payload.get("rollups", {}).get("follow_up_tasks") or {}
    followup_by_text: dict[str, int] = {
        str(task): int(count) for task, count in followup_counts.items()
    }
    seeds = payload.get("task_seeds") or []
    actionable: list[dict[str, Any]] = []

    for seed in seeds:
        task = str(seed.get("task") or "").strip()
        if not task:
            continue
        count = int(seed.get("count") or followup_by_text.get(task, 1))
        actionable.append(
            {
                "title": str(seed.get("title") or task_seed_title(task)),
                "task": task,
                "count": count,
                "priority": str(seed.get("suggested_priority") or ("high" if count > 1 else "medium")),
                "project": str(seed.get("suggested_project") or "Transcripted"),
            }
        )
        if len(actionable) >= 20:
            break

    if actionable:
        return actionable

    for task, count in sorted(followup_by_text.items(), key=lambda item: item[1], reverse=True):
        normalized = normalize_task_text(task)
        if not normalized:
            continue
        actionable.append(
            {
                "title": task_seed_title(normalized),
                "task": normalized,
                "count": int(count),
                "priority": "high" if int(count) > 1 else "medium",
                "project": "Transcripted",
            }
        )
        if len(actionable) >= 20:
            break

    return actionable


def build_nightly_decision(payload: dict[str, Any], actionable_followups: list[dict[str, Any]]) -> dict[str, Any]:
    stats = payload.get("stats") or {}
    scanned = int(stats.get("scanned_files") or 0)
    included = int(stats.get("included_sessions") or 0)
    window_hours = payload.get("input", {}).get("since_hours")
    window_label = f"last {window_hours:g}h" if isinstance(window_hours, (int, float)) and window_hours else "current scan window"

    if scanned == 0:
        question = "Can you confirm where Codex archives live on this machine so nightly mining can run?"
        return {
            "decision": "ask_founder",
            "summary_lines": [],
            "blocker": None,
            "owner": None,
            "question": question,
            "rationale": f"No session files were discovered in {window_label}.",
        }

    if included == 0:
        return {
            "decision": "wait",
            "summary_lines": [],
            "blocker": f"No Transcripted sessions were found in {window_label}.",
            "owner": "Codex Operator",
            "question": None,
            "rationale": "Routine should wait until new Transcripted work appears in Codex archives.",
        }

    if actionable_followups:
        top = actionable_followups[0]
        line1 = (
            f"Shipped nightly archive mining for {window_label}: "
            f"{included} Transcripted sessions, {len(actionable_followups)} actionable follow-ups."
        )
        line2 = (
            f"Top follow-up: {top['title']} (count={top['count']}, priority={top['priority']})."
        )
        return {
            "decision": "ship",
            "summary_lines": [line1, line2],
            "blocker": None,
            "owner": None,
            "question": None,
            "rationale": "Actionable follow-ups were extracted and packaged for execution.",
        }

    return {
        "decision": "wait",
        "summary_lines": [],
        "blocker": f"No actionable follow-ups were extracted from {window_label}.",
        "owner": "Codex Operator",
        "question": None,
        "rationale": "Sessions exist but no safe follow-up actions matched extraction rules.",
    }


def render_nightly_report(payload: dict[str, Any], decision: dict[str, Any], actionable_followups: list[dict[str, Any]]) -> str:
    stats = payload["stats"]
    lines: list[str] = []
    lines.append("# Transcripted Nightly Archive Miner")
    lines.append("")
    lines.append(f"Generated: {payload['generated_at']}")
    lines.append("")
    lines.append("## Coverage")
    lines.append(f"- Scanned session files: {stats['scanned_files']}")
    lines.append(f"- Included Transcripted sessions: {stats['included_sessions']}")
    lines.append(f"- Excluded non-Transcripted sessions: {stats['excluded_sessions']}")
    if "excluded_by_time_window" in stats:
        lines.append(f"- Excluded by time window: {stats['excluded_by_time_window']}")
    if payload.get("input", {}).get("since_hours"):
        lines.append(f"- Time window: last {payload['input']['since_hours']:g} hours")
    lines.append("")
    lines.append("## Decision SLA")
    lines.append(f"- Decision: {decision['decision']}")
    if decision["decision"] == "ship":
        for summary in decision.get("summary_lines") or []:
            lines.append(f"- {summary}")
    elif decision["decision"] == "wait":
        lines.append(f"- Blocker: {decision.get('blocker') or 'unknown'}")
        lines.append(f"- Owner: {decision.get('owner') or 'unknown'}")
    elif decision["decision"] == "ask_founder":
        lines.append(f"- Question: {decision.get('question') or 'No question generated.'}")
    lines.append(f"- Rationale: {decision.get('rationale') or 'n/a'}")
    lines.append("")
    lines.append("## Actionable Follow-ups")
    if actionable_followups:
        for item in actionable_followups[:20]:
            lines.append(
                f"- [{item['priority']}] {item['title']} "
                f"(count={item['count']}, project={item['project']})"
            )
            lines.append(f"  - Task: {item['task']}")
    else:
        lines.append("- None extracted in this run.")
    lines.append("")
    return "\n".join(lines).strip() + "\n"


def render_digest(payload: dict[str, Any]) -> str:
    sessions = payload["sessions"]
    stats = payload["stats"]
    rollups = payload["rollups"]

    shipped = [s for s in sessions if s["outcome"] in {"shipped", "shipped_with_issues"}]
    broke = [s for s in sessions if s["stats"]["had_errors"]]
    unfinished = [s for s in sessions if s["outcome"] in {"unfinished_followups", "in_progress_or_unknown", "partial_or_failed"}]

    follow_up_counter: Counter[str] = Counter()
    for task, count in (rollups.get("follow_up_tasks") or {}).items():
        follow_up_counter[task] = int(count)

    lines: list[str] = []
    lines.append("# Transcripted Codex Memory Digest")
    lines.append("")
    lines.append(f"Generated: {payload['generated_at']}")
    lines.append("")
    lines.append("## Coverage")
    lines.append(f"- Scanned session files: {stats['scanned_files']}")
    lines.append(f"- Included Transcripted sessions: {stats['included_sessions']}")
    lines.append(f"- Excluded non-Transcripted sessions: {stats['excluded_sessions']}")
    lines.append("")
    lines.append("## What Shipped")
    if shipped:
        for s in shipped[:20]:
            pull_count = len(s["links"]["pulls"])
            rel_count = len(s["links"]["releases"])
            lines.append(
                f"- {s['date']} [{s['session_id']}]: {s['intent_summary']} "
                f"(pulls={pull_count}, releases={rel_count}, repo={s['repo']})"
            )
    else:
        lines.append("- No clear shipping evidence in scanned sessions.")
    lines.append("")
    lines.append("## What Broke")
    if broke:
        for s in broke[:20]:
            lines.append(
                f"- {s['date']} [{s['session_id']}]: outcome={s['outcome']}; "
                f"intent={s['intent_summary']}"
            )
    else:
        lines.append("- No command-failure signal detected.")
    lines.append("")
    lines.append("## Repeated Patterns")
    for name, count in list((rollups.get("themes") or {}).items())[:10]:
        lines.append(f"- Theme: {name} ({count})")
    for name, count in list((rollups.get("command_categories") or {}).items())[:10]:
        lines.append(f"- Command category: {name} ({count})")
    for path, count in list((rollups.get("files_changed") or {}).items())[:12]:
        lines.append(f"- Frequent file/path: {path} ({count})")
    lines.append("")
    lines.append("## Unfinished Threads")
    if unfinished:
        for s in unfinished[:20]:
            next_task = (s.get("follow_up_tasks") or ["none"])[0]
            lines.append(
                f"- {s['date']} [{s['session_id']}]: outcome={s['outcome']}; "
                f"top follow-up={next_task}"
            )
    else:
        lines.append("- No unfinished sessions detected from available metadata.")
    lines.append("")
    lines.append("## Next Moves")
    if follow_up_counter:
        for task, count in follow_up_counter.most_common(15):
            lines.append(f"- {task} (seen {count}x)")
    else:
        lines.append("- No explicit follow-up bullets extracted.")
    lines.append("")
    lines.append("## Rollup Counts")
    lines.append("- Sessions by date:")
    for k, v in list((rollups.get("by_date") or {}).items())[:20]:
        lines.append(f"  - {k}: {v}")
    lines.append("- Sessions by cwd:")
    for k, v in list((rollups.get("by_cwd") or {}).items())[:20]:
        lines.append(f"  - {k}: {v}")
    lines.append("- Sessions by repo:")
    for k, v in list((rollups.get("by_repo") or {}).items())[:20]:
        lines.append(f"  - {k}: {v}")
    lines.append("- Sessions by project:")
    for k, v in list((rollups.get("by_project") or {}).items())[:20]:
        lines.append(f"  - {k}: {v}")
    lines.append("")
    return "\n".join(lines).strip() + "\n"


def build_index(
    archived_dir: Path,
    sessions_dir: Path,
    output_dir: Path,
    limit: int | None,
    since_hours: float | None,
    verbose: bool,
    summarizer: MlxSummarizer,
    nightly_report: bool,
) -> dict[str, Any]:
    now_utc = dt.datetime.now(dt.timezone.utc)
    files = find_session_files(archived_dir=archived_dir, sessions_dir=sessions_dir, limit=limit)
    branch_cache: dict[str, str | None] = {}

    included_sessions: list[SessionAccumulator] = []
    for i, (path, source_kind) in enumerate(files, start=1):
        if verbose and i % 25 == 0:
            print(f"[index] processed {i}/{len(files)} files...", file=sys.stderr)
        try:
            session = process_session_file(path, source_kind, branch_cache)
        except Exception as exc:
            if verbose:
                print(f"[index] skip unreadable {path}: {exc}", file=sys.stderr)
            continue
        if session_is_transcripted(session):
            included_sessions.append(session)

    # Deduplicate by session id / file stem and keep the richer one.
    deduped: dict[str, SessionAccumulator] = {}
    for session in included_sessions:
        key = session.session_key()
        prev = deduped.get(key)
        if prev is None or session.total_lines > prev.total_lines:
            deduped[key] = session

    sessions = list(deduped.values())
    sessions.sort(key=lambda s: s.started_at or "", reverse=True)
    sessions, excluded_by_time_window = filter_sessions_by_since_hours(
        sessions=sessions,
        since_hours=since_hours,
        now=now_utc,
    )

    for session in sessions:
        summary = summarizer.summarize(session)
        session.intent_summary = summary if summary else heuristic_intent_summary(session)

    entries = [session.to_index_entry() for session in sessions]
    rollups = build_rollups(entries)
    followup_queue = [
        {"task": task, "count": count}
        for task, count in list((rollups.get("follow_up_tasks") or {}).items())[:30]
    ]
    task_seeds = build_task_seeds(rollups.get("follow_up_tasks") or {})

    payload = {
        "generated_at": now_utc.isoformat(),
        "input": {
            "archived_sessions_dir": str(archived_dir),
            "sessions_dir": str(sessions_dir),
            "limit": limit,
            "since_hours": since_hours,
        },
        "stats": {
            "scanned_files": len(files),
            "included_sessions": len(entries),
            "excluded_sessions": max(0, len(files) - len(entries)),
            "excluded_by_time_window": excluded_by_time_window,
            "mlx_summaries_used": summarizer._used if summarizer.enabled else 0,
        },
        "rollups": rollups,
        "followup_queue": followup_queue,
        "task_seeds": task_seeds,
        "sessions": entries,
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "transcripted-codex-index.json"
    stats_path = output_dir / "transcripted-codex-stats.json"
    digest_path = output_dir / "transcripted-codex-digest.md"
    followup_path = output_dir / "transcripted-codex-followups.json"
    task_seed_path = output_dir / "transcripted-paperclip-task-seeds.json"

    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    stats_path.write_text(json.dumps({"stats": payload["stats"], "rollups": payload["rollups"]}, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    followup_path.write_text(json.dumps({"followup_queue": payload["followup_queue"]}, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    task_seed_path.write_text(json.dumps({"task_seeds": payload["task_seeds"]}, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    digest_path.write_text(render_digest(payload), encoding="utf-8")

    nightly_json_path: str | None = None
    nightly_markdown_path: str | None = None
    if nightly_report:
        actionable_followups = build_nightly_actionable_followups(payload)
        decision = build_nightly_decision(payload, actionable_followups)
        nightly_payload = {
            "generated_at": payload["generated_at"],
            "input": payload["input"],
            "stats": payload["stats"],
            "decision": decision,
            "actionable_followups": actionable_followups,
        }
        nightly_json = output_dir / "transcripted-nightly-archive-miner.json"
        nightly_markdown = output_dir / "transcripted-nightly-archive-miner.md"
        nightly_json.write_text(json.dumps(nightly_payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
        nightly_markdown.write_text(render_nightly_report(payload, decision, actionable_followups), encoding="utf-8")
        nightly_json_path = str(nightly_json)
        nightly_markdown_path = str(nightly_markdown)

    return {
        "json": str(json_path),
        "stats_json": str(stats_path),
        "followups_json": str(followup_path),
        "task_seeds_json": str(task_seed_path),
        "digest_markdown": str(digest_path),
        "nightly_json": nightly_json_path,
        "nightly_markdown": nightly_markdown_path,
        "stats": payload["stats"],
    }


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    home = Path.home()
    parser = argparse.ArgumentParser(description="Build a safe Transcripted-focused Codex session index")
    parser.add_argument(
        "--archived-dir",
        type=Path,
        default=home / ".codex" / "archived_sessions",
        help="Path to Codex archived_sessions directory",
    )
    parser.add_argument(
        "--sessions-dir",
        type=Path,
        default=home / ".codex" / "sessions",
        help="Path to Codex sessions directory",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("build") / "codex-memory-index",
        help="Directory where index and digest files are written",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Optional max number of session files to scan (newest first)",
    )
    parser.add_argument(
        "--since-hours",
        type=float,
        default=None,
        help="Only include sessions with timestamps newer than now-N hours",
    )
    parser.add_argument(
        "--nightly-report",
        action="store_true",
        help="Write nightly decision + actionable follow-up artifacts",
    )
    parser.add_argument("--verbose", action="store_true", help="Print progress logs")
    parser.add_argument(
        "--mlx-summarize",
        action="store_true",
        help="Use local MLX OpenAI-compatible endpoint to summarize intent safely",
    )
    parser.add_argument(
        "--mlx-endpoint",
        default="http://localhost:8800/v1",
        help="Local MLX API base URL",
    )
    parser.add_argument(
        "--mlx-model",
        default="mlx-community/gemma-4-31b-it-4bit",
        help="Model id used for local intent summarization",
    )
    parser.add_argument(
        "--mlx-timeout-seconds",
        type=float,
        default=12.0,
        help="Timeout per MLX summarization call",
    )
    parser.add_argument(
        "--mlx-max-sessions",
        type=int,
        default=120,
        help="Max sessions to summarize via MLX (set 0 to disable external calls)",
    )
    parser.add_argument(
        "--allow-local-model-calls",
        action="store_true",
        help="Required when enabling --mlx-summarize; keeps local model usage opt-in",
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    if args.mlx_summarize and not args.allow_local_model_calls:
        print(
            "Refusing local model calls without explicit opt-in. "
            "Re-run with --allow-local-model-calls to enable --mlx-summarize.",
            file=sys.stderr,
        )
        return 2
    summarizer = MlxSummarizer(
        enabled=bool(args.mlx_summarize and args.mlx_max_sessions != 0),
        endpoint=args.mlx_endpoint,
        model=args.mlx_model,
        timeout_seconds=args.mlx_timeout_seconds,
        max_sessions=max(0, args.mlx_max_sessions),
        verbose=args.verbose,
    )
    result = build_index(
        archived_dir=args.archived_dir,
        sessions_dir=args.sessions_dir,
        output_dir=args.output_dir,
        limit=args.limit,
        since_hours=args.since_hours,
        verbose=args.verbose,
        summarizer=summarizer,
        nightly_report=bool(args.nightly_report),
    )
    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
