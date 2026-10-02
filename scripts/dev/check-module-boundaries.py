#!/usr/bin/env python3
"""Module-boundary ratchet for the app's Swift sources.

The app compiles as one Swift target, so the compiler lets any file name any
type. This check gives the folders real edges. `.agents/modules.json` maps every
`Sources/**/*.swift` file to one module and says which modules each one may
depend on. The check indexes the top-level types each module declares and flags
any reference from an app file to a type in a module it may not depend on.

Core (`Sources/TranscriptedCore`) is a separate Swift library, so only its
`public` declarations are indexed, and a module may name a Core type only when
the type is in one of the Core tiers the module lists (`Core:core-vocab`,
`Core:mic-primitives`, ...; `Core:core-engine` means all of Core).

Existing crossings are grandfathered in `.agents/module-boundary-baseline.json`
(file -> module -> type names). The check fails on a crossing that isn't in the
baseline and on a baseline entry that no longer happens, so the pile only
shrinks:

    python3 scripts/dev/check-module-boundaries.py             # check
    python3 scripts/dev/check-module-boundaries.py --shrink    # drop baseline entries that went away
    python3 scripts/dev/check-module-boundaries.py --explain Sources/Speech/ParakeetEngine.swift
    python3 scripts/dev/check-module-boundaries.py --graph     # module edge counts
    python3 scripts/dev/check-module-boundaries.py --self-test

--shrink never adds an entry. Growing the baseline is a human edit made in
review and called out in the PR.

It is a lexer, not a compiler: it sees type names, not type inference, free
functions, globals, or members added by extensions. A surprising violation is
more likely a checker bug than a real edge, so fix the checker (or add the name
to `ambiguousNames` with a reason) rather than baselining noise. Offline,
python3 stdlib only, writes nothing except the baseline on --shrink.
"""

from __future__ import annotations

import argparse
import bisect
import contextlib
import fnmatch
import importlib.util
import io
import json
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / ".agents/modules.json"
BASELINE_PATH = REPO_ROOT / ".agents/module-boundary-baseline.json"
CORE_MODULE = "Core"
CORE_ENGINE_TIER = "core-engine"


