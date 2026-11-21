"""gate.py 2단계 검사 테스트: 가설 종결 규칙과 XFAIL 로그 규칙이 맞는 경우만 통과시키는지."""
import tempfile
import unittest
from pathlib import Path

import gate

CFG = {"tbs": {"top": {"tests": ["t_bug", "t_note", "t_ref"]}}}


def plan(**over):
    p = {"bugs": [{"id": "BUG-1", "kind": "bug", "known_fail": ["top/t_bug"]},
                  {"id": "NOTE-1", "kind": "note", "known_fail": []}],
         "hypotheses": [{"id": "H1", "status": "confirmed", "bug": "BUG-1", "test": "top/t_bug"},
                        {"id": "H2", "status": "confirmed", "bug": "NOTE-1", "test": "top/t_note"},
                        {"id": "H3", "status": "refuted", "test": "top/t_ref"}]}
    p.update(over)
    return p


class Hypotheses(unittest.TestCase):
    def test_closed_ok(self):
        self.assertEqual(gate.hypothesis_problems(plan(), CFG), [])

    def test_open_and_unregistered(self):
        p = plan(hypotheses=[{"id": "H9", "status": "open", "test": "top/nope"}])
        probs = gate.hypothesis_problems(p, CFG)
        self.assertEqual(len(probs), 2, probs)

    def test_bug_without_known_fail(self):
        p = plan(); p["bugs"][0]["known_fail"] = []
        self.assertTrue(any("known_fail" in x for x in gate.hypothesis_problems(p, CFG)))

    def test_note_test_must_not_be_known_fail(self):
        p = plan(); p["bugs"][0]["known_fail"].append("top/t_note")
        self.assertTrue(any("note NOTE-1" in x for x in gate.hypothesis_problems(p, CFG)))


class XfailLogs(unittest.TestCase):
    def run_one(self, log: str, reasons=("UVM_ERROR=3",)):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td) / "r"; d.mkdir()
            (d / "run.log").write_text(log, encoding="utf-8")
            res = [{"tb": "top", "test": "t", "seed": 1, "verdict": "XFAIL", "reasons": list(reasons), "run_dir": "r"},
                   {"tb": "top", "test": "u", "seed": 1, "verdict": "PASS", "reasons": [], "run_dir": "none"}]
            return gate.xfail_problems(res, Path(td))

    def test_clean(self):
        self.assertEqual(self.run_one("UVM_ERROR x [AXI_WLAST] bad\nUVM_FATAL :    0\n"), [])

    def test_tb_limit_and_fatal(self):
        probs = self.run_one("UVM_ERROR x [SCENARIO_MISS] no\nUVM_FATAL a.sv(1) @ 5: x [T] y\n")
        self.assertEqual(len(probs), 1); self.assertIn("SCENARIO_MISS", probs[0]); self.assertIn("UVM_FATAL", probs[0])

    def test_timeout_reason(self):
        self.assertEqual(len(self.run_one("ok\n", reasons=("timeout 600s",))), 1)


if __name__ == "__main__":
    unittest.main()
