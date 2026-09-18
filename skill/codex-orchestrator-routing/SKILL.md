---
name: codex-orchestrator-routing
description: Decide which Codex subagent role (and therefore which model and reasoning effort) should handle each part of a task, and when not to delegate at all. Use when planning how to approach a coding task, when a bug's root cause is unknown, when a build or test fails and you must decide whether to escalate, when several independent questions about a codebase need answering, or when you are about to spawn a subagent and need to pick agent_type.
---

# Orchestrator routing

Spend the cheapest tier that can actually do the job. Not the cheapest possible tier, and not the
strongest model for everything.

The roles below are installed as Codex agent roles. Their model and reasoning effort are fixed in
their config files, so `spawn_agent(agent_type = "...")` is what selects the tier — you do not, and
cannot, pick the model yourself for these roles.

| role | tier | use it for |
|---|---|---|
| `explorer_low` | cheap / low | read-only investigation: find files, grep, trace call paths, map modules, locate tests, read logs |
| `verifier_low` | cheap / low | build, lint, type-check, test, inspect the diff, check acceptance criteria, classify failures |
| `implementer_medium` | general / medium | ordinary implementation where the cause or spec is already known |
| `debugger_high` | strong / high | unknown root cause: races, deadlocks, leaks, perf regressions, corruption, failed previous fixes |
| `architect_high` | strongest / high | whole-system redesign or migration only |

Run `/effort` at any time to see what each live agent actually resolved to.

## First decide the class of the task

Classify by **difficulty**, never by prompt length. "rename foo to bar" is trivial; "random crash
after reconnect" may be the hardest thing in the repo.

Weigh: is the root cause known? Is the failure reproducible? Does it involve concurrency, memory
lifetime, persistent state, or timing? Is it security-sensitive? Did a previous fix already fail?
Is there a test that proves the fix?

**TRIVIAL** — rename, a string change, a small config edit, formatting, "where is X defined".
Do it yourself. Do not spawn anything. A swarm here costs more than the task.

**NORMAL** — an ordinary feature, a known bug, a small multi-file change.
Do it yourself, or hand it to one `implementer_medium`. Optionally one `explorer_low` first if you
genuinely do not know where the code lives.

**COMPLEX** — unclear bug, performance issue, substantial feature.

    explorer_low (1-3 in parallel)  ->  debugger_high (only if the cause is still unknown)
                                    ->  implementer_medium
                                    ->  verifier_low

**HARD** — race, deadlock, memory corruption, persistent crash, architecture problem, or a fix that
has already been attempted and failed. Same flow as COMPLEX, but the `debugger_high` branch is
mandatory and gets the best evidence you can assemble.

## Escalate along the branch, not the whole task

Never re-run the entire task on a stronger model. Escalate only the part that is actually stuck:

- `explorer_low` returns UNCERTAIN on the decisive question → spawn `debugger_high` for that one
  question, with the explorer's evidence attached.
- `debugger_high` returns a root cause → hand the fix plan to `implementer_medium`. Do not let the
  expensive tier do routine editing.
- `verifier_low` reports `LOGIC_FAILURE` → reopen only the failing branch.

## Failure classification gates escalation

`verifier_low` tags every failure. Only `LOGIC_FAILURE` justifies a stronger model.

`ENVIRONMENT_FAILURE`, `DEPENDENCY_FAILURE`, `PERMISSION_FAILURE`, `DEVICE_FAILURE`,
`NETWORK_FAILURE` and `FLAKY_FAILURE` mean the machine is wrong, not the code. Fix the environment,
ask the user, or say the check could not run. Spawning `debugger_high` for a missing compiler burns
the expensive tier on nothing.

## Concurrency

Readers parallelise, writers serialise.

- Up to 3 read-heavy agents (`explorer_low`, `verifier_low`) at once.
- One writer (`implementer_medium`) at a time, unless two writers own strictly disjoint files — and
  if you do run two, tell each one which files it owns and that it is not alone in the repo.
- Never run a writer and a verifier over the same files at the same time; the verifier will read a
  half-applied change.

## Keep handoffs compact

A subagent starts with a fresh context. What you send is what it costs. Send a curated brief, never
the repository and never the whole conversation.

    USER ISSUE:
    FPS falls after returning from an app.

    FILES:
    browser.c, screen_manager.c

    OBSERVATION:
    LVGL object count rises on every reopen; it never falls.

    RULED OUT:
    refresh frequency, image decode

    QUESTION:
    Identify the exact lifecycle leak.

Rules for briefs:
- State the symptom, the files that matter, what you already ruled out, and one precise question.
- Attach the specific evidence (a stack, a log excerpt, a diff) rather than telling the agent to go
  find it again.
- Give the acceptance criteria to `verifier_low` and `implementer_medium` explicitly.
- Assign file ownership when more than one writer is live.

## When not to delegate

- The task is trivial.
- You already know the answer and are just typing it out.
- The subagent would need your whole conversation to be useful.
- You would spend more tokens writing the brief than doing the work.
- Two agents would edit the same file.
