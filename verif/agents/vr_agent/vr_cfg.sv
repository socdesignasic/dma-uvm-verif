// vr_cfg : agent mode + stimulus/backpressure knobs
class vr_cfg extends uvm_object;
  vr_mode_e    mode      = VR_MASTER;
  // master knob: idle cycles after reset before the first beat may be driven
  // (0 = drive valid on the very first cycle out of reset, legal per AXI-Stream)
  int unsigned post_reset_idle = 0;
  // slave backpressure knobs
  int unsigned ready_pct = 100;  // P(ready=1) per cycle
  int unsigned stall_pct = 0;    // P(start a long stall) per cycle
  int unsigned max_stall = 0;    // long stall length upper bound (cycles)

  `uvm_object_utils(vr_cfg)
  function new(string name = "vr_cfg");
    super.new(name);
  endfunction
endclass
