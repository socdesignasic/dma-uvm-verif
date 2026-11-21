# dma-uvm용 MCP 서버 (P4)

MCP 서버 세 개로 에이전트(Claude Code)가 전체 루프를 돌 수 있습니다:
**시뮬레이션 → 디버그 → 회귀 → CI → PR**.

| 서버 | 위치 | 전송 방식 | 등록 위치 |
|---|---|---|---|
| `vivado` | `mcp/vivado_mcp/server.py` (이 저장소) | stdio | `.mcp.json` (커밋됨, 비밀값 없음) |
| `jenkins` | Jenkins `mcp-server` 플러그인, http://localhost:8090/mcp-server/mcp | HTTP, Basic 인증 | local scope에만 (`~/.claude.json`) |
| `github` | GitHub 원격 MCP, https://api.githubcopilot.com/mcp/ | HTTP, Bearer | local scope에만 (`~/.claude.json`) |

## vivado-mcp 도구
Jenkins가 쓰는 것과 같은 진입점인 `scripts/sim.py` / `scripts/regress.py`를 감싼 얇은 wrapper입니다.

아래 표는 `server.py`의 도구 설명 첫 줄에서 생성합니다(`python scripts/check_docs.py --write`).

<!-- gen:mcp_tools -->
| 도구 | 하는 일 |
|---|---|
| `list_testbenches` | 등록된 테스트벤치와 각각의 테스트, 기본 테스트, known-fail(RTL 버그) 항목을 보여 줍니다. |
| `list_known_bugs` | 검증에서 찾은 RTL 버그와 노트(verif/plan.toml bugs, 설명은 verif/BUGS.md), 그 버그를 known_fail로 |
| `lint` | 테스트벤치를 시뮬레이션 없이 컴파일하고 elaborate합니다 (xvlog + xelab). |
| `run_test` | UVM 테스트 하나를 seed 하나로 실행합니다 (seed: 정수 또는 'random'). |
| `get_log_excerpt` | run.log에서 걸러낸 일부를 돌려줍니다 (파일 전체는 돌려주지 않음). |
| `trace_signals` | 테스트 하나를 다시 돌리며 HDL 객체(objects, 예: ['/tb_skid/dut/*'])의 값을 VCD로 남기고, |
| `start_regression` | 회귀를 백그라운드에서 시작합니다 (suite: unit\|top\|all, 또는 tbs를 직접 지정). |
| `regression_status` | start_regression으로 시작한 회귀의 상태: 실행 중이면 진행률, 끝났으면 집계와 실패한 실행 목록 |
| `cancel_job` | 백그라운드 회귀를 멈춥니다 (시뮬레이터까지 프로세스 트리 전체 종료). 잠금도 풉니다. |
| `coverage_report` | 기능 커버리지를 합쳐 covergroup별 점수, 못 친 bin 목록, HTML 보고서 경로를 돌려줍니다. |
| `check_inventory` | 검사 목록을 기준선(verif/check_baseline.json)과 비교합니다. 사라지거나 줄어든 검사, 늘어난 억제 구문을 |
| `run_gate` | 단계의 완료 기준을 scripts/gate.py로 판정합니다 (예: static, A, B). 시뮬레이션은 돌리지 않고, |
| `signoff` | verif/SIGNOFF.md의 sign-off 기준을 지금 out/의 결과로 판정합니다 (level: smoke \| nightly \| release). |
| `compare_regressions` | 두 회귀(out/regress/<이름>/summary.json)의 판정을 (tb, test, seed)마다 비교합니다. 폴더 이동처럼 코드가 |
| `ledger_append` | 작업 기록(out/loop/<loop_id>/ledger.json)에 항목을 덧붙입니다. 결과마다 재실행 명령과 결과 파일 경로를 |
| `ledger_read` | 작업 기록의 마지막 항목들을 돌려줍니다 (gate.py --ledger와 ledger_append가 쓴 것). |
<!-- /gen:mcp_tools -->

- **worktree:** 모든 도구가 `workspace` 인자를 받습니다. 비우면 이 저장소, 주면 이 저장소의 git worktree여야 하고
  그 안의 `scripts/`와 `out/`을 씁니다.
