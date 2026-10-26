# lint-fixture-path: scripts/ops/first-launch-smoke.py
import subprocess
from pathlib import Path

safety = subprocess.run(["/usr/bin/python3", str(Path(__file__).with_name("native-smoke-isolation.py"))])
app_binary = Path("build/Transcripted.app") / "Contents/MacOS" / "Transcripted"
if safety.returncode == 0:
    subprocess.Popen([str(app_binary)])
