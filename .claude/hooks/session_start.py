#!/usr/bin/env python3
"""
SessionStart hook: 세션을 시작할 때 지금 상태를 짧게 보여 줍니다.
브랜치, HW/가 git HEAD와 같은지, 로컬 Jenkins(8090)가 떠 있는지, 진행 중인 ledger의 마지막 기록.
"""
import json                                                 # ledger, 출력
import subprocess                                           # git
import sys                                                  # 출력
import urllib.request                                       # Jenkins 상태
from pathlib import Path                                    # 경로

ROOT = Path(__file__).resolve().parents[2]                  # 저장소 루트


def git(*args: str) -> str:
    r = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return r.stdout.strip()


def jenkins() -> str:
    try:
        urllib.request.urlopen("http://localhost:8090/login", timeout=1.5)
        return "up (http://localhost:8090)"
    except OSError:
        return "DOWN (start: powershell -ExecutionPolicy Bypass -File ci\\start-jenkins.ps1)"


def main() -> int:
    hw = git("status", "--porcelain", "--", "HW")
    lines = [f"branch: {git('rev-parse', '--abbrev-ref', 'HEAD')} @ {git('rev-parse', '--short', 'HEAD')}",
             "HW/: " + ("matches HEAD" if not hw else f"DIFFERS from HEAD ({len(hw.splitlines())} files) - "
                                                          "RTL is read-only for agents"),
             f"jenkins: {jenkins()}"]
    ledgers = sorted((ROOT / "out" / "loop").glob("*/ledger.json"), key=lambda p: p.stat().st_mtime)
    if ledgers:
        try:
            last = json.loads(ledgers[-1].read_text(encoding="utf-8"))["entries"][-1]
            lines.append(f"ledger {ledgers[-1].parent.name}: last {last.get('kind')} {last.get('stage', '')} "
                         f"{last.get('verdict', '')} at {last.get('time', '')}")
        except (ValueError, KeyError, IndexError):
            pass
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                             "additionalContext": "dma-uvm status:\n" + "\n".join(lines)}}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)                                         # 상태 표시는 실패해도 세션을 막지 않음
