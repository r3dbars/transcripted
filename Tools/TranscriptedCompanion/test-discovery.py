#!/usr/bin/env python3
"""Check a packaged plugin through Codex's supported plugin/read protocol.

Uses an unregistered temporary marketplace. It never installs a plugin, changes
Codex configuration, or invokes a Transcripted tool. With the explicit
--check-installed-startup option it also starts the configured MCP servers.
"""
import argparse
import json
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PLUGIN = ROOT / "build/companion/local/transcripted"
DESKTOP_CODEX = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")


class AppServer:
    def __init__(self, command):
        self.process = subprocess.Popen(
            [command, "app-server", "--stdio"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.sequence = 0

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if not self.selector.select(max(0, deadline - time.monotonic())):
                break
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("Codex app-server exited before its reply")
            response = json.loads(line)
            if response.get("id") != request_id:
                continue
            if "error" in response:
                raise RuntimeError(f"Codex refused {method}: {response['error']}")
            return response["result"]
        raise RuntimeError(f"No Codex reply to {method}")

    def initialize(self):
        self.request("initialize", {
            "clientInfo": {"name": "transcripted-plugin-discovery-test", "version": "0.1.0"},
            "capabilities": {"experimentalApi": True},
        })
        self.process.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n")
        self.process.stdin.flush()

    def close(self):
        self.selector.close()
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def read_package(server, source, temporary):
    source = source.resolve(strict=True)
    portable = source / "plugin.json"
    manifest_path = portable if portable.is_file() else source / ".codex-plugin/plugin.json"
    name = json.loads(manifest_path.read_text())["name"]
    destination = temporary / "plugins" / name
    shutil.copytree(source, destination)
    marketplace = temporary / ".agents/plugins/marketplace.json"
    marketplace.parent.mkdir(parents=True)
    marketplace.write_text(json.dumps({
        "name": "transcripted-discovery-test",
        "plugins": [{
            "name": name,
            "source": {"source": "local", "path": "./plugins/" + name},
            "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
            "category": "Productivity",
        }],
    }))
    return server.request("plugin/read", {"pluginName": name, "marketplacePath": str(marketplace)})["plugin"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-root", type=Path, default=DEFAULT_PLUGIN)
    parser.add_argument("--codex", "--codex-path", default=str(DESKTOP_CODEX) if DESKTOP_CODEX.is_file() else "codex")
    parser.add_argument("--probe-portable", type=Path, help="Also report portable discovery; this diagnostic is not an assertion")
    parser.add_argument("--check-installed-startup", action="store_true", help="Start configured MCP servers and assert the installed Transcripted tools load; never calls a tool")
    args = parser.parse_args()
    version = subprocess.run([args.codex, "--version"], check=True, capture_output=True, text=True).stdout.strip()
    server = AppServer(args.codex)
    try:
        server.initialize()
        with tempfile.TemporaryDirectory(prefix="transcripted-discovery-test-", dir="/private/tmp") as directory:
            plugin = read_package(server, args.plugin_root, Path(directory))
            assert plugin["mcpServers"] == ["transcripted"], f"Packaged MCP server was not discovered: {plugin['mcpServers']}"
            assert plugin["summary"]["installed"] is False, "Discovery fixture must remain uninstalled"
            report = {"codex": version, "discovered_mcp_servers": plugin["mcpServers"], "installed": False, "panel_verified": False}
        if args.probe_portable:
            with tempfile.TemporaryDirectory(prefix="transcripted-portable-probe-", dir="/private/tmp") as directory:
                portable = read_package(server, args.probe_portable, Path(directory))
                report["portable_mcp_servers"] = portable["mcpServers"]
        if args.check_installed_startup:
            status = server.request("mcpServerStatus/list", {"limit": 100, "detail": "full"})
            candidates = list(status["data"])
            while status.get("nextCursor"):
                status = server.request("mcpServerStatus/list", {"limit": 100, "detail": "full", "cursor": status["nextCursor"]})
                candidates.extend(status["data"])
            installed = next(item for item in candidates if item.get("pluginId") == "transcripted@transcripted-local")
            assert not installed.get("toolsError"), installed.get("toolsError")
            assert "show_companion" in installed["tools"], "Companion tool missing from installed server"
            assert "get_recording_status" in installed["tools"], "Native status tool missing"
            report["installed_startup_verified"] = True
            report["installed_tool_count"] = len(installed["tools"])
        print(json.dumps(report, indent=2))
    finally:
        server.close()


if __name__ == "__main__":
    main()
