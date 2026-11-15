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

| 도구 | 용도 |
|---|---|
| `list_testbenches` | TB, 테스트, 기본값, `known_fail` (추적 중인 RTL 버그) |
| `lint(tb)` | xvlog + xelab만 실행, 처음 나온 컴파일 에러 |
| `run_test(tb, test, seed, plusargs, rebuild, coverage, wave)` | 실행 한 번: 판정, 이유, 처음 나온 UVM 에러, `rerun` 명령 |
| `get_log_excerpt(tb, test, seed, pattern)` | 걸러낸 `run.log` 일부 (에러, SB/JOB/AXI 줄). 로그 전체는 절대 주지 않음 |
| `start_regression(suite/tbs, tests, seeds, jobs)` → `regression_status(id)` | 백그라운드 회귀, 끝나면 실패한 실행과 `rerun` |
| `coverage_report(tb)` | 합친 기능 커버리지: covergroup별 점수 + HTML 경로 |
| `list_known_bugs` | `verif/BUGS.md` 항목과 그 버그를 추적하는 테스트 |

안전장치 (에이전트에게 맡기지 않고 서버에서 강제):
- `tb`/`test`는 `verif/sim_cfg.json`에 있어야 합니다. `plusargs`/`defines`는 `NAME[=value]` 형식이어야 합니다.
  shell을 거치는 것은 없습니다.
- 파일을 쓰는 도구가 없습니다. 출력은 `out/` 아래에만 가고, **RTL(`HW/`)은 수정할 수 없습니다**.
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
