"""record_signoff.py 테스트: 넣을 줄의 숫자와 위치, 같은 빌드를 두 번 넣지 않음."""
import json
import unittest
from types import SimpleNamespace

import record_signoff as rs
from tests.helpers import TempRepo

MD = """## 판정 기록

### Jenkins smoke 추이

| 빌드 | smoke 방식 | 결과 | 테스트 (pass / skip(XFAIL) / fail) | OOC WNS | 계획 목표 bin | Sign-off | 시간 |
|---|---|---|---|---|---|---|---|
| #27 | ML 계획 (47회) | SUCCESS | 43 / 4 / 0 | +0.014ns | 183/183 | **smoke PASS** | 9.3분 |

### Jenkins nightly(full) 추이

| 빌드 | 결과 |
|---|---|
"""


class RecordSignoff(unittest.TestCase):
    def setUp(self):
        self.repo = TempRepo()
        out = self.repo.root / "out"
        (out / "regress" / "top").mkdir(parents=True)
        (out / "regress" / "top" / "junit.xml").write_text(
            '<testsuite name="top" tests="17" failures="0" skipped="1"></testsuite>', encoding="utf-8")
        (out / "regress" / "top" / "summary.json").write_text(json.dumps(
            {"runs": 17, "fail": 0, "xfail": 1, "results": [], "build_fail": []}), encoding="utf-8")
        (out / "ml").mkdir()
        (out / "ml" / "check.json").write_text(json.dumps({"ok": True, "covered": 183, "target": 183}), encoding="utf-8")
        (out / "fpga" / "ooc").mkdir(parents=True)
        (out / "fpga" / "ooc" / "result.json").write_text(json.dumps({"wns": 0.014, "whs": 0.125}), encoding="utf-8")

    def tearDown(self):
        self.repo.cleanup()

    def test_smoke_row_and_insert(self):
        a = SimpleNamespace(mode="smoke", build="#30", result="SUCCESS", minutes=10.6)
        line, so = rs.row(self.repo.root, a)
        self.assertTrue(line.startswith("| #30 | ML 계획 (17회) | SUCCESS | 16 / 1 / 0 | +0.014ns | 183/183 | **smoke "), line)
        self.assertTrue(line.endswith("| 10.6분 |"))
        md = rs.insert(MD, "smoke", line, "#30")
        rows = [l for l in md.splitlines() if l.startswith("| #")]
        self.assertEqual([r.split(" | ")[0] for r in rows], ["| #30", "| #27"])   # 최신이 위
        with self.assertRaises(SystemExit):
            rs.insert(md, "smoke", line, "#30")                                   # 같은 빌드 두 번 금지


if __name__ == "__main__":
    unittest.main()