def _load_sanitizer():
    spec = importlib.util.spec_from_file_location(
        "check_duplicate_declarations", Path(__file__).resolve().parent / "check-duplicate-declarations.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module.sanitize


sanitize = _load_sanitizer()

DECL = re.compile(r"\b(class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)")
NOT_A_TYPE_NAME = {"func", "var", "let", "subscript", "init", "deinit", "case", "protocol", "struct", "enum", "class"}
TYPE_REF = re.compile(r"(?<![A-Za-z0-9_.$@#])([A-Z][A-Za-z0-9_]*)\b")
IMPORT_CORE = re.compile(r"^\s*(?:@[A-Za-z_]+\s+)*import\s+TranscriptedCore\b", re.M)
PRIVATE = re.compile(r"\b(private|fileprivate)\b")
PUBLIC = re.compile(r"\b(public|open)\b")


@dataclass
class Module:
    name: str
    paths: list[str]
    may_depend_on: list[str]
    agents_doc: str | None
    app_target: bool = True


@dataclass
class Manifest:
    modules: dict[str, Module]
    core_tiers: dict[str, list[str]]
    ambiguous_names: dict[str, str]
    cycle_allowed_edges: list[tuple[str, str]]

    def module_of(self, rel: str) -> str | None:
        best: tuple[int, str] | None = None
        for module in self.modules.values():
            for prefix in module.paths:
                if rel == prefix or rel.startswith(prefix.rstrip("/") + "/"):
                    if best is None or len(prefix) > best[0]:
                        best = (len(prefix), module.name)
        return best[1] if best else None


@dataclass
class FileFacts:
    rel: str
    module: str
    declared: dict[str, str] = field(default_factory=dict)  # name -> "public" | "internal" | "private"
    nested: set[str] = field(default_factory=set)
    refs: dict[str, int] = field(default_factory=dict)  # name -> first line
    imports_core: bool = False


def load_manifest(path: Path) -> Manifest:
    raw = json.loads(path.read_text(encoding="utf-8"))
    modules = {}
    for entry in raw["modules"]:
        modules[entry["name"]] = Module(
            name=entry["name"],
            paths=entry["paths"],
            may_depend_on=entry.get("mayDependOn", []),
            agents_doc=entry.get("agentsDoc"),
            app_target=entry.get("appTarget", True),
        )
    return Manifest(
        modules=modules,
        core_tiers=raw.get("coreTiers", {}),
        ambiguous_names=raw.get("ambiguousNames", {}),
        cycle_allowed_edges=[tuple(edge) for edge in raw.get("cycleAllowedEdges", [])],
    )


def validate_manifest(manifest: Manifest, root: Path) -> list[str]:
    problems = []
    names = set(manifest.modules)
    for module in manifest.modules.values():
        for dep in module.may_depend_on:
            if dep == "*":
                continue
            if dep.startswith(CORE_MODULE + ":"):
                tier = dep.split(":", 1)[1]
                if tier != CORE_ENGINE_TIER and tier not in manifest.core_tiers:
                    problems.append(f"{module.name}: unknown Core tier {tier!r}")
                continue
            if dep not in names:
                problems.append(f"{module.name}: mayDependOn names unknown module {dep!r}")
            if dep == "AppShell":
                problems.append(f"{module.name}: nothing may depend on AppShell (the composition root)")
            if dep == module.name:
                problems.append(f"{module.name}: lists itself in mayDependOn")
        for prefix in module.paths:
            if not (root / prefix).exists():
                problems.append(f"{module.name}: path {prefix} does not exist")
        if module.agents_doc and not (root / module.agents_doc).exists():
            problems.append(f"{module.name}: agentsDoc {module.agents_doc} does not exist")
    seen_prefixes: dict[str, str] = {}
    for module in manifest.modules.values():
        for prefix in module.paths:
            if prefix in seen_prefixes:
                problems.append(f"path {prefix} is mapped by both {seen_prefixes[prefix]} and {module.name}")
            seen_prefixes[prefix] = module.name
    # mayDependOn must be acyclic, apart from the named cycle-allowed edges.
    allowed = set(manifest.cycle_allowed_edges)
    graph = {
        m.name: [d for d in m.may_depend_on if d in names and (m.name, d) not in allowed]
        for m in manifest.modules.values()
    }
    state: dict[str, int] = {}

    def visit(node: str, trail: list[str]) -> None:
        state[node] = 1
        for dep in graph[node]:
            if state.get(dep) == 1:
                cycle = trail[trail.index(dep):] + [dep] if dep in trail else [node, dep]
                problems.append("mayDependOn cycle: " + " -> ".join(cycle))
            elif dep not in state:
                visit(dep, trail + [dep])
        state[node] = 2

    for name in sorted(graph):
        if name not in state:
            visit(name, [name])
    for edge in allowed:
        if edge[0] not in names or edge[1] not in names or edge[1] not in manifest.modules[edge[0]].may_depend_on:
            problems.append(f"cycleAllowedEdges entry {list(edge)} is not a mayDependOn edge")
    return problems


def analyze_source(rel: str, module: str, raw: str) -> FileFacts:
    facts = FileFacts(rel=rel, module=module)
    clean = sanitize(raw)
    facts.imports_core = bool(IMPORT_CORE.search(clean))
    depth_at = [0] * (len(clean) + 1)
    depth = 0
    for index, char in enumerate(clean):
        depth_at[index] = depth
        if char == "{":
            depth += 1
        elif char == "}":
            depth = max(0, depth - 1)
    starts = [0] + [i + 1 for i, c in enumerate(clean) if c == "\n"]
    declared_at: set[int] = set()
    for match in DECL.finditer(clean):
        name = match.group(2)
        if name in NOT_A_TYPE_NAME:
            continue
        declared_at.add(match.start(2))
        if depth_at[match.start()] != 0:
            facts.nested.add(name)
            continue
        line_start = clean.rfind("\n", 0, match.start()) + 1
        prefix = clean[line_start:match.start()]
        if PRIVATE.search(prefix):
            access = "private"
        elif PUBLIC.search(prefix):
            access = "public"
        else:
            access = "internal"
        facts.declared[name] = access
    for match in TYPE_REF.finditer(clean):
        if match.start(1) in declared_at:
            continue
        name = match.group(1)
        if name not in facts.refs:
            facts.refs[name] = bisect.bisect_right(starts, match.start(1))
    return facts


@dataclass
class Index:
    app_decl: dict[str, set[str]]  # name -> app modules declaring it at top level (not private)
    any_decl: dict[str, set[str]]  # name -> modules declaring it at any depth or access (local shadowing)
    core_public: set[str]
    separate: dict[str, str]  # types of separately compiled non-Core modules: name -> module


def build_index(manifest: Manifest, files: list[FileFacts]) -> Index:
    app_decl: dict[str, set[str]] = {}
    any_decl: dict[str, set[str]] = {}
    core_public: set[str] = set()
    separate: dict[str, str] = {}
    for facts in files:
        module = manifest.modules[facts.module]
        for name in facts.nested:
            any_decl.setdefault(name, set()).add(facts.module)
        for name, access in facts.declared.items():
            any_decl.setdefault(name, set()).add(facts.module)
            if facts.module == CORE_MODULE:
                if access == "public":
                    core_public.add(name)
            elif module.app_target:
                if access != "private":
                    app_decl.setdefault(name, set()).add(facts.module)
            else:
                separate.setdefault(name, facts.module)
    return Index(app_decl=app_decl, any_decl=any_decl, core_public=core_public, separate=separate)


def core_tier_allows(manifest: Manifest, module: Module, name: str) -> bool:
    for dep in module.may_depend_on:
        if dep == "*" or dep == CORE_MODULE + ":" + CORE_ENGINE_TIER:
            return True
        if dep.startswith(CORE_MODULE + ":"):
            patterns = manifest.core_tiers.get(dep.split(":", 1)[1], [])
            if any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns):
                return True
    return False


