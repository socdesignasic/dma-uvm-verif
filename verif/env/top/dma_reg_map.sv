// dma_reg_map : register map of dma_ip_control_s_axi (plain constants, no RAL)
//   unused bits read as 0

// ---- addresses ----
localparam bit [11:0] ADDR_AP_CTRL            = 12'h00;
localparam bit [11:0] ADDR_GIE                = 12'h04;  // [0]   global interrupt enable
localparam bit [11:0] ADDR_IER                = 12'h08;  // [1:0] interrupt enable (0: ap_done, 1: ap_ready)
localparam bit [11:0] ADDR_ISR                = 12'h0C;  // [1:0] interrupt status, clear on read
localparam bit [11:0] ADDR_RDMA_TRANSFER_BYTE = 12'h10;
localparam bit [11:0] ADDR_RDMA_MEM_PTR       = 12'h14;
localparam bit [11:0] ADDR_WDMA_TRANSFER_BYTE = 12'h18;
localparam bit [11:0] ADDR_WDMA_MEM_PTR       = 12'h1C;
localparam bit [11:0] ADDR_AXI00_PTR0         = 12'h20;
localparam bit [11:0] ADDR_VALUE_TO_ADD       = 12'h24;

// ---- AP_CTRL bits ----
localparam int AP_START        = 0;   // RW, self-clearing
localparam int AP_DONE         = 1;   // RO, clear on read
localparam int AP_IDLE         = 2;   // RO
localparam int AP_READY        = 3;   // RO, clear on read
localparam int AP_AUTO_RESTART = 7;   // RW
localparam int AP_INTERRUPT    = 9;   // RO

// ---- ISR / IER bits ----
localparam int ISR_AP_DONE     = 0;
