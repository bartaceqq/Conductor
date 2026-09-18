#!/usr/bin/env python3
"""Drive the real interactive Codex TUI through a pseudo-terminal.

Used for the acceptance tests: they have to exercise `codex` itself, not `codex exec`, so we give
it a real PTY, type into it, and record everything it renders. The raw byte log keeps the ANSI
sequences; the ``--plain`` log strips them so assertions can be made on readable text.

Script format (one directive per line, ``#`` comments ignored):

    send: <text>          type the text and press Enter
    type: <text>          type the text without pressing Enter
    key: <name>           enter | esc | ctrl-c | ctrl-d | tab | up | down
    wait: <regex>         block until the regex appears in the output (see --timeout)
    waitfor: <secs> <re>  same, with an explicit timeout
    sleep: <secs>         wait unconditionally
    mark: <label>         write a labelled marker into both logs
    quit                  send Ctrl+C twice and stop
"""

from __future__ import annotations

import argparse
import errno
import os
import pty
import re
import select
import shutil
import signal
import sys
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")

KEYS = {
    "enter": b"\r",
    "esc": b"\x1b",
    "ctrl-c": b"\x03",
    "ctrl-d": b"\x04",
    "ctrl-t": b"\x14",
    "tab": b"\t",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "left": b"\x1b[D",
    "right": b"\x1b[C",
    "backspace": b"\x7f",
}


class Session:
    def __init__(self, argv: list[str], cwd: str, env: dict[str, str], cols: int, rows: int):
        self.buffer = bytearray()
        self.raw_log = bytearray()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # child
            os.chdir(cwd)
            os.environ.clear()
            os.environ.update(env)
            os.environ["COLUMNS"] = str(cols)
            os.environ["LINES"] = str(rows)
            os.execvp(argv[0], argv)
        self._set_winsize(cols, rows)

    def _set_winsize(self, cols: int, rows: int) -> None:
        import fcntl
        import struct
        import termios

        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            try:
                ready, _, _ = select.select([self.fd], [], [], min(0.2, max(remaining, 0.01)))
            except OSError:
                return
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError as err:
                if err.errno == errno.EIO:
                    return
                raise
            if not chunk:
                return
            self.buffer.extend(chunk)
            self.raw_log.extend(chunk)

    def wait_for(self, pattern: str, timeout: float) -> bool:
        regex = re.compile(pattern.encode(), re.IGNORECASE)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if regex.search(strip_ansi(bytes(self.buffer))):
                return True
            self.pump(0.3)
        return bool(regex.search(strip_ansi(bytes(self.buffer))))

    def write(self, data: bytes) -> None:
        os.write(self.fd, data)
        # Give the TUI a beat to echo before the next directive races it.
        self.pump(0.25)

    def note(self, label: str) -> None:
        marker = f"\n===== {label} =====\n".encode()
        self.raw_log.extend(marker)

    def close(self) -> None:
        try:
            os.write(self.fd, b"\x03")
            self.pump(0.6)
            os.write(self.fd, b"\x03")
            self.pump(1.2)
        except OSError:
            pass
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        self.pump(0.8)
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pass


def strip_ansi(data: bytes) -> bytes:
    return ANSI.sub(b"", data).replace(b"\r", b"\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--codex-home")
    parser.add_argument("--out", required=True, help="path for the raw log; .txt gets the plain log")
    parser.add_argument("--cols", type=int, default=120)
    parser.add_argument("--rows", type=int, default=45)
    parser.add_argument("--timeout", type=float, default=300.0, help="default wait timeout")
    parser.add_argument("--codex", default=shutil.which("codex") or "codex")
    args = parser.parse_args()

    env = dict(os.environ)
    if args.codex_home:
        env["CODEX_HOME"] = args.codex_home
    env.setdefault("TERM", "xterm-256color")
    # Keep the recording readable and deterministic.
    env["NO_COLOR"] = "1"
    env["CODEX_DISABLE_ANIMATIONS"] = "1"

    directives = []
    with open(args.script, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            directives.append(line)

    session = Session([args.codex], args.cwd, env, args.cols, args.rows)
    failures: list[str] = []
    try:
        session.pump(3.0)
        for line in directives:
            verb, _, rest = line.partition(":")
            verb = verb.strip().lower()
            rest = rest.strip()
            if verb == "send":
                session.note(f"SEND {rest}")
                session.write(rest.encode() + b"\r")
            elif verb == "type":
                session.note(f"TYPE {rest}")
                session.write(rest.encode())
            elif verb == "key":
                key = KEYS.get(rest.lower())
                if key is None:
                    raise SystemExit(f"unknown key: {rest}")
                session.note(f"KEY {rest}")
                session.write(key)
            elif verb == "wait":
                session.note(f"WAIT {rest}")
                if not session.wait_for(rest, args.timeout):
                    failures.append(f"timed out waiting for: {rest}")
            elif verb == "waitfor":
                secs, _, pattern = rest.partition(" ")
                session.note(f"WAIT {pattern} ({secs}s)")
                if not session.wait_for(pattern.strip(), float(secs)):
                    failures.append(f"timed out waiting for: {pattern.strip()}")
            elif verb == "sleep":
                session.note(f"SLEEP {rest}")
                session.pump(float(rest))
            elif verb == "mark":
                session.note(rest)
            elif verb == "quit" or line.strip().lower() == "quit":
                break
            else:
                raise SystemExit(f"unknown directive: {line}")
    finally:
        session.close()
        with open(args.out, "wb") as handle:
            handle.write(bytes(session.raw_log))
        plain = args.out + ".txt" if not args.out.endswith(".txt") else args.out + ".plain.txt"
        with open(plain, "wb") as handle:
            handle.write(strip_ansi(bytes(session.raw_log)))
        print(f"raw log   : {args.out}")
        print(f"plain log : {plain}")

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
