# RTL 버그 목록 (검증에서 발견)

검증 흐름은 `HW/` 아래 RTL을 수정하지 않습니다. 버그마다 재현 테스트가 있고, 그 테스트는
`verif/sim_cfg.json`에 `known_fail`로 등록돼 있어서 CI는 초록색으로 유지됩니다 (XFAIL / skipped로 보고).
RTL이 고쳐지면 테스트가 XPASS가 되면서 CI가 실패하고, 그것이 `known_fail` 항목을 지우라는 신호입니다.

## BUG-001: 리셋 후 `s_ready=0`일 때 받아들인 beat를 skid buffer가 중복 출력
- **블록:** `HW/peri_ip/skid_buffer.v` (`sync_fifo` 안의 IN, OUT 단에도 있음)
- **상태:** won't fix (RTL 담당자 결정, 2026-11-14). 영구 `known_fail`로 둡니다.
- **재현:** `python scripts/sim.py run --tb skid --test unit_post_reset_test --seed 1`
  (`fifo`, `fifo_d4`도 같음. 모든 seed에서 실패)
- **증상:** 첫 beat가 두 번 나오고, 그 뒤의 beat가 모두 하나씩 밀립니다.
  ```
  105ns  s_valid=1, s_ready=0   (AXI-Stream 규칙상 handshake 아님)
  115ns  out: 0x..6f004183        (105ns에 잡힌 beat)
         in : 0x..6f004183 수락  (이제 s_ready=1. 소스가 다시 보냄)
  125ns  out: 0x..6f004183        <- 중복
  ```
- **원인:** `s_ready_reg`는 0으로 리셋되지만, `PIPE` 상태에서는 하위 단이 ready이기만 하면
  **`s_ready_reg`를 확인하지 않고** `m_valid_reg <= s_valid`로 값을 받습니다. 리셋 직후 첫 사이클에는
  `s_ready=0`이므로, `valid`를 바로 켜는 소스(규격상 허용)의 beat가 handshake 없이 잡히고,
  소스가 그 beat를 다시 보내서 중복됩니다.
- **수정 제안 (RTL 담당자 승인 필요):** 값을 받을 때 handshake 조건을 넣습니다. 예:
  `m_valid_reg <= s_valid & s_ready_reg;`,
  `m_valid_temp_reg <= s_valid & s_ready_reg;`.
- **dma_ip_top에 미치는 영향 (2026-11-21 TB 2단계에서 고침):** 처음에는 "FIFO 입력은 RDMA가 주고
  RDMA는 `ap_start` 뒤에 시작하므로 낮음"으로 적었지만 틀렸습니다. FIFO 입력은 리셋이 없는 adder 출력입니다
  (`dma_ip_top.v:338`). 작업 도중 리셋하면 adder에 남은 beat가 리셋 해제 첫 에지에서 이 경로로 들어가
  하나가 중복됩니다(BUG-006, `dma_reset_mid_job_test` 2025ns). BUG-006을 고치면(adder valid 리셋) 이 경로의
  BUG-001도 걸리지 않습니다. won't fix는 유지하되, 영향 판단이 바뀌었으므로 RTL 담당자가 다시 확인할 일입니다.

## BUG-002: WDMA가 AW 수락 전에 W beat를 보내고, 그 beat를 잘못 세어 멈춤
- **블록:** `HW/dma_ip/WDMA/wdma.v`
- **상태:** open (검증에서는 RTL을 고치지 않음. RTL 담당자 결정 대기)
- **재현:** `python scripts/sim.py run --tb top --test dma_aw_backpressure_test --seed 1`
  (어떤 seed든, 쓰기 데이터가 준비된 동안 AWREADY를 0으로 잡는 slave면 모두 재현)
