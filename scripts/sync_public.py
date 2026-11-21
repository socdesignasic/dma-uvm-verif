#!/usr/bin/env python3
"""
sync_public.py - 비공개 저장소의 커밋된 내용을 공개 저장소(dma-uvm-verif) checkout으로 옮길 내용을 만듭니다.

  python scripts/sync_public.py --public-dir <공개 저장소 clone>           # 미리 보기: 바뀔 파일과 검사 결과
  python scripts/sync_public.py --public-dir <공개 저장소 clone> --apply   # 공개 checkout에 파일을 씀

규칙 (2026-11-19에 공개 저장소와 대조해 확인: 공통 파일 125개 중 124개가 이 규칙으로 글자 그대로 같음):
  - 옮기는 것: HEAD에 커밋된 파일 (작업 중인 변경은 옮기지 않음)
  - 빼는 것: HW/, SW/, uvm_reference/, ci/vivado/ip/ (공개하지 않는 RTL과 받은 자료)
  - 내용과 경로에서 원본 IP 이름 접두어(PREFIX + "_")를 지움. 그 뒤 PREFIX가 남으면 실패
  - 공개 저장소 전용 파일은 건드리지 않음: README.md, .gitattributes, docs/index.html, docs/.nojekyll
  - .gitignore는 공개 저장소 전용 줄을 뒤에 붙임
  - 저장소 규칙의 금지어(.githooks/check_commit.py)와 개인 경로(C:/Users/<USER>가 아닌 사용자 폴더)가 남으면 실패
커밋과 push는 하지 않습니다. sync-public 스킬이 diff를 사용자에게 보여 주고 확인을 받은 뒤 GitHub noreply
작성자로 커밋합니다.
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

from common import ROOT, setup_utf8

setup_utf8()

EXCLUDE = ("HW/", "SW/", "uvm_reference/", "ci/vivado/ip/")
PUBLIC_ONLY = {"README.md", ".gitattributes", "docs/index.html", "docs/.nojekyll"}
GITIGNORE_TAIL = ("\n# ---- DUT RTL (not distributed in this repository) ----\nHW/\n"
                  "# not distributed here (see README)\nSW/\nuvm_reference/\nci/vivado/ip/\n")


def forbidden_re():                                         # .githooks/check_commit.py의 금지어 (한 곳에서만 정의)
    spec = importlib.util.spec_from_file_location("check_commit", ROOT / ".githooks" / "check_commit.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.FORBIDDEN


PREFIX = "mat" + "bi"                                       # 원본 IP 이름 접두어 (이 파일이 자기 검사에 걸리지 않게 나눠 씀)


def transform(path: str, data: bytes) -> tuple[str, bytes]:  # 경로와 내용 변환
    out = path.replace(PREFIX + "_", "")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:                              # 바이너리는 그대로
        return out, data
    text = text.replace(PREFIX + "_", "")
    if path == ".gitignore":
        text += GITIGNORE_TAIL
    return out, text.encode("utf-8")


def problems(path: str, data: bytes, forb) -> list[str]:    # 공개해도 되는지 검사
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return []
    probs = []
    if re.search(PREFIX, path + "\n" + text, re.I):
        probs.append(f"{path}: IP name prefix remains")
    m = forb.search(text)
    if m and not path.startswith(".githooks/"):             # 금지어 정규식이 있는 파일 자신은 이스케이프로 적혀 있음
        probs.append(f"{path}: forbidden word")
    if re.search(r"[A-Za-z]:[/\\]Users[/\\](?!<USER>)[^/\\\s]+", text):
        probs.append(f"{path}: personal path (not C:/Users/<USER>)")
    return probs


def private_files() -> dict[str, bytes]:                    # HEAD에 커밋된 파일 -> 내용
    names = subprocess.run(["git", "ls-tree", "-r", "--name-only", "-z", "HEAD"], cwd=ROOT,
                           capture_output=True).stdout.decode("utf-8").split("\0")
    out = {}
    for n in names:
        if n and not n.startswith(EXCLUDE):
            out[n] = subprocess.run(["git", "show", f"HEAD:{n}"], cwd=ROOT, capture_output=True).stdout
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--public-dir", required=True, help="공개 저장소 clone 경로")
    ap.add_argument("--apply", action="store_true", help="공개 checkout에 파일을 씀 (커밋하지 않음)")
    a = ap.parse_args()
    pub = Path(a.public_dir)
    if not (pub / ".git").exists():
        sys.exit(f"ERROR: {pub} is not a git checkout")
    forb = forbidden_re()
    want, probs = {}, []                                    # 공개 경로 -> 내용, 문제
    for path, data in private_files().items():
        out, new = transform(path, data)
        if out in PUBLIC_ONLY:
            continue
        probs += problems(out, new, forb)
        want[out] = new
    have = set(subprocess.run(["git", "ls-files", "-z"], cwd=pub, capture_output=True).stdout.decode("utf-8").split("\0")) - {""}
    added = sorted(p for p in want if p not in have)
    blob = lambda p: subprocess.run(["git", "show", f"HEAD:{p}"], cwd=pub, capture_output=True).stdout  # 공개 저장소의 커밋 내용
    changed = sorted(p for p in want if p in have and blob(p) != want[p])  # (작업 트리는 CRLF일 수 있어 커밋 내용과 비교)
    removed = sorted(p for p in have - set(want) - PUBLIC_ONLY)
    for tag, lst in (("A", added), ("M", changed), ("D", removed)):
        for p in lst:
            print(f"{tag} {p}")
    for p in probs:
        print("PROBLEM", p)
    print(f"sync-public: {len(added)} added, {len(changed)} changed, {len(removed)} removed, "
          f"{len(probs)} problems{' (not applied)' if probs or not a.apply else ''}")
    if probs:
        return 1
    if a.apply:
        for p in added + changed:
            (pub / p).parent.mkdir(parents=True, exist_ok=True)
            (pub / p).write_bytes(want[p])
        for p in removed:
            (pub / p).unlink()
        print(f"applied to {pub} (review with git -C {pub} diff, then commit with the noreply author)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
