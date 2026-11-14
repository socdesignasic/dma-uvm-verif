// vr_stream_seq : n_items random beats with optional idle gaps and corner-value bias
class vr_stream_seq extends uvm_sequence #(vr_item);
  `uvm_object_utils(vr_stream_seq)
  int unsigned n_items        = 100;
  int unsigned max_delay      = 0;    // idle cycles between beats (upper bound)
  int unsigned zero_delay_pct = 100;  // P(no idle cycle before a beat)
  bit          fix_side       = 0;
  bit [31:0]   side_val       = 0;

  function new(string name = "vr_stream_seq");
    super.new(name);
  endfunction

  // ~8% data corners, ~15% side corners (adder overflow / wrap stimulus)
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
