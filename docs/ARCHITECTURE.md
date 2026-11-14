# 코드 구조

저장소는 다섯 층으로 나뉩니다. 맨 아래 RTL(DUT)이 있고, 그 위에 UVM 검증 환경, 실행 스크립트,
CI/CD, 에이전트 자동화가 차례로 올라갑니다. 위층은 모두 아래층을 감싸는 형태이고, 시뮬레이션과 빌드는
결국 `scripts/` 아래의 스크립트 세 개를 통해서만 실행됩니다.

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
| `dma_ip/WDMA/wdma.v` | 스트림을 AXI4로 메모리에 씀 (BUG-002가 여기 있음) |
| `peri_ip/sync_fifo.v`, `skid_buffer.v` | FIFO와 skid buffer (BUG-001이 여기 있음) |

데이터는 메모리에서 RDMA, FIFO, adder, FIFO, WDMA를 거쳐 다시 메모리로 갑니다. 전송 동작은 레지스터로
설정합니다.

## 2. `verif/`: UVM 검증 환경

UVM 코드는 파일 하나에 클래스 하나를 담고, 파일 이름은 클래스 이름과 같습니다. 자세한 구조는
[UVM_STRUCTURE.md](UVM_STRUCTURE.md)를 참고하세요.

- **`agents/`:** 재사용하는 에이전트 세 개입니다.
  - `vr_agent`: valid/ready 스트림을 구동하고 모니터링합니다.
  - `axil_agent`: AXI-Lite 마스터입니다. 레지스터는 `axil_base_seq`의 `write_reg`/`read_reg`로 읽고 씁니다(RAL 없음).
  - `axi4_slv_agent`: AXI4 슬레이브 메모리 모델입니다. driver(응답)와 monitor(관찰, burst 검사)로 나뉩니다. AR/R/AW/W/B 채널마다 지연을 넣어
    backpressure를 줄 수 있습니다.
- **`env/unit`:** FIFO, skid buffer, adder 같은 블록 단위 env입니다. 스코어보드와 커버리지가 들어 있습니다.
- **`env/top`:** DMA 전체 env입니다. 레지스터 주소 상수(`dma_reg_map.sv`)도 여기 있습니다. 메모리 모델로 기대 결과(dst = src + value)를 비교하고, `cg_job`과
  `cg_burst`로 기능 커버리지를 수집합니다.
- **`sequences/top/`:** top 시퀀스입니다. job 하나를 끝까지 실행하는 `dma_job_seq`와 레지스터 검사 시퀀스 2개가 있습니다.
- **`tests/unit`, `tests/top`:** 테스트 클래스입니다. unit 6종, top 11종입니다.
- **`tb/`:** TB top 모듈입니다. `ref_adder`는 참고 코드를 이식한 것으로, 의도적으로 실패하는 예시(XFAIL)입니다.
- **`filelist/*.f`:** TB마다 컴파일할 파일 목록입니다.
- **`sim_cfg.json`:** TB 레지스트리입니다. TB마다 filelist, 테스트 목록, `known_fail`을 정합니다. CI와 회귀
  테스트는 이 파일에 등록된 것만 돌립니다.
- **`vplan/vplan.md`:** 기능, 테스트, 커버리지의 대응표입니다.
- **`BUGS.md`:** 검증에서 찾은 RTL 버그(BUG-001, BUG-002)와 설계 노트(NOTE-001)입니다.

## 3. `scripts/`: 실행 진입점

- **`sim.py`:**
  - 하위 명령: `list`, `lint`, `run`, `cov-report`
  - xvlog → xelab → xsim을 감싸고, 로그를 분석해 PASS/FAIL/XFAIL/XPASS를 판정합니다.
  - Windows `.bat` 인자 처리 같은 XSim 우회 처리도 모두 여기에 있습니다.
- **`regress.py`:** `sim.py`를 seed와 테스트 조합으로 병렬 실행하고, `junit.xml`과 `summary.json`을 만듭니다.
- **`fpga.py`:**
  - `ooc`: DMA만 따로 합성, 배치, 배선해서 타이밍을 확인합니다.
  - `system`: PS7과 블록 디자인을 함께 빌드해 비트스트림과 XSA를 만듭니다.
  - 결과는 `result.json`에 남습니다. 종료 코드는 0이 통과, 1이 타이밍 위반, 2가 빌드 실패입니다.

로컬과 CI가 같은 스크립트를 쓰기 때문에, 로컬 결과와 CI 결과가 같습니다.

## 4. CI/CD: `Jenkinsfile`, `ci/`

- **`Jenkinsfile`:** Plan → Lint → Unit regression → Top regression → FPGA timing(OOC) → Bitstream →
  Coverage 순서로 실행합니다. Bitstream과 Coverage는 full 모드나 지정했을 때만 돕니다.
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

- **`mcp/vivado_mcp/server.py`:** `sim.py`와 `regress.py`를 MCP 도구 8개로 노출합니다. 테스트 실행, 로그 발췌,
  커버리지, 회귀, known bug 조회 등이 있습니다. Jenkins MCP와 GitHub MCP는 로컬 설정에만 등록돼 있습니다.
- **`.claude/agents/`:** 서브에이전트 다섯 개입니다.
  - `verif-planner`: 검증 계획을 세웁니다.
  - `uvm-builder`: 테스트와 시퀀스를 구현합니다.
  - `sim-triage`: 실패한 시뮬레이션을 분류합니다.
  - `coverage-closer`: 커버리지 빈칸을 메웁니다.
  - `ci-watcher`: CI 상태를 조회합니다.
- **`.claude/skills/verify-loop/`:** 위 에이전트들을 계획 → 구현 → 실행 → 분류 → CI 확인 순서로 돌리는
  루프입니다. RTL 버그를 찾았을 때와 커밋할 때는 사람이 승인합니다.
- **`.claude/hooks/protect_rtl.py`:** `HW/` 수정을 막는 PreToolUse hook입니다. 테스트 16개가 있습니다.
- **`CLAUDE.md`:** 에이전트 작업 규칙과 XSim 함정 목록입니다.

## 기타

- **`uvm_reference/`:** 받은 참고 코드입니다. 수정하지 않습니다.
- **`docs/REPORT.md`:** 결과 보고서의 저장소 사본입니다.
- **`SW/`:** 보드용 소프트웨어입니다.
- **`out/`:** 빌드와 시뮬레이션 결과물입니다. git에 넣지 않습니다.
