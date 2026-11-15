// vr_stream_seq : 랜덤 beat n_items개. 쉬는 간격과 경계값 편향은 선택
class vr_stream_seq extends uvm_sequence #(vr_item);
  `uvm_object_utils(vr_stream_seq)
  int unsigned n_items        = 100;
  int unsigned max_delay      = 0;    // beat 사이 쉬는 사이클 (상한)
  int unsigned zero_delay_pct = 100;  // beat 앞에 쉬는 사이클이 없을 확률(%)
  bit          fix_side       = 0;
  bit [31:0]   side_val       = 0;

  function new(string name = "vr_stream_seq");
    super.new(name);
  endfunction

  // data 경계값 약 8%, side 경계값 약 15% (adder overflow / wrap 자극)
  static const bit [63:0] DATA_CORNER[4] = '{64'h0, 64'hFFFF_FFFF_FFFF_FFFF,
                                             64'h7FFF_FFFF_7FFF_FFFF, 64'h8000_0000_8000_0000};
  static const bit [31:0] SIDE_CORNER[3] = '{32'h0, 32'h1, 32'hFFFF_FFFF};

  function void apply_corners(vr_item t);
    int unsigned pick = $urandom_range(99);
    if (pick < 8) t.data = DATA_CORNER[pick / 2];
    if (fix_side) t.side = side_val;
    else begin
      pick = $urandom_range(99);
      if (pick < 15) t.side = SIDE_CORNER[pick / 5];
    end
  endfunction

  virtual task body();
    repeat (n_items) begin
      req = vr_item::type_id::create("req");
      start_item(req);
      if (!req.randomize())
        `uvm_fatal("RAND", "vr_item randomize failed")
      apply_corners(req);
      req.delay = (max_delay == 0 || $urandom_range(99) < zero_delay_pct)
                  ? 0 : $urandom_range(max_delay, 1);
      finish_item(req);
    end
  endtask
endclass
