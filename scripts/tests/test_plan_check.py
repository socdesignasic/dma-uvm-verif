"""plan_check.py 테스트: 지금 저장소는 통과하고, 어긋나게 만들면 해당 문제 코드가 나와야 함."""
import unittest

import plan_check
from check_inventory import scan
from common import ROOT
from tests.helpers import TempRepo

INV = scan(ROOT / "verif")                                  # 실제 검사 목록 (복사본과 같음)


def codes(res: dict) -> set[str]:
    return {p.split(" ", 1)[0] for p in res["problems"]}


class PlanCheck(unittest.TestCase):
    def setUp(self):
        self.repo = TempRepo()

    def tearDown(self):
        self.repo.cleanup()

    def run_check(self):
        return plan_check.check(self.repo.root, inventory=INV)

    def test_current_repo_passes(self):
        res = self.run_check()
        self.assertTrue(res["ok"], res["problems"])

    def test_unplanned_test(self):
        cfg = self.repo.cfg()
        cfg["tbs"]["top"]["tests"].append("dma_new_test")
        self.repo.write_cfg(cfg)
        self.assertIn("TEST_UNPLANNED", codes(self.run_check()))

    def test_hand_edited_vplan(self):
        self.repo.edit("verif/vplan/vplan.md", "| ✅ |", "| 🚧 |")
        self.assertIn("VPLAN_STALE", codes(self.run_check()))

    def test_known_fail_without_bug_entry(self):
        cfg = self.repo.cfg()
        cfg["tbs"]["top"]["known_fail"]["dma_rand_test"] = "BUG-009: 없는 버그"
        self.repo.write_cfg(cfg)
        self.assertIn("KNOWN_FAIL", codes(self.run_check()))

    def test_blocked_without_reason(self):
        self.repo.edit("verif/plan.toml", 'status = "blocked"\nbug = "BUG-002"', 'status = "blocked"')
        self.assertIn("BLOCKED_NO_REASON", codes(self.run_check()))

    def test_unknown_check_id(self):
        self.repo.edit("verif/plan.toml", '"SB_OVERRUN", "SB_SRC"', '"SB_OVERRUN", "SB_GONE"')
        self.assertIn("CHECK_UNKNOWN", codes(self.run_check()))

    def test_confirmed_hypothesis_needs_bug(self):
        # H1은 confirmed이고 BUG-005를 가리킴. plan.toml bugs에 없는 ID로 바꾸면 HYPOTHESIS여야 함
        anchor = 'test = "top/dma_start_busy_test"\nstatus = "confirmed"  # open | confirmed | refuted\nbug = "BUG-005"'
        self.repo.edit("verif/plan.toml", anchor, anchor.replace("BUG-005", "BUG-999"))
        self.assertIn("HYPOTHESIS", codes(self.run_check()))

    def test_render_has_every_feature(self):
        plan = plan_check.load(self.repo.root)
        md = plan_check.render(plan)
        for f in plan["features"]:
            self.assertIn(f["title"], md)


if __name__ == "__main__":
    unittest.main()
