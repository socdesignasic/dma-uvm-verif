// dma_reg_map : dma_ip_control_s_axi의 레지스터 맵 (단순 상수, RAL 없음)
//   사용하지 않는 비트는 0으로 읽힘

// ---- 주소 ----
localparam bit [11:0] ADDR_AP_CTRL            = 12'h00;
localparam bit [11:0] ADDR_GIE                = 12'h04;  // [0]   전역 인터럽트 enable
localparam bit [11:0] ADDR_IER                = 12'h08;  // [1:0] 인터럽트 enable (0: ap_done, 1: ap_ready)
localparam bit [11:0] ADDR_ISR                = 12'h0C;  // [1:0] 인터럽트 상태, 읽으면 지워짐
localparam bit [11:0] ADDR_RDMA_TRANSFER_BYTE = 12'h10;
localparam bit [11:0] ADDR_RDMA_MEM_PTR       = 12'h14;
localparam bit [11:0] ADDR_WDMA_TRANSFER_BYTE = 12'h18;
localparam bit [11:0] ADDR_WDMA_MEM_PTR       = 12'h1C;
localparam bit [11:0] ADDR_AXI00_PTR0         = 12'h20;
localparam bit [11:0] ADDR_VALUE_TO_ADD       = 12'h24;

// ---- AP_CTRL 비트 ----
localparam int AP_START        = 0;   // RW, 스스로 지워짐
localparam int AP_DONE         = 1;   // RO, 읽으면 지워짐
localparam int AP_IDLE         = 2;   // RO
localparam int AP_READY        = 3;   // RO, 읽으면 지워짐
localparam int AP_AUTO_RESTART = 7;   // RW
localparam int AP_INTERRUPT    = 9;   // RO

// ---- ISR / IER 비트 ----
localparam int ISR_AP_DONE     = 0;
