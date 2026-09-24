#!/usr/bin/env python3
"""Start `tart run` detached from whoever called transcripted-vm.sh, and log how it ends.

The first real run on a Mac lost its VM a few minutes after boot with nothing in
Tart's log. Tart prints a line for every way the VM can stop on its own (guest
shutdown, Virtualization error, `tart stop`), so a silent end means the tart
process itself was killed from outside (SIGTERM/SIGKILL). Likely culprit: the
tool that ran the script killing its process group or tree when a command
ended or timed out, which took the backgrounded tart with it.

So this helper:
  - starts tart in a new session (its own process group, no terminal), so a
    kill aimed at the caller's group or tree does not reach the VM
  - keeps the Mac from idle-sleeping while the VM runs (caffeinate -i -w)
  - appends one line to the VM log saying exactly how tart ended (exit status
    or signal), plus any signal the helper itself received

The VM script also runs its one long-lived VNC session (vnc.py serve)
through it, with --name "VNC session".

Usage:
  supervise.py --log FILE --pidfile FILE [--name NAME] -- tart run ...
  supervise.py --self-test

Prints the tart pid and returns once tart has started. Stdlib only.
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def note(log, text: str) -> None:
    log.write(f"[tvm {stamp()}] {text}\n")
    log.flush()


def describe(status: int, name_of: str = "tart") -> str:
    if status < 0:
        num = -status
        try:
            name = signal.Signals(num).name
        except ValueError:
            name = f"signal {num}"
        why = {
            "SIGKILL": "killed from outside (kill -9, or macOS under memory pressure)",
            "SIGTERM": "killed from outside (kill, pkill, or a tool ending its command)",
            "SIGHUP": "its terminal went away",
        }.get(name, "killed by a signal")
        return f"{name_of} was stopped by {name} ({num}): {why}"
    if status == 0:
        return f"{name_of} exited normally (status 0); see its own lines above for why"
    return f"{name_of} exited with status {status}; see its error above"


def supervise(log_path: str, pidfile: str, cmd: list[str], ready_fd: int, name: str) -> int:
    os.setsid()
    # Don't hold the caller's working directory (say, a checkout) for the VM's life.
    os.chdir("/")
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    with open(log_path, "a", buffering=1) as log:
        try:
            child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        except OSError as error:
            note(log, f"could not start {name}: {error}")
            os.write(ready_fd, b"error\n")
            return 1
        with open(pidfile, "w") as handle:
            handle.write(f"{child.pid}\n")
        note(log, f"{name} started (pid {child.pid}, helper pid {os.getpid()}, own session)")
        os.write(ready_fd, f"{child.pid}\n".encode())
        os.close(ready_fd)

        caffeinate = None
        if shutil.which("caffeinate"):
            caffeinate = subprocess.Popen(["caffeinate", "-i", "-w", str(child.pid)],
                                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL)

        def forward(num, _frame):
            note(log, f"helper got {signal.Signals(num).name}; asking {name} to stop (SIGINT)")
            try:
                child.send_signal(signal.SIGINT)
            except ProcessLookupError:
                pass

        for num in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(num, forward)

        while True:
            try:
                status = child.wait()
                break
            except InterruptedError:
                continue
        note(log, describe(status, name))
        if caffeinate and caffeinate.poll() is None:
            caffeinate.terminate()
        return 0


def start(log_path: str, pidfile: str, cmd: list[str], name: str = "tart") -> int:
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        code = 1
        try:
            code = supervise(log_path, pidfile, cmd, write_fd, name)
        finally:
            os._exit(code)
    os.close(write_fd)
    with os.fdopen(read_fd) as ready:
        answer = ready.readline().strip()
    if not answer.isdigit():
        print(f"could not start {name}; see {log_path}", file=sys.stderr)
        return 1
    print(answer)
    return 0


def wait_for(path: str, text: str, seconds: float = 10) -> str:
    deadline = time.monotonic() + seconds
    content = ""
    while time.monotonic() < deadline:
        with open(path) as handle:
            content = handle.read()
        if text in content:
            return content
        time.sleep(0.05)
    raise AssertionError(f"{text!r} never showed up in the log:\n{content}")


def self_test() -> int:
    me = os.path.abspath(__file__)
    with tempfile.TemporaryDirectory() as tmp:
        log, pidfile = os.path.join(tmp, "vm.log"), os.path.join(tmp, "vm.pid")

        # A clean exit is reported as such.
        open(log, "w").close()
        out = subprocess.run([sys.executable, me, "--log", log, "--pidfile", pidfile, "--", "sh", "-c", "echo booted"],
                             capture_output=True, text=True, check=True)
        assert out.stdout.strip().isdigit(), out
        content = wait_for(log, "exited normally")
        assert "booted" in content and "tart started" in content, content

        # A kill from outside is named, with the signal.
        open(log, "w").close()
        out = subprocess.run([sys.executable, me, "--log", log, "--pidfile", pidfile, "--", "sleep", "30"],
                             capture_output=True, text=True, check=True)
        pid = int(out.stdout.strip())
        assert open(pidfile).read().strip() == str(pid)
        # The VM process must not share the caller's process group.
        assert os.getpgid(pid) != os.getpgid(0), "tart shares the caller's process group"
        os.kill(pid, signal.SIGTERM)
        wait_for(log, "stopped by SIGTERM")

        # A signal to the helper is logged and turned into a graceful SIGINT.
        open(log, "w").close()
        out = subprocess.run([sys.executable, me, "--log", log, "--pidfile", pidfile, "--", "sleep", "30"],
                             capture_output=True, text=True, check=True)
        pid = int(out.stdout.strip())
        helper = os.getpgid(pid)  # the helper leads the new session and group
        os.kill(helper, signal.SIGTERM)
        content = wait_for(log, "stopped by SIGINT")
        assert "helper got SIGTERM" in content, content

        # A command that cannot start fails loudly.
        open(log, "w").close()
        out = subprocess.run([sys.executable, me, "--log", log, "--pidfile", pidfile, "--", os.path.join(tmp, "missing")],
                             capture_output=True, text=True)
        assert out.returncode != 0 and "could not start" in open(log).read(), out
    print("supervise self-test: ok")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", required=True)
    parser.add_argument("--pidfile", required=True)
    parser.add_argument("--name", default="tart", help="what the log calls the process (default tart)")
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
    if not cmd:
        parser.error("give the command after --")
    return start(os.path.abspath(args.log), os.path.abspath(args.pidfile), cmd, args.name)


if __name__ == "__main__":
    sys.exit(main())
