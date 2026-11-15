// vr_item : valid/ready beat 하나 (data + sideband)와 그 앞의 쉬는 사이클
class vr_item extends uvm_sequence_item;
  rand bit [63:0] data;
  rand bit [31:0] side;
  int unsigned    delay;   // valid 전에 쉬는 사이클 (sequence가 정함)

  // 일부러 여기에는 constraint를 두지 않음: XSim 2022.2의 `dist`가 값을 심하게
  // 치우치게 만들었음 (넓은 64비트 범위가 2^32 아래로 몰리고, 2% 가중치 값이
  // 약 50% 나옴). 경계값 편향은 vr_stream_seq에서 절차적으로 넣습니다.

  `uvm_object_utils_begin(vr_item)
    `uvm_field_int(data, UVM_ALL_ON)
    `uvm_field_int(side, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "vr_item");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("data=0x%016h side=0x%08h", data, side);
  endfunction
endclass
