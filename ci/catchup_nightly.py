#!/usr/bin/env python3
"""
catchup_nightly.py - PC가 꺼져 있어서 02:00 nightly(full)를 놓쳤으면 한 번 돌립니다.

  python ci/catchup_nightly.py --port 8090 --password-file <JENKINS_HOME>/secrets/casc/JENKINS_ADMIN_PASSWORD

start-jenkins.ps1 -CatchUpNightly가 Jenkins를 띄운 뒤 부릅니다. Jenkins가 응답할 때까지 최대 5분 기다리고,
잡 dma-uvm의 마지막 full 빌드(타이머로 시작했거나 MODE=full)가 24시간보다 오래됐으면 MODE=full로 빌드를 겁니다.
"""
import argparse
import base64
import http.cookiejar
import json
import sys
import time
import urllib.error
import urllib.request

JOB = "dma-uvm"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--password-file", required=True)
    ap.add_argument("--max-age-h", type=float, default=24)
    a = ap.parse_args()
    base = f"http://localhost:{a.port}"
    pw = open(a.password_file, encoding="utf-8").read().strip()
    auth = {"Authorization": "Basic " + base64.b64encode(f"admin:{pw}".encode()).decode()}
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))  # crumb는 세션에 묶임

    def get(path: str) -> dict:
        with opener.open(urllib.request.Request(base + path, headers=auth), timeout=10) as r:
            return json.loads(r.read().decode("utf-8"))

    for _ in range(60):                                     # Jenkins가 뜰 때까지 (최대 5분)
        try:
            get("/api/json?tree=mode")
            break
        except (urllib.error.URLError, OSError, ValueError):
            time.sleep(5)
    else:
        print("catchup: Jenkins did not come up; skipped")
        return 0
    tree = "builds[number,timestamp,result,actions[causes[_class],parameters[name,value]]]{0,40}"
    builds = get(f"/job/{JOB}/api/json?tree={tree}").get("builds", [])

    def is_full(b: dict) -> bool:                           # 타이머 시작이거나 MODE=full
        for act in b.get("actions") or []:
            if any("TimerTrigger" in c.get("_class", "") for c in act.get("causes") or []):
                return True
            if any(p.get("name") == "MODE" and p.get("value") == "full" for p in act.get("parameters") or []):
                return True
        return False

    last = max((b["timestamp"] for b in builds if is_full(b)), default=0) / 1000
    age_h = (time.time() - last) / 3600
    if age_h < a.max_age_h:
        print(f"catchup: last full build {age_h:.1f}h ago; nothing to do")
        return 0
    crumb = get("/crumbIssuer/api/json")                    # CSRF 보호
    req = urllib.request.Request(f"{base}/job/{JOB}/buildWithParameters?MODE=full", method="POST",
                                 headers={**auth, crumb["crumbRequestField"]: crumb["crumb"]})
    with opener.open(req, timeout=10) as r:
        print(f"catchup: last full build {age_h:.1f}h ago -> started MODE=full ({r.status})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:                                  # 보충 실패는 Jenkins 시작을 막지 않음
        print(f"catchup: skipped ({e})")
        sys.exit(0)
