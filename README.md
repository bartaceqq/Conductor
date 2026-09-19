# Conductor

A patched OpenAI Codex CLI that adds a **native `/effort` slash command**, plus a small set of
agent roles and a routing policy that make Codex spend a cheap model on cheap subtasks and an
expensive one only where it earns its keep.

The command is still `codex`. The interface is still the real Codex TUI. Nothing is replaced.

```
$ codex

› investigate and fix the FPS drop after repeatedly opening apps

• Spawned explorer_low
• Spawned debugger_high

› /effort

Model / reasoning status

Role            Model          Effort  State
────────────────────────────────────────────────
parent          gpt-6-astra    medium  working
explorer_low    gpt-5.6-luna   low     working
debugger_high   gpt-5.6-sol    high    working

Auto-routing: enabled · Active workers: 2/4
```

---

## Contents

- [Architecture](#architecture)
- [`/effort`](#effort)
- [How model and effort actually resolve](#how-model-and-effort-actually-resolve)
- [Agent roles](#agent-roles)
- [Routing rules](#routing-rules)
- [Installation](#installation)
- [Rollback](#rollback)
- [Upgrading](#upgrading)
- [Benchmarks](#benchmarks)
- [Limitations](#limitations)
- [Files this patch touches](#files-this-patch-touches)

## Quickstart / Download

Conductor uses a unified installation script that automatically supports **Windows (via Git Bash or WSL)**, **macOS**, and **Linux (Debian, Arch, Ubuntu, etc.)**.

### Prerequisites
- [Git](https://git-scm.com/)
- [Rust & Cargo](https://rustup.rs/)

### Installation

Run the following commands in your terminal (or Git Bash on Windows):

```bash
git clone https://github.com/bartaceqq/Conductor.git
cd Conductor
./install.sh
```

Ensure that `~/.local/bin` is in your `PATH` and restart your shell (or run `rehash` if using zsh) so the newly built `codex` command takes precedence over the original one.

---

## Architecture

### Why subagents, and not model hot-swapping

A model invocation is a single request with a single model and a single reasoning effort. There is
no way to change the model halfway through a turn that is already streaming, and pretending
otherwise would just mean cancelling and restarting the turn — which loses the work and costs more
than it saves.

So per-subtask model selection has to happen at a boundary where a *new* request starts. Codex
already has exactly such a boundary: **subagents**. `spawn_agent` creates a new thread with its own
resolved configuration, including its own model and reasoning effort, and runs it concurrently with
the parent. That is the mechanism this project uses.

```
       user task
           │
        PARENT  (general tier, orchestrates, does trivial work itself)
           │
           ├── explorer_low       cheap / low     read-only investigation   ┐
           ├── explorer_low       cheap / low     read-only investigation   ├ parallel
           ├── verifier_low       cheap / low     build · test · classify   ┘
           │
           ├── debugger_high      strong / high   root cause, only if unknown
           │
           └── implementer_medium general / medium  the actual edit          (serialised)
```

Three layers make this happen, in increasing order of reliability:

| layer | what it does | how reliable |
|---|---|---|
| routing skill | teaches the parent when and how to delegate | model-dependent (skill triggers on relevance) |
| `~/.codex/AGENTS.md` managed block | always-on summary of the same policy | always in context, still advisory |
| **agent role config files** | **fix each role's model and effort** | **enforced by Codex, not by the prompt** |

The last layer is the one that matters. A role's `model` and `model_reasoning_effort` are applied
by Codex when the child thread is built; the model cannot override them, and Codex tells the parent
so in the spawn tool description ("This role's model is set to `…` and cannot be changed"). The
prompt layers only decide *which* role gets spawned.

### Why the parent is not the strongest model

The parent reads the repository, holds the conversation, and coordinates. Broad reading is exactly
what a cheap tier is for, and the parent delegates it. Making the parent the most expensive model
means paying frontier prices for coordination tokens. The default here leaves the parent on
whatever you already chose in `/model`; the roles do the tier work.

---

## `/effort`

`/effort` is a real native slash command in the Codex TUI — a variant of the same `SlashCommand`
enum that backs `/model`, `/status` and `/agents`. It appears in slash autocomplete, renders with
native TUI history cells, and **never sends a model request**.

### What it shows

For every agent it lists the **effective** model and reasoning effort — the values Codex resolved
after spawn arguments, `[agents]` defaults, parent inheritance and role config files were all
applied. A worker that inherited both values from the parent is annotated `inherited`.

```
Role            Model          Effort  State
────────────────────────────────────────────────
parent          gpt-6-astra    medium  working
explorer        gpt-6-astra    medium  working   inherited
debugger_high   gpt-5.6-sol    high    working
verifier_low    gpt-5.6-luna   low     idle
```

States come from the live thread status Codex tracks:

| label | meaning |
|---|---|
| `working` | a turn is running |
| `waiting` | blocked waiting for user input |
| `approval` | blocked on a command/file approval |
| `idle` | loaded, no turn running (a finished-but-open subagent reads as idle) |
| `failed` | the thread reported a system error |
| `closed` | the thread is no longer loaded (only shown by `/effort all`) |
| `unknown` | the live read failed; the row fell back to this session's own values |

### Subcommands

| command | shows |
|---|---|
| `/effort` | parent + subagents that are still open |
| `/effort all` | parent + every subagent this session spawned, including closed ones |
| `/effort parent` | parent only |
| `/effort agents` | subagents only |
| `/effort low\|medium\|high\|xhigh\|max` | sets the **parent's** reasoning effort for **future** turns |

`/effort <level>` goes through the same path as `/model`'s reasoning picker and the `Alt+,` /
`Alt+.` shortcuts. It does not — and cannot — change a model invocation that is already running.

### It works while agents are busy

`/effort` is marked `available_during_task`, so the composer accepts it mid-turn. It is safe to
exempt because it only reads: it issues `thread/read` and `thread/list`, both of which are
read-only app-server requests, and `thread/list` is not serialised behind the running turn at all.
Nothing is cancelled, nothing is interrupted, and no worker is disturbed.

### Where the numbers come from

This is the part that matters for trusting the output.

`/effort` does **not** read `config.toml`, and does **not** read the agent role `.toml` files, and
does **not** infer anything from role names. It asks the running app server:

- `thread/read` for the session's root thread,
- `thread/list` with `ancestorThreadId = <root>` and `sourceKinds = ["subAgentThreadSpawn"]` for the
  subagents.

For every thread that is currently loaded, the app server fills `model` and `reasoningEffort` from
that thread's live `ThreadConfigSnapshot` (`codex-rs/app-server/src/request_processors.rs`,
`apply_live_thread_settings`) — the same struct the spawn handler consults to report a worker's
effective configuration. If the parent read fails, the parent row falls back to the values this TUI
last applied and the output says so; it never silently invents a value. A value the runtime did not
report renders as `—`.

---

## How model and effort actually resolve

Read from the 0.155.0 source (`codex-rs/core/src/tools/handlers/multi_agents/spawn.rs` and
`multi_agents_common.rs`), the V1 spawn path resolves a child's configuration in this order, each
step overriding the previous one:

1. **Parent inheritance.** `build_agent_spawn_config` clones the parent turn's config, so the child
   starts at the parent's model and the parent's effort (or the parent model's default effort).
2. **Explicit spawn arguments**, falling back to `[agents].default_subagent_model` and
   `[agents].default_subagent_reasoning_effort`. Note the subtlety: if a *model* is selected here
   without an effort, the effort becomes **that model's** default reasoning level, not the parent's.
3. **The agent role's config file** — `model`, `model_reasoning_effort`, `developer_instructions`,
   `personality`, `service_tier`, `model_verbosity`, plus feature/skill *disabling*. This runs last,
   so **the role wins over the model's own spawn arguments.**
4. Service tier and runtime overrides.

That ordering is why this project puts the tier in the role file rather than asking the model to
pass `model=` on spawn: step 3 beats step 2, and the model is told the value is locked.

Effort values are validated against the target model's advertised reasoning levels, so a role
cannot request an effort its model does not support.

---

## Agent roles

Installed into `$CODEX_HOME/agents/` (default `~/.codex/agents/`), generated from the templates in
`agents/` by `bin/codex-orchestrator-sync`.

| role | tier | reasoning | purpose |
|---|---|---|---|
| `explorer_low` | cheap | low | locate files, grep, trace call paths, map modules, find tests, read logs |
| `verifier_low` | cheap | low | build, lint, type-check, test, inspect the diff, classify failures |
| `implementer_medium` | general | medium | ordinary implementation: known bug, normal feature, targeted refactor |
| `debugger_high` | strong | high | unknown root cause: races, deadlocks, leaks, perf, corruption, failed fixes |
| `architect_high` | strongest | high | whole-system redesign or migration only |

### Model roles are discovered, never hardcoded

`bin/codex-orchestrator-sync` reads the model list Codex actually cached for your account
(`$CODEX_HOME/models_cache.json`), keeps only models that are listed in the picker *and* usable as a
multi-agent backend, and maps them onto four abstract tiers. The result is written to an editable
file:

```
~/.config/codex-orchestrator/config.toml

[models]
cheap     = "…"
general   = "…"
strong    = "…"
strongest = "…"
```

That file is authoritative once written. Edit it and re-run `bin/codex-orchestrator-sync` to change
which model a tier uses. `--check` prints the resolved mapping without writing anything:

```console
$ ~/codex-orchestrator/bin/codex-orchestrator-sync --check
```

Each role's requested effort is validated against that model's advertised reasoning levels, and
falls back to the nearest supported level (the sync output says when it did).

### `verifier_low`'s failure taxonomy

The verifier tags every failure with exactly one of:

`LOGIC_FAILURE` · `ENVIRONMENT_FAILURE` · `DEPENDENCY_FAILURE` · `PERMISSION_FAILURE` ·
`DEVICE_FAILURE` · `NETWORK_FAILURE` · `FLAKY_FAILURE`

Only `LOGIC_FAILURE` may trigger escalation to a stronger model. This is the single highest-value
rule in the whole setup: without it, a missing compiler or a denied sandbox call sends the most
expensive model off to debug an imaginary bug.

---

## Routing rules

Full policy: `skill/codex-orchestrator-routing/SKILL.md`. In brief:

- **Trivial** (rename, one string, small config edit, "where is X") → do it directly. No agents.
- **Normal** (known bug, ordinary feature) → do it directly or one `implementer_medium`; optionally
  one `explorer_low` first.
- **Complex** (unclear bug, perf issue, substantial feature) → `explorer_low` ×N →
  `debugger_high` (only if the cause is still unknown) → `implementer_medium` → `verifier_low`.
- **Hard** (race, deadlock, corruption, a fix that already failed) → same, with `debugger_high`
  mandatory.

Classify by difficulty, not by prompt length. `rename foo to bar` is trivial; `random crash after
reconnect` may be the hardest thing in the repo.

**Escalate the branch, not the task.** Never re-run everything on a stronger model — hand the one
stuck question to the stronger tier with the evidence already gathered.

**Readers parallelise, writers serialise.** Up to three read-heavy agents at once; one writer,
unless two writers own strictly disjoint files.

**Compact handoffs.** A subagent starts with an empty context; what you send is what it costs. Send
the symptom, the files that matter, what is ruled out, and one precise question.

---

## Installation

### Requirements

- Linux x86-64, an existing Codex install (for the bundled ripgrep/bwrap/code-mode helpers)
- Rust toolchain (`cargo`)
- `~/.local/bin` on `PATH`, **earlier than** the existing `codex`
- ~12 GB free disk for the build

### Install

```console
$ cd ~/codex-orchestrator
$ ./install.sh
```

`install.sh` is idempotent. It:

1. records what `which codex` resolves to today,
2. verifies `~/.local/bin` really does come first on `PATH`,
3. builds `codex` from the patched source (`codex/`, branch `orchestrator/effort-0.155.0`),
4. assembles a Codex **package layout** in `pkg/` — `bin/codex`, `codex-package.json`,
   `codex-resources/`, `codex-path/` — copying the version-matched `rg`, `bwrap`, voice resources
   and `codex-code-mode-host` out of your existing install, so every bundled helper still resolves,
5. symlinks `~/.local/bin/codex` at `pkg/bin/codex`,
6. installs the routing skill into `$CODEX_HOME/skills/`,
7. runs `bin/codex-orchestrator-sync`, which discovers your models, writes the tier mapping, renders
   the role files, and appends two clearly marked managed blocks to `$CODEX_HOME/config.toml` and
   `$CODEX_HOME/AGENTS.md`.

Useful flags: `--skip-build` (reuse the existing `target/release/codex`), `--max-agents=N`.

Nothing outside `pkg/`, `~/.local/bin/codex`, `$CODEX_HOME/agents/`,
`$CODEX_HOME/skills/codex-orchestrator-routing/` and the two marked blocks is modified. Both edited
files are backed up to `backup/` first.

### `which codex`, before and after

```
before: /usr/bin/codex
        -> /usr/lib/node_modules/@openai/codex/bin/codex.js   (npm shim)

after : /home/<you>/.local/bin/codex
        -> /home/<you>/codex-orchestrator/pkg/bin/codex        (patched native binary)
```

The original npm install is untouched and still works — `/usr/bin/codex` runs it directly.

### The patched binary does not self-update

The package lives outside `$CODEX_HOME/packages/standalone/releases`, so `InstallContext` classifies
it as `Other` and Codex offers no update action for it. It will not overwrite itself with an
upstream release, which would silently drop the patch. Upgrades go through
`update-patched-codex.sh` (below).

---

## Rollback

```console
$ ~/codex-orchestrator/uninstall.sh
```

Removes the `~/.local/bin/codex` symlink (only if it points at our build), deletes the five
generated role files and the routing skill, and strips the two managed blocks — backing up both
edited files first. It restores any pre-existing `~/.local/bin/codex` it moved aside during install,
then prints the restored `which codex`.

`--purge-source` additionally deletes `pkg/` and the Rust `target/` directory. The git clone and the
tier mapping in `~/.config/codex-orchestrator/` are always kept.

---

## Upgrading

A patched binary and an upstream release are a merge problem, so this is automated and gated:

```console
$ ~/codex-orchestrator/update-patched-codex.sh              # newest stable rust-v* tag
$ ~/codex-orchestrator/update-patched-codex.sh --tag=rust-v0.156.0
$ ~/codex-orchestrator/update-patched-codex.sh --dry-run    # rebase + build + test, do not install
```

It fetches upstream, saves your current patch branch as `…-backup-<timestamp>`, rebases onto the
target tag on a fresh branch, builds, runs `bin/run-effort-tests.sh`, and **installs only if all of
that passed**. A rebase conflict, a build failure or a test failure leaves the installed binary
exactly as it was and prints the commands to finish the rebase by hand.

---

## Benchmarks

```console
$ ~/codex-orchestrator/bench/run-benchmark.sh --task=hard-leak
$ ~/codex-orchestrator/bench/run-benchmark.sh --repeats=3
```

Runs each task twice — once with `[agents].enabled = false` (single model, no delegation) and once
with the orchestrator roles — in a throwaway repo and an isolated `CODEX_HOME`, and records
whatever usage this Codex build exposes: models used, reasoning efforts used, agents spawned, input
/cached/output/reasoning tokens, retries, wall time, and whether the task's `check.sh` passed.

Bundled tasks:

| task | what it probes |
|---|---|
| `trivial-string` | a rename-class change should *not* summon a swarm |
| `normal-feature` | ordinary multi-file work |
| `hard-leak` | a real non-obvious lifecycle leak, cause not stated in the prompt |
| `env-failure` | a missing build tool must be reported, not escalated or worked around |

**The metric is usage per successful task**, not the smallest token count. Compare token totals only
between arms with the same `passed` count; a cheaper arm that failed saved nothing. The summary
table prints `passed` next to the tokens for exactly this reason.

`codex exec` is used here only as a measurement harness. It is not the interface.

---

## Limitations

These are real and worth knowing before you rely on this.

- **Roles cannot restrict the sandbox.** In 0.155.0 an agent-role config file may only override
  `developer_instructions`, `model`, `model_reasoning_effort`, `model_reasoning_summary`,
  `model_verbosity`, `personality`, `service_tier`, plus *disabling* features and skills
  (`codex-rs/core/src/agent/role.rs`). A `sandbox_mode` or `permissions` key in a role file parses
  but is ignored: "roles may customize the child or reduce its capabilities, but never replace the
  parent session's authority". `explorer_low` is therefore read-only **by instruction**, not by
  sandbox enforcement. Its permissions are the parent's.
- **Routing is advisory; tiers are enforced.** Nothing forces the parent to delegate. If the model
  ignores the policy, it just does the work itself at the parent's model. What *is* guaranteed is
  that once `agent_type = "debugger_high"` is spawned, it really runs on the strong tier.
- **`idle` versus `completed`.** Codex reports a spawned agent that has finished its turn but is
  still open as idle, so `/effort` shows `idle`. It does not invent a `completed` state that the
  runtime does not track.
- **`/effort` needs a started session.** Before the root thread exists there is nothing to read; the
  command says so instead of guessing.
- **Active-worker denominator.** `Active workers: N/M` only shows `M` when
  `[agents].max_concurrent_threads_per_session` is set. The installer sets it (default 4). Unset, the
  footer shows just `N`, because the effective default is internal to core and not exposed to the TUI.
- **`/effort all` is capped** at 100 subagent rows per invocation.
- **Linux x86-64 only.** The package layout assembly in `install.sh` looks for the
  `x86_64-unknown-linux-musl` vendor directory.
- **Build profile.** The release build sets `debug = none` and `strip = symbols` (upstream keeps
  line tables) so the build fits in ~12 GB of disk. Backtraces from the patched binary are therefore
  less detailed than from an official release.

---

## Files this patch touches

Useful when a rebase conflicts. Everything is in `codex/codex-rs/tui/`:

| file | change |
|---|---|
| `src/effort_status.rs` | **new** — rows, scopes, level parsing, the `EffortStatusCell` renderer |
| `src/effort_status_tests.rs` | **new** — unit + snapshot tests for the above |
| `src/app/effort_status.rs` | **new** — the background `thread/read` + `thread/list` runtime read |
| `src/app/effort_status_tests.rs` | **new** — tests for degraded/partial reads |
| `src/chatwidget/effort_command.rs` | **new** — `/effort` command handling on `ChatWidget` |
| `src/slash_command.rs` | `Effort` variant, description, inline args, availability, tests |
| `src/app_event.rs` | `RequestEffortStatus`, `EffortStatusLoaded`, `EffortStatusReadout` |
| `src/chatwidget/slash_dispatch.rs` | dispatch for bare and inline `/effort`, queue classification |
| `src/app/event_dispatch.rs` | routes the two new events |
| `src/bottom_pane/chat_composer.rs` | keeps `/effort` usable on a parent-owned child thread |
| `src/bottom_pane/snapshots/…command_popup_default_items.snap` | `/effort` now appears in the popup listing |
| `src/lib.rs`, `src/app.rs`, `src/chatwidget.rs` | module registration |

No change to `codex-rs/core`, `codex-rs/app-server` or `codex-rs/app-server-protocol`: `/effort`
reads runtime state through app-server requests that already exist, which is what keeps the patch
small and rebasable.

---

## Project layout

```
~/codex-orchestrator/
├── codex/                     patched upstream source (branch orchestrator/effort-0.155.0)
├── pkg/                       assembled Codex package layout (install target)
├── agents/                    role templates rendered by codex-orchestrator-sync
├── skill/                     the routing skill installed into $CODEX_HOME/skills
├── bin/
│   ├── codex-orchestrator-sync    model discovery + role rendering + managed config blocks
│   └── run-effort-tests.sh        the test gate used by the updater
├── bench/
│   ├── run-benchmark.sh
│   └── tasks/                 trivial-string · normal-feature · hard-leak · env-failure
├── backup/                    timestamped copies of every file we edited
├── install.sh
├── uninstall.sh
└── update-patched-codex.sh
```
