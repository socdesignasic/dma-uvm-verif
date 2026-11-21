#!/usr/bin/env python3
"""
plan_check.py - 검증 계획 데이터(verif/plan.toml)가 코드와 서로 맞는지 검사하고, vplan.md를 생성합니다.

  python scripts/plan_check.py               # 검사 (문제가 있으면 종료 코드 1)
  python scripts/plan_check.py --write       # verif/vplan/vplan.md 다시 생성 후 검사
  python scripts/plan_check.py --json        # 결과 JSON (signoff.py, gate.py가 같은 함수를 씀)
  python scripts/plan_check.py --smoke-tests # 계획 없이 도는 smoke의 top 테스트 목록 (Jenkinsfile용)

검사 (문제 코드):
  PLAN_SCHEMA        필수 키, 중복 ID, 상태 값
  TEST_UNKNOWN       기능의 테스트가 sim_cfg.json에 없음
  TEST_UNPLANNED     sim_cfg.json에 등록된 테스트가 어떤 기능에도 없음
  CHECK_UNKNOWN      기능의 검사 ID가 check_inventory.py 목록에 없음
  COVER_UNKNOWN      기능의 커버포인트가 regress_plan.json 목표 bin에 없음
  KNOWN_FAIL         sim_cfg.json known_fail <-> plan.toml bugs <-> BUGS.md가 어긋남
  BLOCKED_NO_REASON  blocked 기능이 버그나 가설을 가리키지 않음
  HYPOTHESIS         가설 상태, confirmed인데 BUG ID 없음, 근거 파일 없음
  VPLAN_STALE        vplan.md가 plan.toml에서 생성한 내용과 다름 (직접 고쳤거나 --write를 안 함)
  RTL_APPROVAL       승인된 HW/ 해시가 없음
"""
from __future__ import annotations                          # 타입 힌트 지연 평가

import argparse                                             # 명령줄 인자
import fnmatch                                              # TB 자리의 * 처리
import json                                                 # sim_cfg.json, regress_plan.json
import re                                                   # BUGS.md 제목 찾기
import sys                                                  # 종료 코드
import tomllib                                              # plan.toml (표준 라이브러리, 읽기 전용)
from pathlib import Path                                    # 경로

from common import ROOT, setup_utf8                       # 공통 모듈

setup_utf8()                                                # UTF-8 출력

STATUS = {"planned": "⬜", "in_progress": "🚧", "done": "✅", "blocked": "❌"}  # 상태 -> 표 기호
HYP_STATUS = {"open", "confirmed", "refuted"}               # 가설 상태
BUG_STATUS = {"open", "wont_fix", "closed"}                 # 버그 상태
BANNER = ("<!-- 생성된 파일입니다. verif/plan.toml을 고친 뒤 "
          "python scripts/plan_check.py --write 로 다시 만드세요. 직접 고치지 마세요. -->")


def load(root: Path = ROOT) -> dict:                        # plan.toml 읽기
    with open(root / "verif" / "plan.toml", "rb") as f:
        return tomllib.load(f)


def smoke_tests(root: Path = ROOT) -> list[str]:            # 계획 없이 도는 smoke의 top 테스트
    return list(load(root).get("smoke", {}).get("top_tests", []))


def _cell(s: str) -> str:                                   # 표 칸 (파이프 문자 보호)
    return s.replace("|", "\\|")


