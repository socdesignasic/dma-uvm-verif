#!/usr/bin/env python3
"""
PreToolUse hook: HW/ 아래 파일 수정을 막습니다 (에이전트에게 DUT RTL은 읽기 전용, CLAUDE.md 규칙 1).

stdin으로 hook JSON을 읽고, 종료 코드 2를 내면 호출이 막히고 stderr가 모델에게 보입니다.
  - Edit / Write / MultiEdit / NotebookEdit: 대상 경로가 어느 git 작업 트리(worktree 포함)의 HW/ 아래면 막음
  - GitHub MCP 파일 쓰기 도구 (create_or_update_file, delete_file, push_files): 경로가 HW/면 막음
  - Bash / PowerShell: HW/에 쓰는 것이 분명한 명령을 막음 (리디렉션, sed -i, cp/mv/rm, PowerShell cmdlet과 별칭,
    cmd copy/move, .NET 파일 API, 인터프리터 인라인 코드, cd HW 뒤의 쓰기, 변수에 담은 HW 경로)
  - 저장소 전체를 되돌리는 git 명령 (stash, checkout -- ., reset --hard, clean -f, apply 등): 확인(ask)
입력 JSON이 깨지거나 hook 자체에 오류가 나면 막습니다 (조용히 허용하지 않음).
이 hook이 놓친 쓰기는 PostToolUse hook(post_tool_use.py)이 HW/를 git HEAD와 비교해 잡고,
커밋된 변경은 sign-off S11(승인된 HW/ 해시)이 잡습니다.
"""
import json                                                 # hook 입력 JSON 파싱
import re                                                   # 명령 검사 정규식
import sys                                                  # stdin, stderr, 종료 코드
from pathlib import Path                                    # 경로 처리

ROOT = Path(__file__).resolve().parents[2]                  # 이 hook이 있는 저장소 루트 (.claude/hooks/의 두 단계 위)
MSG = ("BLOCKED: HW/ (DUT RTL) is read-only in this project. Do not fix RTL. "
       "Record the bug in verif/BUGS.md and verif/plan.toml, register the reproducer as known_fail in "
       "verif/sim_cfg.json, and report to the user. To read RTL use the Read or Grep tools.")


def work_tree_of(p: Path) -> Path | None:                   # p를 담고 있는 가장 가까운 git 작업 트리 루트
    """.git(폴더 또는 worktree의 .git 파일)이 있는 가장 가까운 상위 폴더. 없으면 None."""
    for d in [p, *p.parents]:
        if (d / ".git").exists():
            return d
    return None


def under_hw(path: str, cwd: str | None = None) -> bool:    # 경로가 어느 작업 트리의 HW/ 아래인지
    try:
        q = Path(path)
        base = Path(cwd) if cwd else ROOT                   # 상대 경로의 기준 (hook 입력의 cwd)
        q = (q if q.is_absolute() else base / q).resolve()
        parts = q.parts
        try:                                                # 1) 이 저장소: HW/ 또는 .claude/worktrees/<이름>/HW/
            rel = q.relative_to(ROOT).parts
            if rel[:1] == ("HW",) or (rel[:2] == (".claude", "worktrees") and rel[3:4] == ("HW",)):
                return True
        except ValueError:
            pass
        wt = work_tree_of(q.parent if not q.exists() or q.is_file() else q)  # 2) 다른 곳의 worktree (형제 폴더 등)
        if wt is not None:
            return q.relative_to(wt).parts[:1] == ("HW",)
        return False                                        # 작업 트리를 찾을 수 없으면 해당 없음
    except (OSError, ValueError):
        return False


# --------------------------------------------------------------------------- #
# 셸 명령 검사
# --------------------------------------------------------------------------- #
# HW/ 경로: 토큰 시작, ./, 따옴표, 괄호, 또는 절대 경로 .../HW/
_HW = r"""(?:^|[\s"'=(,])(?:\.?[/\\])?(?:[^\s"'|;&,()]*[/\\])?HW[/\\]"""
_HW_ANY = r"""(?:^|[\s"'=(,:])(?:\.?[/\\])?(?:[^\s"'|;&,()]*[/\\])?HW(?:[/\\]|["'\s;&|)]|$)"""  # HW 폴더 자체 포함
_VERBS = (r"cp|mv|rm|rmdir|del|erase|touch|tee|truncate|install|patch|dd|ln|chmod|copy|move|ren|rename|xcopy|robocopy|"
          r"Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|New-Item|Clear-Content|Rename-Item|"
          r"sc|ac|ni|ri|mi|cpi|rni|clc")
