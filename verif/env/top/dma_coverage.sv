// dma_coverage : job-level (size, value, mode, 4KB) and burst-level functional coverage
class dma_coverage extends uvm_component;
  `uvm_component_utils(dma_coverage)
  uvm_analysis_imp #(axi4_burst, dma_coverage) burst_imp;

  // sampled values
  int unsigned beats, blen;
  bit [7:0]    v8;
  bit          upper_set, src_x4k, dst_x4k, is_wr, at_4k_end;
  done_mode_e  mode;

  covergroup cg_job;
    option.per_instance = 1;
    cp_beats : coverpoint beats { bins one = {1}; bins few = {[2:15]}; bins max_burst = {16};
                                  bins multi = {[17:511]}; bins page = {512};
                                  // explicit bound: XSim 2022.2 mis-evaluates `$` here and
                                  // counted EVERY job as huge (see CLAUDE.md pitfalls)
                                  bins huge = {[513:32'h1FFF_FFFF]}; }
    cp_value : coverpoint v8    { bins zero = {0}; bins one = {1}; bins max = {255};
                                  bins other = {[2:254]}; }
    cp_upper : coverpoint upper_set;   // value_to_add[31:8] != 0 must be ignored
    cp_mode  : coverpoint mode;
    cp_src4k : coverpoint src_x4k;
    cp_dst4k : coverpoint dst_x4k;
    x_size_mode : cross cp_beats, cp_mode;
  endgroup

  covergroup cg_burst;
    option.per_instance = 1;
    cp_dir  : coverpoint is_wr { bins rd = {0}; bins wr = {1}; }
    cp_len  : coverpoint blen  { bins one = {1}; bins mid = {[2:15]}; bins full = {16}; }
    cp_4k   : coverpoint at_4k_end { bins split_at_4k = {1}; bins other = {0}; }
    x_dir_len : cross cp_dir, cp_len;
    x_dir_4k  : cross cp_dir, cp_4k;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    burst_imp = new("burst_imp", this);
    cg_job    = new();
    cg_burst  = new();
  endfunction

  function void sample_job(dma_job j);
    beats = j.beats(); v8 = j.value[7:0]; upper_set = (j.value[31:8] != 0);
    mode = j.mode; src_x4k = j.crosses_4k(j.src); dst_x4k = j.crosses_4k(j.dst);
    cg_job.sample();
  endfunction

  // a short burst ending exactly on a 4KB page = the DUT's 4KB split logic fired
  function void write(axi4_burst b);
    bit [31:0] e = b.end_addr();
    is_wr = b.is_write; blen = b.beats();
    at_4k_end = (e[11:0] == 0) && (b.beats() < 16);
    cg_burst.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("job=%.1f%% burst=%.1f%%",
                               cg_job.get_inst_coverage(), cg_burst.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
