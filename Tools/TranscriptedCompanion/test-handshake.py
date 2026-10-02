#!/usr/bin/env python3
"""Replay the panel's object-valued capabilities against the packaged helper.

Uses an empty temporary capture library. Never controls recording or sharing.
"""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plugin-root', type=Path, default=ROOT / 'build/companion/local/transcripted')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tc-panel-handshake-') as temporary:
        environment = dict(os.environ, TRANSCRIPTED_DATA_DIR=temporary,
                           TRANSCRIPTED_INDEX_DIR=temporary,
                           TRANSCRIPTED_DISABLE_FILE_LOGGER='1')
        process = subprocess.Popen(['/bin/bash', str(args.plugin_root / 'scripts/launch.sh')],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True, env=environment)
        sequence = 0

        def request(method, params):
            nonlocal sequence
            sequence += 1
            process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': sequence,
                                            'method': method, 'params': params}) + '\n')
            process.stdin.flush()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if not select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                    break
                line = process.stdout.readline()
                if not line:
                    raise RuntimeError('Helper exited before replying')
                reply = json.loads(line)
                if reply.get('id') == sequence:
                    assert 'error' not in reply, reply.get('error')
                    return reply['result']
            raise RuntimeError('Helper did not reply')

        try:
            request('initialize', {'protocolVersion': '2025-11-25',
                                   'clientInfo': {'name': 'panel-handshake-fixture', 'version': '1'},
                                   'capabilities': {'experimental': {
                                       'io.modelcontextprotocol/ui': {'mimeTypes': ['text/html;profile=mcp-app']},
                                       'openai/ui': {'entrypoints': ['global', 'thread']}}}})
            process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
            process.stdin.flush()
            tools = request('tools/list', {})
            assert any(tool['name'] == 'show_companion' for tool in tools['tools'])
            resource = request('resources/read', {'uri': 'ui://transcripted/companion.html'})
            content = resource['contents'][0]
            assert content['mimeType'] == 'text/html;profile=mcp-app'
            assert 'ui/initialize' in content['text']
            print(json.dumps({'panel_handshake': 'passed', 'tool_discovery': 'passed',
                              'html_resource': 'passed', 'visual_panel_verified': False}))
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    main()