def module_allows(module: Module, target: str) -> bool:
    return "*" in module.may_depend_on or target in module.may_depend_on


@dataclass
class Edge:
    rel: str
    source: str
    target: str
    name: str
    line: int
    allowed: bool


def resolve_edges(manifest: Manifest, files: list[FileFacts], index: Index) -> tuple[list[Edge], set[str]]:
    edges: list[Edge] = []
    ambiguous_hits: set[str] = set()
    for facts in files:
        module = manifest.modules[facts.module]
        if not module.app_target:
            continue  # a separately compiled module: its own compiler enforces its edges
        for name, line in facts.refs.items():
            if name in manifest.ambiguous_names or name in facts.declared:
                continue
            if facts.module in index.any_decl.get(name, set()):
                continue
            owners = index.app_decl.get(name, set())
            if len(owners) > 1:
                ambiguous_hits.add(name)
                continue
            if owners:
                target = next(iter(owners))
                edges.append(Edge(facts.rel, facts.module, target, name, line, module_allows(module, target)))
                continue
            if name in index.core_public:
                if not facts.imports_core:
                    continue  # this file can't see Core, so the name isn't Core's
                allowed = core_tier_allows(manifest, module, name)
                edges.append(Edge(facts.rel, facts.module, CORE_MODULE, name, line, allowed))
                continue
            if name in index.separate:
                target = index.separate[name]
                edges.append(Edge(facts.rel, facts.module, target, name, line, module_allows(module, target)))
    return edges, ambiguous_hits


