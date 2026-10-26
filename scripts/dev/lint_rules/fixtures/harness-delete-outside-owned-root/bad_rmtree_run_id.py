# lint-fixture-path: scripts/hillclimb/fixture.py
"""A lab that clears a run folder named by --run-id: `--run-id ..` clears the parent."""
import argparse
import shutil
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    run_dir = args.out / "runs" / args.run_id
    shutil.rmtree(run_dir, ignore_errors=True)
    run_dir.mkdir(parents=True)


if __name__ == "__main__":
    main()
