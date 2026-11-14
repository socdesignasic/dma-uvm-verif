#!/usr/bin/env python3
"""
PreToolUse hook: block any file edit under HW/ (DUT RTL is read-only for agents).
Reads the hook JSON on stdin; exit code 2 blocks the call and shows stderr to the model.
Covers Edit / Write / MultiEdit / NotebookEdit, plus Bash/PowerShell commands that
obviously write into HW/ (redirection, sed -i, cp/mv/rm, Set-Content, ...).
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


# a path token that is (or is inside) HW/: start of token, ./, a quote, or an absolute .../PRJ/HW/
_HW = r"""(?:^|[\s"'=(])(?:\.?[/\\])?(?:[^\s"'|;&]*[/\\]PRJ[/\\])?HW[/\\]"""
_WRITE_PATTERNS = [
    r">>?\s*['\"]?" + r"(?:\.?[/\\])?(?:[^\s\"'|;&]*[/\\]PRJ[/\\])?HW[/\\]",          # redirect into HW/
    r"\bsed\s+(?:-\w+\s+)*-i\b[^|;&\n]*" + _HW,                                    # sed -i ... HW/x
    r"\b(?:cp|mv|rm|del|touch|tee|truncate|install|patch|dd)\b[^|;&\n]*" + _HW,
    r"\bgit\s+(?:checkout|restore|apply|rm|mv)\b[^|;&\n]*" + _HW,
    r"\b(?:Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|New-Item|Clear-Content)\b[^|;\n]*" + _HW,
]


def shell_writes_hw(cmd: str) -> bool:
    # heredoc bodies are data (file contents), not commands: drop them before matching
    cmd = re.sub(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\2[ \t]*(?=\n|$)", "<<HEREDOC", cmd, flags=re.S)
    return any(re.search(p, cmd, re.I | re.M) for p in _WRITE_PATTERNS)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # fail closed: a broken guard must not silently allow edits
        print(f"protect_rtl hook error ({exc!r}); blocking to be safe", file=sys.stderr)
        sys.exit(2)
