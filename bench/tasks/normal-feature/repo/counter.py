"""Count files, lines and bytes under a directory."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def collect(root: Path) -> dict[str, int]:
    files = lines = size = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = Path(dirpath) / name
            files += 1
            size += path.stat().st_size
            with path.open("rb") as handle:
                lines += sum(1 for _ in handle)
    return {"files": files, "lines": lines, "bytes": size}


def format_report(stats: dict[str, int]) -> str:
    return (
        f"files: {stats['files']}\n"
        f"lines: {stats['lines']}\n"
        f"bytes: {stats['bytes']}"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="counter")
    parser.add_argument("root", type=Path)
    args = parser.parse_args(argv)
    print(format_report(collect(args.root)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
