#!/usr/bin/env python3
"""
PreToolUse hook: CLAUDE.md의 다른 규칙을 지킵니다.

  - 규칙 2: xvlog / xelab / xsim / xcrg를 직접 부르면 막고 scripts/sim.py를 안내
  - known_fail 등록: verif/sim_cfg.json에 넣는 BUG ID가 verif/BUGS.md에 없으면 막고,
    있으면 "등록한 뒤 멈추고 사용자에게 보고" 안내를 붙임 (규칙 1, 사람 확인 지점)
  - verif/vplan/vplan.md를 직접 고치면 경고 (verif/plan.toml이 원본, plan_check.py --write로 생성)
입력이 깨지거나 오류가 나면 막습니다.
"""
import json                                                 # hook 입력
import re                                                   # 패턴
import sys                                                  # 종료 코드
from pathlib import Path                                    # 경로

ROOT = Path(__file__).resolve().parents[2]                  # 저장소 루트
# 명령 위치(줄 처음, ; && || | ( 뒤, cmd /c, PowerShell &)의 Vivado 시뮬레이터 도구
_TOOLS = (r"(?:^|[;&|(]\s*|\bcmd(?:\.exe)?\s+/[ck]\s+|&\s*)['\"]?(?:[^\s'\";&|]*[/\\])?"
          r"(xvlog|xelab|xsim|xcrg)(?:\.bat|\.exe)?['\"]?(?=\s|;|&|\||$)")
_HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")  # heredoc 시작 (<<EOF, <<'EOF', <<-EOF)
_SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "cmd", "powershell", "pwsh"}  # 본문을 명령으로 실행하는 프로그램


def _strip_heredocs(cmd: str) -> str:
    """셸이 아닌 프로그램(python, cat 등)에 넘기는 heredoc 본문을 뺌. 그 본문은 실행되는 명령이 아니라 데이터라서,
    안에 적힌 메모 글자(예: "(XSim 크래시")를 시뮬레이터 호출로 오인하지 않게 함. 셸에 넘기는 본문은 그대로 검사."""
    lines, out, i = cmd.split("\n"), [], 0
    while i < len(lines):
        out.append(lines[i])
        m = _HEREDOC.search(lines[i])
        i += 1
        if not m:
            continue
        words = re.split(r"[;&|(]", lines[i - 1][:m.start()])[-1].split()  # heredoc을 받는 명령 구간
        names = {w.strip("'\"").replace("\\", "/").rsplit("/", 1)[-1].lower().removesuffix(".exe") for w in words}
        if names & _SHELLS:                                 # 셸이 본문을 실행함 → 검사 대상
            continue
        while i < len(lines) and lines[i].strip() != m.group(2):
            i += 1                                          # 본문을 건너뜀 (종료 줄은 다음 반복에서 다시 봄)
    return "\n".join(out)


def _ask(reason: str) -> int:                               # 사용자에게 확인을 받게 함
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
    return 0


def _context(text: str) -> int:                             # 허용하되 모델에게 안내를 붙임
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                             "additionalContext": text}}, ensure_ascii=False))
    return 0


def main() -> int:
    try:
        ev = json.load(sys.stdin)
    except ValueError:
        print("BLOCKED: guard_rules hook received invalid JSON input.", file=sys.stderr)
        return 2
    tool, ti = ev.get("tool_name", ""), ev.get("tool_input", {}) or {}
    if tool in ("Bash", "PowerShell"):
        if re.search(r"check_inventory\.py\b[^\n]*--save", ti.get("command", "")):  # 검사 기준선 갱신
            return _ask("Updating verif/check_baseline.json changes what counts as a removed check (rule 5). "
                        "Confirm a human reviewed why checks changed.")
        m = re.search(_TOOLS, _strip_heredocs(ti.get("command", "")), re.I | re.M)
        if m:
            print(f"BLOCKED: do not call {m.group(1)} directly (CLAUDE.md rule 2). Use scripts/sim.py "
                  "(lint/run/cov-report) or scripts/regress.py, or the vivado MCP tools, so local = CI.",
                  file=sys.stderr)
            return 2
        return 0
    if tool not in ("Edit", "Write", "MultiEdit"):
        return 0
    path = (ti.get("file_path") or "").replace("\\", "/")
    if path.endswith("verif/check_baseline.json"):          # 검사 기준선을 손으로 고침
        return _ask("verif/check_baseline.json is the rule-5 baseline. Confirm a human reviewed this change.")
    if path.endswith("verif/sim_cfg.json"):                 # known_fail 등록
        new = ti.get("new_string", "") + ti.get("content", "") + "".join(
            e.get("new_string", "") for e in ti.get("edits", []) or [])
        ids = sorted(set(re.findall(r"\bBUG-\d+\b", new)))
        if ids:
            bugs_md = (ROOT / "verif" / "BUGS.md").read_text(encoding="utf-8")
            missing = [i for i in ids if not re.search(rf"^## {i}\b", bugs_md, re.M)]
            if missing:
                print(f"BLOCKED: {', '.join(missing)} has no '## {missing[0]}' section in verif/BUGS.md. "
                      "Write the bug first (symptom, cause, reproduction, suggested fix), add it to "
                      "verif/plan.toml bugs, then register known_fail.", file=sys.stderr)
                return 2
            return _context("known_fail touches " + ", ".join(ids) + ". If this registers a new RTL bug, stop "
                            "after registering and report to the user (CLAUDE.md rule 1, human checkpoint). "
                            "Keep verif/plan.toml bugs.known_fail in sync and run python scripts/plan_check.py.")
    if path.endswith("verif/vplan/vplan.md"):               # 생성 파일 직접 수정
        return _context("verif/vplan/vplan.md is generated. Edit verif/plan.toml instead and run "
                        "python scripts/plan_check.py --write; a hand edit makes plan_check report VPLAN_STALE.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"guard_rules hook error ({exc!r}); blocking to be safe", file=sys.stderr)
        sys.exit(2)
