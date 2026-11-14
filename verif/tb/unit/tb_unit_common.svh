// Shared TB-top boilerplate for unit TBs: clock, reset, two vr_if, UVM kick-off.
// Expects the including module to define DUT_KIND (string literal).
  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;                       // 100 MHz
  initial begin
    repeat (10) @(posedge clk);
    rst <= 1'b0;
  end

  vr_if #(64) in_if  (clk, rst);
  vr_if #(64) out_if (clk, rst);
  assign out_if.side = '0;                    // sideband unused on output

  initial begin
    uvm_config_db#(virtual vr_if #(64))::set(null, "uvm_test_top.env.in_agt",  "vif", in_if);
    uvm_config_db#(virtual vr_if #(64))::set(null, "uvm_test_top.env.out_agt", "vif", out_if);
    uvm_config_db#(string)::set(null, "uvm_test_top", "dut_kind", `DUT_KIND);
    run_test();
  end
