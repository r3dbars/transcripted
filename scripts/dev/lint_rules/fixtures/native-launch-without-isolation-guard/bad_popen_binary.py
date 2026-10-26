# lint-fixture-path: scripts/ops/first-launch-smoke.py
import subprocess
from pathlib import Path

app_binary = Path("build/Transcripted.app") / "Contents/MacOS" / "Transcripted"
process = subprocess.Popen(
    [str(app_binary)],
    env={"HOME": "/tmp/x"},
)