- **증상:** `WLAST`가 늦게 나오고 (16번째가 아니라 19번째 beat), 그 뒤 burst가 모두 밀리며,
  B 응답 개수가 총합에 도달하지 못해 **`ap_done`이 끝내 나오지 않습니다 (멈춤)**.
  메모리 모델이 beat 순서대로 쓰기 때문에 데이터 바이트 자체는 올바른 주소에 들어갑니다.
  ```
  715/745/755ns  W beat #1-3 수락   (아직 AW 수락 없음, W FSM은 IDLE)
  765ns          AW #0 수락 (16 beat)
  1135ns         beat #16, WLAST=0  <- slave는 여기서 WLAST를 기대
  1235ns         beat #19, WLAST=1
  ```
- **원인:** `m_axi_gmem_WVALID = s_valid` (FIFO가 비어 있지 않음)와 `s_ready = WREADY`가
  W 상태 머신으로 막혀 있지 않습니다. `c_state_w == S_IDLE`(AW->W FIFO에 아직 AW 없음)인 동안
  `r_burst_cnt_w`는 0에 고정되므로, 그때 수락된 beat는 세지 않습니다. 버스 입장에서 W가 AW보다
  먼저 오는 것은 AXI 규격상 허용되지만, WDMA 자체의 WLAST/B 계산은 그런 일이 없다고 가정합니다.
- **증상은 작업 이력에 따라 다릅니다 (2026-11-21 TB 2단계):** 위 증상은 리셋 뒤 **첫 작업**의 형태입니다(W FSM이
  IDLE이라 AW 전 beat를 세지 않음). 작업을 한 번이라도 끝낸 뒤에는 W FSM이 RUN에 남아 AW 전 beat를 이전 burst
  길이로 세며, 그 형태는 BUG-003입니다.
- **수정 제안 (RTL 담당자 승인 필요):** 처음 제안(`& w_s_run_w`만)으로는 **부족합니다**. 첫 작업 뒤에는 AW FIFO가
  비어도 `w_s_run_w=1`이라 BUG-003이 남고, W->B FIFO 넘침(BUG-004)도 남습니다. BUG-002/003/004를 함께 닫는 안:
  ```
  wire w_go = w_s_run_w & aw_fifo_empty_n & w_fifo_full_n;
  assign m_axi_gmem_WVALID = s_valid & w_go;
  assign s_ready           = m_axi_gmem_WREADY & w_go;
  ```
  네 조건은 W handshake로만 1에서 0이 되므로(pop, push, burst 끝) WVALID가 handshake 없이 내려가지 않습니다.
  대안: AW 발행을 "미해결 AW - B <= 4"로 제한. 확인: `dma_aw_backpressure_test`, `dma_aw_wait_after_job_test`,
  `dma_slow_b_test`가 모두 XPASS.
- **보드에 미치는 영향:** 실제로 멈출 위험이 있습니다. Zynq HP 포트나 AXI interconnect / SmartConnect가
  AWREADY를 늦출 수 있습니다. 지금까지 기존 보드 구성이 동작한 것은 AWREADY가 보통 빨리 돌아오기 때문입니다.
- **검증에 미치는 영향:** 다른 top 테스트는 모두 AWREADY=1로 둡니다 (W/AR/R/B backpressure는 계속 랜덤).
  그래서 나머지 설계는 여전히 검사됩니다. AWREADY 지연은 `dma_aw_backpressure_test`만 다루고,
  이 테스트는 `known_fail`로 등록돼 있습니다.

