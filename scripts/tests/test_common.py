"""common.py 테스트: Windows 명령줄, 입력 해시, 시간 초과 때 프로세스 트리 종료."""
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import common


def alive(pid: int) -> bool:                                # 프로세스가 살아 있는지
    if os.name == "nt":
        out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True).stdout
        return str(pid) in out
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


class WinCmdline(unittest.TestCase):
    def test_quotes_and_slashes(self):
        line = common.win_cmdline(["xsim.bat", "UVM_TESTNAME=foo", "C:\\a b\\c", "-R"])
        self.assertEqual(line, 'xsim.bat "UVM_TESTNAME=foo" "C:/a b/c" -R')


class FilesHash(unittest.TestCase):
    def test_content_and_extra_change_hash(self):
        with tempfile.TemporaryDirectory() as td:
            f = Path(td) / "a.sv"
            f.write_text("module a; endmodule\n", encoding="utf-8")
            h1 = common.files_hash([f], ["X=1"])
            self.assertEqual(h1, common.files_hash([f], ["X=1"]))         # 같은 입력 -> 같은 해시
            self.assertNotEqual(h1, common.files_hash([f], ["X=2"]))      # define이 다르면 다름
            f.write_text("module a; wire w; endmodule\n", encoding="utf-8")
            self.assertNotEqual(h1, common.files_hash([f], ["X=1"]))      # 내용이 바뀌면 다름


class RunCmdTimeout(unittest.TestCase):
    def test_timeout_kills_children(self):
        """부모가 자식을 띄우고 둘 다 오래 잠. 시간 초과면 124를 돌려주고 자식도 죽어야 함."""
        with tempfile.TemporaryDirectory() as td:
            pidf = Path(td) / "child.pid"
            code = ("import subprocess, sys, time; "
                    "p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)']); "
                    f"open(r'{pidf}', 'w').write(str(p.pid)); time.sleep(120)")
            t0 = time.time()
            rc = common.run_cmd([sys.executable, "-c", code], Path(td), timeout=4, echo=False)
            self.assertEqual(rc, common.TIMEOUT_RC)
            self.assertLess(time.time() - t0, 60)
            child = int(pidf.read_text())
            for _ in range(20):                             # 정리될 때까지 잠깐 기다림
                if not alive(child):
                    break
                time.sleep(0.5)
            self.assertFalse(alive(child), "child process survived the timeout")


class Provenance(unittest.TestCase):
    def test_fields(self):
        p = common.provenance()
        for k in ("commit", "dirty", "branch", "hw_hash", "time"):
            self.assertIn(k, p)

    def test_hw_hash_ignores_line_endings(self):
        """같은 RTL이면 LF로 풀린 checkout과 CRLF로 풀린 checkout의 해시가 같아야 함 (S11)."""
        with tempfile.TemporaryDirectory() as td:
            t = Path(td)
            subprocess.run(["git", "init", "-q"], cwd=t)
            (t / "HW").mkdir()
            f = t / "HW" / "a.v"
            f.write_bytes(b"module a;\nendmodule\n")
            subprocess.run(["git", "add", "-A"], cwd=t)
            lf = common.hw_hash(t)
            f.write_bytes(b"module a;\r\nendmodule\r\n")
            self.assertEqual(common.hw_hash(t), lf)
            f.write_bytes(b"module a; wire w;\nendmodule\n")
            self.assertNotEqual(common.hw_hash(t), lf)      # 내용이 바뀌면 달라야 함

    def test_outside_git(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertIsNone(common.hw_hash(Path(td)))


if __name__ == "__main__":
    unittest.main()
