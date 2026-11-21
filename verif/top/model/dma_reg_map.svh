// dma_reg_map : dma_ip_control_s_axi의 레지스터 맵 (주소와 비트 위치 상수. dma_reg_block과 dma_predictor가 씀)
//   사용하지 않는 비트는 0으로 읽힘

// ---- 주소 ----
localparam bit [11:0] ADDR_AP_CTRL            = 12'h00;  // AP_CTRL: 시작/완료/idle 제어 레지스터
localparam bit [11:0] ADDR_GIE                = 12'h04;  // [0]   전역 인터럽트 enable
localparam bit [11:0] ADDR_IER                = 12'h08;  // [1:0] 인터럽트 enable (0: ap_done, 1: ap_ready)
localparam bit [11:0] ADDR_ISR                = 12'h0C;  // [1:0] 인터럽트 상태, 읽으면 지워짐
localparam bit [11:0] ADDR_RDMA_TRANSFER_BYTE = 12'h10;  // RDMA 전송 바이트 수
localparam bit [11:0] ADDR_RDMA_MEM_PTR       = 12'h14;  // RDMA 원본 주소
localparam bit [11:0] ADDR_WDMA_TRANSFER_BYTE = 12'h18;  // WDMA 전송 바이트 수
localparam bit [11:0] ADDR_WDMA_MEM_PTR       = 12'h1C;  // WDMA 대상 주소
localparam bit [11:0] ADDR_AXI00_PTR0         = 12'h20;  // AXI00 포인터 (사용 안 함, 0으로 설정)
localparam bit [11:0] ADDR_VALUE_TO_ADD       = 12'h24;  // 더할 값 (하위 8비트 사용)

// ---- AP_CTRL 비트 ----
localparam int AP_START        = 0;   // RW, 스스로 지워짐
localparam int AP_DONE         = 1;   // RO, 읽으면 지워짐
localparam int AP_IDLE         = 2;   // RO
localparam int AP_READY        = 3;   // RO, 읽으면 지워짐
localparam int AP_AUTO_RESTART = 7;   // RW
localparam int AP_INTERRUPT    = 9;   // RO

// ---- ISR / IER 비트 ----
localparam int ISR_AP_DONE     = 0;                 // ISR/IER 0번 비트: ap_done
localparam int ISR_AP_READY    = 1;                 // ISR/IER 1번 비트: ap_ready
