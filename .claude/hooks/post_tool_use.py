#!/usr/bin/env python3
"""
PostToolUse hook: 실행 전 hook이 놓친 것을 결과로 확인합니다.

1) 셸과 MCP 호출 뒤: 그 호출의 작업 트리(worktree 포함)에서 HW/가 git HEAD와 같은지 확인
   - 이번 호출 때문에 달라졌으면 HEAD로 되돌리고(추적 파일 복원, 새 파일 삭제) 모델에게 알림 (종료 코드 2)
   - 호출 전부터 달라져 있었으면(사람이 고친 경우) 건드리지 않고 알리기만 함
   "호출 전" 상태는 git 폴더 안의 claude_hw_state 파일에 남깁니다 (저장소에 커밋되지 않음).
2) verif/ 아래 SystemVerilog를 Edit/Write한 뒤: check_inventory.py로 기준선과 비교해,
   사라진 검사 ID나 늘어난 억제 구문을 모델에게 되돌려 줌 (CLAUDE.md 규칙 5)
"""
import hashlib                                              # HW/ 변경 상태 해시
import json                                                 # hook 입력
import subprocess                                           # git
import sys                                                  # 종료 코드
from pathlib import Path                                    # 경로

ROOT = Path(__file__).resolve().parents[2]                  # 이 hook이 있는 저장소 루트


def git(args: list[str], cwd: Path) -> tuple[int, str]:     # git 실행 -> (종료 코드, 출력)
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=60)
    return r.returncode, r.stdout


def hw_state(top: Path) -> str:                             # HW/가 HEAD와 다른 상태의 해시 ("clean"이면 같음)
    _, st = git(["status", "--porcelain", "--untracked-files=all", "--", "HW"], top)
    if not st.strip():
        return "clean"
    h = hashlib.sha256(st.encode("utf-8"))                  # 바뀐 파일 목록
    for line in st.splitlines():                            # 바뀐 파일 내용까지
        p = top / line[3:].strip().strip('"').split(" -> ")[-1]
        if p.is_file():
            h.update(p.read_bytes())
    return h.hexdigest()[:16]


def check_hw(cwd: Path) -> int:                             # 1) HW/ 변경 확인
    rc, top = git(["rev-parse", "--show-toplevel"], cwd)
    if rc != 0 or not top.strip():
        return 0                                            # git 작업 트리 밖
    top = Path(top.strip())
    if not (top / "HW").is_dir():
        return 0                                            # HW/가 없는 저장소
    _, gdir = git(["rev-parse", "--absolute-git-dir"], top)
    state_f = Path(gdir.strip()) / "claude_hw_state"        # 지난 확인 때의 상태
    before = state_f.read_text().strip() if state_f.exists() else "clean"
    now = hw_state(top)
    if now == "clean" or now == before:                     # 같거나, 이번 호출로 바뀐 것이 아님
        state_f.write_text(now)
        if now != "clean":                                  # 사람이 고친 상태가 남아 있음
            print("NOTE: HW/ differs from git HEAD since before this call (left untouched). "
                  "RTL is read-only for agents; sign-off S11 will fail until a human approves.", file=sys.stderr)
        return 0
    if before == "clean":                                   # 이번 호출이 깨끗한 HW/를 바꿈 -> 되돌림
        git(["checkout", "HEAD", "--", "HW"], top)
        git(["clean", "-fdq", "--", "HW"], top)
        state_f.write_text(hw_state(top))
        print("BLOCKED AFTER THE FACT: this command modified HW/ (read-only RTL). The change was reverted to "
              "git HEAD. Do not modify RTL; record the bug in verif/BUGS.md and report to the user.", file=sys.stderr)
        return 2
    state_f.write_text(now)                                 # 사람이 고친 상태 위에서 더 바뀜: 되돌리면 사람 작업이 지워짐
    print("WARNING: HW/ changed again during this call while it already had uncommitted (human) edits. "
          "Not reverting; stop and tell the user exactly what changed in HW/.", file=sys.stderr)
    return 2


def check_inventory(path: str) -> int:                      # 2) 검사 목록 비교
    p = Path(path)
    if p.suffix not in (".sv", ".svh", ".v", ".vh"):
        return 0
    wt = next((d for d in [p.parent, *p.parent.parents] if (d / ".git").exists()), None)  # 그 파일의 작업 트리
    if wt is None or "verif" not in p.relative_to(wt).parts[:1]:
        return 0
    baseline = wt / "verif" / "check_baseline.json"
    if not baseline.exists():
        return 0
    sys.path.insert(0, str(wt / "scripts"))
    from check_inventory import compare, scan               # 같은 작업 트리의 스크립트
    probs = compare(scan(wt / "verif"), json.loads(baseline.read_text(encoding="utf-8")))
    if probs:
        print("CHECK INVENTORY (CLAUDE.md rule 5): this edit removed or weakened checks compared with "
              "verif/check_baseline.json:\n  " + "\n  ".join(probs[:10]) +
              "\nRestore them, or if a check really moved under a new ID, ask the user before updating the baseline.",
              file=sys.stderr)
        return 2
    return 0


def main() -> int:
    try:
        ev = json.load(sys.stdin)
    except ValueError:
        return 0                                            # 실행은 이미 끝남: 입력이 깨지면 판단만 건너뜀
    tool, ti = ev.get("tool_name", ""), ev.get("tool_input", {}) or {}
    cwd = Path(ev.get("cwd") or ROOT)
    if tool in ("Bash", "PowerShell") or tool.startswith("mcp__"):
        return check_hw(cwd)
    if tool in ("Edit", "Write", "MultiEdit"):
        return check_inventory(ti.get("file_path", ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"post_tool_use hook error ({exc!r})", file=sys.stderr)
        sys.exit(1)                                         # 실행 후 hook 오류는 알리기만 함
