#!/usr/bin/env python3
"""
저장소에 둔 git hook의 검사 (commit-msg, pre-commit이 부름). 켜기: git config core.hooksPath .githooks

  python .githooks/check_commit.py msg <메시지 파일>   # 커밋 메시지: Claude 트레일러, 금지어
  python .githooks/check_commit.py staged              # 스테이징된 추가 줄: 금지어

프로젝트 규칙: 커밋에 Co-Authored-By/Claude-Session 같은 Claude 트레일러를 붙이지 않고,
저장소 어디에도 정해진 금지어(RTL 출처 관련 단어 4개)를 쓰지 않습니다. 금지어 자체도 저장소에
글자 그대로 남지 않도록 아래 정규식은 유니코드 이스케이프와 쪼갠 문자열로 적습니다. 거부하면 종료 코드 1.
"""
import re
import subprocess
import sys

TRAILER = re.compile(r"^(co-authored-by:.*(claude|anthropic)|claude-session:)|generated with \[?claude", re.I | re.M)
FORBIDDEN = re.compile("\\uac15\\uc758|\\uad50\\uc721\\uc6a9|" + r"\bcou" + r"rse\b|\blec" + r"tures?\b", re.I)


def check_msg(path: str) -> int:
    with open(path, encoding="utf-8", errors="replace") as f:
        msg = "".join(l for l in f if not l.startswith("#"))  # git 주석 줄 제외
    if TRAILER.search(msg):
        print("commit-msg: remove the Claude attribution trailer (project rule: no Co-Authored-By/Claude-Session).",
              file=sys.stderr)
        return 1
    m = FORBIDDEN.search(msg)
    if m:
        print(f"commit-msg: forbidden word '{m.group(0)}' in the message (project rule).", file=sys.stderr)
        return 1
    return 0


def check_staged() -> int:
    diff = subprocess.run(["git", "diff", "--cached", "-U0", "--no-color"], capture_output=True, text=True,
                          encoding="utf-8", errors="replace").stdout
    bad, cur = [], None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            cur = line[6:]
        elif line.startswith("+") and FORBIDDEN.search(line):
            bad.append(f"{cur}: {line[1:80]}")
    if bad:
        print("pre-commit: forbidden word in added lines (project rule):\n  " + "\n  ".join(bad[:10]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "msg":
        sys.exit(check_msg(sys.argv[2]))
    if len(sys.argv) >= 2 and sys.argv[1] == "staged":
        sys.exit(check_staged())
    print(__doc__)
    sys.exit(2)
