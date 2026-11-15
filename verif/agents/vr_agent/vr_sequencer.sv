// vr_sequencer : vr_item의 sequencer (master 모드에서만)
class vr_sequencer extends uvm_sequencer #(vr_item);  // vr_item용 UVM sequencer 상속
  `uvm_component_utils(vr_sequencer)                // factory 등록
  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝
endclass                                            // 클래스 끝
