// dma_scoreboard : per-job check of memory contents and bus traffic
//   start_job() clears the burst list, check_job() runs after ap_done
class dma_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(dma_scoreboard)
  uvm_analysis_imp #(axi4_burst, dma_scoreboard) burst_imp;
  axi4_mem     mem;
  axi4_burst   bursts[$];        // AR+AW seen during the current job
  int unsigned n_jobs, n_jobs_fail;
  bit          expect_jobs = 1;  // register-only tests clear this

  function new(string name, uvm_component parent);
    super.new(name, parent);
    burst_imp = new("burst_imp", this);
  endfunction

  function void write(axi4_burst b);
    bursts.push_back(b);
  endfunction

  function void start_job(dma_job j);
    bursts.delete();
  endfunction

  static function bit [7:0] model_byte(bit [7:0] s, bit [31:0] value);
    return s + value[LANE_BW-1:0];
  endfunction

  // src_snapshot: source bytes captured before start (DUT must not touch them)
  function void check_job(dma_job j, bit [7:0] src_snapshot[], bit [7:0] guard_val);
    int unsigned errs, rd_beats, wr_beats;
    bit [7:0] exp, act;

    // 1. data: every destination byte
    for (int unsigned i = 0; i < j.bytes; i++) begin
      exp = model_byte(src_snapshot[i], j.value);
      act = mem.rd8(j.dst + i);
      if (!mem.has(j.dst + i) || act !== exp) begin
        if (errs < 10)
          `uvm_error("SB_DATA", $sformatf("%s: byte %0d @0x%08h exp=0x%02h act=0x%02h%s",
                     j.convert2string(), i, j.dst + i, exp, act,
                     mem.has(j.dst + i) ? "" : " (never written)"))
        errs++;
      end
    end
    // 2. no overrun/underrun around dst, source untouched
    for (int unsigned g = 1; g <= GUARD; g++) begin
      if (mem.rd8(j.dst - g) !== guard_val || mem.rd8(j.dst + j.bytes - 1 + g) !== guard_val) begin
        `uvm_error("SB_OVERRUN", $sformatf("%s: write outside dst (guard byte %0d changed)",
                                            j.convert2string(), g))
        errs++;
        break;
      end
    end
    for (int unsigned i = 0; i < j.bytes; i++)
      if (mem.rd8(j.src + i) !== src_snapshot[i]) begin
        `uvm_error("SB_SRC", $sformatf("%s: source byte %0d was modified", j.convert2string(), i))
        errs++;
        break;
      end
    // 3. bus traffic: every burst inside its window, beat totals exact
    foreach (bursts[k]) begin
      axi4_burst b = bursts[k];
      bit [31:0] lo = b.is_write ? j.dst : j.src;
      if (b.addr < lo || b.end_addr() > lo + j.bytes) begin
        `uvm_error("SB_RANGE", $sformatf("%s: %s outside [0x%08h,0x%08h)",
                                          j.convert2string(), b.convert2string(), lo, lo + j.bytes))
        errs++;
      end
      if (b.is_write) wr_beats += b.beats(); else rd_beats += b.beats();
    end
    if (rd_beats != j.beats() || wr_beats != j.beats()) begin
      `uvm_error("SB_BEATS", $sformatf("%s: AR beats=%0d AW beats=%0d, expected %0d each",
                                        j.convert2string(), rd_beats, wr_beats, j.beats()))
      errs++;
    end

    n_jobs++;
    if (errs) n_jobs_fail++;
    else `uvm_info("SB_JOB", {"PASS ", j.convert2string(),
                              $sformatf(" bursts=%0d", bursts.size())}, UVM_LOW)
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB_SUMMARY", $sformatf("jobs=%0d failed=%0d", n_jobs, n_jobs_fail), UVM_LOW)
  endfunction

  function void check_phase(uvm_phase phase);
    if (n_jobs == 0 && expect_jobs)
      `uvm_error("SB_NO_JOBS", "no DMA job was checked")
  endfunction
endclass
