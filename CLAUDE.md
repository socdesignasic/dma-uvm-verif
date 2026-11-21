# dma-uvm: 에이전트 작업 규칙

`dma_ip_top`(Zybo Z7-20)을 **Vivado 2022.2 XSim**에서 UVM으로 검증합니다. CI는 로컬
Jenkins(http://localhost:8090), 저장소는 `socdesignasic/dma-uvm`(private)입니다.

## 반드시 지킬 규칙
1. **`HW/` 아래 RTL은 읽기 전용입니다.** `PreToolUse` hook이 수정을 막습니다. 테스트가 RTL 버그를 드러내도
   고치지 않습니다. `verif/BUGS.md`에 적고 (증상, 원인, 재현 방법, 수정 제안), `verif/plan.toml`의 bugs에 같은 ID를
   넣고, 재현 테스트를 `verif/sim_cfg.json`에 `known_fail`로 등록합니다. 그다음 멈추고 사용자에게 보고합니다 (사람 확인 지점).
2. **시뮬레이션은 `scripts/sim.py` / `scripts/regress.py`, 또는 이를 감싼 `vivado` MCP 도구로만 실행합니다.**
   xvlog/xelab/xsim을 직접 부르지 않습니다. CI도 같은 스크립트를 쓰므로 로컬 = CI입니다.
3. **커밋 / push는 사용자가 명시적으로 요청할 때만 합니다.**
4. 테스트 결과는 실제로 실행한 것만 인정합니다. 판정과 `rerun` 명령을 함께 적습니다. 보지 않은 PASS를
   주장하지 않습니다.
5. 테스트를 통과시키려고 검사를 낮추거나, 허용 범위를 넓히거나, assertion을 지우지 않습니다. 실패한
   검사는 TB 버그(TB를 고침)이거나 RTL 버그(규칙 1)입니다. 검사 목록은 `check_inventory.py --compare`가
   기준선(`verif/check_baseline.json`)과 비교하고, hook이 verif/를 고칠 때마다 확인합니다.
6. 단계를 끝냈다는 판정은 글이 아니라 `scripts/gate.py <단계>`의 결과로 합니다.

### 규칙을 지키는 장치
| 규칙 | 장치 |
|---|---|
| 1 RTL 읽기 전용 | `protect_rtl` hook(HW/ 수정 차단, 실행 뒤 바뀐 HW/ 되돌림), `guard_rules` hook(BUGS.md에 없는 BUG ID의 known_fail 차단), `plan_check`(KNOWN_FAIL 일관성), 사람(등록 뒤 보고), sign-off S11(승인된 HW 해시) |
| 2 시뮬레이션 스크립트만 | `guard_rules` hook(명령 위치의 xvlog/xelab/xsim/xcrg 차단, python·cat에 넘기는 heredoc 본문은 제외), Jenkins가 같은 스크립트를 씀 |
| 3 커밋/push는 요청 때만 | 사람. `protect_rtl` hook이 저장소 전체 git 명령(stash, reset --hard 등)은 확인을 받음, `.githooks`가 커밋 메시지 규칙 검사 |
| 4 실행한 결과만 | `sim.py`/`regress.py`가 결과마다 rerun과 출처(commit, dirty, HW 해시)를 남김, gate `results_fresh`, sign-off S10 |
| 5 검사를 낮추지 않음 | `check_inventory --compare`(post_tool_use hook이 verif/ 수정 때마다, gate static), 기준선 저장은 hook이 확인 요청(사람 승인), checker self-test(`dma_checker_test`), gate `xfail_clean` |
| 6 gate로 판정 | `scripts/gate.py <단계>` (static, A, B, C, 0-1, 0-2, 1, 2), 결과는 `out/gate/<단계>.json` |

## 구성
| 경로 | 내용 |
|---|---|
| `HW/` | DUT RTL (읽기 전용) |
| `verif/vip/` | 재사용 VIP (DUT를 모름): `stream/` (valid/ready), `axil/` (AXI4-Lite master, `write_reg`/`read_reg`), `axi4_slave/` (driver + monitor + 메모리 모델) |
| `verif/{top,unit,ref_adder,selftest}/` | 테스트벤치 폴더. 안에 `<이름>.f`, `tb_*.sv`, 역할 폴더 `env/`, `model/`, `scoreboard/`, `coverage/`, `seq/`, `test/` (unit은 VIP의 sequence를 써서 `seq/` 없음). `verif/rtl.f`는 RTL 파일 목록 |
| `verif/sim_cfg.json` | TB 목록: filelist, 테스트, `known_fail` |
| `verif/plan.toml` | 검증 계획 원본: 기능 ↔ 테스트 ↔ 검사 ID ↔ 커버포인트, 가설, 버그, 승인된 RTL 해시. `vplan/vplan.md`는 여기서 생성 |
| `verif/BUGS.md` | 발견한 RTL 버그와 설계 노트 (BUG-001 won't fix, BUG-002~007 open, NOTE-001~003) |
| `verif/SIGNOFF.md` | sign-off 기준 S1~S11, waiver(known_fail) 승인 절차, 판정 기록. 판정은 `scripts/signoff.py` |
| `scripts/` | 실행(`sim.py`, `regress.py`, `fpga.py`, `board*.py`), 판정과 검사(`signoff.py`, `gate.py`, `plan_check.py`, `check_inventory.py`, `check_docs.py`, `ml_regress.py`), 공통(`common.py`), 테스트(`tests/`) |
| `ci/`, `Jenkinsfile` | Jenkins (JCasC) |
| `mcp/` | `vivado` MCP 서버, Jenkins/GitHub MCP 설정 |
| `.claude/agents/`, `.claude/skills/` | 서브에이전트 7개와 스킬 7개 (`/verify-stage`, `/ci-check`, `/confirm-hypothesis`, `/add-test`, `/file-rtl-bug`, `/record-signoff`, `/sync-public`). 정의는 `scripts/check_agents.py`가 검사 |

## 명령
```bash
python scripts/sim.py list
python scripts/sim.py lint --tb top
python scripts/sim.py run --tb top --test dma_smoke_test --seed 1
python scripts/regress.py --suite all --seeds 2 --jobs 6
python scripts/sim.py cov-report --tb top     # out/top/cov/func/xcrg_func_cov_report.txt
python scripts/signoff.py --level smoke       # sign-off 기준 판정 (smoke / nightly / release)
python scripts/gate.py static                 # hook/스크립트 테스트, 검사 목록, 계획, 문서 (시뮬레이션 없음)
python scripts/plan_check.py --write          # plan.toml에서 vplan.md 생성 + 검사
```

## XSim 2022.2 주의사항 (이미 처리함, 다시 만들지 말 것)
- 넓은 범위에 `dist`를 쓰면 값이 심하게 치우칩니다. 경계값 편향은 절차적으로 넣습니다.
- `coverpoint` 식 안의 폭 변환(cast)은 잘못 계산됩니다. 먼저 계산하고 샘플링합니다.
- `small`, `large`, `medium`, `weak*`, `strong*`은 키워드입니다. bin 이름으로 쓰지 않습니다.
- 함수 호출 결과에는 비트 선택을 할 수 없습니다 (`f()[3:0]`). 임시 변수를 씁니다.
- bin 상한에 `$`를 쓰면 (`[513:$]`) 잘못 계산돼 모든 샘플이 그 bin에 들어갑니다. 상한을 명시합니다.
- `xcrg`는 기존 보고서 뒤에 덧붙입니다. `sim.py cov-report`는 먼저 `out/<tb>/cov`를 비웁니다.
- static 함수 안에서 다른 클래스의 static 함수를 부르면 elaboration(xelab codegen)이
  EXCEPTION_ACCESS_VIOLATION으로 죽습니다 (TB 1단계에서 확인). 그런 호출은 non-static 함수에서 합니다.
- 같은 `-sv_seed`라도 컴파일된 코드 구조가 바뀌면(호출하지 않는 task 하나만 더해도) 랜덤 값이 달라집니다. `--trace`
  (debug 빌드)도 같은 seed에서 랜덤 값이 다릅니다. 변경 전후 동등성은 job 값을 고정한 replay나 판정·요약 불변량으로
  비교하고, trace로 시각을 볼 때는 그 trace 실행 자신의 로그 시각을 씁니다 (TB 2단계에서 확인).
- 주석과 설명은 한국어로 씁니다 (UTF-8). XSim은 한글 주석을 문제없이 컴파일합니다. 로그 메시지와
  태그(`[SB_JOB]` 등)는 스크립트가 파싱하므로 영어로 둡니다.

## UVM 코드 배치
- **파일 하나에 클래스 하나, 파일 이름 = 클래스 이름** (`dma_scoreboard` → `dma_scoreboard.svh`).
- `*_pkg.sv`에는 import, 패키지 전체의 typedef/상수, `` `include `` 줄만 둡니다.
  filelist(`.f`)에는 패키지 파일만 적고, 클래스 파일은 적지 않습니다. 패키지가 include하는 역할 폴더마다 `+incdir+`를 둡니다.
- 레지스터 모델은 RAL(`uvm_reg`)입니다 (TB 1단계). `verif/top/model/dma_reg_block.svh`는 정의되지 않은 비트도 RO 필드로
  모델링해 32비트 전체를 덮습니다. 레지스터 접근은 regmodel frontdoor(`axil_reg_adapter`)로 합니다. mirror는 auto predict를
  끄고 axil_monitor → `dma_predictor` → `uvm_reg_predictor` 순서로만 갱신합니다(순서를 바꾸면 predictor가 이미 갱신된
  mirror와 비교해 검사가 무력해집니다). 읽기 값과 interrupt 판정은 `dma_predictor`, 버스와 메모리 판정은 `dma_scoreboard`가
  합니다. `axil_reg_base_seq::write_reg()/read_reg()`는 RAL 없이 직접 접근할 때만 씁니다.
- 자극은 env가 아니라 sequence(`verif/top/seq/`, `verif/vip/stream/`의 `stream_rand_seq`)에 둡니다.

## 테스트 추가 방법
`verif/<unit|top>/test/<test_name>.svh`를 만들고 (클래스 하나), 그 디렉터리의 `*_test_pkg.sv`에
`` `include `` 줄을 추가하고, `verif/sim_cfg.json`의 그 TB `tests` 목록에 넣고 (CI와 `regress.py`가 돌리는
목록), `verif/plan.toml`의 기능에 테스트를 넣고 `python scripts/plan_check.py --write`로 vplan.md를 다시 만든 뒤,
lint → seed 3개 이상 실행 → 영향받는 suite 회귀 → `python scripts/gate.py static` 순으로 확인합니다.
