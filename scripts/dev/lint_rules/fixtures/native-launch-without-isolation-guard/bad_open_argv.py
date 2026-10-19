# lint-fixture-path: scripts/hillclimb/launch_lab.py
import subprocess

def launch(app):
    app = app or "build/Transcripted.app"
    argv = ["open", "-n", "-a", str(app)]
    subprocess.run(argv, check=True)
