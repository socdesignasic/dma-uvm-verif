# 코드 구조

저장소는 다섯 층으로 나뉩니다. 맨 아래 RTL(DUT)이 있고, 그 위에 UVM 검증 환경, 실행 스크립트,
CI/CD, 에이전트 자동화가 차례로 올라갑니다. 위층은 모두 아래층을 감싸는 형태이고, 시뮬레이션과 빌드는
결국 `scripts/` 아래의 스크립트(`sim.py`, `regress.py`, `fpga.py`)를 통해서만 실행되고, 판정과 검사도 같은 폴더의
스크립트가 합니다.

```
 사람 / Claude Code ──(MCP, 서브에이전트)──┐
 Jenkins (Jenkinsfile) ────────────────────┤
                                           ▼
            scripts/sim.py · regress.py · fpga.py   ← 단일 진입점
                 │                     │
          verif/ (UVM TB)        ci/vivado/ (Tcl, BD, IP 메타)
                 └──────── HW/ (RTL, 읽기 전용) ───┘
```

## 1. `HW/`: 검증 대상 RTL (수정 금지)

| 파일 | 역할 |
|---|---|
| `dma_ip/dma_ip_top.v`, `dma_wrapper.v` | 최상위 모듈 |
| `dma_ip/dma_ip_control_s_axi.v` | AXI-Lite 레지스터 (ap_start/done, 주소, 길이, 더할 값, 인터럽트) |
| `dma_ip/RDMA/rdma.v` | AXI4로 메모리를 읽어 스트림으로 내보냄 |
| `dma_ip/axis_adder.v` | 스트림 데이터마다 값을 더함 (top에서는 8비트) |
| `dma_ip/WDMA/wdma.v` | 스트림을 AXI4로 메모리에 씀 (BUG-002~004가 여기 있음. 버그별 위치는 [BUGS.md](../verif/BUGS.md)) |
| `peri_ip/sync_fifo.v`, `skid_buffer.v` | FIFO와 skid buffer (BUG-001이 여기 있음) |

데이터는 메모리에서 RDMA, FIFO, adder, FIFO, WDMA를 거쳐 다시 메모리로 갑니다. 전송 동작은 레지스터로
설정합니다.

## 2. `verif/`: UVM 검증 환경

UVM 코드는 파일 하나에 클래스 하나를 담고, 파일 이름은 클래스 이름과 같습니다. 자세한 구조는
[UVM_STRUCTURE.md](UVM_STRUCTURE.md)를 참고하세요.

- **`vip/`:** 재사용하는 VIP 세 개입니다. DUT를 모릅니다.
  - `stream/`: valid/ready 스트림을 구동하고 모니터링합니다 (`stream_agent`).
  - `axil/`: AXI-Lite 마스터입니다 (`axil_agent`). driver, monitor, RAL용 adapter(`axil_reg_adapter`)가 있습니다. 레지스터는 top TB의 RAL(`dma_reg_block`)로 읽고 씁니다.
  - `axi4_slave/`: AXI4 슬레이브 메모리 모델입니다 (`axi4_slave_agent`). driver(응답)와 monitor(AR/AW/W/B 관찰, burst 검사)로 나뉩니다. AR/R/AW/W/B 채널마다 지연을 넣어
    backpressure를 줄 수 있습니다.
- **`unit/`:** FIFO, skid buffer, adder 같은 블록 단위 TB입니다. `env/`, `scoreboard/`, `coverage/`, `test/`와 TB top(`tb_*.sv`)이 있습니다. 시퀀스는 `vip/stream/`의 것을 씁니다.
- **`top/`:** DMA 전체 TB입니다. 역할 폴더마다 나뉩니다.
  - `env/`: env, env cfg, job virtual sequencer(`dma_vsqr`, 리셋 interface 핸들 포함), 패키지
  - `model/`: 레지스터 주소 상수(`dma_reg_map.svh`), RAL 블록과 레지스터 클래스, `dma_job.svh`, 기대 동작 모델(`dma_ref_model`), `dma_predictor`(ap_ctrl_hs start 모델, 리셋 중단 포함)
  - `scoreboard/`, `coverage/`: monitor와 predictor가 본 것으로 job의 메모리 결과(dst = src + value)와 버스 트래픽을 비교하고, `cg_job`과 `cg_burst`로 기능 커버리지를 수집합니다. 데이터 흐름은 UVM_STRUCTURE.md 2절에 한 번만 적습니다.
  - `seq/`: job 하나를 끝까지 실행하는 virtual sequence `dma_job_vseq`(`dma_vsqr`에서 실행)와 이를 확장한 `dma_pipeline_vseq`(연속 job), `dma_busy_reg_vseq`(작업 중 레지스터 쓰기), 테스트 중간 리셋 `dma_reset_vseq`, 레지스터 bit-bash `dma_reg_bitbash_vseq`
  - `test/`: 테스트 클래스(checker self-test `dma_checker_test`, RTL 가설 테스트 포함). TB별 테스트 수는 [verif/README.md](../verif/README.md)의 표(코드에서 생성)를 봅니다.
  - `tb_dma.sv`: TB top 모듈
  - `dma_reset_if.sv`: 전원 리셋과 테스트 중간 리셋이 같이 쓰는 interface
  - `dma_ap_ctrl_sva.sv`: DUT 안쪽 ap_ctrl_hs 신호를 `bind`로 검사하는 assertion 모듈