- **잠금:** 같은 (workspace, TB)의 빌드와 실행은 `out/mcp/locks/<tb>.lock`으로 하나씩만 돕니다. 주인 프로세스가
  죽은 잠금은 자동으로 지웁니다. 회귀가 도는 동안 그 TB들은 잠깁니다.
- **작업 상태:** 백그라운드 회귀는 `out/mcp/jobs/<id>.json`에 남아, 서버를 다시 띄워도 `regression_status`로
  결과를 읽을 수 있습니다. `cancel_job`은 시뮬레이터까지 프로세스 트리 전체를 끝냅니다.
  한계: 회귀는 그것을 띄운 서버(세션)가 살아 있는 동안만 돕니다. Windows의 mcp 클라이언트는 서버를 닫힐 때
  안의 프로세스를 모두 끝내는 job에 넣고 이탈을 허용하지 않아, 세션이 먼저 끝나면 회귀도 끝납니다. 그때 상태는
  `interrupted`이고 `regression_status`가 재실행 명령을 돌려줍니다.
- **확인:** `mcp/.venv/Scripts/python.exe mcp/vivado_mcp/selftest.py` (`--full`이면 worktree 동시 빌드, 서버 재시작,
  작업 취소까지).

안전장치 (에이전트에게 맡기지 않고 서버에서 강제):
- `tb`/`test`는 `verif/sim_cfg.json`에 있어야 합니다. `plusargs`/`defines`는 `NAME[=value]`, 신호 추적 객체는
  HDL 경로(`/tb_skid/dut/*`) 형식이어야 합니다.
  shell을 거치는 것은 없습니다.
- 소스 파일을 쓰는 도구가 없습니다. 출력은 `out/` 아래에만 가고, **RTL(`HW/`)은 수정할 수 없습니다**.
- 로그 접근은 `out/`로 제한되고, 결과를 잘라서 주므로 XSim 로그가 컨텍스트를 채우지 않습니다.

## 새 PC에서 설정
```powershell
python -m venv mcp\.venv
mcp\.venv\Scripts\python.exe -m pip install -r mcp\requirements.txt
mcp\.venv\Scripts\python.exe mcp\vivado_mcp\selftest.py          # 모든 도구를 stdio로 한 번씩 호출
mcp\.venv\Scripts\python.exe mcp\vivado_mcp\selftest.py --full   # + top 테스트 + 회귀
```
Claude Code가 `.mcp.json`의 프로젝트 서버 `vivado`를 승인할지 한 번 묻습니다.

Jenkins + GitHub (비밀값은 git 밖에 둠):
```bash
# Jenkins: admin의 API 토큰. Jenkins에서 만들어 %USERPROFILE%\jenkins\home\secrets\claude_mcp_api_token에 저장
B64=$(printf 'admin:%s' "$(cat ~/jenkins/home/secrets/claude_mcp_api_token)" | base64 -w0)
claude mcp add --scope local --transport http jenkins http://localhost:8090/mcp-server/mcp --header "Authorization: Basic $B64"
claude mcp add --scope local --transport http github https://api.githubcopilot.com/mcp/ --header "Authorization: Bearer $(gh auth token)"
mcp/.venv/Scripts/python.exe mcp/check_jenkins_mcp.py     # Jenkins MCP 도구 23개를 보여 줌
```
`gh auth token`이 바뀌면 (다시 로그인하면) `github` 줄을 다시 실행하세요.

## 참고
- Jenkins 토큰은 `admin` 것이고, Jenkins MCP는 강력한 도구(`triggerBuild`, `replayBuild`,
  `createPipeline`, `updateBuild`)를 제공합니다. allow-list에 넣지 않으면 Claude Code가 도구를 부를 때마다
  묻습니다. 확인 창이 너무 많으면 읽기 전용 도구(`getBuild`, `getTestResults`, `getBuildLog`,
  `searchBuildLog`)만 allow-list에 넣으세요.
- `jenkins` 서버에 연결하려면 Jenkins가 실행 중이어야 합니다 (`ci/start-jenkins.ps1`).
- 폴더 이름을 바꾸면 local scope 등록이 사라집니다. 위의 `claude mcp add` 두 줄을 새 경로에서 다시 실행하세요.
