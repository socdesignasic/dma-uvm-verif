"""check_inventory.py 테스트: 검사를 지우거나 억제 구문을 넣으면 기준선 비교가 잡아야 함."""
import tempfile
import unittest
from pathlib import Path

import check_inventory as ci

SRC = '''
`define HOLD(name, v) \\
  name : assert property (@(posedge clk) v) \\
    else `uvm_error("X_SVA", "hold")
interface x_if;
  `HOLD(a_x_hold, ok)
  a_known : assert property (@(posedge clk) !$isunknown(v)) else `uvm_error("X_SVA", "x");
endinterface
class x_sb;
  function void check();
    if (a != b) `uvm_error("SB_DATA", "mismatch")   // 주석 안의 `uvm_error("FAKE", "") 는 세지 않음
    if (c) `uvm_error("SB_DATA", "again")
  endfunction
endclass
'''


class Inventory(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.root = Path(self.td.name)
        (self.root / "x.sv").write_text(SRC, encoding="utf-8")
        self.base = ci.scan(self.root)

    def tearDown(self):
        self.td.cleanup()

    def test_counts(self):
        c = self.base["checks"]
        self.assertEqual(c.get("SB_DATA"), 2)
        self.assertEqual(c.get("SVA:a_x_hold"), 1)          # 매크로로 만든 assertion
        self.assertEqual(c.get("SVA:a_known"), 1)
        self.assertNotIn("FAKE", c)                         # 주석은 세지 않음
        self.assertNotIn("SVA:name", c)                     # 매크로 정의 안의 형식 인자는 세지 않음

    def test_removed_check_is_reported(self):
        f = self.root / "x.sv"
        f.write_text(SRC.replace('    if (c) `uvm_error("SB_DATA", "again")\n', ""), encoding="utf-8")
        probs = ci.compare(ci.scan(self.root), self.base)
        self.assertTrue(any(p.startswith("CHECK_REMOVED SB_DATA: 2 -> 1") for p in probs), probs)

    def test_demoted_check_is_reported(self):
        f = self.root / "x.sv"
        f.write_text(SRC.replace('`uvm_error("SB_DATA", "again")', '`uvm_info("SB_DATA", "again", UVM_LOW)'),
                     encoding="utf-8")
        self.assertTrue(ci.compare(ci.scan(self.root), self.base))

    def test_suppression_is_reported(self):
        (self.root / "t.sv").write_text(
            'class t; function f(); set_report_severity_id_override(UVM_ERROR, "SB_DATA", UVM_INFO); '
            'endfunction endclass\n', encoding="utf-8")
        probs = ci.compare(ci.scan(self.root), self.base)
        self.assertTrue(any(p.startswith("SUPPRESSION_ADDED report_override") for p in probs), probs)

    def test_moved_check_is_fine(self):
        (self.root / "x.sv").write_text(SRC.replace('    if (c) `uvm_error("SB_DATA", "again")\n', ""),
                                        encoding="utf-8")
        (self.root / "y.sv").write_text('class y; function f(); `uvm_error("SB_DATA", "moved") endfunction endclass\n',
                                        encoding="utf-8")
        self.assertEqual(ci.compare(ci.scan(self.root), self.base), [])


if __name__ == "__main__":
    unittest.main()
