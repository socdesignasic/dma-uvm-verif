// -----------------------------------------------------------------------------
// P0 smoke TB: 사용자의 UVM 참고 코드(uvm_reference/)를 고치지 않고 그대로
// Vivado XSim에서 컴파일. 참고 코드는 UVM을 자동 import하는 EDA Playground용으로
// 작성됐고 XSim은 자동 import를 하지 않으므로, 이 wrapper가 import를 넣어 줌.
// -----------------------------------------------------------------------------
`include "uvm_macros.svh"                           // UVM 매크로 포함
import uvm_pkg::*;                                  // UVM 라이브러리 import (참고 코드가 기대함)
`include "testbench.sv"                             // 참고 코드의 testbench를 그대로 포함
