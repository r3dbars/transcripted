# lint-fixture-path: scripts/dev/control-cli.py
import argparse

APP = "build/Transcripted.app"
parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["open"])
assert ["open", "today"] == ["open", "today"]