def collect(root: Path, manifest: Manifest) -> tuple[list[FileFacts], list[str]]:
    problems = []
    files = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        rel = path.relative_to(root).as_posix()
        module = manifest.module_of(rel)
        if module is None:
            problems.append(f"{rel}: no module in .agents/modules.json maps this file (add its folder to a module)")
            continue
        files.append(analyze_source(rel, module, path.read_text(encoding="utf-8", errors="replace")))
    return files, problems


def violations_by_file(edges: list[Edge]) -> dict[str, dict[str, list[str]]]:
    out: dict[str, dict[str, set[str]]] = {}
    for edge in edges:
        if not edge.allowed:
            out.setdefault(edge.rel, {}).setdefault(edge.target, set()).add(edge.name)
    return {rel: {t: sorted(n) for t, n in sorted(targets.items())} for rel, targets in sorted(out.items())}


def count_crossings(edges: dict[str, dict[str, list[str]]]) -> int:
    return sum(len(names) for targets in edges.values() for names in targets.values())


def load_baseline(path: Path) -> dict[str, dict[str, list[str]]]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8")).get("edges", {})


def save_baseline(path: Path, edges: dict[str, dict[str, list[str]]]) -> None:
    payload = {
        "_comment": (
            "Grandfathered module-boundary crossings: file -> module it reaches into -> type names. "
            "scripts/dev/check-module-boundaries.py --shrink only removes entries; adding one is a reviewed human edit."
        ),
        "edges": edges,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def compare(current, baseline):
    new, stale = [], []
    for rel, targets in current.items():
        for target, names in targets.items():
            allowed = set(baseline.get(rel, {}).get(target, []))
            new += [(rel, target, n) for n in names if n not in allowed]
    for rel, targets in baseline.items():
        for target, names in targets.items():
            have = set(current.get(rel, {}).get(target, []))
            stale += [(rel, target, n) for n in names if n not in have]
    return new, stale


def shrink(current, baseline):
    out: dict[str, dict[str, list[str]]] = {}
    for rel, targets in baseline.items():
        for target, names in targets.items():
            have = set(current.get(rel, {}).get(target, []))
            kept = [n for n in names if n in have]
            if kept:
                out.setdefault(rel, {})[target] = kept
    return out


def explain_path(manifest: Manifest, raw_path: str) -> int:
    rel = Path(raw_path).as_posix()
    while rel.startswith("./"):
        rel = rel[2:]
    name = manifest.module_of(rel)
    if name is None:
        print(f"{rel}: not mapped to any module. Add its folder to .agents/modules.json.")
        return 1
    module = manifest.modules[name]
    dependents = sorted(m.name for m in manifest.modules.values() if name in m.may_depend_on)
    print(rel)
    print(f"  module:         {name}")
    print(f"  may depend on:  {', '.join(module.may_depend_on) or '(nothing)'}")
    print(f"  depended on by: {', '.join(dependents) or '(nothing)'}")
    print(f"  agents doc:     {module.agents_doc or '(none)'}")
    return 0


def run(root: Path, manifest_path: Path, baseline_path: Path, mode: str = "check", explain: str | None = None) -> int:
    manifest = load_manifest(manifest_path)
    if explain:
        return explain_path(manifest, explain)

    problems = validate_manifest(manifest, root)
    files, unmapped = collect(root, manifest)
    problems += unmapped
    index = build_index(manifest, files)
    edges, ambiguous = resolve_edges(manifest, files, index)
    current = violations_by_file(edges)

    if mode == "graph":
        counts: dict[tuple[str, str], list[int]] = {}
        for edge in edges:
            slot = counts.setdefault((edge.source, edge.target), [0, 0])
            slot[0 if edge.allowed else 1] += 1
        print(f"{'from':16} {'to':16} {'allowed':>8} {'crossing':>9}   (distinct type names per file)")
        for (source, target), (ok, bad) in sorted(counts.items()):
            print(f"{source:16} {target:16} {ok:>8} {bad:>9}")
        importers = [f.rel for f in files if f.imports_core and f.module not in (CORE_MODULE, "Meeting")]
        print(f"\nfiles outside Core and Meeting that import TranscriptedCore: {len(importers)}")
        print(f"names declared in more than one app module (ignored): {len(ambiguous)}")
        print(f"grandfathered crossings: {count_crossings(load_baseline(baseline_path))}")
        for problem in problems:
            print(f"FAIL {problem}")
        return 1 if problems else 0

    for problem in problems:
        print(f"FAIL {problem}")
    baseline = load_baseline(baseline_path)
    new, stale = compare(current, baseline)
    if mode == "shrink":
        if problems or new:
            for rel, target, name in new:
                print(f"FAIL new crossing: {rel} -> {target}.{name}")
            print("Refusing to shrink while the check has new failures; fix them first.")
            return 1
        save_baseline(baseline_path, shrink(current, baseline))
        print(f"Baseline updated: {count_crossings(load_baseline(baseline_path))} crossings")
        return 0
    if mode == "write-baseline":
        save_baseline(baseline_path, current)
        print(f"Baseline written: {count_crossings(current)} crossings")
        return 1 if problems else 0

    line_of = {(e.rel, e.target, e.name): e.line for e in edges if not e.allowed}
    for rel, target, name in new:
        source = manifest.module_of(rel)
        tier = " (outside its Core tiers)" if target == CORE_MODULE else ""
        print(
            f"FAIL {rel}:{line_of.get((rel, target, name), 0)}: module {source} names {target} type "
            f"{name}{tier}, but {source} may not depend on it."
        )
    if new:
        print(
            "  Fix: move the type down, pass plain values, or (if the edge is right) change mayDependOn in "
            ".agents/modules.json and that module's AGENTS.md. `--explain <file>` shows what a file may use."
        )
    for rel, target, name in stale:
        print(f"FAIL baseline entry no longer happens: {rel} -> {target}.{name}. Run with --shrink.")
    if problems or new or stale:
        return 1
    print(
        f"module boundaries OK: {len(files)} files in {len(manifest.modules)} modules, "
        f"{count_crossings(current)} grandfathered crossings"
    )
    return 0


def self_test() -> None:
    manifest_doc = {
        "modules": [
            {"name": "Core", "paths": ["Sources/Core"], "appTarget": False},
            {"name": "Low", "paths": ["Sources/Low"], "mayDependOn": ["Core:vocab"], "agentsDoc": "Sources/Low/AGENTS.md"},
            {"name": "High", "paths": ["Sources/High"], "mayDependOn": ["Low", "Core:core-engine"]},
            {"name": "AppShell", "paths": ["Sources/App.swift"], "mayDependOn": ["*"]},
        ],
        "coreTiers": {"vocab": ["Logger", "Speaker*"]},
        "ambiguousNames": {"Shared": "declared everywhere"},
    }
    sources = {
        "Sources/Core/A.swift": "public final class Logger {}\npublic struct SpeakerName {}\npublic class Engine {}\nclass Hidden {}\n",
        "Sources/Low/L.swift": (
            "import TranscriptedCore\n"
            "struct LowThing { let log: Logger; let s: SpeakerName }\n"
            "// HighThing in a comment is fine\n"
            "let text = \"HighThing in a string is fine\"\n"
            "func bad() { _ = HighThing(); _ = Engine() }\n"
            "private struct Row {}\nstruct Shared {}\n"
        ),
        "Sources/Low/AGENTS.md": "",
        "Sources/High/H.swift": (
            "import TranscriptedCore\n"
            "struct HighThing { let low: LowThing; let e: Engine; let r: Row; let s: Shared }\n"
            "struct Row {}\nstruct Shared {}\n"
            "extension HighThing { struct Config {} }\n"
        ),
        "Sources/High/NoImport.swift": "func f() { _ = Engine() }\n",
        "Sources/App.swift": "struct App { let h: HighThing; let l: LowThing; let e: Engine }\n",
    }
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for rel, text in sources.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text, encoding="utf-8")
        manifest_path = root / "modules.json"
        manifest_path.write_text(json.dumps(manifest_doc), encoding="utf-8")
        baseline_path = root / "baseline.json"
        manifest = load_manifest(manifest_path)
        assert validate_manifest(manifest, root) == [], validate_manifest(manifest, root)
        files, unmapped = collect(root, manifest)
        assert unmapped == [], unmapped
        index = build_index(manifest, files)
        assert "Hidden" not in index.core_public and "Logger" in index.core_public
        edges, _ = resolve_edges(manifest, files, index)
        current = violations_by_file(edges)
        # Low reaching up into High, and Low naming a Core type outside its tier.
        assert current == {"Sources/Low/L.swift": {"Core": ["Engine"], "High": ["HighThing"]}}, current
        # High's own Row wins over Low's private one; Shared is on the ignore list.
        assert not any(e.name in ("Row", "Shared") for e in edges), edges
        # A file that doesn't import Core can't be naming a Core type.
        assert not any(e.rel.endswith("NoImport.swift") for e in edges)
        with contextlib.redirect_stdout(io.StringIO()):
            assert run(root, manifest_path, baseline_path) == 1  # empty baseline: two new crossings
            save_baseline(baseline_path, current)
            assert run(root, manifest_path, baseline_path) == 0
            # A stale entry fails until --shrink drops it; --shrink never adds.
            save_baseline(baseline_path, {**current, "Sources/High/H.swift": {"Low": ["Gone"]}})
            assert run(root, manifest_path, baseline_path) == 1
            assert run(root, manifest_path, baseline_path, mode="shrink") == 0
            assert load_baseline(baseline_path) == current
            save_baseline(baseline_path, {})
            assert run(root, manifest_path, baseline_path, mode="shrink") == 1
            save_baseline(baseline_path, current)
            # A new file outside every module fails.
            (root / "Sources/Stray").mkdir()
            (root / "Sources/Stray/S.swift").write_text("struct S {}\n", encoding="utf-8")
            assert run(root, manifest_path, baseline_path) == 1
            (root / "Sources/Stray/S.swift").unlink()
            assert run(root, manifest_path, baseline_path, explain="Sources/High/H.swift") == 0
            assert run(root, manifest_path, baseline_path, explain="Elsewhere/X.swift") == 1
        # Manifest rules: cycles and depending on AppShell are refused.
        bad = json.loads(json.dumps(manifest_doc))
        bad["modules"][1]["mayDependOn"] = ["High", "AppShell"]
        manifest_path.write_text(json.dumps(bad), encoding="utf-8")
        problems = validate_manifest(load_manifest(manifest_path), root)
        assert any("cycle" in p for p in problems), problems
        assert any("AppShell" in p for p in problems), problems
        bad["cycleAllowedEdges"] = [["Low", "High"]]
        bad["modules"][1]["mayDependOn"] = ["High"]
        manifest_path.write_text(json.dumps(bad), encoding="utf-8")
        assert validate_manifest(load_manifest(manifest_path), root) == []
    print("check-module-boundaries self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shrink", action="store_true", help="drop baseline entries that no longer happen (never adds)")
    parser.add_argument("--explain", metavar="PATH", help="print the module, allowed deps and AGENTS.md for a path")
    parser.add_argument("--graph", action="store_true", help="print module edge counts")
    parser.add_argument("--write-baseline", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    mode = "shrink" if args.shrink else "graph" if args.graph else "write-baseline" if args.write_baseline else "check"
    return run(REPO_ROOT, MANIFEST_PATH, BASELINE_PATH, mode=mode, explain=args.explain)


if __name__ == "__main__":
    sys.exit(main())