- **`ref_adder/`:** 참고 코드를 이식한 TB입니다. 의도적으로 실패하는 예시(XFAIL)입니다.
- **`selftest/`:** `sim.py` 판정이 XSim 자체 메시지를 잡는지 확인하는 자체 시험용 TB입니다.
- **`*.f`:** TB 폴더마다 컴파일할 파일 목록(`<이름>.f`)이 있고, RTL 목록은 `verif/rtl.f`입니다. 패키지 파일과 `+incdir+`만 적습니다.
- **`sim_cfg.json`:** TB 레지스트리입니다. TB마다 filelist, 테스트 목록, `known_fail`을 정합니다. CI와 회귀
  테스트는 이 파일에 등록된 것만 돌립니다.
- **`plan.toml`:** 검증 계획의 원본입니다. 기능마다 테스트, 검사 ID, 커버포인트를 적고, 가설, 버그, waiver,
  승인된 RTL 해시도 여기에 둡니다. `vplan/vplan.md`는 여기서 생성합니다(`python scripts/plan_check.py --write`).
- **`check_baseline.json`:** 검사 목록의 기준선입니다. 검사가 줄면 `check_inventory.py --compare`가 실패합니다.
- **`BUGS.md`:** 검증에서 찾은 RTL 버그(BUG-001~BUG-007)와 설계 노트(NOTE-001~NOTE-003)입니다. 상태와 재현 명령은 이 파일이 원본입니다.

## 3. `scripts/`: 실행 진입점

실행하는 스크립트(`sim.py`, `regress.py`, `fpga.py`, `board.py`, `board_c.py`)와 판정·검사하는 스크립트가
있습니다. 아래 표는 각 스크립트의 설명 첫 줄에서 생성합니다(`python scripts/check_docs.py --write`).

<!-- gen:scripts -->
| 스크립트 | 하는 일 |
|---|---|
| `scripts/board.py` | 보드 시험: Zybo에 비트스트림을 올리고 DMA mem copy를 실제 DDR에서 실행해 결과를 확인. |
| `scripts/board_c.py` | C 보드 시험: ARM(Cortex-A9)에서 C 프로그램이 DMA를 구동하고 결과를 스스로 판정합니다. |
| `scripts/check_agents.py` | 서브에이전트(.claude/agents/*.md)와 스킬(.claude/skills/*/SKILL.md) 정의를 검사합니다. |
| `scripts/check_docs.py` | 문서가 코드와 맞는지 검사하고, 문서의 생성 구간을 다시 만듭니다. |
| `scripts/check_inventory.py` | verif/ 아래의 검사 목록을 세고, 기준선과 비교합니다. |
| `scripts/ci_status.py` | Jenkins 빌드 결과를 GitHub 커밋 상태(commit status)로 올립니다. |
| `scripts/common.py` | scripts/ 아래 스크립트가 같이 쓰는 함수. |
| `scripts/fpga.py` | FPGA 구현 흐름의 단일 진입점 (P6, "CD"). |
| `scripts/gate.py` | 단계의 완료 기준을 기계로 판정합니다. 에이전트는 "끝났다"를 글로 말하지 않고 이 결과로 말합니다. |
| `scripts/ml_regress.py` | 회귀 결과로 커버리지 모델을 학습해, 같은 커버리지를 더 적은 실행으로 얻는 회귀 계획을 만듭니다. |
| `scripts/plan_check.py` | 검증 계획 데이터(verif/plan.toml)가 코드와 서로 맞는지 검사하고, vplan.md를 생성합니다. |
| `scripts/record_signoff.py` | Jenkins 빌드 하나의 결과를 판정해 verif/SIGNOFF.md의 판정 기록 표에 한 줄을 넣습니다. |
| `scripts/regress.py` | 선택한 TB에 등록된 모든 테스트를 seed N개로 병렬 실행합니다. |
| `scripts/signoff.py` | verif/SIGNOFF.md의 sign-off 기준을 결과 파일로 판정합니다. |
| `scripts/sim.py` | Vivado XSim 시뮬레이션의 단일 진입점. |
| `scripts/sync_public.py` | 비공개 저장소의 커밋된 내용을 공개 저장소(dma-uvm-verif) checkout으로 옮길 내용을 만듭니다. |
| `scripts/vcd.py` | VCD 파일에서 시간 구간의 신호 변화를 텍스트로 뽑습니다 (MCP trace_signals, 가설 확인용). |
| `scripts/xcrg_report.py` | xcrg 2022.2 기능 커버리지 텍스트 보고서(xcrg_func_cov_report.txt)를 읽습니다. |
<!-- /gen:scripts -->