## BUG-003: 작업을 한 번 끝낸 뒤에는 W FSM이 RUN에 남아, AW보다 먼저 온 W beat를 이전 burst 길이로 셈
- **블록:** `HW/dma_ip/WDMA/wdma.v`
- **발견:** TB 2단계 가설 H6, `dma_aw_wait_after_job_test` (seed 1, 1379565920, 1689246514, 7 모두 같은 시각)
- **상태:** open (검증에서는 RTL을 고치지 않음. RTL 담당자 결정 대기)
- **재현:** `python scripts/sim.py run --tb top --test dma_aw_wait_after_job_test --seed 1`
- **증상:** 리셋 뒤 첫 작업은 BUG-002처럼 WLAST가 늦습니다. 작업을 한 번 끝낸 뒤 AWREADY가 늦으면, AW FIFO가 빈 채
  4개 전 burst 길이(stale AWLEN)로 W beat를 셉니다. 길이가 같으면 가려지고(job2: AW 전 beat 14개인데 PASS),
  다르면 WLAST가 틀린 beat에 나오고, 가짜 burst 끝이 W->B FIFO에 들어가 B 합계가 어긋나 `ap_done`이 나오지 않습니다.
  ```
  1285ns       job1 마지막 burst 끝: aw_fifo_empty_n=0인데 c_state_w=01(RUN) 유지
  1825-1875ns  job2: AW FIFO 빔, AWLEN_w=0x10(stale), AW 전 beat를 1..5로 셈 -> 1975ns 16번째 beat WLAST (가려짐)
  4575ns       job5 (AWLEN_w=0x01, job3의 1 beat 칸): 첫 W beat에 WLAST=1, 가짜 burst 끝, c_state_w=00
  4635ns       AXI_WLAST "WLAST=1 on beat 0..5 of 16" -> 4745/4905ns 실제 B를 가짜 항목으로 받음 -> 멈춤
  ```
- **원인:** `is_aw_req_pre`(:465)가 burst 끝에 pop 전 `aw_fifo_empty_n`(늘 1)을 봐서 마지막 burst 뒤에도 RUN(:472-476).
  WLAST와 burst 끝(:486-487, :502)이 `AWLEN_w`로 계산되고 FIFO가 비었는지 보지 않음. 비면 `AWLEN_w = cmd_fifo[rptr]`
  (`sync_fifo.v:99`, 4번 전 값, 리셋 뒤 안 쓴 칸은 0). 가짜 끝이 W->B FIFO에 push(:537, :540)되어 :581에 못 닿음.
  전제는 BUG-002의 :497-498 (W가 AW보다 먼저 나감).
- **수정 제안 (RTL 담당자 승인 필요):** BUG-002 절의 `w_go`(`aw_fifo_empty_n` 항). 선택: `is_aw_req_pre`가 pop 뒤 상태를 보게.
- **보드에 미치는 영향:** BUG-002와 같은 조건(W 데이터가 준비된 동안 AWREADY가 늦음)이고, 여러 작업을 돌리는 실제 사용에서는
  이 형태가 주로 나타납니다. 짧은 burst(4KB 경계, 16 beat가 아닌 크기) 뒤면 WLAST 위반과 멈춤.

## BUG-004: B 응답이 W burst보다 느리면 W->B FIFO(깊이 4)가 넘쳐 B 항목이 버려지고, WLAST가 틀리며 멈춤
- **블록:** `HW/dma_ip/WDMA/wdma.v`
- **발견:** TB 2단계 가설 H7(새 후보), `dma_slow_b_test` (seed 1, 1259867101, 2051893976, 7)
- **상태:** open (검증에서는 RTL을 고치지 않음. RTL 담당자 결정 대기)
- **재현:** `python scripts/sim.py run --tb top --test dma_slow_b_test --seed 1` (약 100초, JOB_TIMEOUT 예산 1.41ms)
- **증상:** AR/AW/W ready 100%(AW 지연 없음), B만 하나씩 0..60사이클 지연. 미해결 burst가 6개가 되는 burst의 B 항목이
  버려지고 W FSM이 IDLE로 가서 다음 beat를 세지 않음 -> WLAST가 늦고 이후 burst마다 위치가 틀림, B가 하나 모자라 멈춤.
  ```
  2395ns       burst 11 끝: W->B FIFO 3개, w_fifo_full_n=1 -> RUN 유지, 2405ns push로 4개(가득)
  2555ns       burst 12 끝: is_burst_done_w=1 && w_fifo_full_n=0 -> push 버려짐
  2565-2715ns  c_state_w=00 (aw_fifo_empty_n=1), WVALID=WREADY=1인데 beat 15개를 세지 않음
  2735ns       AXI_WLAST "WLAST=0 on beat 15 of 16" ... r_b_hs_cnt가 총합에 못 닿고 BREADY=0으로 멈춤
  ```
  (trace는 debug 빌드라 일반 실행보다 시각이 다름. 일반 실행 seed 1: 1765ns 미해결 6, 1935ns 첫 AXI_WLAST)
