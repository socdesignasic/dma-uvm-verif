"""signoff.py 테스트: 빠진 TB(S3)와 커밋이 섞인 결과(S10)를 FAIL로 판정해야 함.

임시 저장소에 회귀 요약과 FPGA 결과를 만들어 signoff.py --root로 판정합니다.
(임시 저장소는 git이 아니라 S11과 커버리지 S4는 여기서 보지 않음)
"""
import json
import subprocess
import sys
import unittest
from pathlib import Path

from common import ROOT
from tests.helpers import TempRepo


class Signoff(unittest.TestCase):
    def setUp(self):
        self.repo = TempRepo()
        self.out = self.repo.root / "out"

    def tearDown(self):
        self.repo.cleanup()

    def write_regress(self, commit_unit="c1", commit_top="c1", drop_tb=None):
        cfg = self.repo.cfg()
        kf = {(tb, t) for tb, v in cfg["tbs"].items() for t in (v.get("known_fail") or {})}
        for name, tbs, commit in (("unit", [t for t in cfg["tbs"] if cfg["tbs"][t].get("tests") and t != "top"],
                                   commit_unit), ("top", ["top"], commit_top)):
            res = [{"tb": tb, "test": t, "seed": 1, "verdict": "XFAIL" if (tb, t) in kf else "PASS", "ok": True,
                    "reasons": [], "rerun": ""}
                   for tb in tbs if tb != drop_tb for t in cfg["tbs"][tb]["tests"]]
            d = self.out / "regress" / name
            d.mkdir(parents=True, exist_ok=True)
            (d / "summary.json").write_text(json.dumps({
                "results": res, "build_fail": [], "commits": [commit],
                "provenance": {"commit": commit, "dirty": False, "hw_hash": "h1"}}), encoding="utf-8")
        d = self.out / "fpga" / "ooc"
        d.mkdir(parents=True, exist_ok=True)
        (d / "result.json").write_text(json.dumps({"wns": 0.01, "whs": 0.1, "provenance": {
            "commit": commit_unit, "dirty": False, "hw_hash": "h1"}}), encoding="utf-8")

    def verdicts(self) -> dict:
        subprocess.run([sys.executable, str(ROOT / "scripts" / "signoff.py"), "--level", "smoke",
                        "--root", str(self.repo.root)], capture_output=True)
        doc = json.loads((self.out / "signoff" / "signoff.json").read_text(encoding="utf-8"))
        return {c["id"]: c for c in doc["criteria"]}

    def test_complete_and_consistent(self):
        self.write_regress()
        v = self.verdicts()
        for cid in ("S1", "S2", "S3", "S10"):
            self.assertEqual(v[cid]["status"], "PASS", (cid, v[cid]["detail"]))

    def test_missing_tb_fails_s3(self):
        self.write_regress(drop_tb="adder8")
        v = self.verdicts()
        self.assertEqual(v["S3"]["status"], "FAIL")
        self.assertIn("missing_tbs=['adder8']", v["S3"]["detail"])

    def test_mixed_commits_fail_s10(self):
        self.write_regress(commit_top="c2")
        self.assertEqual(self.verdicts()["S10"]["status"], "FAIL")

    def test_results_without_provenance_fail_s10(self):
        self.write_regress()
        sj = self.out / "regress" / "top" / "summary.json"
        s = json.loads(sj.read_text(encoding="utf-8"))
        s.pop("provenance"), s.pop("commits")
        sj.write_text(json.dumps(s), encoding="utf-8")
        v = self.verdicts()
        self.assertEqual(v["S10"]["status"], "FAIL")
        self.assertIn("no_provenance", v["S10"]["detail"])


if __name__ == "__main__":
    unittest.main()