모든 결과 파일(`result.json`, `summary.json`, `out/fpga/*/result.json`, 보드 결과)에 커밋, 수정 여부, HW/ 내용
해시를 남기고(`common.py`의 `provenance`), sign-off는 출처가 섞인 결과를 받지 않습니다(S10, S11).
스크립트 자체의 테스트는 `scripts/tests/`에 있습니다(`python -m unittest discover -s scripts/tests -t scripts`).

로컬과 CI가 같은 스크립트를 쓰기 때문에, 로컬 결과와 CI 결과가 같습니다.

## 4. CI/CD: `Jenkinsfile`, `ci/`

- **`Jenkinsfile`:** 단계와 실패 기준은 [FLOW.md](FLOW.md) 2절의 표에만 적습니다(`check_docs.py`가 Jenkinsfile과 비교).
- **`ci/jenkins.yaml`:** JCasC 설정입니다. 사용자, 자격 증명, 잡, 트리거(push 후 5분 polling, nightly 02:00)를
  정합니다.
- **`ci/plugins.txt`:** 설치할 Jenkins 플러그인 목록입니다.
- **`ci/start-jenkins.ps1`, `ci/stop-jenkins.ps1`:** 포트 8090에서 Jenkins를 시작하고 멈춥니다. 비밀값은 저장소
  밖 `secrets\casc`에 둡니다.
- **`ci/vivado/`:** Vivado 빌드 재료입니다.
  - `ooc.tcl`, `build_system.tcl`: 빌드 Tcl
  - `bd/design_1.tcl`: 블록 디자인
  - `ip/dma_ip_top/`: IP 패키징 메타데이터
  - 빌드할 때는 이 메타데이터와 `HW/`를 합쳐 IP repo를 조립하므로, 검증한 RTL 그대로 비트스트림이 만들어집니다.

## 5. 에이전트 자동화: `mcp/`, `.claude/`, `CLAUDE.md`

- **`mcp/vivado_mcp/server.py`:** `sim.py`와 `regress.py`를 MCP 도구로 노출합니다(목록은 [mcp/README.md](../mcp/README.md)). 테스트 실행, 로그 발췌,
  커버리지, 회귀, known bug 조회 등이 있습니다. Jenkins MCP와 GitHub MCP는 로컬 설정에만 등록돼 있습니다.
- **`.claude/agents/`:** 서브에이전트 일곱 개입니다. 만드는 쪽과 검토하는 쪽을 나눴고, 검토하는 쪽은 파일을 고치지 않습니다.
  - 만드는 쪽: `verif-planner`(작업 목록, 커버리지 구멍 분석, plan.toml만 고침), `uvm-builder`(worktree에서 구현,
    lint와 seed 3개 실행), `doc-sync`(구조가 바뀐 뒤 문서만 고침)
  - 검토하는 쪽: `rtl-reviewer`(RTL을 읽고 가설), `tb-reviewer`(builder의 diff 승인 또는 수정 요청),
    `sim-triage`(실패 분류), `ci-watcher`(CI 상태, 작은 모델)
- **`.claude/skills/`:** 사람과 함께 진행하는 절차입니다. `verify-stage`(단계를 gate PASS까지), `ci-check`(CI 확인과
  실패 분류), `confirm-hypothesis`(가설 확인), `add-test`(테스트 추가), `file-rtl-bug`(RTL 버그 등록 후 멈춤),
  `record-signoff`(빌드 판정 기록), `sync-public`(공개 저장소 반영). 정해진 계산은 스크립트가 합니다.
- 에이전트와 스킬 정의(도구 이름, 쓰기 권한, 박힌 경로, 없는 이름 참조)는 `scripts/check_agents.py`가 검사합니다.
- **`.claude/hooks/`:** 세 겹으로 규칙을 지킵니다.
  - 실행 전: `protect_rtl.py`(HW/ 쓰기 차단, worktree 포함, 저장소 전체 git 명령은 확인), `guard_rules.py`(시뮬레이터 직접 호출 차단, known_fail 등록 확인)
  - 실행 후: `post_tool_use.py`(HW/가 git HEAD와 달라지면 되돌림, verif/를 고치면 검사 목록을 기준선과 비교)
  - 세션 시작: `session_start.py`(브랜치, HW/, Jenkins 상태)
  - 회귀 테스트: `test_hooks.py`. 커밋 메시지와 금지어는 `.githooks/`가 막습니다(`git config core.hooksPath .githooks`).
- **`CLAUDE.md`:** 에이전트 작업 규칙과 XSim 함정 목록입니다.

## 기타

- **`uvm_reference/`:** 받은 참고 코드입니다. 수정하지 않습니다.
- **`docs/REPORT.md`:** 검증·CI/CD 결과 보고서입니다(2026-11-21 기준). 판정 기록의 원본은 `verif/SIGNOFF.md`입니다.
- **`fw/`:** 보드 시험용 ARM C 프로그램입니다(`board_c.py`, 실행 방법은 `ci/README.md`).
- **`SW/`:** 보드용 소프트웨어입니다.
- **`out/`:** 빌드와 시뮬레이션 결과물입니다. git에 넣지 않습니다.