def render(plan: dict) -> str:                              # vplan.md 내용 생성
    out = [BANNER, f"# {plan['title']}", "", plan["legend"], ""]  # 머리
    for sec in plan["sections"]:                            # 구역(P1 unit, P2 top)마다
        out.append(f"## {sec['heading']}")                  # 제목
        if sec["preamble"]:                                 # 설명 줄
            out += sec["preamble"] + [""]
        cols = sec["columns"]                               # 열 이름
        out += ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
        for f in plan["features"]:                          # 이 구역의 기능마다
            if f["section"] != sec["id"]:
                continue
            st = STATUS[f["status"]]                        # 상태 기호
            tail = [x for x in (f.get("bug") if f["status"] == "blocked" else None, f.get("status_note")) if x]
            if f["status"] != "blocked" and f.get("hypothesis"):
                tail.append(f"(가설 {f['hypothesis']})")
            st = " ".join([st] + tail)                      # 예: ❌ BUG-001, ⬜ 사양 밖
            cells = [f["title"]] + ([f.get("block", "")] if "블록" in cols else []) + \
                    [f["tests_text"], f["checks_text"], f["coverage_text"], st]
            out.append("|" + "|".join(f" {_cell(c)} " if c else " " for c in cells) + "|")  # 빈 칸은 "| |"
        out.append("")
    out += ["## 가설 (RTL을 읽고 세운 것, 시뮬레이션으로 확인하기 전)", "",
            "| ID | 내용 | 근거 | 확인할 테스트 | 상태 |", "|---|---|---|---|---|"]
    for h in plan.get("hypotheses", []):                    # 가설마다
        ev = ", ".join(f"`{e}`" for e in h["evidence"])
        out.append(f"| {h['id']} | {_cell(h['title'])} | {ev} | {h.get('test') or '(2단계)'} | "
                   f"{h['status']}{' → ' + h['bug'] if h.get('bug') else ''} |")
    out += ["", "## 버그와 waiver (설명은 `verif/BUGS.md`)", "",
            "| ID | 종류 | 상태 | 내용 | known_fail | waiver |", "|---|---|---|---|---|---|"]
    for b in plan.get("bugs", []):                          # 버그마다
        kf = ", ".join(f"`{t}`" for t in b.get("known_fail", [])) or "-"
        out.append(f"| {b['id']} | {b['kind']} | {b['status']} | {_cell(b['title'])} | {kf} | {b.get('waiver') or '-'} |")
    return "\n".join(out) + "\n"


def expand(test: str, cfg: dict) -> list[tuple[str, str]]:  # "tb/test" -> [(tb, test)] (* 처리)
    tb, _, name = test.partition("/")
    return [(t, name) for t, v in cfg["tbs"].items() if fnmatch.fnmatch(t, tb) and name in v.get("tests", [])]


