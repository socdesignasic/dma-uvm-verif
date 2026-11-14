// -----------------------------------------------------------------------------
// unit_env_pkg : block-level env for stream blocks with one input and one
// output valid/ready port (sync_fifo, skid_buffer, axis_adder)
//
//   in_agt (VR_MASTER) --> DUT --> out_agt (VR_SLAVE, random backpressure)
//        \                             /
//         `--> scoreboard (in-order, reference model) <--'
//         `--> coverage   (beat values + per-cycle handshake states)
// -----------------------------------------------------------------------------
package unit_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import vr_pkg::*;

  // Reference model kind. Every unit block is in-order, lossless, 1 in : 1 out.
  typedef enum {MODEL_PASS,    // FIFO, skid buffer: out = in
                MODEL_ADD}     // axis_adder: each lane_bw-bit lane += side[lane_bw-1:0]
          model_e;

  `include "unit_env_cfg.sv"
  `include "unit_scoreboard.sv"
  `include "unit_coverage.sv"
  `include "unit_env.sv"
endpackage
