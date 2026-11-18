# dma-uvm: 에이전트 작업 규칙

`dma_ip_top`(Zybo Z7-20)을 **Vivado 2022.2 XSim**에서 UVM으로 검증합니다. CI는 로컬
Jenkins(http://localhost:8090), 저장소는 `socdesignasic/dma-uvm`(private)입니다.

## 반드시 지킬 규칙
1. **`HW/` 아래 RTL은 읽기 전용입니다.** `PreToolUse` hook이 수정을 막습니다. 테스트가 RTL 버그를 드러내도
   고치지 않습니다. `verif/BUGS.md`에 적고 (증상, 원인, 재현 방법, 수정 제안), 재현 테스트를
   `verif/sim_cfg.json`에 `known_fail`로 등록합니다. 그다음 멈추고 사용자에게 보고합니다 (사람 확인 지점).
2. **시뮬레이션은 `scripts/sim.py` / `scripts/regress.py`, 또는 이를 감싼 `vivado` MCP 도구로만 실행합니다.**
   xvlog/xelab/xsim을 직접 부르지 않습니다. CI도 같은 스크립트를 쓰므로 로컬 = CI입니다.
3. **커밋 / push는 사용자가 명시적으로 요청할 때만 합니다.**
4. 테스트 결과는 실제로 실행한 것만 인정합니다. 판정과 `rerun` 명령을 함께 적습니다. 보지 않은 PASS를
   주장하지 않습니다.
5. 테스트를 통과시키려고 검사를 낮추거나, 허용 범위를 넓히거나, assertion을 지우지 않습니다. 실패한
   검사는 TB 버그(TB를 고침)이거나 RTL 버그(규칙 1)입니다.

## 구성
| 경로 | 내용 |
|---|---|
| `HW/` | DUT RTL (읽기 전용) |
| `verif/agents/` | `vr_agent` (valid/ready), `axil_agent` (AXI4-Lite master, `write_reg`/`read_reg`), `axi4_slv_agent` (driver + monitor + 메모리 모델) |
| `verif/env/{unit,top}/`, `verif/sequences/top/`, `verif/tests/{unit,top}/`, `verif/tb/` | env (scoreboard, coverage, 레지스터 맵), sequence, 테스트, TB top |
| `verif/sim_cfg.json` | TB 목록: filelist, 테스트, `known_fail` |
| `verif/vplan/vplan.md` | 기능 ↔ 테스트 ↔ 커버리지 대응표 (계속 갱신) |
| `verif/BUGS.md` | 발견한 RTL 버그 (BUG-001 won't fix, BUG-002 open) |
| `verif/SIGNOFF.md` | sign-off 기준 S1~S9, waiver(known_fail) 승인 절차, 판정 기록. 판정은 `scripts/signoff.py` |
| `scripts/` | `sim.py`, `regress.py` |
| `ci/`, `Jenkinsfile` | Jenkins (JCasC) |
| `mcp/` | `vivado` MCP 서버, Jenkins/GitHub MCP 설정 |
| `.claude/agents/`, `.claude/skills/` | 서브에이전트와 오케스트레이션 루프 (`/verify-loop`) |

## 명령
```bash
python scripts/sim.py list
python scripts/sim.py lint --tb top
python scripts/sim.py run --tb top --test dma_smoke_test --seed 1
python scripts/regress.py --suite all --seeds 2 --jobs 6
python scripts/sim.py cov-report --tb top     # out/top/cov/func/xcrg_func_cov_report.txt
python scripts/signoff.py --level smoke       # sign-off 기준 판정 (smoke / nightly / release)
```

## XSim 2022.2 주의사항 (이미 처리함, 다시 만들지 말 것)
- 넓은 범위에 `dist`를 쓰면 값이 심하게 치우칩니다. 경계값 편향은 절차적으로 넣습니다.
- `coverpoint` 식 안의 폭 변환(cast)은 잘못 계산됩니다. 먼저 계산하고 샘플링합니다.
- `small`, `large`, `medium`, `weak*`, `strong*`은 키워드입니다. bin 이름으로 쓰지 않습니다.
- 함수 호출 결과에는 비트 선택을 할 수 없습니다 (`f()[3:0]`). 임시 변수를 씁니다.
- bin 상한에 `$`를 쓰면 (`[513:$]`) 잘못 계산돼 모든 샘플이 그 bin에 들어갑니다. 상한을 명시합니다.
- `xcrg`는 기존 보고서 뒤에 덧붙입니다. `sim.py cov-report`는 먼저 `out/<tb>/cov`를 비웁니다.
- 주석과 설명은 한국어로 씁니다 (UTF-8). XSim은 한글 주석을 문제없이 컴파일합니다. 로그 메시지와
  태그(`[SB_JOB]` 등)는 스크립트가 파싱하므로 영어로 둡니다.

## UVM 코드 배치
- **파일 하나에 클래스 하나, 파일 이름 = 클래스 이름** (`dma_scoreboard` → `dma_scoreboard.sv`).
- `*_pkg.sv`에는 import, 패키지 전체의 typedef/상수, `` `include `` 줄만 둡니다.
  클래스 파일은 filelist에 적지 않고, filelist에 패키지 디렉터리마다 `+incdir+`를 둡니다.
- RAL은 쓰지 않습니다. 레지스터는 `axil_base_seq::write_reg()/read_reg()`와
  `verif/env/top/dma_reg_map.sv`의 상수로 다룹니다.
- 자극은 env가 아니라 sequence(`verif/sequences/top/`, `vr_stream_seq`)에 둡니다.

## 테스트 추가 방법
`verif/tests/<unit|top>/<test_name>.sv`를 만들고 (클래스 하나), 그 디렉터리의 `*_test_pkg.sv`에
`` `include `` 줄을 추가하고, `verif/sim_cfg.json`의 그 TB `tests` 목록에 넣고 (CI와 `regress.py`가 돌리는
목록), `verif/vplan/vplan.md`에 행을 추가한 뒤, lint → seed 3개 이상 실행 → 영향받는 suite 회귀 순으로
확인합니다.