- **원인:** burst 끝의 `w_fifo_full_n`도 push 전 값(:465)이라 3개 찬 채 끝나도 RUN 유지. full이면 push가 조용히 버려짐
  (:537-538, `sync_fifo.v:114`). W 경로(:497-498)와 AW 발행(:391, AW FIFO는 W burst 끝에 pop :482)이 B 쪽 여유를 보지 않음.
  B FSM은 하나씩 처리(:560-568). 손실 뒤 :506, :581 때문에 멈춤.
- **수정 제안 (RTL 담당자 승인 필요):** BUG-002 절의 `w_go`(`w_fifo_full_n` 항), 또는 B 기준으로 AW 발행 제한.
  BUG-002 처음 제안대로 고쳐도 B 손실은 남아 멈춤.
- **보드에 미치는 영향:** AW 지연 없이도 HP 포트의 B가 W보다 약 80사이클 넘게 밀리면 생김. 보드 측정 필요.

## BUG-005: ap_start를 에지로만 받아, 작업 중 start나 auto_restart 뒤에는 리셋 전까지 다시 시작하지 않음
- **블록:** `HW/dma_ip/dma_wrapper.v` (+ `RDMA/rdma.v`, `WDMA/wdma.v` 시작 로직)
- **발견:** TB 2단계 가설 H1(작업 중 start, 변형 H1b), H2(auto_restart). `dma_start_busy_test`, `dma_auto_restart_test`
  (각 seed 1과 랜덤 여러 개, 모두 같음)
- **상태:** open (검증에서는 RTL을 고치지 않음. RTL 담당자 결정 대기)
- **재현:** `python scripts/sim.py run --tb top --test dma_start_busy_test --seed 1`,
  `python scripts/sim.py run --tb top --test dma_auto_restart_test --seed 1`
- **증상:**
  1. 작업 A 중 start를 쓰면 A는 정상 완료, 그 start(B)는 실행되지 않음(done/IRQ 없음). AP_CTRL이 0x05(start=1, idle=1)로
     굳고, idle을 확인한 뒤 쓴 start(C, SW 순서 그대로)도 무시. PL 리셋 전까지 아무 작업도 못 함.
     975ns B start -> 985ns `r_ap_start_*=1`(두 블록 RUN이라 무시) -> 995ns `tick_ff=1` -> 1325ns WDMA IDLE ->
     1.6~62.3us AR/AW/W 0, `int_ap_start=1`, `r_ap_start_*=1`, `tick_ff=1` 유지 (32045ns C start에도 변화 없음)
  2. RDMA만 끝난 구간(RDMA IDLE, WDMA RUN)에 start를 쓰면 RDMA만 다음 src를 읽고, 그 데이터 32 beat가 AW 없이 W로 나감
     (AXI 위반, `wdma.v:497` = BUG-002 경로). 그 뒤는 1과 같이 멈춤.
  3. AP_CTRL=0x81(auto_restart)이면 한 번만 실행하고 멈춤. 0x00으로 끄고 idle 확인 뒤 0x01을 써도 실행 안 됨(0x85 -> 0x05).
- **원인:** control_s_axi는 ap_start를 level로 두고 ap_ready에서만 내림(:308-311, 레지스터 맵 :60 COH). wrapper는 이를
  상승 에지 펄스로 바꿈(:134-138). 블록은 `is_run = ap_start & ~tick_ff`를 IDLE에서만 받음(rdma.v:292/307, wdma.v:310/325).
  (1) RUN 중 펄스는 버려지고 `r_ap_start_*`는 ap_ready로만 내려가므로(:143-145, :153-155) 1로, `tick_ff`도 1로 굳어
  is_run이 다시 안 생김. ap_ready가 없으니 `int_ap_start`도 1로 남아 새 에지가 없음.
  (2) auto_restart면 ap_ready에서 `int_ap_start <= 1`(:311)이라 level이 내려가지 않아 두 번째 에지가 없음.
  0x00은 auto_restart만 끄고 start는 못 내림(:308은 세트만).
