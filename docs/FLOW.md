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
| 1 | Plan | 모드(smoke 또는 full)와 seed 수를 정합니다 | – |
| 2 | Lint | 모든 TB를 컴파일하고 elaborate합니다 (`sim.py lint`) | 컴파일 에러 |
| 3 | Unit regression | 블록 단위 TB 5종을 병렬로 돌립니다 (smoke 30회) | FAIL 또는 XPASS |
| 4 | Top regression | DMA 전체 TB를 돌립니다 (smoke 6회) | FAIL 또는 XPASS |
| 5 | FPGA timing | `fpga.py ooc`로 DMA만 따로 배치·배선해 100MHz 타이밍을 봅니다 | WNS < 0 |
| 6 | FPGA bitstream | `fpga.py system`으로 PS7과 BD를 넣어 .bit과 .xsa를 만듭니다 | 타이밍 위반이나 빌드 에러 |
| 7 | Coverage | 커버리지를 수집하고 리포트를 만듭니다 | – |

- 6단계와 7단계는 full 모드에서만 돕니다. 6단계는 `BITSTREAM=true`를 줘도 돕니다.
- XFAIL(알려진 버그 재현)은 skip으로 집계되므로 빌드가 계속 초록으로 유지됩니다.
- RTL이 고쳐져서 XFAIL 테스트가 통과하면 XPASS가 되고, 빌드가 실패합니다. 이것이 `known_fail` 등록을 지우라는
  신호입니다.

## 3. 시뮬레이션 한 번

예: `python scripts/sim.py run --tb top --test dma_smoke_test --seed 1`

```
 sim_cfg.json에서 TB 정보 조회 (filelist, top, known_fail)
   → xvlog  : 컴파일 (filelist/*.f)
   → xelab  : elaborate (스냅샷 생성)
   → xsim   : 실행 (+UVM_TESTNAME, seed)
   → 로그 분석 : UVM_ERROR/FATAL 수, 종료 여부
   → 판정    : PASS / FAIL / XFAIL / XPASS / NO_RESULT
```

xsim 안에서 top 테스트는 다음 순서로 진행됩니다.

1. **build/connect 단계:** env를 만듭니다.
   - AXI-Lite 마스터 에이전트
   - AXI4 슬레이브 메모리 모델
   - 스코어보드
   - 커버리지
2. **리셋 후 레지스터 확인:** `reg_reset` 테스트와 `reg_bitbash` 테스트는 여기서 끝납니다.
3. **job 준비:** `dma_job_seq`가 메모리 모델에 무작위 source 데이터를 채웁니다. 그다음 `write_reg`로 레지스터를 씁니다.
   - src 주소, dst 주소, 길이, 더할 값
4. **`ap_start`:** DUT가 동작을 시작합니다.
   - RDMA가 AXI4로 source를 읽습니다(AR/R).
   - 읽은 데이터가 FIFO, adder, FIFO를 지납니다.
   - WDMA가 결과를 씁니다(AW/W/B).
   - 이 동안 메모리 모델은 채널마다 무작위 지연(backpressure)을 줍니다.
5. **완료 대기:** `ap_done`이나 인터럽트를 기다립니다. 정해진 시간이 지나도 오지 않으면 타임아웃으로 FAIL입니다.
   BUG-002가 이렇게 드러났습니다.
6. **결과 확인:** 스코어보드가 dst 메모리를 기대값과 바이트 단위로 비교합니다. 기대값은 src + value[7:0]입니다.
   dst 앞뒤 guard 영역, src 보존, burst 주소 범위, beat 총수도 확인합니다. burst 규칙(INCR, 8바이트, 4KB 경계,
   최대 16 beat, WLAST)은 AXI4 슬레이브 모델이 burst마다 실시간으로 검사합니다.
7. **반복:** job이 여러 개인 테스트(`small` 30개, `rand`/`4kb` 15개 등)는 3~6을 job 수만큼 반복합니다.
   커버리지는 job 크기와 burst 형태를 샘플링합니다.

unit 테스트는 더 단순합니다. `vr_agent`가 입력 스트림을 넣고, 출력을 받는 쪽에 무작위 ready를 줍니다.
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
                   → 사람에게 보고하고 결정을 기다립니다 (BUG-001: won't fix, BUG-002: 결정 대기)
```

검사를 느슨하게 만들어서 통과시키는 것은 금지입니다. 실패는 TB를 고치거나 버그로 등록하는 두 가지 중 하나로만
처리합니다.

## 5. 에이전트 루프 (`/verify-loop`)

사람이 "이 기능 검증해줘"라고 하면 다음 순서로 진행합니다.

```
 verif-planner  : RTL, vplan, 커버리지를 읽고 작업 목록을 만듭니다
   → uvm-builder    : 테스트와 시퀀스를 구현하고, lint와 run까지 확인합니다
   → coverage-closer: 비어 있는 커버리지 bin을 메웁니다 (자극만 조정하고 검사는 건드리지 않습니다)
   → regress.py     : 영향받는 suite를 회귀 테스트합니다
   → sim-triage     : 실패를 분류합니다 (RTL 버그면 여기서 멈추고 사람에게 묻습니다)
   → [사람 승인] 커밋과 push
   → ci-watcher     : Jenkins 결과를 확인하고 보고합니다
```

각 에이전트는 MCP 도구로 일합니다. `vivado` MCP는 `sim.py`/`regress.py`를 감싼 것이고, 그 밖에 `jenkins` MCP와
`github` MCP를 씁니다. 그래서 사람이 직접 하든 에이전트가 하든 결국 같은 스크립트가 실행됩니다.
