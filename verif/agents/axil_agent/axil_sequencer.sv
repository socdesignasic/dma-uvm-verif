// axil_sequencer : axil_item의 sequencer
class axil_sequencer extends uvm_sequencer #(axil_item);  // axil_item용 UVM sequencer 상속
  `uvm_component_utils(axil_sequencer)              // factory 등록
  function new(string name, uvm_component parent);  // 생성자
    super.new(name, parent);                        // 부모 생성자 호출
  endfunction                                       // 생성자 끝
endclass                                            // 클래스 끝
