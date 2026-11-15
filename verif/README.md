# dma_ip 검증 (UVM / Vivado XSim 2022.2)

모든 시뮬레이션은 `scripts/sim.py`로 실행합니다. Jenkins와 MCP 서버도 같은 스크립트를 부릅니다.

```bash
python scripts/sim.py list                                   # 등록된 테스트벤치 목록
python scripts/sim.py lint --tb rtl                          # DUT만 컴파일+elaborate
python scripts/sim.py run  --tb ref_adder_fixed --seed random
python scripts/sim.py run  --tb ref_adder_fixed --cov        # + 코드 커버리지 (sbct)
python scripts/sim.py cov-report --tb ref_adder_fixed        # HTML -> out/<tb>/cov/
python scripts/sim.py run  --tb <tb> --wave                  # 실행 폴더에 wave.wdb
```

실행할 때마다 `out/<tb>/runs/<test>_<seed>/{run.log,result.json,junit.xml}`을 씁니다.
종료 코드: 0 = 기대와 일치, 1 = 테스트 결과 불일치, 2 = 빌드/도구 오류.

회귀: 선택한 TB의 모든 테스트 × seed N개를, snapshot 개인 사본에서 병렬로 실행합니다.
JUnit과 요약은 `out/regress/<name>/`에 씁니다.
```bash
python scripts/regress.py --suite all --seeds 2 --jobs 6      # suite: unit | top | all
python scripts/regress.py --tb top --tests dma_smoke_test dma_irq_test
```
CI(Jenkins)도 같은 스크립트를 실행합니다. `ci/README.md`를 참고하세요.

## 테스트벤치 목록: `verif/sim_cfg.json`
| tb | 용도 |
|---|---|
| `rtl` | DUT lint/elaborate (adder datapath, 기본 빌드) |
| `ref_adder` | 사용자의 UVM 참고 코드 그대로. `"expect": "fail"` -> XFAIL로 보고 (검사기가 버그를 잡는다는 증명) |
| `ref_adder_fixed` | 같은 TB, DUT 리셋 극성만 고침 -> PASS |
| `fifo` / `fifo_d4` | `sync_fifo` 깊이 64 (top과 같음) / 깊이 4 |
| `skid` | `skid_buffer` |
| `adder` / `adder8` | `axis_adder`, 32비트 lane 2개 (모듈 기본값) / 8비트 lane 8개 (top과 같음) |
| `top` | `dma_ip_top`: AXI4-Lite master, AXI4 slave 메모리 모델, RDMA → adder → WDMA 전체 경로 |

`known_fail`은 테스트를 추적 중인 RTL 버그(`verif/BUGS.md`)에 연결합니다. 결과는 XFAIL로 보고되고,
RTL이 고쳐지면 CI 실패(XPASS)로 바뀝니다.

## 코드 배치
파일 하나에 클래스 하나, 파일 이름은 클래스 이름과 같습니다. 각 `*_pkg.sv`는 import, 패키지 전체에서 쓰는
typedef/상수 선언, 클래스 파일 `` `include ``만 합니다. filelist에는 패키지를 적고, 패키지 디렉터리마다
`+incdir+`를 둡니다.

```
verif/
  agents/vr_agent/        vr_if, vr_pkg, vr_item, vr_cfg, vr_sequencer, vr_master_driver,
                          vr_slave_driver, vr_monitor, vr_agent, vr_stream_seq
  agents/axil_agent/      axil_if, axil_pkg, axil_item, axil_sequencer, axil_driver, axil_agent,
                          axil_base_seq (write_reg / read_reg)
  agents/axi4_slv_agent/  axi4_if, axi4_slv_pkg, axi4_slv_cfg, axi4_mem, axi4_burst,
                          axi4_slv_monitor, axi4_slv_driver, axi4_slv_agent
  env/unit/               unit_env_pkg, unit_env_cfg, unit_scoreboard, unit_coverage, unit_env
  env/top/                dma_env_pkg, dma_reg_map, dma_job, dma_env_cfg, dma_scoreboard,
                          dma_coverage, dma_env
  sequences/top/          dma_seq_pkg, dma_job_seq, dma_reg_reset_seq, dma_reg_bitbash_seq
  tests/unit/             unit_test_pkg, unit_base_test, unit_<name>_test (6개)
  tests/top/              dma_test_pkg, dma_base_test, dma_<name>_test (11개)
  tb/                     TB top 모듈
```

## 단위(unit) UVM 구조
`vr_agent` (범용 valid/ready, master/slave/passive) → `unit_env` (입력/출력 agent,
DUT별 모델로 순서대로 비교하는 `unit_scoreboard`, `unit_coverage`) → `unit_test_pkg`의 테스트.
구조는 `uvm_reference/`를 따르지만 패키지로 묶었습니다 (전역 scope include 없음,
modport 계층 참조 없음).

## top UVM 구조
RAL은 쓰지 않습니다. `axil_agent`가 `env/top/dma_reg_map.sv`의 주소로
`axil_base_seq::write_reg()/read_reg()`를 불러 DUT를 설정합니다.
`axi4_slv_agent`는 m00에 붙는 반응형 slave입니다. `axi4_slv_driver`는 희소 바이트 메모리(`axi4_mem`)로
응답하면서 채널마다 랜덤 backpressure를 넣고, WLAST와 초기화 안 된 메모리 읽기를 검사합니다.
`axi4_slv_monitor`는 모든 AR/AW를 내보내고 burst를 검사합니다 (INCR, size, 정렬, 16 beat 이하, 4KB).
`dma_job_seq`는 DMA 작업 하나를 처음부터 끝까지 실행하고, `dma_scoreboard`는 대상의 모든 바이트를
`src + value_to_add[7:0]`과 비교합니다. 앞뒤 보호 영역, 원본 보존, burst 범위, beat 합계도 확인합니다.
`dma_reg_reset_seq` / `dma_reg_bitbash_seq`는 리셋 값과 RW 비트를 확인합니다 (32비트 전체).

## Windows XSim의 알려진 함정 (sim.py에서 처리함)
- Vivado 도구는 `.bat` wrapper라서 cmd.exe가 `UVM_TESTNAME=foo`를 `=`에서 나눕니다. 인자를 따옴표로 감쌉니다.
- 역슬래시 경로가 XSim이 만드는 C 코드에 들어가 `--cc_type` elaboration을 깨뜨립니다. 경로는 `/`로 넘깁니다.
- `xcrg`는 성공해도 종료 코드 127을 냅니다. 성공 여부는 로그로 판단합니다.
- 넓은 범위나 작은 가중치를 쓴 XSim `dist`는 결과가 심하게 치우칩니다. 경계값 편향은 절차적으로 넣습니다 (`vr_stream_seq`).
- `coverpoint` 안의 폭 변환(cast) 식은 잘못 계산됩니다. 값을 먼저 계산한 뒤 샘플링합니다.
- bin 상한에 `$`를 쓰면 잘못 계산됩니다 (모든 샘플이 그 bin에 들어감). 상한을 명시합니다.
- `xcrg`는 기존 보고서 뒤에 덧붙입니다. `cov-report`는 먼저 보고서 디렉터리를 비웁니다.
- XSim은 UVM을 자동 import하지 않습니다 (EDA Playground는 함). `import uvm_pkg::*;` + `` `include "uvm_macros.svh" ``를 넣습니다.
