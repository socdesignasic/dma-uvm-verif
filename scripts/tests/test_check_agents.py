"""check_agents.py 테스트: 지금 저장소는 통과하고, 규칙을 어긴 정의는 해당 코드로 잡혀야 함."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import check_agents
from common import ROOT

GOOD = "---\nname: {n}\ndescription: d\ntools: Read, Grep\n---\n본문\n"


class CheckAgents(unittest.TestCase):
    def test_current_repo_passes(self):
        self.assertEqual(check_agents.check(), [])

    def make(self, files: dict[str, str]) -> list[str]:
        with tempfile.TemporaryDirectory() as td:
            t = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=t)
            shutil.copytree(ROOT / ".claude" / "skills", t / ".claude" / "skills")
            shutil.copytree(ROOT / ".claude" / "agents", t / ".claude" / "agents")  # 스킬이 가리키는 에이전트
            for rel, txt in files.items():
                (t / rel).parent.mkdir(parents=True, exist_ok=True)
                (t / rel).write_text(txt, encoding="utf-8")
            return check_agents.check(t)

    def codes(self, files):
        return {p.split(" ", 1)[0] for p in self.make(files)}

    def test_reviewer_with_write(self):
        bad = GOOD.format(n="tb-reviewer").replace("Read, Grep", "Read, Edit")
        self.assertIn("AGENT_WRITE", self.codes({".claude/agents/tb-reviewer.md": bad}))

    def test_unknown_tools(self):
        bad = GOOD.format(n="sim-triage").replace("Read, Grep", "Read, mcp__vivado__no_such, mcp__jenkins__replayBuild")
        probs = self.make({".claude/agents/sim-triage.md": bad})
        self.assertEqual(len([p for p in probs if p.startswith("AGENT_TOOL")]), 2, probs)

    def test_hard_coded_path_and_name_mismatch(self):
        bad = GOOD.format(n="other").replace("본문", "verif/tests/top/ 를 읽으세요")
        self.assertTrue({"AGENT_PATH", "AGENT_META"} <= self.codes({".claude/agents/uvm-builder.md": bad}))

    def test_colon_in_frontmatter(self):
        bad = GOOD.format(n="sim-triage").replace("description: d", "description: x (예: y)")
        self.assertIn("AGENT_META", self.codes({".claude/agents/sim-triage.md": bad}))

    def test_stale_reference(self):
        doc = "`/verify-loop`를 돌리고 coverage-closer에게 맡김\n"
        codes = [p for p in self.make({"docs/X.md": doc}) if p.startswith("STALE_REF")]
        self.assertEqual(len(codes), 2, codes)


if __name__ == "__main__":
    unittest.main()
