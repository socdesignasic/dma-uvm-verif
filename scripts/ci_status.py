#!/usr/bin/env python3
"""
ci_status.py - Jenkins 빌드 결과를 GitHub 커밋 상태(commit status)로 올립니다.

  python scripts/ci_status.py --state success --context dma-uvm/smoke
  (Jenkinsfile의 post 단계가 부름. 토큰은 환경 변수 GH_TOKEN, Jenkins credential 'github'에서 옴)

설명 문구는 out/signoff/signoff.json의 판정에서 만들고, 링크는 Jenkins 빌드(BUILD_URL)입니다.
커밋은 GIT_COMMIT(없으면 git rev-parse HEAD), 저장소는 origin URL에서 읽습니다.
토큰이 없거나 올리기에 실패해도 빌드 결과는 바꾸지 않습니다 (종료 코드 0, 경고만 출력).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request

from common import ROOT, setup_utf8

setup_utf8()


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def describe() -> str:                                      # sign-off 판정 한 줄 (GitHub 설명은 140자까지)
    p = ROOT / "out" / "signoff" / "signoff.json"
    if not p.exists():
        return "no sign-off result"
    d = json.loads(p.read_text(encoding="utf-8"))
    bad = [c["id"] for c in d["criteria"] if c["status"] == "FAIL"]
    return (f"sign-off {d['level']} {d['verdict']}" + (f" (fail: {', '.join(bad)})" if bad else ""))[:140]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state", required=True, choices=["success", "failure", "error", "pending"])
    ap.add_argument("--context", default="dma-uvm")
    ap.add_argument("--description")
    a = ap.parse_args()
    token = os.environ.get("GH_TOKEN")
    sha = os.environ.get("GIT_COMMIT") or git("rev-parse", "HEAD")
    m = re.search(r"github\.com[:/]([^/]+/[^/.]+?)(?:\.git)?$", git("config", "--get", "remote.origin.url"))
    if not (token and sha and m):
        print("WARN: commit status not posted (missing GH_TOKEN, commit, or GitHub origin)")
        return 0
    body = {"state": a.state, "context": a.context, "description": a.description or describe()}
    if os.environ.get("BUILD_URL"):
        body["target_url"] = os.environ["BUILD_URL"]
    req = urllib.request.Request(f"https://api.github.com/repos/{m.group(1)}/statuses/{sha}",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                                          "User-Agent": "dma-uvm-ci"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            print(f"commit status {a.state} posted for {sha[:8]} ({r.status}): {body['description']}")
    except OSError as e:
        print(f"WARN: commit status not posted: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
