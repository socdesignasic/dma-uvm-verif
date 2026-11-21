# 진행 흐름

흐름은 세 겹으로 나눠 보면 이해하기 쉽습니다. 바깥부터 순서대로 설명합니다.

1. **개발 흐름:** 코드를 바꾼 뒤 CI를 거쳐 결과가 나오기까지
2. **CI 파이프라인:** Jenkins 안에서 단계가 진행되는 순서
3. **시뮬레이션 한 번:** 테스트 하나가 실행되는 과정

여기에 실패가 났을 때의 처리 흐름과 에이전트 루프가 더해집니다. 디렉터리 구성은
[ARCHITECTURE.md](ARCHITECTURE.md)를 참고하세요.

---

## 1. 개발 흐름 (전체)

```
 테스트/TB 수정 (verif/)
      │
      ▼
 로컬 확인: sim.py lint → sim.py run (seed 3개 이상) → regress.py
      │
      ▼
 git commit / push (사용자가 요청할 때만)
      │
      ▼
 Jenkins가 5분마다 GitHub를 polling → 변경을 감지하면 smoke 빌드
 (매일 02:00에는 변경이 없어도 full 빌드)
      │
      ▼
 결과: SUCCESS / UNSTABLE / FAILURE, JUnit 리포트, OOC 타이밍, (full이면) 비트스트림과 커버리지
```

로컬과 CI는 같은 `scripts/*.py`를 실행합니다. 그래서 로컬에서 통과하면 CI에서도 같은 결과가 나옵니다.

## 2. CI 파이프라인 (Jenkinsfile)

| 순서 | 단계 | 하는 일 | 실패 기준 |
|---|---|---|---|
| 1 | Plan | 모드(smoke 또는 full)와 seed 수를 정합니다. smoke는 ML 회귀 계획(`verif/regress_plan.json`)을 씁니다 | – |
| 2 | Lint | `gate.py static`(hook 테스트, 스크립트 테스트, 검사 목록 기준선, 검증 계획, 문서)을 돌리고, DUT와 top TB를 컴파일·elaborate합니다(`sim.py lint`) | 정적 검사 실패, 컴파일 에러 |
| 3 | Unit regression | 블록 단위 TB 5종을 병렬로 돌립니다 (smoke 계획 30회 + 계획에 없는 테스트 1개, 31회) | FAIL 또는 XPASS |
| 4 | Top regression | DMA 전체 TB를 돌립니다 (smoke 계획 17회 + 계획에 없는 테스트 10개, 27회) | FAIL 또는 XPASS |
| 4a | Plan coverage | smoke가 계획의 목표 bin(183개)을 모두 채웠는지 확인합니다 (`ml_regress.py check`) | 못 채우면 UNSTABLE |
| 5 | FPGA timing (OOC) | `fpga.py ooc`로 DMA만 따로 배치·배선해 100MHz 타이밍을 봅니다 | WNS < 0 |
| 6 | FPGA bitstream | `fpga.py system`으로 PS7과 BD를 넣어 .bit과 .xsa를 만듭니다 | 타이밍 위반이나 빌드 에러 |
| 7 | Coverage | 이번 빌드의 실행으로 커버리지 리포트를 만듭니다 | – |
| 8 | Sign-off | `signoff.py`로 `verif/SIGNOFF.md`의 기준 S1~S11을 판정합니다 (smoke는 smoke, full은 nightly 수준) | 기준 미달이면 UNSTABLE |

- 6단계는 full 모드에서만 돕니다. `BITSTREAM=true`를 줘도 돕니다. 7단계는 두 모드 모두 돕니다.
- 4a단계는 계획을 쓴 smoke에서만 돕니다. 계획은 교차 검증에서 100% 도달 확률 99.1%라, 드물게 UNSTABLE이 날 수 있습니다.
- XFAIL(알려진 버그 재현)은 skip으로 집계되므로 빌드가 계속 초록으로 유지됩니다.
- RTL이 고쳐져서 XFAIL 테스트가 통과하면 XPASS가 되고, 빌드가 실패합니다. 이것이 `known_fail` 등록을 지우라는
  신호입니다.

## 3. 시뮬레이션 한 번

예: `python scripts/sim.py run --tb top --test dma_smoke_test --seed 1`

```
 sim_cfg.json에서 TB 정보 조회 (filelist, top, known_fail)
   → xvlog  : 컴파일 (verif/rtl.f, TB의 *.f)
   → xelab  : elaborate (스냅샷 생성)
   → xsim   : 실행 (+UVM_TESTNAME, seed)
   → 로그 분석 : UVM_ERROR/FATAL 수, 종료 여부
   → 판정    : PASS / FAIL / XFAIL / XPASS / NO_RESULT
```

xsim 안에서 top 테스트는 다음 순서로 진행됩니다.

1. **build/connect 단계:** env를 만듭니다.
   - AXI-Lite 마스터 에이전트(monitor 포함)
   - AXI4 슬레이브 메모리 모델
   - RAL 모델과 predictor(`dma_predictor`, `uvm_reg_predictor`)
   - 스코어보드
   - 커버리지

   연결과 데이터 흐름은 [UVM_STRUCTURE.md](UVM_STRUCTURE.md) 2절에 적습니다.
2. **리셋 후 레지스터 확인:** `reg_reset` 테스트와 `reg_bitbash` 테스트는 여기서 끝납니다.
   읽은 값은 `dma_predictor`가 32비트 전체로 비교합니다.
3. **job 준비:** `dma_job_vseq`가 메모리 모델에 무작위 source 데이터를 채웁니다. 그다음 `regmodel`(frontdoor)로 레지스터를 씁니다.
   - src 주소, dst 주소, 길이, 더할 값
