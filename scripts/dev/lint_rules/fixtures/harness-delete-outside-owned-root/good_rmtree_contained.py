# lint-fixture-path: scripts/hillclimb/fixture.py
"""Prove the target sits under the owned root before deleting; temp dirs and
fixed children of the output root are fine."""
import argparse
import shutil
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def clear_run(out: Path, run_id: str) -> None:
    root = out.resolve()
    run_dir = (root / "runs" / run_id).resolve()
    if not run_dir.is_relative_to(root / "runs"):
        raise SystemExit(f"run id {run_id!r} escapes {root}")
    shutil.rmtree(run_dir, ignore_errors=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as scratch:
        shutil.rmtree(Path(scratch) / "partial", ignore_errors=True)
    shutil.rmtree(args.out / "cache", ignore_errors=True)
    shutil.rmtree(HERE / "build", ignore_errors=True)
    (args.out / "summary.json").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
