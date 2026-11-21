"""sim.py 판정(judge) 테스트. 고정 샘플은 실제 XSim 2022.2 로그에서 뽑은 것입니다.

xsim_*.log: verif/selftest/xsim_msgs_tb.sv를 +KIND=<종류>로 돌린 로그
uvm_pass.log: top dma_smoke_test seed 1 (PASS), uvm_xfail_bug002.log: top dma_aw_backpressure_test seed 1
"""
import tempfile
import unittest
from pathlib import Path

import sim

FX = Path(__file__).parent / "fixtures"
FIXTURES = [f"xsim_{k}.log" for k in ("none", "error", "warning", "fatal", "assert", "immediate", "bind")] + [
    "uvm_pass.log", "uvm_xfail_bug002.log"]


class Fixtures(unittest.TestCase):
    """샘플이 없으면 judge가 빈 로그로 판정해 조용히 통과할 수 있으므로 먼저 확인 (.gitignore에 걸린 적 있음)."""

    def test_fixtures_exist(self):
        self.assertEqual([f for f in FIXTURES if not (FX / f).is_file()], [])


class JudgeXsimMessages(unittest.TestCase):
    """XSim 자체 메시지: $error, $fatal, 동작 블록 없는 assertion은 FAIL, $warning은 영향 없음."""

    def test_each_kind(self):
        expect = {"none": "PASS", "warning": "PASS", "error": "FAIL", "fatal": "FAIL",
                  "assert": "FAIL", "immediate": "FAIL", "bind": "FAIL"}
        for kind, status in expect.items():
            with self.subTest(kind=kind):
                r = sim.judge(FX / f"xsim_{kind}.log", uvm=False, rc=0)  # 종료 코드는 0으로 둬도 로그로 잡아야 함
                self.assertEqual(r["status"], status, r["reasons"])

    def test_error_line_is_reported(self):
        r = sim.judge(FX / "xsim_error.log", uvm=False, rc=0)
        self.assertTrue(any("selftest error message" in e for e in r["first_errors"]))


class JudgeUvm(unittest.TestCase):
    def test_pass(self):
        r = sim.judge(FX / "uvm_pass.log", uvm=True, rc=0)
        self.assertEqual(r["status"], "PASS", r["reasons"])
        self.assertEqual(r["uvm_counts"].get("UVM_ERROR"), 0)

    def test_uvm_error_counts(self):
        r = sim.judge(FX / "uvm_xfail_bug002.log", uvm=True, rc=0)
        self.assertEqual(r["status"], "FAIL")
        self.assertTrue(any(x.startswith("UVM_ERROR=") for x in r["reasons"]), r["reasons"])
        self.assertTrue(any("[AXI_WLAST]" in e for e in r["first_errors"]))

    def test_timeout_and_exit_code(self):
        self.assertIn("timeout", sim.judge(FX / "uvm_pass.log", uvm=True, rc=124)["reasons"])
        self.assertEqual(sim.judge(FX / "uvm_pass.log", uvm=True, rc=3)["status"], "FAIL")

    def test_no_summary_means_fail(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "run.log"
            log.write_text("UVM_INFO @ 0: reporter [RNTST] Running test dma_smoke_test...\n", encoding="utf-8")
            r = sim.judge(log, uvm=True, rc=0)
            self.assertEqual(r["status"], "FAIL")
            self.assertTrue(any("no UVM Report Summary" in x for x in r["reasons"]))

    def test_missing_log(self):
        self.assertEqual(sim.judge(FX / "does_not_exist.log", uvm=True, rc=0)["status"], "FAIL")


if __name__ == "__main__":
    unittest.main()
