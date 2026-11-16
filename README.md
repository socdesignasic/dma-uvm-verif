# dma-uvm-verif

간단한 AXI DMA IP(`dma_ip_top`: RDMA → FIFO → adder → FIFO → WDMA, AXI4-Lite 제어, AXI4 master)를
Vivado 2022.2 XSim에서 검증하는 UVM 환경, CI/CD, 에이전트 도구입니다. 기본 대상은 Zybo Z7-20
(xc7z020clg400-1)이고, 실보드 시험은 Zybo Z7-10(xc7z010clg400-1)에서 했습니다.

**포트폴리오 페이지:** https://socdesignasic.github.io/dma-uvm-verif/

> **DUT RTL은 들어 있지 않습니다.** 이 저장소에는 검증 코드만 있습니다. 실행하기 전에
> 다음을 추가하세요 (모두 이 저장소의 git에서 무시됨):
> - `HW/`: DUT RTL. 테스트벤치는 `verif/filelist/rtl.f`와 unit filelist에 적힌 파일과 모듈 이름을
>   기대합니다 (top 모듈 `dma_ip_top`)
> - `uvm_reference/`: 참고용 UVM 예제 (`ref_adder*` 테스트벤치만 사용)
> - `ci/vivado/ip/dma_ip_top/`: IP 패키징 메타데이터 (`component.xml`, `xgui/`).
>   `scripts/fpga.py system`(비트스트림 빌드)에만 필요
> - `SW/`: 참조용 보드 예제 (쓰지 않음. C 보드 시험은 `fw/`에 새로 작성)

## 구성

| 경로 | 내용 |
|---|---|
| `verif/` | UVM 테스트벤치: agent, env, sequence, 테스트, TB top, 테스트 목록(`sim_cfg.json`), vplan, 버그 목록 |
| `scripts/` | `sim.py` (lint/실행/커버리지), `regress.py` (병렬 회귀), `fpga.py` (OOC 타이밍, 비트스트림 + XSA), `board.py` / `board_c.py` (보드 시험) |
| `fw/dma_board_test/` | Cortex-A9 bare-metal C 보드 시험 프로그램 (Vitis standalone BSP) |
| `Jenkinsfile`, `ci/` | 로컬 Jenkins (Configuration as Code), Vivado 블록 디자인과 IP 패키징, xsdb 보드 시험(`ci/vivado/board_*.tcl`), Vitis 빌드(`ci/vitis/`) 스크립트 |
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

## 보드 시험 (Zybo Z7-10)

같은 시험 7개(8B~1MB, burst 경계, 4KB 경계, `add_val` 0/255 포함)를 두 가지 방식으로 실제 DDR에서 실행합니다.
판정 기준은 바이트마다 `대상 = (원본 + add_val) & 0xFF`입니다.

| 방식 | 명령 | 하는 일 |
|---|---|---|
| JTAG | `python scripts/board.py --xsa out/fpga/system_xc7z010/design_1_wrapper.xsa` | xsdb가 데이터를 DDR에 쓰고 DMA 레지스터를 직접 구동, 결과를 읽어 Python이 비교 (하드웨어만 확인) |
| ARM C | `python scripts/board_c.py` | xsct로 BSP와 ELF 빌드 → xsdb로 비트스트림, PS 초기화, ELF 실행 → Cortex-A9의 C 프로그램이 DMA를 구동하고 스스로 판정 |

C 프로그램(`fw/dma_board_test/dma_board_test.c`)이 하는 일:
- D-cache를 켠 채로 DMA 전에 원본/대상 범위를 flush하고, DMA 뒤 대상 범위를 invalidate합니다 (HP0 포트는 cache coherent가 아님).
- 레지스터 설정 → IDLE 확인 → `ap_start` → DONE 대기 (1초 넘으면 HANG).
- 결과를 UART(115200)로 출력하고 DDR mailbox(`0x0F000000`)에도 씁니다. `board_c.py`는 JTAG로 mailbox를 읽어
  UART 로그와 판정이 같은지 확인하고, 다르면 실패로 처리합니다.

필요한 것: Vivado 2022.2 (xsdb), Vitis 2022.2 (xsct, ARM 컴파일러, C 방식만), Zybo의 USB-UART 포트
(기본 `COM7`, `--com`으로 변경). 결과는 `out/board/<시각>/`, `out/board_c/<시각>/result.json`에 남습니다.

결과 (2026-11-17, 두 방식 모두 7/7 PASS):

| 시험 | 크기 | DMA (C) | CPU memcpy |
|---|---|---|---|
| page4k | 4 KB | 6.0 µs | 2.1 µs |
| c_ref_64k | 64 KB | 84 µs (779 MB/s) | 63 µs |
| big_1m | 1 MB | 1332 µs (787 MB/s) | 2869 µs (366 MB/s) |

1MB에서 DMA는 64-bit × 100MHz 이론값(800 MB/s)의 98%입니다. 작은 크기에서는 원본이 cache에 남아 있어 CPU가
빠르게 나오므로, L2(512KB)보다 큰 1MB만 공정한 비교입니다. DMA 시간에는 DONE 폴링 지연이 포함됩니다.

자세한 내용은 `docs/ARCHITECTURE.md`, `docs/FLOW.md`, `docs/UVM_STRUCTURE.md`를,
이 환경이 찾은 RTL 문제는 `verif/BUGS.md`를 보세요.