_WRITE_PATTERNS = [                                         # HW/에 쓰는 명령 패턴
    r">>?\s*['\"]?" + r"(?:\.?[/\\])?(?:[^\s\"'|;&]*[/\\])?HW[/\\]",                 # HW/로 리디렉션
    r"\bsed\s+(?:-\w+\s+)*-i\w*\b[^|;&\n]*" + _HW,                                  # sed -i ... HW/x
    r"(?:^|[\s;&|(])(?:" + _VERBS + r")(?:\.exe)?\b[^|;&\n]*" + _HW,                # 파일 명령, PowerShell cmdlet/별칭, cmd
    r"\bgit\s+(?:checkout|restore|apply|rm|mv)\b[^|;&\n]*" + _HW,                    # git으로 HW/ 파일을 바꿈
    r"\[(?:System\.)?IO\.(?:File|Directory)\]::\w+[^|;\n]*" + _HW,                  # .NET 파일 API
    r"\b(?:python3?|py|perl|ruby|node|pwsh|powershell)(?:\.exe)?\b[^|;&\n]*"         # 인터프리터 인라인 코드가 HW 경로를 언급
    r"\s(?:-c|-e|-pi|-p|-i|-Command|-EncodedCommand)\b[^\n]*" + _HW_ANY,
]
_CD_HW = r"(?:^|[;&|(]\s*|\s)(?:cd|pushd|Set-Location|sl|chdir)\s+['\"]?(?:[^\s'\";&|]*[/\\])?HW(?:[/\\][^\s'\";&|]*)?['\"]?(?=\s|;|&|\||$)"
_WRITEISH = (r"(?:>|\bsed\s+(?:-\w+\s+)*-i|(?:^|[\s;&|(])(?:" + _VERBS +
             r"|python3?|py|perl|ruby|node|git)(?:\.exe)?\b|\[(?:System\.)?IO\.)")
_VAR_HW = r"(?:^|[\s;&(])\$?\w+\s*=\s*['\"]?(?:\.?[/\\])?(?:[^\s'\";&|]*[/\\])?HW[/\\]"  # F=HW/x.v, $f = 'HW\x.v'
# 저장소 전체를 되돌리거나 덮어써서 HW/도 바꿀 수 있는 git 명령 -> 확인
_GIT_WIDE = (r"\bgit\s+(?:-C\s+\S+\s+)?(?:stash(?!\s+(?:list|show)\b)|reset\s+[^|;&\n]*--hard|clean\s+[^|;&\n]*-\w*f|"
             r"apply\b|am\b|cherry-pick\b|revert\b|rebase\b|merge\b|pull\b|"
             r"checkout\s+[^|;&\n]*(?:--\s+\.|\s\.(?:\s|$))|restore\s+(?![^|;&\n]*--staged)[^|;&\n]*(?:\s\.(?:\s|$)|--source))")


def _strip_heredocs(cmd: str) -> str:                       # heredoc 본문은 명령이 아니라 데이터
    return re.sub(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\2[ \t]*(?=\n|$)", "<<HEREDOC", cmd, flags=re.S)


def shell_writes_hw(cmd: str) -> bool:                      # 명령이 HW/에 쓰는지
    c = _strip_heredocs(cmd)
    if any(re.search(p, c, re.I | re.M) for p in _WRITE_PATTERNS):
        return True
    if re.search(_CD_HW, c, re.I | re.M) and re.search(_WRITEISH, c, re.I | re.M):  # cd HW 뒤 쓰기
        return True
    if re.search(_VAR_HW, c, re.I | re.M) and re.search(_WRITEISH, c, re.I | re.M) and re.search(r"\$\{?\w+", c):
        return True                                         # 변수에 HW 경로를 담고 쓰기
    return False


def shell_repo_wide_git(cmd: str) -> bool:                  # 저장소 전체를 되돌리는 git 명령인지
    return bool(re.search(_GIT_WIDE, _strip_heredocs(cmd), re.I | re.M))


def _ask(reason: str) -> int:                               # 사용자에게 확인을 받게 함 (막지는 않음)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                             "permissionDecisionReason": reason}}))
    return 0


def main() -> int:                                          # hook 진입점
    try:
        ev = json.load(sys.stdin)                           # stdin에서 hook JSON 읽기
    except ValueError:                                      # 입력이 깨지면 판단할 수 없으므로 막음
        print("BLOCKED: protect_rtl hook received invalid JSON input; refusing to guess.", file=sys.stderr)
        return 2
    tool = ev.get("tool_name", "")                          # 도구 이름
    ti = ev.get("tool_input", {}) or {}                     # 도구 입력
    cwd = ev.get("cwd")                                     # 호출한 세션의 작업 폴더 (worktree일 수 있음)
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = ti.get("file_path") or ti.get("notebook_path") or ""
        if path and under_hw(path, cwd):
            print(MSG, file=sys.stderr)
            return 2
    elif tool.startswith("mcp__github__"):                  # GitHub MCP: 원격 저장소의 HW/ 수정
        paths = [ti.get("path", "")] + [f.get("path", "") for f in ti.get("files", []) or [] if isinstance(f, dict)]
        if any(re.match(r"^\.?/?HW/", p or "") for p in paths):
            print(MSG + " (GitHub MCP write to HW/)", file=sys.stderr)
            return 2
    elif tool in ("Bash", "PowerShell"):
        cmd = ti.get("command", "")
        if shell_writes_hw(cmd):
            print(MSG + " (command appears to write into HW/)", file=sys.stderr)
            return 2
        if shell_repo_wide_git(cmd):
            return _ask("This git command can rewrite the whole working tree, including the read-only HW/. "
                        "Confirm it is intended.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # 검사기가 고장 나도 수정이 조용히 허용되면 안 됨
        print(f"protect_rtl hook error ({exc!r}); blocking to be safe", file=sys.stderr)
        sys.exit(2)
