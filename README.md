# dma-uvm-verif

간단한 AXI DMA IP(`dma_ip_top`: RDMA → FIFO → adder → FIFO → WDMA, AXI4-Lite 제어, AXI4 master)를
Vivado 2022.2 XSim에서 검증하는 UVM 환경, CI/CD, 에이전트 도구입니다. 대상 보드는 Zybo Z7-20
(xc7z020clg400-1)입니다.

**포트폴리오 페이지:** https://socdesignasic.github.io/dma-uvm-verif/

> **DUT RTL은 들어 있지 않습니다.** 이 저장소에는 검증 코드만 있습니다. 실행하기 전에
> 다음을 추가하세요 (모두 이 저장소의 git에서 무시됨):
> - `HW/`: DUT RTL. 테스트벤치는 `verif/filelist/rtl.f`와 unit filelist에 적힌 파일과 모듈 이름을
>   기대합니다 (top 모듈 `dma_ip_top`)
> - `uvm_reference/`: 참고용 UVM 예제 (`ref_adder*` 테스트벤치만 사용)
> - `ci/vivado/ip/dma_ip_top/`: IP 패키징 메타데이터 (`component.xml`, `xgui/`).
>   `scripts/fpga.py system`(비트스트림 빌드)에만 필요
> - `SW/`: 보드 시험 프로그램 (시뮬레이션과 CI에서는 쓰지 않음)

## 구성

| 경로 | 내용 |
|---|---|
| `verif/` | UVM 테스트벤치: agent, env, sequence, 테스트, TB top, 테스트 목록(`sim_cfg.json`), vplan, 버그 목록 |
| `scripts/` | `sim.py` (lint/실행/커버리지), `regress.py` (병렬 회귀), `fpga.py` (OOC 타이밍, 비트스트림 + XSA) |
| `Jenkinsfile`, `ci/` | 로컬 Jenkins (Configuration as Code), Vivado 블록 디자인과 IP 패키징 스크립트 |
| `mcp/` | 시뮬레이션 흐름을 에이전트에 제공하는 MCP 서버 |
| `.claude/`, `CLAUDE.md` | 에이전트 규칙, 서브에이전트, `/verify-loop` 스킬, `HW/`를 읽기 전용으로 지키는 hook |
| `docs/` | 결과 보고서, 저장소 구성, 흐름, UVM 코드 구조 |

## 빠른 시작 (`HW/`에 RTL을 넣은 뒤)

```bash
python scripts/sim.py list
python scripts/sim.py run --tb top --test dma_smoke_test --seed 1
python scripts/regress.py --suite all --seeds 2 --jobs 6
python scripts/sim.py cov-report --tb top
```

자세한 내용은 `docs/ARCHITECTURE.md`, `docs/FLOW.md`, `docs/UVM_STRUCTURE.md`를,
이 환경이 찾은 RTL 문제는 `verif/BUGS.md`를 보세요.
