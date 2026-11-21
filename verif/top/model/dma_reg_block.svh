// dma_reg_block : dma_ip_control_s_axi 레지스터 10개의 RAL 모델 (주소는 dma_reg_map.svh 상수)
//   0x00 AP_CTRL  0x04 GIE  0x08 IER  0x0C ISR
//   0x10 RDMA_TRANSFER_BYTE  0x14 RDMA_MEM_PTR  0x18 WDMA_TRANSFER_BYTE  0x1C WDMA_MEM_PTR
//   0x20 AXI00_PTR0  0x24 VALUE_TO_ADD
//   모든 레지스터를 map에 "RW"로 올림 (쓰기 무시나 읽으면 지워짐은 필드 접근 방식이 정함).
//   그래서 uvm_reg_predictor가 0x00~0x24의 읽기와 쓰기를 모두 레지스터로 찾음
//   mirror는 uvm_reg_predictor가 axil_monitor 관찰값으로 갱신 (env가 연결, auto predict 끔)
//   AP_CTRL과 ISR은 build에서 NO_REG_BIT_BASH_TEST resource로 bit-bash 대상에서 뺌
class dma_reg_block extends uvm_reg_block;          // UVM 레지스터 블록 상속
  `uvm_object_utils(dma_reg_block)                  // factory 등록
  rand dma_ap_ctrl_reg ap_ctrl;                     // 0x00 AP_CTRL
  rand dma_gie_reg     gie;                         // 0x04 GIE
  rand dma_ier_reg     ier;                         // 0x08 IER
  rand dma_isr_reg     isr;                         // 0x0C ISR
  rand dma_data_reg    rdma_transfer_byte;          // 0x10 RDMA 바이트 수
  rand dma_data_reg    rdma_mem_ptr;                // 0x14 RDMA 원본 주소
  rand dma_data_reg    wdma_transfer_byte;          // 0x18 WDMA 바이트 수
  rand dma_data_reg    wdma_mem_ptr;                // 0x1C WDMA 대상 주소
  rand dma_data_reg    axi00_ptr0;                  // 0x20 AXI00 포인터 (DUT는 쓰지 않음)
  rand dma_data_reg    value_to_add;                // 0x24 더할 값

  function new(string name = "dma_reg_block");      // 생성자
    super.new(name, UVM_NO_COVERAGE);               // RAL 커버리지 없음
  endfunction                                       // 생성자 끝

  // 32비트 데이터 레지스터 하나를 만들고 map에 올림
  local function dma_data_reg add_data_reg(string name, uvm_reg_addr_t offset);  // 이름, 주소
    dma_data_reg r = dma_data_reg::type_id::create(name);  // 레지스터 객체 생성
    r.configure(this);                              // 이 블록에 속하게 함
    r.build();                                      // 필드 생성
    default_map.add_reg(r, offset, "RW");           // map에 주소와 함께 올림
    return r;                                       // 만든 레지스터 돌려줌
  endfunction                                       // add_data_reg 끝

  virtual function void build();                    // 레지스터 생성과 map 구성
    default_map = create_map("default_map", 0, 4, UVM_LITTLE_ENDIAN);  // 기준 주소 0, 4바이트 버스, 바이트 주소
    ap_ctrl = dma_ap_ctrl_reg::type_id::create("ap_ctrl");  // AP_CTRL 생성
    ap_ctrl.configure(this);                        // 이 블록에 속하게 함
    ap_ctrl.build();                                // 필드 생성
    default_map.add_reg(ap_ctrl, ADDR_AP_CTRL, "RW");  // map에 올림
    gie = dma_gie_reg::type_id::create("gie");      // GIE 생성
    gie.configure(this);                            // 이 블록에 속하게 함
    gie.build();                                    // 필드 생성
    default_map.add_reg(gie, ADDR_GIE, "RW");       // map에 올림
    ier = dma_ier_reg::type_id::create("ier");      // IER 생성
    ier.configure(this);                            // 이 블록에 속하게 함
    ier.build();                                    // 필드 생성
    default_map.add_reg(ier, ADDR_IER, "RW");       // map에 올림
    isr = dma_isr_reg::type_id::create("isr");      // ISR 생성
    isr.configure(this);                            // 이 블록에 속하게 함
    isr.build();                                    // 필드 생성
    default_map.add_reg(isr, ADDR_ISR, "RW");       // map에 올림 (쓰기 무시는 RC 필드가 처리)
    rdma_transfer_byte = add_data_reg("rdma_transfer_byte", ADDR_RDMA_TRANSFER_BYTE);  // 0x10
    rdma_mem_ptr       = add_data_reg("rdma_mem_ptr",       ADDR_RDMA_MEM_PTR);        // 0x14
    wdma_transfer_byte = add_data_reg("wdma_transfer_byte", ADDR_WDMA_TRANSFER_BYTE);  // 0x18
    wdma_mem_ptr       = add_data_reg("wdma_mem_ptr",       ADDR_WDMA_MEM_PTR);        // 0x1C
    axi00_ptr0         = add_data_reg("axi00_ptr0",         ADDR_AXI00_PTR0);          // 0x20
    value_to_add       = add_data_reg("value_to_add",       ADDR_VALUE_TO_ADD);        // 0x24
    lock_model();                                   // 모델 확정 (주소 표 생성)
    // RAL 내장 bit-bash에서 뺄 레지스터 (어디서 bit-bash를 돌려도 같게 블록이 정함).
    //   AP_CTRL: start를 쓰면 DMA가 시작됨, ISR: 읽으면 지워짐(RC).
    //   NO_REG_BIT_BASH_TEST만 씀 -> uvm_reg_hw_reset_seq의 리셋 값 검사에서는 빠지지 않음
    uvm_resource_db#(bit)::set({"REG::", ap_ctrl.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);  // AP_CTRL
    uvm_resource_db#(bit)::set({"REG::", isr.get_full_name()},     "NO_REG_BIT_BASH_TEST", 1, this);  // ISR
  endfunction                                       // build 끝
endclass                                            // 클래스 끝
