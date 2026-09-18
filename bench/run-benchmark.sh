#!/usr/bin/env bash
# Measure whether routing actually saves usage, by running the same task twice:
#
#   A. baseline  — one model, no subagents        ([agents].enabled = false)
#   B. routed    — the orchestrator roles enabled ([agents].enabled = true)
#
# Each run is a real `codex exec` against a throwaway copy of the task repo, in an isolated
# CODEX_HOME so the comparison cannot be polluted by session history. `codex exec` is used here
# *only* for measurement; the interactive `codex` TUI remains the actual interface.
#
# The metric that matters is usage per SUCCESSFUL task, not the smallest token count: a cheap run
# that fails costs more than an expensive run that works.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="$PROJECT_DIR/bench"
TASKS_DIR="$BENCH_DIR/tasks"
RESULTS_DIR="${CODEX_ORCHESTRATOR_BENCH_RESULTS:-$BENCH_DIR/results}"
REAL_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

TASKS=()
ARMS="baseline routed"
REPEATS=1
for arg in "$@"; do
  case "$arg" in
    --task=*) TASKS+=("${arg#*=}") ;;
    --arms=*) ARMS="${arg#*=}" ;;
    --repeats=*) REPEATS="${arg#*=}" ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}"
      echo
      echo "Usage: run-benchmark.sh [--task=NAME]... [--arms='baseline routed'] [--repeats=N]"
      echo "Tasks available: $(ls "$TASKS_DIR" 2>/dev/null | tr '\n' ' ')"
      exit 0
      ;;
    *) echo "run-benchmark.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ ${#TASKS[@]} -eq 0 ]]; then
  mapfile -t TASKS < <(ls "$TASKS_DIR")
fi

