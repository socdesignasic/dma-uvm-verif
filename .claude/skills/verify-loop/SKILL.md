---
name: verify-loop
description: Orchestrate one verification iteration on dma-uvm. Plan with verif-planner, build with uvm-builder/coverage-closer, run and regress, triage failures with sim-triage, check CI with ci-watcher, with human gates for RTL bugs and commits. Use when the user asks to verify a feature, close coverage, investigate CI failures, or run "the loop".
---
# verify-loop: orchestrator procedure

You are the orchestrator. Subagents do the work and you keep the state, the gates and the
summary. Read CLAUDE.md first. A hook blocks HW/ edits for everyone.

## 0. Frame the iteration
State the goal in one line and the exit criteria. Defaults:
- every test of the affected suites matches its expectation (PASS, or XFAIL for known bugs) on 3 seeds,
- target covergroups at 100% (or every remaining hole is explicitly accepted by the user),
- no new UVM_ERROR/UVM_FATAL in a regression of the affected suites.

## 1. Plan → `verif-planner`
Give it the goal. You get back a task table with dependencies and parallel groups.
If it lists questions that need a human decision, ask the user before building.

## 2. Build → `uvm-builder` / `coverage-closer`
- One subagent per task. Tasks that touch different files may run **in parallel**. Tasks that
  share a file (e.g. both add an `` `include `` to `dma_test_pkg.sv`, or both edit `sim_cfg.json`) run **sequentially**.
- Each returns files changed + verdicts with rerun commands. Re-check claims you depend on
  (e.g. run `python scripts/sim.py run ... --no-build` yourself for one seed).

## 3. Regress
`start_regression` (vivado MCP) or `python scripts/regress.py --suite <unit|top|all> --seeds 3`.
A clean result means `fail=0`. XFAIL entries must be the known BUG-00x reproducers and nothing else.

## 4. Triage → `sim-triage` (one per distinct failure signature, in parallel)
Act on its classification:
| Class | Action |
|---|---|
| TB bug | back to step 2 with the evidence |
| known bug | nothing to do; if XPASS, tell the user the RTL looks fixed and propose removing the known_fail |
| **RTL bug** | **GATE: stop.** Show the user the evidence and the drafted BUGS.md entry. After approval, add BUGS.md + `known_fail` (never edit HW/) |
| environment | fix the script/budget if it is ours, otherwise report |

## 5. Coverage
Run `coverage_report` for the affected TBs and compare with the iteration start. Holes left → step 2
(coverage-closer) or ask the user to accept/exclude them.

## 6. CI → `ci-watcher`
Report the last builds. After the user asks you to commit/push (**GATE: never on your own**),
the next SCM poll builds smoke. Ask ci-watcher for the result, and send failures to step 4.

## 7. Report
Show a short table: tasks done, tests added, regression counts (runs/fail/xfail), coverage
before → after, new bugs, open questions. Every number must come from a run in this iteration.

## Stop conditions
Exit criteria met, or the same failure persists after 2 build/triage rounds (escalate to the
user with the evidence), or a gate is waiting for the user.
