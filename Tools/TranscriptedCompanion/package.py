#!/usr/bin/env python3
"""Build a self-contained Mac plugin; no credentials or capture data enter it."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent / "plugin" / "transcripted"
SOURCE_FILES = frozenset({
    "plugin.json", "mcp.json", ".codex-plugin/plugin.json", ".mcp.json",
    "assets/icon.png", "scripts/launch.sh", "skills/transcripted-companion/SKILL.md",
})
RUNTIME_FILES = frozenset({"server/transcripted-mcp", "server/manifest.json"})
PACKAGE_FILES = SOURCE_FILES | RUNTIME_FILES


def validate(source):
    manifest = json.loads((source / "plugin.json").read_text())
    assert manifest["name"] == source.name == "transcripted"
    interface = manifest["extensions"]["com.openai"]["interface"]
    assert len(interface["shortDescription"]) <= 30
    legacy = json.loads((source / ".codex-plugin" / "plugin.json").read_text())
    assert legacy["name"] == manifest["name"] and legacy["version"] == manifest["version"]
    assert legacy["interface"]["defaultPrompt"] == interface["defaultPrompt"]
    for key in ("logo", "composerIcon"):
        asset = source / interface[key]
        assert asset.is_file() and asset.stat().st_size < 5 * 1024 * 1024
        assert asset.resolve().is_relative_to(source.resolve())
    for config in ("mcp.json", ".mcp.json"):
        servers = json.loads((source / config).read_text())["mcpServers"]
        assert set(servers) == {"transcripted"}
        assert servers["transcripted"]["command"] == "/bin/bash"
    skill = (source / "skills/transcripted-companion/SKILL.md").read_text()
    assert skill.startswith("---\nname: transcripted-companion\n")
    subprocess.run(["/bin/bash", "-n", str(source / "scripts/launch.sh")], check=True)
    for path in source.rglob("*"):
        assert not path.is_symlink(), f"Symlink is not allowed: {path}"
        if path.is_file():
            relative = path.relative_to(source).as_posix()
            assert relative in PACKAGE_FILES or relative in {".gitignore", ".DS_Store"}, f"Unexpected plugin file: {relative}"
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "build/companion")
    args = parser.parse_args()
    manifest = validate(SOURCE)
    if args.validate_only:
        print(json.dumps({"validated": True, "name": manifest["name"], "version": manifest["version"]}))
        return
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build the Transcripted companion plugin on an Apple Silicon Mac.")
    if not args.no_build:
        subprocess.run(["swift", "build", "-c", "release", "--package-path", str(ROOT / "Tools/TranscriptedMCP")], check=True)
    binary = ROOT / "Tools/TranscriptedMCP/.build/release/transcripted-mcp"
    if not binary.is_file() or binary.is_symlink():
        raise SystemExit("Build the release MCP helper before packaging.")
    runtime = SOURCE / "server"
    runtime.mkdir(exist_ok=True)
    shutil.copy2(binary, runtime / "transcripted-mcp")
    (runtime / "transcripted-mcp").chmod(0o755)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    (runtime / "manifest.json").write_text(json.dumps({
        "protocol_version": 1,
        "architecture": "arm64",
        "sha256": digest,
        "version": manifest["version"],
    }, indent=2) + "\n")
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / "Transcripted-plugin.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for relative in sorted(PACKAGE_FILES):
            path = SOURCE / relative
            assert path.is_file() and not path.is_symlink()
            bundle.write(path, "transcripted/" + relative)
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        assert all(name.startswith("transcripted/") for name in names)
        assert "transcripted/plugin.json" in names and "transcripted/mcp.json" in names
        assert "transcripted/.codex-plugin/plugin.json" in names
        assert "transcripted/server/transcripted-mcp" in names
        assert set(names) == {"transcripted/" + relative for relative in PACKAGE_FILES}
    print(json.dumps({"archive": str(archive.resolve()), "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(), "helper_sha256": digest, "files": len(names)}, indent=2))


if __name__ == "__main__":
    main()
