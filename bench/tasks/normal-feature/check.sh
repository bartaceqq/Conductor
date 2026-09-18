#!/usr/bin/env bash
set -euo pipefail
python3 -m unittest discover -q
mkdir -p .bench_probe && printf 'x\ny\n' > .bench_probe/f.txt
out="$(python3 counter.py --json .bench_probe)"
rm -rf .bench_probe
python3 - "$out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["files"] == 1, data
assert data["lines"] == 2, data
assert "bytes" in data, data
PY
