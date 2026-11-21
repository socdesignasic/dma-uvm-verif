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

실행할 때마다 `out/<tb>/runs/<test>_<seed>/{run.log,result.json,junit.xml}`을 씁니다(회귀는
`out/<tb>/runs/<회귀 이름>/<test>_<seed>/`). `result.json`에는 커밋, HW/ 해시, 빌드 입력 해시가 들어갑니다.
종료 코드: 0 = 기대와 일치, 1 = 테스트 결과 불일치, 2 = 빌드/도구 오류.

회귀: 선택한 TB의 모든 테스트 × seed N개를, snapshot 개인 사본에서 병렬로 실행합니다.
JUnit과 요약은 `out/regress/<name>/`에 씁니다.
```bash
python scripts/regress.py --suite all --seeds 2 --jobs 6      # suite: unit | top | all
python scripts/regress.py --tb top --tests dma_smoke_test dma_irq_test
```
CI(Jenkins)도 같은 스크립트를 실행합니다. `ci/README.md`를 참고하세요.

## 테스트벤치 목록: `verif/sim_cfg.json`

아래 표는 `sim_cfg.json`에서 생성합니다(`python scripts/check_docs.py --write`).

<!-- gen:tbs -->
| TB | 설명 | 테스트 | known_fail |
|---|---|---|---|
| `rtl` | DUT RTL만 (lint/elaborate 확인, adder datapath) | - | - |
| `ref_adder` | 사용자 UVM 참고 코드, 원본 DUT (FAIL이 정상: 리셋 극성 버그) | - | - |
| `ref_adder_fixed` | 사용자 UVM 참고 코드, 고친 DUT (PASS가 정상) | - | - |
| `xsim_msgs` | sim.py 판정 자체 시험 (UVM 없음, +KIND=error\|warning\|fatal\|assert\|immediate\|bind\|none) | - | - |
| `fifo` | sync_fifo 깊이 64 (top과 같음) + 입출력 skid | 6 | 1 |
| `fifo_d4` | sync_fifo 깊이 4 (full/empty 경계 집중 시험) | 6 | 1 |
| `skid` | skid_buffer 64비트 | 7 | 1 |
| `adder` | axis_adder 64비트, 32비트 lane 2개 (모듈 기본값) + beat마다 ctrl_constant | 6 | - |
| `adder8` | axis_adder 64비트, 8비트 lane 8개 (dma_ip_top과 같음) | 6 | - |
| `top` | dma_ip_top: AXI-Lite master + AXI4 slave 메모리, RDMA->adder(8비트 lane)->WDMA | 22 | 7 |

테스트 29종, TB별로 세면 53개입니다. CI와 `regress.py`는 이 표의 테스트만 돌립니다.
<!-- /gen:tbs -->

`known_fail`은 테스트를 추적 중인 RTL 버그(`verif/BUGS.md`)에 연결합니다. 결과는 XFAIL로 보고되고,
RTL이 고쳐지면 CI 실패(XPASS)로 바뀝니다.

## 코드 구조

UVM 코드의 배치, 에이전트, env, sequence, 테스트 구조는 [docs/UVM_STRUCTURE.md](../docs/UVM_STRUCTURE.md)
한 곳에 적습니다. 기능과 테스트, 검사, 커버리지의 대응은 `verif/plan.toml`이 원본이고 `vplan/vplan.md`는
여기서 생성합니다. 검사 목록의 기준선은 `check_baseline.json`입니다.

## Windows XSim의 알려진 함정 (sim.py에서 처리함)
- Vivado 도구는 `.bat` wrapper라서 cmd.exe가 `UVM_TESTNAME=foo`를 `=`에서 나눕니다. 인자를 따옴표로 감쌉니다.
- 역슬래시 경로가 XSim이 만드는 C 코드에 들어가 `--cc_type` elaboration을 깨뜨립니다. 경로는 `/`로 넘깁니다.
- `xcrg`는 성공해도 종료 코드 127을 냅니다. 성공 여부는 로그로 판단합니다.
- 넓은 범위나 작은 가중치를 쓴 XSim `dist`는 결과가 심하게 치우칩니다. 경계값 편향은 절차적으로 넣습니다 (`stream_rand_seq`).
- `coverpoint` 안의 폭 변환(cast) 식은 잘못 계산됩니다. 값을 먼저 계산한 뒤 샘플링합니다.
- bin 상한에 `$`를 쓰면 잘못 계산됩니다 (모든 샘플이 그 bin에 들어감). 상한을 명시합니다.
- `xcrg`는 기존 보고서 뒤에 덧붙입니다. `cov-report`는 먼저 보고서 디렉터리를 비웁니다.
- XSim은 UVM을 자동 import하지 않습니다 (EDA Playground는 함). `import uvm_pkg::*;` + `` `include "uvm_macros.svh" ``를 넣습니다.
