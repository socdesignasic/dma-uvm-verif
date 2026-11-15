#!/usr/bin/env python3
"""
PreToolUse hook: HW/ 아래 파일 수정을 모두 막습니다 (에이전트에게 DUT RTL은 읽기 전용).
stdin으로 hook JSON을 읽고, 종료 코드 2를 내면 호출이 막히고 stderr가 모델에게 보입니다.
Edit / Write / MultiEdit / NotebookEdit와, HW/에 쓰는 것이 분명한 Bash/PowerShell 명령
(리디렉션, sed -i, cp/mv/rm, Set-Content 등)을 막습니다.
"""
import json                                                 # hook 입력 JSON 파싱
import re                                                   # 명령 검사 정규식
import sys                                                  # stdin, stderr, 종료 코드
from pathlib import Path                                    # 경로 처리

ROOT = Path(__file__).resolve().parents[2]                  # 저장소 루트 (.claude/hooks/의 두 단계 위)
HW = (ROOT / "HW").resolve()                                # 보호할 HW/ 절대 경로
MSG = ("BLOCKED: HW/ (DUT RTL) is read-only in this project. Do not fix RTL. "  # 막을 때 모델에게 보여 줄 메시지
       "Record the bug in verif/BUGS.md, register the reproducer as known_fail in "  # (메시지 계속)
       "verif/sim_cfg.json, and report to the user.")       # (메시지 끝)


def under_hw(p: str) -> bool:                               # 경로가 HW/ 자체이거나 그 안인지 판정하는 함수
    try:                                                    # 잘못된 경로 처리
        q = Path(p)                                         # Path 객체로
        q = (q if q.is_absolute() else ROOT / q).resolve()  # 상대 경로면 루트 기준으로 바꾸고 정리
        return q == HW or HW in q.parents                   # HW/ 자체이거나 그 하위면 True
    except (OSError, ValueError):                           # 경로가 잘못됐으면
        return False                                        # 해당 없음


def main() -> int:                                          # hook 진입점
    try:                                                    # 입력 파싱
        ev = json.load(sys.stdin)                           # stdin에서 hook JSON 읽기
    except ValueError:                                      # JSON이 아니면
        return 0                                            # 허용
    tool = ev.get("tool_name", "")                          # 도구 이름
    ti = ev.get("tool_input", {}) or {}                     # 도구 입력
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):  # 파일 수정 도구면
        path = ti.get("file_path") or ti.get("notebook_path") or ""  # 대상 파일 경로
        if path and under_hw(path):                         # HW/ 아래면
            print(MSG, file=sys.stderr)                     # 메시지를 stderr로
            return 2                                        # 종료 코드 2 = 막음
    elif tool in ("Bash", "PowerShell"):                    # shell 도구면
        if shell_writes_hw(ti.get("command", "")):          # 명령이 HW/에 쓰면
            print(MSG + " (command appears to write into HW/)", file=sys.stderr)  # 메시지를 stderr로
            return 2                                        # 막음
    return 0                                                # 그 밖에는 허용


# HW/ 자체이거나 그 안을 가리키는 경로: 토큰 시작, ./, 따옴표, 또는 절대 경로 .../PRJ/HW/
_HW = r"""(?:^|[\s"'=(])(?:\.?[/\\])?(?:[^\s"'|;&]*[/\\]PRJ[/\\])?HW[/\\]"""  # HW/ 경로를 찾는 정규식 조각
_WRITE_PATTERNS = [                                         # HW/에 쓰는 명령 패턴 목록
    r">>?\s*['\"]?" + r"(?:\.?[/\\])?(?:[^\s\"'|;&]*[/\\]PRJ[/\\])?HW[/\\]",          # HW/로 리디렉션
    r"\bsed\s+(?:-\w+\s+)*-i\b[^|;&\n]*" + _HW,                                    # sed -i ... HW/x
    r"\b(?:cp|mv|rm|del|touch|tee|truncate|install|patch|dd)\b[^|;&\n]*" + _HW,  # 파일 복사/이동/삭제/생성 명령
    r"\bgit\s+(?:checkout|restore|apply|rm|mv)\b[^|;&\n]*" + _HW,  # git으로 HW/ 파일을 바꾸는 명령
    r"\b(?:Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|New-Item|Clear-Content)\b[^|;\n]*" + _HW,  # PowerShell 파일 쓰기/삭제 cmdlet
]                                                           # 목록 끝


def shell_writes_hw(cmd: str) -> bool:                      # 명령이 HW/에 쓰는지 판정하는 함수
    # heredoc 본문은 명령이 아니라 데이터(파일 내용)이므로 검사 전에 뺌
    cmd = re.sub(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\2[ \t]*(?=\n|$)", "<<HEREDOC", cmd, flags=re.S)  # heredoc 본문을 자리표시로 바꿈
    return any(re.search(p, cmd, re.I | re.M) for p in _WRITE_PATTERNS)  # 패턴 중 하나라도 맞으면 True


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    try:                                                    # 예외 처리
        sys.exit(main())                                    # main의 반환값을 종료 코드로
    except Exception as exc:  # 오류 시 막음: 검사기가 고장 나도 수정이 조용히 허용되면 안 됨
        print(f"protect_rtl hook error ({exc!r}); blocking to be safe", file=sys.stderr)  # 오류 메시지
        sys.exit(2)                                         # 막음
