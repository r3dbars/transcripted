#!/usr/bin/env python3
"""Fixture-only preview: real MCP resource/tools, invented native socket, simulated host.

No Mac app, microphone, system capture, production preferences, or personal library.
Run: python3 companion_preview.py --binary /path/to/transcripted-mcp --port 8767
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True)
parser.add_argument("--port", type=int, default=8767)
options = parser.parse_args()
binary = Path(options.binary).resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix="tc-preview-", dir="/private/tmp"))
os.chmod(root, 0o700)
for name in ["data/meetings", "data/dictations", "data/writing", "index", "companion"]:
    (root / name).mkdir(parents=True, exist_ok=True, mode=0o700)
fixture = """---
title: \"Sample launch planning\"
date: 2026-09-30
time: 10:00:00
duration: \"4m 0s\"
sources: [mic, system_audio]
speakers:
  - id: \"0\"
    channel: system
    name: \"Sample colleague\"
---
# Sample launch planning
## Full Transcript
[00:00] [Mic/You] This is an invented meeting for the companion preview.

[00:12] [System/Sample colleague] We decided to test the invitation screen with three volunteers.

[00:25] [Mic/You] I will prepare the sample invitation tomorrow.
"""
(root / "data/meetings/Call_2026-09-30_10-00-00.md").write_text(fixture)
native = {"available": True, "capture_active": False, "session_id": None, "sharing_enabled": False, "segments": [],
          "snapshot_counter": 0, "session_started_at": None, "latest_text_at": None, "live_read_count": 0}
# Invented source times advance deterministically; they are not recording clocks.
fixture_epoch = 1_790_787_600.0
native_lock = threading.Lock()
token = uuid.uuid4().hex + uuid.uuid4().hex
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(str(root / "companion/s"))
os.chmod(root / "companion/s", 0o600)
listener.listen(8)
(root / "companion/connection.json").write_text(json.dumps({"protocol_version": 1, "socket_path": str(root / "companion/s"), "token": token}))
os.chmod(root / "companion/connection.json", 0o600)

def status():
    native["snapshot_counter"] += 1
    snapshot = fixture_epoch + native["snapshot_counter"]
    count = len(native["segments"])
    return {"companion_enabled": True, "allow_meeting_control": True, "allow_live_sharing": True,
            "capture_active": native["capture_active"], "session_id": native["session_id"], "sharing_enabled": native["sharing_enabled"],
            "recording_state": "recording" if native["capture_active"] else "ready", "state": "listening" if native["capture_active"] else "idle",
            "first_sequence": 1 if count else 0, "latest_sequence": count, "provisional": True,
            "snapshot_at_unix_seconds": snapshot, "session_started_at_unix_seconds": native["session_started_at"],
            "latest_text_at_unix_seconds": native["latest_text_at"],
            "capture_elapsed_seconds": max(0, snapshot - native["session_started_at"]) if native["session_started_at"] is not None else 0,
            "latest_text_audio_end_seconds": native["segments"][-1]["end_seconds"] if count else None,
            "preview_lag_seconds": 8.5, "pending_windows": 1, "dropped_windows": 2, "dropped_audio_buffers": 1, "context_gap": True,
            "live_status": "listening" if native["capture_active"] else "idle"}

def native_call(request):
    def failed(code):
        return {"version": 1, "id": request.get("id"), "ok": False, "error": {"code": code, "message": "Synthetic preview refusal"}}
    if request.get("token") != token:
        return failed("auth_failed")
    with native_lock:
        if not native["available"]:
            return failed("companion_unavailable")
        method, args = request.get("method"), request.get("params", {})
        if method == "start_meeting":
            if native["capture_active"]:
                return failed("capture_busy")
            native.update(capture_active=True, session_id=str(uuid.uuid4()), sharing_enabled=False, segments=[],
                          session_started_at=fixture_epoch + native["snapshot_counter"], latest_text_at=None, live_read_count=0)
            result = dict(status(), started=True)
        elif method == "status":
            result = status()
        elif method in ["stop_meeting", "read_live_transcript", "set_live_sharing"]:
            if args.get("session_id") != native["session_id"] or not native["capture_active"]:
                return failed("stale_session")
            if method == "stop_meeting":
                native.update(capture_active=False, sharing_enabled=False)
                result = dict(status(), stopped=True)
            elif method == "set_live_sharing":
                native["sharing_enabled"] = args.get("enabled") is True
                result = status()
            else:
                if not native["sharing_enabled"]:
                    return failed("permission_denied")
                native["live_read_count"] += 1
                texts = ["This is synthetic live text, not a real recording.", "We decided to keep the sample pilot small.", "The sample owner will invite three volunteers."]
                if len(native["segments"]) < len(texts):
                    index = len(native["segments"])
                    native["segments"].append({"sequence": index + 1, "start_seconds": index * 12, "end_seconds": index * 12 + 7,
                        "source": "microphone" if index % 2 == 0 else "system", "text": texts[index], "provisional": True})
                    native["latest_text_at"] = fixture_epoch + native["snapshot_counter"]
                segments = [s for s in native["segments"] if s["sequence"] > args.get("after_sequence", 0)][:args.get("limit", 20)]
                result = dict(status(), segments=segments, next_sequence=segments[-1]["sequence"] if segments else args.get("after_sequence", 0), truncated=False)
                if native["live_read_count"] == 1:
                    result["error_code"] = "inference_failed"
        else:
            return failed("unknown_method")
        return {"version": 1, "id": request.get("id"), "ok": True, "result": result}

def serve_native():
    while True:
        try:
            connection, _ = listener.accept()
        except OSError:
            return
        with connection:
            connection.settimeout(5)
            stream = connection.makefile("rb")
            try:
                request = json.loads(stream.readline(32769))
                connection.sendall(json.dumps(native_call(request)).encode() + b"\n")
            except (ValueError, OSError):
                pass

threading.Thread(target=serve_native, daemon=True).start()
environment = {k: v for k, v in os.environ.items() if not k.startswith("TRANSCRIPTED_") and not k.startswith("POSTHOG_")}
environment.update(TRANSCRIPTED_CONTAINER_DIR=str(root), TRANSCRIPTED_DATA_DIR=str(root / "data"), TRANSCRIPTED_INDEX_DIR=str(root / "index"), TRANSCRIPTED_DISABLE_FILE_LOGGER="1", TRANSCRIPTED_MCP_COMPANION_MODE="1")
process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment, text=True)
rpc_lock, sequence = threading.Lock(), 0

def rpc(method, params):
    global sequence
    with rpc_lock:
        sequence += 1
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}) + "\n")
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            if not line:
                raise RuntimeError("Isolated MCP helper stopped")
            result = json.loads(line)
            if result.get("id") == sequence:
                if "error" in result:
                    raise RuntimeError(result["error"].get("message", "MCP error"))
                return result["result"]

rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "Synthetic companion preview", "version": "1"}})
html = rpc("resources/read", {"uri": "ui://transcripted/companion.html"})["contents"][0]["text"]
host_html = """<!doctype html><html><head><meta charset='utf-8'><style>body{margin:0;background:#ededeb;font:13px system-ui}header{padding:12px 18px;background:#262521;color:#fff;display:flex;gap:16px;align-items:center;flex-wrap:wrap}header strong{margin-right:auto}iframe{display:block;border:0;width:100%;min-height:850px}#host-context{padding:12px 20px;white-space:pre-wrap;font:11px ui-monospace;background:#fff;border-top:1px solid #bbb;max-height:200px;overflow:auto}</style></head><body><header><strong>Preview · invented samples only · simulated ChatGPT host</strong><label><input id='preview-dark' type='checkbox'> Dark</label><label><input id='preview-disconnect' type='checkbox'> Disconnect native fixture</label><label><input id='preview-limited' type='checkbox'> Unsupported host</label><label><input id='preview-delay-context' type='checkbox'> Hold next live context update</label><button id='preview-release-context' disabled>Release context update</button><label><input id='preview-delay-live' type='checkbox'> Hold next live read reply</label><button id='preview-release-live' disabled>Release live reply</button></header><iframe id='app' title='Transcripted companion preview' src='/app.html'></iframe><pre id='host-context'>No context attached. No model is connected.</pre><script>
const frame=document.getElementById('app');let attached=null,update=0,heldContext=null,heldLive=null;
const send=m=>frame.contentWindow.postMessage({jsonrpc:'2.0',...m},location.origin);
const capabilities=()=>document.getElementById('preview-limited').checked?{}:{serverTools:{},updateModelContext:{text:{},structuredContent:{}},message:{text:{}},openLinks:{},experimental:{'openai/message':{}}};
const context=()=>({theme:document.getElementById('preview-dark').checked?'dark':'light',displayMode:'fullscreen',availableDisplayModes:['fullscreen'],'openai/modelContext':attached});
async function tool(name,args){const response=await fetch('/tool',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,arguments:args})});if(!response.ok)throw Error(await response.text());return response.json()}
function applyContext(m){attached=m.params.content.length?{updateId:String(++update),structuredContent:m.params.structuredContent}:null;document.getElementById('host-context').textContent=attached?JSON.stringify(m.params,null,2):'No context attached. No model is connected.';send({id:m.id,result:{}});send({method:'ui/notifications/host-context-changed',params:context()})}
window.addEventListener('message',async e=>{if(e.source!==frame.contentWindow||e.data?.jsonrpc!=='2.0')return;const m=e.data;try{
if(m.method==='ui/initialize')send({id:m.id,result:{protocolVersion:'2026-01-26',hostInfo:{name:'Synthetic preview host',version:'1'},hostCapabilities:capabilities(),hostContext:context()}});
else if(m.method==='ui/notifications/initialized')send({method:'ui/notifications/tool-result',params:await tool('show_companion',{})});
else if(m.method==='tools/call'){const result=await tool(m.params.name,m.params.arguments);if(m.params.name==='read_live_transcript'&&document.getElementById('preview-delay-live').checked){heldLive={id:m.id,result};document.getElementById('preview-delay-live').checked=false;document.getElementById('preview-release-live').disabled=false}else send({id:m.id,result})}
else if(m.method==='ui/update-model-context'){if(m.params.structuredContent?.live_meeting&&document.getElementById('preview-delay-context').checked){heldContext=m;document.getElementById('preview-delay-context').checked=false;document.getElementById('preview-release-context').disabled=false}else applyContext(m)}
else if(m.method==='ui/message'){document.getElementById('host-context').textContent='Question payload only — no model is connected.\\n'+JSON.stringify(m.params,null,2);send({id:m.id,result:{}})}
else if(m.method==='ui/open-link'){const url=new URL(m.params.url);send({id:m.id,result:{}});send({method:'ui/notifications/host-context-changed',params:{'openai/deepLink':{url:url.searchParams.get('path')}}})}
else if(m.method==='ui/request-display-mode')send({id:m.id,result:{mode:'fullscreen'}});
else if(m.method==='ui/notifications/size-changed')frame.style.height=Math.max(800,m.params.height+20)+'px';
}catch(error){send({id:m.id,error:{code:-32000,message:error.message}})}});
document.getElementById('preview-dark').onchange=()=>send({method:'ui/notifications/host-context-changed',params:context()});
document.getElementById('preview-disconnect').onchange=async e=>{await fetch('/native-availability',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({available:!e.target.checked})})};
document.getElementById('preview-limited').onchange=()=>frame.src='/app.html?restart='+Date.now();
document.getElementById('preview-release-context').onclick=e=>{if(heldContext){const m=heldContext;heldContext=null;e.target.disabled=true;applyContext(m)}};
document.getElementById('preview-release-live').onclick=e=>{if(heldLive){const m=heldLive;heldLive=null;e.target.disabled=true;send(m)}};
</script></body></html>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def respond(self, status, content, mime="text/html; charset=utf-8"):
        encoded = content.encode()
        self.send_response(status); self.send_header("Content-Type", mime); self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
    def do_GET(self):
        self.respond(200, html if self.path.startswith("/app.html") else host_html)
    def do_POST(self):
        try:
            data = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 65536)))
            if self.path == "/native-availability":
                with native_lock:
                    native["available"] = data.get("available") is True
                self.respond(200, "{}", "application/json")
            elif self.path == "/tool":
                self.respond(200, json.dumps(rpc("tools/call", data)), "application/json")
            else:
                self.respond(404, "Unknown fixture endpoint")
        except Exception as error:
            self.respond(500, str(error), "text/plain")

server = ThreadingHTTPServer(("127.0.0.1", options.port), Handler)
print(f"Fixture-only companion preview: http://127.0.0.1:{options.port} (real MCP; invented native socket; no ChatGPT model)", flush=True)
try:
    server.serve_forever()
finally:
    server.server_close(); listener.close(); process.terminate(); process.wait(timeout=5); shutil.rmtree(root)