- **수정 제안 (RTL 담당자 승인 필요):** wrapper에서 level start를 두 블록이 모두 IDLE일 때 받음:
  `assign ap_start_pulse = ap_start & ap_idle_rdma & ap_idle_wdma & ~r_ap_start_rdma & ~r_ap_start_wdma;`
  (ap_start_r 불필요). idle start 사이클은 그대로(Ew+1 요청, Ew+2 PRE), 대기 start와 auto_restart는 WDMA IDLE 진입 +2에 PRE.
  RDMA가 먼저 출발하지 않으므로 증상 2도 사라짐. 확인: 두 테스트 XPASS.
- **보드에 미치는 영향:** 제공 SW(c:52-57)는 idle 뒤 start라 보통 안 걸림. 재시도, ISR 경합, 다중 스레드로 start를 두 번
  쓰거나, HLS 관례대로 다음 작업을 미리 start하거나 auto_restart를 쓰면 DMA가 멈추고 PL 리셋으로만 복구.
  증상 2는 m00 버스 규칙 위반이라 다른 쓰기를 망가뜨릴 수 있음.

## BUG-006: 작업 도중 리셋하면 adder에 남은 beat가 리셋 뒤 AW 없는 W로 나가고, 그 뒤 모든 작업의 데이터가 밀림
- **블록:** `HW/dma_ip/axis_adder.v` (`dma_ip_top.v`의 inst_adder)
- **발견:** TB 2단계 가설 H4, `dma_reset_mid_job_test` (seed 1, 380105152, 581244962, 146775033, 71154262, 1786463746)
- **상태:** open (검증에서는 RTL을 고치지 않음. RTL 담당자 결정 대기)
- **재현:** `python scripts/sim.py run --tb top --test dma_reset_mid_job_test --seed 1` (모든 seed, 약 4초)
- **증상:** 작업 도중 ap_rst_n을 걸었다 풀면 start 없이 W beat 3개(직전 작업의 마지막 R beat 2개, 첫 beat는 BUG-001로 두 번)가
  AW 없이 나감. 다음 작업의 dst 앞에 그 beat가 써지고 데이터가 3 beat 밀리며, 끝 3 beat는 그다음 작업으로 넘어감.
  **done/IRQ/AP_CTRL은 정상이라 SW는 모름 (조용한 데이터 오류, 멈추지 않음).**
  ```
  2005ns            리셋 해제 (adder d1/d2_tvalid=1 그대로)
  2025ns            FIFO 입력 skid가 s_ready=0인데 adder d2(A beat 101)를 잡음 (BUG-001)
  2035ns            adder가 같은 beat를 다시 넘김, d2 <- beat 102
  2055/2065/2075ns  W beat 101, 101, 102 (WDMA IDLE, AW 없음) -> SB_NO_JOB_BUS
  3565ns            job B: WLAST=0 on beat 15 of 16 ... SB_DATA(dst 앞 = A beat 101), 끝에 AXI_PENDING W 3
  ```
- **원인:** adder의 always 블록 3개(:99, :114, :123)에 리셋이 없음(`s_axis_areset` 포트 :38 미사용, `top.v:301`에서 연결).
  리셋 중 FIFO 입력 skid `s_ready=0`이라 tready(:96)=0, d1/d2가 남음. 해제 뒤 FIFO로 들어가고(skid.v:67-70에서 하나 중복),
  WVALID가 FIFO valid 그대로라(wdma.v:497) IDLE에서 AW 없이 나감. IDLE에서는 이 beat를 세지 않아 WDMA B 계산은 맞음(멈추지 않음).
