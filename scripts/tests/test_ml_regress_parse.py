"""ml_regress.py xcrg 보고서 파서 테스트. 이 파서는 xcrg 2022.2 텍스트 형식 때문에 두 번 고쳤습니다
(7f37abb: 두 번째 cross 표 중복, 묶인 미적중 행 "(a b)"/"*"; 9cd7f01: 보고서 없이 끝나는 경우 재시도).
고정 샘플: top TB의 병합 기능 커버리지 보고서 (cov-report)."""
import json
import unittest
from pathlib import Path

import ml_regress
from common import ROOT

FX = Path(__file__).parent / "fixtures"


class ParseReport(unittest.TestCase):
    def setUp(self):
        self.bins = ml_regress.parse_report((FX / "xcrg_top_func_report.txt").read_text(encoding="utf-8"))

    def test_target_bins_are_parsed(self):
        """계획의 top 목표 bin(실제로 친 bin)은 모두 보고서에서 읽혀야 하고, 적중 수가 1 이상이어야 함."""
        plan = json.loads((ROOT / "verif" / "regress_plan.json").read_text(encoding="utf-8"))
        target = plan["target_bins"]["top"]
        missing = [b for b in target if b not in self.bins]
        self.assertEqual(missing, [])
        self.assertTrue(all(self.bins[b] > 0 for b in target))

    def test_no_aggregated_rows(self):
        """못 친 cross bin 묶음 행("*", "(a b)")은 개별 bin으로 읽지 않음."""
        self.assertFalse([k for k in self.bins if "*" in k or "(" in k])


if __name__ == "__main__":
    unittest.main()
