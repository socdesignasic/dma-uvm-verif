"""vcd.py 테스트: 구간 시작 값, 구간 안 변화, 신호 고르기, 16진수 표시."""
import unittest

import vcd

SAMPLE = """$timescale 1ps $end
$scope module tb $end
$scope module dut $end
$var wire 1 ! s_valid $end
$var wire 1 " s_ready $end
$var wire 64 # m_data [63:0] $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
$dumpvars
1!
0"
b0 #
$end
#105000
1"
b1011100101011101 #
#116000
0!
#200000
1!
"""


class Vcd(unittest.TestCase):
    def test_window(self):
        r = vcd.parse(SAMPLE, 100, 120)
        self.assertEqual(r["initial"]["/tb/dut/s_ready"], "0")
        self.assertEqual(r["initial"]["/tb/dut/s_valid"], "1")
        self.assertIn((105.0, "/tb/dut/m_data", "0x000000000000b95d"), r["changes"])
        self.assertIn((116.0, "/tb/dut/s_valid", "0"), r["changes"])
        self.assertFalse([c for c in r["changes"] if c[0] > 120])

    def test_signal_filter_and_text(self):
        r = vcd.parse(SAMPLE, 100, 120, ["s_ready"])
        self.assertEqual(set(r["signals"]), {"/tb/dut/s_ready"})
        txt = vcd.as_text(r)
        self.assertIn("initial: s_ready=0", txt)
        self.assertIn("105.000ns  s_ready=1", txt)


if __name__ == "__main__":
    unittest.main()