- **수정 제안 (RTL 담당자 승인 필요):** valid 비트에 리셋 (데이터는 불필요):
  `if (s_axis_areset) d1_tvalid <= 1'b0; else if (s_axis_tready) d1_tvalid <= s_axis_tvalid;` (d2_tvalid도 같게).
  FIFO와 같은 areset이라 같은 에지에 비워지고, 해제 첫 에지 s_valid=0이라 이 경로의 BUG-001도 사라짐.
  BUG-002 수정(WVALID 막기)으로는 안 고쳐짐(stale beat가 다음 작업 첫 burst에 섞여 더 조용한 오류가 될 수 있음).
- **보드에 미치는 영향:** 작업 중단이나 멈춤(BUG-002~005) 복구를 위해 PL 리셋을 쓰면 그 뒤 작업이 조용히 틀림.
  제공 SW는 작업 도중 리셋을 하지 않음.

## BUG-007: RDMA/WDMA beat 카운터가 24비트라 128MiB 이상 전송하면 일부만 복사하고 done, 128MiB 배수면 멈춤
- **블록:** `HW/dma_ip/RDMA/rdma.v`, `HW/dma_ip/WDMA/wdma.v`
- **발견:** TB 2단계 가설 H5, `dma_size_128mib_test` (seed 1, 694132592, 1540469464, 1103096672)
- **상태:** open (검증에서는 RTL을 고치지 않음. RTL 담당자 결정 대기). 사용자 결정(2026-11-21): 128MiB 이상은 사양 안.
- **재현:** `python scripts/sim.py run --tb top --test dma_size_128mib_test --seed 1` (모든 seed, 약 5초)
- **증상:**
  ```
  bytes=0x08000040: 555ns r_num_total_stream_hs=0x000008 -> AR 1개(ARLEN=7), AW 1개, W 8 beat -> 775ns done (64B만 복사)
  bytes=0x08000000: r_num_total_stream_hs=0, is_last_ar/aw=1 -> AR/AW 없음, c_state=RUN, idle=0 (리셋까지)
  ```
  >= 128MiB면 (bytes>>3) mod 2^24 beat만 복사하고 done(조용한 부분 복사), 128MiB 배수면 IRQ 없이 멈춤(리셋으로만 풀림).
- **원인:** beat 카운터 폭 `[31-NUM_SAMPLE_IN_AXI_DATA:0]` = [23:0] (rdma.v:206, 208, 218, 219, 340 / wdma.v:213, 215, 226-228, 359).
  `NUM_SAMPLE_IN_AXI_DATA`(=8, 바이트 수, rdma.v:175)를 `AXI_DATA_SHIFT`(=3, :176) 자리에 쓴 것으로 보임. rdma.v:332 / wdma.v:350에서
  bytes>>3(29비트)이 24비트로 잘림. 0이면 is_last가 바로 1(rdma.v:401, wdma.v:420)이고 is_done(rdma.v:293, wdma.v:311)이 오지 않음.
- **수정 제안 (RTL 담당자 승인 필요):** 폭을 `[31-AXI_DATA_SHIFT:0]` / `[C_M_AXI_GMEM_ADDR_WIDTH-AXI_DATA_SHIFT-1:0]`(29비트)로,
  rdma.v:348 / wdma.v:367의 오프셋 `{cnt,3'b0}`도 32비트로. **주의:** `r_hs_data_cnt` 루프가 NOTE-001의 critical path라
  29비트로 늘면 100MHz를 못 맞출 수 있음 -> NOTE-001 개선과 함께 하고 `fpga.py ooc/system`으로 확인.
- **보드에 미치는 영향:** 제공 SW는 64MiB로 제한(`mem_copy_test.c:79`)이라 안 걸림. Zybo Z7-20 DDR은 1GiB라 다른 SW에서는 가능.

---
# 설계 노트 (기능 버그 아님)

