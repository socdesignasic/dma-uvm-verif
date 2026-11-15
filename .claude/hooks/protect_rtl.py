#!/usr/bin/env python3
"""
PreToolUse hook: HW/ 아래 파일 수정을 모두 막습니다 (에이전트에게 DUT RTL은 읽기 전용).
stdin으로 hook JSON을 읽고, 종료 코드 2를 내면 호출이 막히고 stderr가 모델에게 보입니다.
Edit / Write / MultiEdit / NotebookEdit와, HW/에 쓰는 것이 분명한 Bash/PowerShell 명령
(리디렉션, sed -i, cp/mv/rm, Set-Content 등)을 막습니다.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HW = (ROOT / "HW").resolve()
MSG = ("BLOCKED: HW/ (DUT RTL) is read-only in this project. Do not fix RTL. "
       "Record the bug in verif/BUGS.md, register the reproducer as known_fail in "
       "verif/sim_cfg.json, and report to the user.")


def under_hw(p: str) -> bool:
    try:
        q = Path(p)
        q = (q if q.is_absolute() else ROOT / q).resolve()
        return q == HW or HW in q.parents
    except (OSError, ValueError):
        return False


def main() -> int:
    try:
        ev = json.load(sys.stdin)
    except ValueError:
        return 0
    tool = ev.get("tool_name", "")
    ti = ev.get("tool_input", {}) or {}
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = ti.get("file_path") or ti.get("notebook_path") or ""
        if path and under_hw(path):
            print(MSG, file=sys.stderr)
            return 2
    elif tool in ("Bash", "PowerShell"):
        if shell_writes_hw(ti.get("command", "")):
            print(MSG + " (command appears to write into HW/)", file=sys.stderr)
            return 2
    return 0


# HW/ 자체이거나 그 안을 가리키는 경로: 토큰 시작, ./, 따옴표, 또는 절대 경로 .../PRJ/HW/
_HW = r"""(?:^|[\s"'=(])(?:\.?[/\\])?(?:[^\s"'|;&]*[/\\]PRJ[/\\])?HW[/\\]"""
_WRITE_PATTERNS = [
    r">>?\s*['\"]?" + r"(?:\.?[/\\])?(?:[^\s\"'|;&]*[/\\]PRJ[/\\])?HW[/\\]",          # HW/로 리디렉션
    r"\bsed\s+(?:-\w+\s+)*-i\b[^|;&\n]*" + _HW,                                    # sed -i ... HW/x
    r"\b(?:cp|mv|rm|del|touch|tee|truncate|install|patch|dd)\b[^|;&\n]*" + _HW,
    r"\bgit\s+(?:checkout|restore|apply|rm|mv)\b[^|;&\n]*" + _HW,
    r"\b(?:Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|New-Item|Clear-Content)\b[^|;\n]*" + _HW,
]


def shell_writes_hw(cmd: str) -> bool:
    # heredoc 본문은 명령이 아니라 데이터(파일 내용)이므로 검사 전에 뺌
    cmd = re.sub(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\2[ \t]*(?=\n|$)", "<<HEREDOC", cmd, flags=re.S)
    return any(re.search(p, cmd, re.I | re.M) for p in _WRITE_PATTERNS)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # 오류 시 막음: 검사기가 고장 나도 수정이 조용히 허용되면 안 됨
        print(f"protect_rtl hook error ({exc!r}); blocking to be safe", file=sys.stderr)
        sys.exit(2)
