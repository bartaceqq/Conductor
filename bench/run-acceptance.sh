#!/usr/bin/env bash
# Drive the acceptance tests through the real interactive Codex TUI in a pseudo-terminal.
#
# These are not `codex exec` runs: `bench/tui-drive.py` starts `codex` itself, types into it, and
# records what it renders, so the `/effort` output captured here is the real TUI output.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCEPT_DIR="$PROJECT_DIR/bench/acceptance"
OUT_ROOT="${CODEX_ORCHESTRATOR_ACCEPTANCE_OUT:-$PROJECT_DIR/bench/acceptance-runs}"
WORK_ROOT="${CODEX_ORCHESTRATOR_ACCEPTANCE_WORK:-$(mktemp -d)}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$OUT_ROOT/$RUN_ID"
mkdir -p "$OUT_DIR"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

run_case() {
  local name="$1" script="$2" workdir="$3" timeout="${4:-600}"
  say "$name  (cwd: $workdir)"
  python3 "$PROJECT_DIR/bench/tui-drive.py" \
    --script "$script" \
    --cwd "$workdir" \
    --out "$OUT_DIR/$name.raw" \
    --timeout "$timeout"
  local status=$?
  echo "    exit: $status"
  return $status
}

prepare_repo() {
  local task="$1" dest="$2"
  rm -rf "$dest"
  cp -a "$PROJECT_DIR/bench/tasks/$task/repo" "$dest"
  find "$dest" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
  (cd "$dest" && git init -q && git add -A \
    && git -c user.email=acceptance@local -c user.name=acceptance commit -qm baseline)
}

CASES=("$@")
if [[ ${#CASES[@]} -eq 0 ]]; then
  CASES=(a c e)
fi

for case_name in "${CASES[@]}"; do
  case "$case_name" in
    a)
      prepare_repo trivial-string "$WORK_ROOT/a-trivial"
      run_case a-trivial "$ACCEPT_DIR/a-trivial.txt" "$WORK_ROOT/a-trivial" 600
      say "check.sh for A"
      (cd "$WORK_ROOT/a-trivial" && bash "$PROJECT_DIR/bench/tasks/trivial-string/check.sh" \
        && echo "    A: PASS" || echo "    A: FAIL")
      (cd "$WORK_ROOT/a-trivial" && git diff) >"$OUT_DIR/a-trivial.diff"
      ;;
    c)
      prepare_repo hard-leak "$WORK_ROOT/c-hard"
      run_case c-hard "$ACCEPT_DIR/c-hard.txt" "$WORK_ROOT/c-hard" 1200
      say "check.sh for C"
      (cd "$WORK_ROOT/c-hard" && bash "$PROJECT_DIR/bench/tasks/hard-leak/check.sh" \
        && echo "    C: PASS" || echo "    C: FAIL")
      (cd "$WORK_ROOT/c-hard" && git diff) >"$OUT_DIR/c-hard.diff"
      ;;
    e)
      prepare_repo env-failure "$WORK_ROOT/e-env"
      run_case e-env "$ACCEPT_DIR/e-environment.txt" "$WORK_ROOT/e-env" 600
      say "check.sh for E"
      (cd "$WORK_ROOT/e-env" && bash "$PROJECT_DIR/bench/tasks/env-failure/check.sh" \
        && echo "    E: PASS (project left alone)" || echo "    E: FAIL (project was modified)")
      (cd "$WORK_ROOT/e-env" && git diff) >"$OUT_DIR/e-env.diff"
      ;;
    frostos)
      run_case investigate-frostos "$ACCEPT_DIR/investigate-frostos.txt" "$HOME/FrostOS" 1200
      ;;
    *)
      echo "unknown case: $case_name" >&2
      exit 2
      ;;
  esac
done

echo
say "Transcripts"
ls -la "$OUT_DIR"
echo
echo "Plain-text transcripts end in .raw.txt; grep them for '/effort' to see the captured output."