## NOTE-001: WDMA burst 주소 계산 루프의 100 MHz 타이밍 여유가 거의 없음
- **발견:** `python scripts/fpga.py ooc` (P6), xc7z020clg400-1, ap_clk 10 ns, 단독(out-of-context) 배치배선
- **결과:** WNS = **+0.014 ns** (만족하지만 여유가 사실상 없음). WHS = +0.125 ns. LUT 1931개 / FF 5315개.
- **critical path:** `u_wdma/r_hs_data_cnt_reg[1] -> r_hs_data_cnt_reg[21]`, 로직 20단
  (CARRY4 12개). `r_hs_data_cnt`가 `remain_hs`, 16 beat 제한, 4KB 경계 계산
  (`last_addr_in_burst`, `boudary_burst_len_4k`), `burst_len_aw`를 거쳐 다시 `r_hs_data_cnt`로 돌아오는 것이
  모두 한 사이클 안에 있습니다. `rdma`도 구조가 같습니다.
- **전체 시스템 @100 MHz (PS7 + interconnect + ILA):** 기본 구현 전략으로는 같은 루프가
  손으로 만든 프로젝트와 CD 빌드 모두에서 **타이밍을 못 맞춥니다**:

  | 빌드 | 구현 전략 | WNS | 실패 endpoint | 최악 경로 |
  |---|---|---|---|---|
  | 손으로 만든 `mem_copy_vivado` | 기본 | -0.201 ns | 6 | RDMA `r_hs_data_cnt` |
  | CD `71cdca3` | 기본 | -0.347 ns | 12 | RDMA `r_hs_data_cnt` (22단) |
  | CD `71cdca3` | `Performance_ExplorePostRoutePhysOpt` | **+0.003 ns** | 0 | WDMA `r_hs_data_cnt` (17단) |

  이제 `scripts/fpga.py system`은 기본으로 explore 전략을 쓰고, 배선 전후에 phys_opt를 켭니다.
  타이밍은 맞지만 여유가 +0.003 ns로 매우 얇아서, 배치가 달라지거나 RTL/BD가 조금만 바뀌어도 다시
  실패할 수 있습니다. CI는 WNS < 0이면 FPGA 단계를 실패로 처리합니다.
- **개선 방안 (RTL 담당자):** `burst_len_aw` / 경계 길이를 한 사이클 먼저 레지스터에 저장합니다.
  AW FSM이 이미 `S_PRE`에서 한 사이클을 쓰므로, 거기서 미리 계산해 둘 수 있습니다.

## NOTE-002: 작업 중 VALUE_TO_ADD를 바꾸면 그 뒤에 R로 받는 beat부터 새 값이 더해짐
- **발견:** TB 2단계 가설 H3, `dma_busy_reg_write_test` (PASS, predictor가 이 동작을 beat 단위로 예측해 비교)
- **동작:** 크기와 주소는 start에서 잡지만(rdma.v:276, wdma.v:294, 실제 사용은 S_PRE), VALUE_TO_ADD는 레지스터에 바로
  연결되어(`dma_ip_top.v:302`) adder가 beat마다 그 사이클 값을 씀(`axis_adder.v:109`). 그래서 VALUE를 쓰는 W
  handshake 에지까지 R로 받은 beat 수가 k면 beat 0..k-1은 옛 값, beat k..은 새 값이 더해짐(seed 1: k=40). RDMA가 다 읽은
  뒤 바꾸면 영향 없음. 하위 8비트만 쓰임(0xABCDEF22 -> 0x22).
- **사용자 결정 (2026-11-21):** 버그가 아니라 동작으로 문서화. SW는 start 전에 값을 써야 함(제공 SW는 그렇게 함, c:100).

## NOTE-003: 리셋이 걸린 뒤 2사이클 동안 DUT의 WVALID가 1로 남음
- **발견:** TB 2단계 H4 판정 중 (`dma_reset_mid_job_test` trace, 1845~1865ns)
- **동작:** ap_rst_n을 한 번 레지스터로 받아 쓰므로(`dma_ip_top.v:140-142`, `wdma.v:257-259`) rst_n=0 뒤 2에지 동안
  WVALID=1이 남음. AXI A3.1.2는 "리셋 중 master VALID는 LOW"를 요구함. 그때 slave WREADY=0이라 이번 검증에서는 영향 없었음.
- **영향:** 낮음. 리셋 중 READY를 1로 두는 slave라면 handshake가 될 수 있음. RTL 담당자 참고.
