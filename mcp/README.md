# MCP servers for dma-uvm (P4)

Three MCP servers give an agent (Claude Code) the whole loop:
**simulate → debug → regress → CI → PR**.

| Server | Where | Transport | Registered in |
|---|---|---|---|
| `vivado` | `mcp/vivado_mcp/server.py` (this repo) | stdio | `.mcp.json` (committed, no secrets) |
| `jenkins` | Jenkins `mcp-server` plugin, http://localhost:8090/mcp-server/mcp | HTTP, Basic auth | local scope only (`~/.claude.json`) |
| `github` | GitHub remote MCP, https://api.githubcopilot.com/mcp/ | HTTP, Bearer | local scope only (`~/.claude.json`) |

## vivado-mcp tools
A thin wrapper over `scripts/sim.py` / `scripts/regress.py`, the same entry points Jenkins uses.

| Tool | Purpose |
|---|---|
| `list_testbenches` | TBs, tests, defaults, `known_fail` (tracked RTL bugs) |
| `lint(tb)` | xvlog + xelab only, first compiler errors |
| `run_test(tb, test, seed, plusargs, rebuild, coverage, wave)` | one run: verdict, reasons, first UVM errors, `rerun` command |
| `get_log_excerpt(tb, test, seed, pattern)` | filtered `run.log` excerpt (errors, SB/JOB/AXI lines). Never the whole log |
| `start_regression(suite/tbs, tests, seeds, jobs)` → `regression_status(id)` | background regression, then the failing runs with `rerun` |
| `coverage_report(tb)` | merged functional coverage: per-covergroup score + HTML path |
| `list_known_bugs` | `verif/BUGS.md` entries and the tests that track them |

Guard rails (enforced in the server, not left to the agent):
- `tb`/`test` must exist in `verif/sim_cfg.json`. `plusargs`/`defines` must match `NAME[=value]`.
  Nothing goes through a shell.
- There is no file-write tool. Outputs only go under `out/`, and **RTL (`HW/`) cannot be modified**.
- Log access is restricted to `out/`, and results are trimmed so XSim logs don't flood context.

## Setup on a new machine
```powershell
python -m venv mcp\.venv
mcp\.venv\Scripts\python.exe -m pip install -r mcp\requirements.txt
mcp\.venv\Scripts\python.exe mcp\vivado_mcp\selftest.py          # stdio round-trip of every tool
mcp\.venv\Scripts\python.exe mcp\vivado_mcp\selftest.py --full   # + top test + regression
```
Claude Code asks once to approve the project server `vivado` from `.mcp.json`.

Jenkins + GitHub (secrets stay out of git):
```bash
# Jenkins: API token for admin, created via Jenkins (stored in %USERPROFILE%\jenkins\home\secrets\claude_mcp_api_token)
B64=$(printf 'admin:%s' "$(cat ~/jenkins/home/secrets/claude_mcp_api_token)" | base64 -w0)
claude mcp add --scope local --transport http jenkins http://localhost:8090/mcp-server/mcp --header "Authorization: Basic $B64"
claude mcp add --scope local --transport http github https://api.githubcopilot.com/mcp/ --header "Authorization: Bearer $(gh auth token)"
mcp/.venv/Scripts/python.exe mcp/check_jenkins_mcp.py     # lists the 23 Jenkins MCP tools
```
If `gh auth token` changes (re-login), re-run the `github` line.

## Notes
- The Jenkins token belongs to `admin`, and the Jenkins MCP exposes powerful tools
  (`triggerBuild`, `replayBuild`, `createPipeline`, `updateBuild`). Claude Code asks
  before each tool call unless you allow-list it. Allow-list read-only ones
  (`getBuild`, `getTestResults`, `getBuildLog`, `searchBuildLog`) if prompts get noisy.
- Jenkins must be running (`ci/start-jenkins.ps1`) for the `jenkins` server to connect.