def check(root: Path = ROOT, inventory: dict | None = None) -> dict:  # 모든 검사
    probs, warns = [], []                                   # 문제, 경고
    P = lambda code, msg: probs.append(f"{code} {msg}")     # 문제 하나 기록
    try:
        plan = load(root)
    except (OSError, tomllib.TOMLDecodeError) as e:         # 파일이 없거나 문법 오류
        return {"ok": False, "problems": [f"PLAN_SCHEMA cannot read verif/plan.toml: {e}"], "warnings": []}
    cfg = json.loads((root / "verif" / "sim_cfg.json").read_text(encoding="utf-8"))
    bugs_md = (root / "verif" / "BUGS.md").read_text(encoding="utf-8")

    # --- 형식
    feats, hyps, bugs = plan.get("features", []), plan.get("hypotheses", []), plan.get("bugs", [])
    for kind, items in (("feature", feats), ("hypothesis", hyps), ("bug", bugs)):
        ids = [x.get("id") for x in items]
        for d in sorted({i for i in ids if ids.count(i) > 1}):
            P("PLAN_SCHEMA", f"duplicate {kind} id {d}")
    secs = {s["id"] for s in plan.get("sections", [])}
    for f in feats:
        for k in ("id", "section", "title", "tests_text", "checks_text", "coverage_text", "tests", "checks", "status"):
            if k not in f:
                P("PLAN_SCHEMA", f"feature {f.get('id')} missing '{k}'")
        if f.get("status") not in STATUS:
            P("PLAN_SCHEMA", f"feature {f.get('id')} bad status {f.get('status')}")
        if f.get("section") not in secs:
            P("PLAN_SCHEMA", f"feature {f.get('id')} unknown section {f.get('section')}")
    if probs:                                               # 형식이 깨지면 나머지 검사는 의미 없음
        return {"ok": False, "problems": probs, "warnings": warns}

    # --- 테스트
    planned = set()                                         # 계획에 있는 (tb, test)
    for f in feats:
        for t in f["tests"]:
            if "/" not in t or "*" in t.split("/", 1)[1]:
                P("PLAN_SCHEMA", f"{f['id']}: test '{t}' must be '<tb>/<test>' (no * in the test name)")
                continue
            hit = expand(t, cfg)
            if not hit:
                P("TEST_UNKNOWN", f"{f['id']}: {t} is not registered in verif/sim_cfg.json")
            planned |= set(hit)
        if f["status"] in ("done", "in_progress", "blocked") and not f["tests"]:
            P("PLAN_SCHEMA", f"{f['id']}: status {f['status']} needs at least one test")
    registered = {(tb, t) for tb, v in cfg["tbs"].items() for t in v.get("tests", [])}
    for tb, t in sorted(registered - planned):
        P("TEST_UNPLANNED", f"{tb}/{t} is registered but in no feature")

    # --- 검사 ID
    if inventory is None:                                   # 검사 목록 (check_inventory.py와 같은 함수)
        from check_inventory import scan
        inventory = scan(root / "verif")
    known_checks = set(inventory["checks"])
    for f in feats:
        for c in f["checks"]:
            if c not in known_checks:
                P("CHECK_UNKNOWN", f"{f['id']}: check id {c} not found by check_inventory.py")
    used = {c for f in feats for c in f["checks"]}
    selftest = lambda c: all(s.startswith("verif/selftest/") for s in inventory.get("sites", {}).get(c, ["x"]))  # 판정 자체 시험 TB의 검사
    unused = sorted(c for c in known_checks - used
                    if not c.startswith(("NO_", "$", "RAND", "uvm_")) and not selftest(c))  # 설정 오류용 fatal, 자체 시험은 제외
    if unused:
        warns.append(f"checks not linked to any feature: {', '.join(unused)}")

    # --- 커버포인트
    rp = root / "verif" / "regress_plan.json"
    if rp.exists():
        tbins = json.loads(rp.read_text(encoding="utf-8")).get("target_bins", {})
        for f in feats:
            tbs = {tb for t in f["tests"] for tb, _ in expand(t, cfg)}
            for c in f.get("covers", []):
                if not any(k.startswith(f"obj.{c}:") for tb in tbs for k in tbins.get(tb, [])):
                    P("COVER_UNKNOWN", f"{f['id']}: coverpoint {c} has no target bin in {sorted(tbs)}")
    else:
        warns.append("verif/regress_plan.json not found; coverpoints not checked")

    # --- known_fail <-> bugs <-> BUGS.md
    bug_ids = {b["id"]: b for b in bugs}
    cfg_kf = {}                                             # (tb, test) -> BUG ID
    for tb, v in cfg["tbs"].items():
        for t, why in (v.get("known_fail") or {}).items():
            m = re.match(r"(BUG-\d+)", why)
            if not m:
                P("KNOWN_FAIL", f"{tb}/{t}: known_fail reason must start with a BUG ID")
                continue
            cfg_kf[(tb, t)] = m[1]
    plan_kf = {}
    for b in bugs:
        if b.get("status") not in BUG_STATUS:
            P("PLAN_SCHEMA", f"bug {b['id']} bad status {b.get('status')}")
        if not re.search(rf"^## {re.escape(b['id'])}\b", bugs_md, re.M):
            P("KNOWN_FAIL", f"{b['id']} has no '## {b['id']}' section in verif/BUGS.md")
        for t in b.get("known_fail", []):
            tb, _, name = t.partition("/")
            plan_kf[(tb, name)] = b["id"]
        if b.get("known_fail") and b.get("status") == "closed":
            P("KNOWN_FAIL", f"{b['id']} is closed but still has known_fail tests")
    for k in sorted(set(cfg_kf) | set(plan_kf)):
        a, b = cfg_kf.get(k), plan_kf.get(k)
        if a != b:
            P("KNOWN_FAIL", f"{k[0]}/{k[1]}: sim_cfg.json says {a}, plan.toml says {b}")
        if a and a not in bug_ids:
            P("KNOWN_FAIL", f"{k[0]}/{k[1]}: {a} is not in plan.toml bugs")

    # --- blocked, 가설
    hyp_ids = {h["id"]: h for h in hyps}
    for f in feats:
        if f["status"] == "blocked" and not (f.get("bug") in bug_ids or f.get("hypothesis") in hyp_ids):
            P("BLOCKED_NO_REASON", f"{f['id']} is blocked but points to no bug or hypothesis")
        if f.get("bug") and f["bug"] not in bug_ids:
            P("BLOCKED_NO_REASON", f"{f['id']}: bug {f['bug']} is not in plan.toml bugs")
        if f.get("hypothesis") and f["hypothesis"] not in hyp_ids:
            P("HYPOTHESIS", f"{f['id']}: hypothesis {f['hypothesis']} is not in plan.toml")
    for h in hyps:
        if h.get("status") not in HYP_STATUS:
            P("HYPOTHESIS", f"{h['id']} bad status {h.get('status')}")
        if h.get("status") == "confirmed" and h.get("bug") not in bug_ids:
            P("HYPOTHESIS", f"{h['id']} is confirmed but has no bug id in plan.toml bugs")
        for e in h.get("evidence", []):
            if not (root / e.split(":")[0]).exists():
                P("HYPOTHESIS", f"{h['id']}: evidence file missing: {e}")
        if h.get("test") and not expand(h["test"], cfg):
            warns.append(f"{h['id']}: test {h['test']} is not registered yet")

    # --- 승인된 RTL, 생성 문서
    if not plan.get("rtl", {}).get("approved_hw_hash"):
        P("RTL_APPROVAL", "plan.toml [rtl] approved_hw_hash is missing")
    vp = root / "verif" / "vplan" / "vplan.md"
    if not vp.exists() or vp.read_text(encoding="utf-8") != render(plan):
        P("VPLAN_STALE", "verif/vplan/vplan.md differs from plan.toml (run: python scripts/plan_check.py --write)")

    return {"ok": not probs, "problems": probs, "warnings": warns, "features": len(feats),
            "tests_registered": len(registered), "tests_planned": len(planned & registered),
            "hypotheses": len(hyps), "bugs": len(bugs)}


def main() -> int:                                          # 진입점
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true", help="vplan.md 다시 생성")
    ap.add_argument("--json", action="store_true", help="JSON 출력")
    ap.add_argument("--smoke-tests", action="store_true", help="smoke top 테스트 목록 (공백 구분)")
    ap.add_argument("--root", default=str(ROOT), help="저장소 루트 (다른 checkout 검사용)")
    a = ap.parse_args()
    root = Path(a.root)
    if a.smoke_tests:                                       # Jenkinsfile이 읽는 목록
        print(" ".join(smoke_tests(root)))
        return 0
    if a.write:                                             # vplan.md 생성
        vp = root / "verif" / "vplan" / "vplan.md"
        vp.write_text(render(load(root)), encoding="utf-8")
        print(f"wrote {vp.relative_to(root).as_posix()}")
    res = check(root)
    if a.json:
        print(json.dumps(res, indent=2, ensure_ascii=False))
    else:
        for p in res["problems"]:
            print(p)
        for w in res["warnings"]:
            print("WARN", w)
        print(f"plan check: {res.get('features', 0)} features, {res.get('tests_planned', 0)}/"
              f"{res.get('tests_registered', 0)} registered tests planned -> {'OK' if res['ok'] else 'FAIL'}")
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