command -v codex >/dev/null || { echo "codex not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "this benchmark needs jq" >&2; exit 1; }

mkdir -p "$RESULTS_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RESULTS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# An isolated CODEX_HOME per arm: auth is copied in, everything else starts empty so token counts
# are not skewed by an existing history or by another arm's sessions.
make_home() {
  local arm="$1" home="$2"
  mkdir -p "$home"
  cp "$REAL_CODEX_HOME/auth.json" "$home/auth.json" 2>/dev/null || true
  cp "$REAL_CODEX_HOME/models_cache.json" "$home/models_cache.json" 2>/dev/null || true
  {
    echo 'approvals_reviewer = "user"'
    echo 'model_reasoning_effort = "medium"'
    # Trust the scratch repo so the run is not blocked on a trust prompt.
    echo "[projects.\"$3\"]"
    echo 'trust_level = "trusted"'
    echo
    if [[ "$arm" == "routed" ]]; then
      echo '[agents]'
      echo 'enabled = true'
      echo 'max_concurrent_threads_per_session = 4'
      echo 'max_depth = 1'
    else
      echo '[agents]'
      echo 'enabled = false'
    fi
  } >"$home/config.toml"
  if [[ "$arm" == "routed" ]]; then
    mkdir -p "$home/agents" "$home/skills"
    cp "$REAL_CODEX_HOME"/agents/*.toml "$home/agents/" 2>/dev/null || true
    cp -a "$REAL_CODEX_HOME/skills/codex-orchestrator-routing" "$home/skills/" 2>/dev/null || true
    # The always-on routing policy the installer appends to the real AGENTS.md.
    if [[ -f "$REAL_CODEX_HOME/AGENTS.md" ]]; then
      cp "$REAL_CODEX_HOME/AGENTS.md" "$home/AGENTS.md"
    fi
  fi
}

# Pull whatever usage Codex actually exposes out of the JSONL event stream. Fields that this
# Codex build does not emit are reported as null rather than guessed at.
summarize() {
  local events="$1" arm="$2" task="$3" repeat="$4" seconds="$5" verdict="$6"
  jq -s --arg arm "$arm" --arg task "$task" --arg repeat "$repeat" \
        --arg seconds "$seconds" --arg verdict "$verdict" '
    def num(f): [ .[] | f | numbers ] | if length == 0 then null else max end;
    def lastnum(f): [ .[] | f | numbers ] | if length == 0 then null else .[-1] end;
    {
      task: $task,
      arm: $arm,
      repeat: ($repeat | tonumber),
      wall_seconds: ($seconds | tonumber),
      verdict: $verdict,
      models_used: ([ .[] | .. | objects | select(has("model")) | .model | strings ] | unique),
      reasoning_efforts_used: (
        [ .[] | .. | objects | select(has("reasoning_effort")) | .reasoning_effort | strings ]
        | unique
      ),
      agents_spawned: (
        [ .[] | .. | objects | select(.tool? == "spawn_agent" or .toolName? == "spawn_agent") ]
        | length
      ),
      input_tokens: num(.. | objects | .input_tokens? // .inputTokens?),
      cached_input_tokens: num(.. | objects | .cached_input_tokens? // .cachedInputTokens?),
      output_tokens: num(.. | objects | .output_tokens? // .outputTokens?),
      reasoning_tokens: num(.. | objects | .reasoning_output_tokens? // .reasoningOutputTokens?),
      total_tokens: num(.. | objects | .total_tokens? // .totalTokens?),
      retries: ([ .[] | .. | objects | select(.type? == "error" or .kind? == "error") ] | length),
      final_message: lastnum(.nothing) // (
        [ .[] | .. | objects | select(.type? == "item.completed")
          | .item? | objects | select(.type? == "agent_message") | .text? | strings ]
        | last // ""
      )
    }' "$events"
}

RESULT_JSONL="$RUN_DIR/results.jsonl"
: >"$RESULT_JSONL"

for task in "${TASKS[@]}"; do
  task_dir="$TASKS_DIR/$task"
  [[ -d "$task_dir" ]] || { echo "no such task: $task" >&2; exit 1; }
  prompt_file="$task_dir/PROMPT.txt"
  [[ -f "$prompt_file" ]] || { echo "task $task has no PROMPT.txt" >&2; exit 1; }

  for arm in $ARMS; do
    for ((repeat = 1; repeat <= REPEATS; repeat++)); do
      say "$task / $arm / run $repeat"
      work="$RUN_DIR/$task.$arm.$repeat"
      mkdir -p "$work"
      repo="$work/repo"
      cp -a "$task_dir/repo" "$repo"
      (cd "$repo" && git init -q && git add -A && git -c user.email=b@e -c user.name=bench commit -qm base)

      home="$work/codex-home"
      make_home "$arm" "$home" "$repo"

      events="$work/events.jsonl"
      start="$(date +%s)"
      set +e
      CODEX_HOME="$home" codex exec \
        --cd "$repo" \
        --json \
        --skip-git-repo-check \
        --dangerously-bypass-approvals-and-sandbox \
        "$(cat "$prompt_file")" >"$events" 2>"$work/stderr.log"
      exec_status=$?
      set -e
      end="$(date +%s)"

      verdict="fail"
      if [[ $exec_status -eq 0 ]] && [[ -x "$task_dir/check.sh" ]]; then
        if (cd "$repo" && "$task_dir/check.sh" >"$work/check.log" 2>&1); then
          verdict="pass"
        fi
      elif [[ $exec_status -eq 0 ]]; then
        verdict="ran"
      fi

      summarize "$events" "$arm" "$task" "$repeat" "$((end - start))" "$verdict" \
        >>"$RESULT_JSONL"
      echo "    -> $verdict in $((end - start))s"
    done
  done
done

say "Summary"
jq -s -r '
  group_by(.task + "/" + .arm)
  | map({
      key: (.[0].task + " / " + .[0].arm),
      runs: length,
      passed: ([ .[] | select(.verdict == "pass") ] | length),
      models: ([ .[] | .models_used[] ] | unique | join(",")),
      efforts: ([ .[] | .reasoning_efforts_used[] ] | unique | join(",")),
      agents: ([ .[] | .agents_spawned ] | add),
      total_tokens: ([ .[] | .total_tokens | numbers ] | if length == 0 then null else add end),
      wall_seconds: ([ .[] | .wall_seconds ] | add)
    })
  | (["task/arm","runs","passed","tokens","seconds","agents","models","efforts"] | @tsv),
    (.[] | [ .key, .runs, .passed, (.total_tokens // "n/a"), .wall_seconds, .agents, .models, .efforts ] | @tsv)
' "$RESULT_JSONL" | column -t -s"$(printf '\t')"

echo
echo "Raw results: $RESULT_JSONL"
echo "Per-run artifacts (events, diffs, check logs): $RUN_DIR"
echo
echo "Read this as usage per SUCCESSFUL task: compare tokens only across arms with the same"
echo "'passed' count. A cheaper arm that failed did not save anything."