4. **`ap_start`:** DUT가 동작을 시작합니다. `dma_predictor`가 start 모델로 블록이 start를 받아들이는 에지(PRE 진입)를 계산하고, 그때의 레지스터 값으로 job을 만들어 스코어보드로 보냅니다.
   - idle에서 쓴 start는 바로 받아들입니다.
   - 작업 중에 쓴 start는 대기했다가 지금 작업이 끝난 뒤 실행하는 것이 사양이고, `auto_restart`도 같습니다. 이 동작은 TB가 정한 모델입니다. RTL은 이 경우 시작하지 않아(BUG-005) 해당 테스트가 FAIL합니다(XFAIL). 모델 설명은 [UVM_STRUCTURE.md](UVM_STRUCTURE.md) 2절.
   - RDMA가 AXI4로 source를 읽습니다(AR/R).
   - 읽은 데이터가 FIFO, adder, FIFO를 지납니다.
   - WDMA가 결과를 씁니다(AW/W/B).
   - 이 동안 메모리 모델은 채널마다 무작위 지연(backpressure)을 줍니다.
5. **완료 대기:** `ap_done`이나 인터럽트를 기다립니다. 정해진 시간이 지나도 오지 않으면 `JOB_TIMEOUT`으로 FAIL입니다.
   BUG-002가 이렇게 드러났습니다. 완료 중 읽은 값과 interrupt 핀은 `dma_predictor`가 비교합니다.
6. **결과 확인:** 스코어보드가 AR/AW/W를 기대 목록과 beat 단위로 비교하고, 마지막 B 뒤에 dst 메모리를 기대값과
   바이트 단위로 비교합니다. 기대값은 start 시점 src + value[7:0]입니다. dst 앞뒤 guard 영역, src 보존,
   burst 주소 범위, beat 총수도 확인합니다. burst 규칙(INCR, 8바이트, 4KB 경계, 최대 16 beat)은 AXI4 슬레이브
   monitor가 burst마다, WLAST는 driver가 실시간으로 검사합니다. DUT 안쪽 ap_start/ap_idle/ap_ready/ap_done은
   `dma_ap_ctrl_sva`의 assertion(`APCTRL_SVA`)이 매 클럭 검사합니다.
7. **테스트 중간 리셋(선택):** 리셋이 필요한 테스트는 `dma_reset_vseq`로 리셋을 겁니다. 진행 중인 AXI-Lite 접근이 끝난 뒤 리셋하고,
   실행 중이던 job은 predictor가 중단합니다. 스코어보드는 중단을 정보로만 남기고, 리셋 뒤 job 없는 버스 활동은 `SB_NO_JOB_BUS`로 잡습니다.
   구성 요소별 동작은 [UVM_STRUCTURE.md](UVM_STRUCTURE.md) 5절 "리셋"에 적습니다.
8. **반복:** job이 여러 개인 테스트(`short_job` 30개, `rand`/`4kb_cross` 15개 등)는 3~6을 job 수만큼 반복합니다.
   커버리지는 스코어보드가 검사를 끝낸 job의 크기와 burst 형태를 샘플링합니다.

unit 테스트는 더 단순합니다. `stream_agent`가 입력 스트림을 넣고, 출력을 받는 쪽에 무작위 ready를 줍니다.
스코어보드는 입력을 순서대로 기대값으로 삼아 출력과 비교합니다.

## 4. 실패했을 때의 흐름

```
 FAIL 발생
   → sim-triage(또는 사람)가 로그와 파형으로 분류합니다
      ├─ TB 버그  → verif/ 수정 → 다시 실행
      ├─ 환경 문제 → 스크립트나 설정 수정
      └─ RTL 버그 → HW/는 고치지 않습니다 (hook이 막습니다)
                   → BUGS.md에 증상, 원인, 재현 명령, 수정 제안을 적습니다
                   → sim_cfg.json에 known_fail로 등록합니다 (XFAIL)
                   → 사람에게 보고하고 결정을 기다립니다 (BUG-001: won't fix, BUG-002~007: 결정 대기)
```

검사를 느슨하게 만들어서 통과시키는 것은 금지입니다. 실패는 TB를 고치거나 버그로 등록하는 두 가지 중 하나로만
처리합니다.

## 5. 에이전트 흐름 (`/verify-stage`)

사람이 "이 기능 검증해줘", "N단계 진행해"라고 하면 `verify-stage` 스킬이 다음 순서로 진행합니다.

```
 verif-planner : plan.toml, RTL, 커버리지(못 친 bin)를 읽고 작업 목록을 만듭니다 (작업마다 건드릴 파일과 통과할 gate)
   → uvm-builder  : worktree마다 하나씩, 구현하고 lint와 seed 3개 실행, gate static까지 확인합니다
   → tb-reviewer  : builder의 diff를 검토합니다 (검사 약화, 등록, 코딩 규칙, 실행 근거). 수정 요청이면 builder로
   → [사람 확인] worktree의 변경을 주 작업 트리로 가져옴
   → gate.py <단계>: 완료 판정 (필요하면 회귀를 먼저 돌림). 판정은 ledger에 남깁니다
   → sim-triage   : 실패를 분류합니다. RTL이 의심되면 confirm-hypothesis로, 확인되면 file-rtl-bug로 등록하고 멈춥니다
   → [사람 승인] 커밋과 push
   → ci-check     : ci-watcher가 Jenkins 결과를 보고, 실패가 있으면 sim-triage가 분류합니다
```

각 에이전트는 MCP 도구로 일합니다. `vivado` MCP는 `scripts/`를 감싼 것이고(worktree는 `workspace` 인자로),
그 밖에 `jenkins` MCP와 `github` MCP를 씁니다. 사람이 직접 하든 에이전트가 하든 결국 같은 스크립트가 실행됩니다.
