#!/usr/bin/env python3
"""
selftest.py - 실제 stdio MCP로 vivado-mcp에 접속해 모든 도구를 실행해 봅니다.

  mcp/.venv/Scripts/python.exe mcp/vivado_mcp/selftest.py          # 기본: 모든 도구, BUG-001 신호 추적
  mcp/.venv/Scripts/python.exe mcp/vivado_mcp/selftest.py --full   # + top 실행, 서버 재시작 뒤 작업 확인,
                                                                   #   작업 취소, worktree 두 곳 동시 빌드와 잠금
모든 확인을 통과하면 종료 코드 0.
"""
from __future__ import annotations

import asyncio
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from mcp import Client
from mcp.client.stdio import StdioServerParameters

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FULL = "--full" in sys.argv
fails = 0


def check(name: str, cond: bool, detail: object = "") -> None:
    global fails
    print(f"[{'OK ' if cond else 'BAD'}] {name}" + (f"  {str(detail)[:600]}" if detail and not cond else ""), flush=True)
    fails += 0 if cond else 1


def data(res) -> object:
    """structured content가 있으면 그것을, 없으면 text content를 JSON으로 파싱해 반환"""
    if getattr(res, "structured_content", None) is not None:
        sc = res.structured_content
        return sc.get("result", sc) if isinstance(sc, dict) and set(sc) == {"result"} else sc
    txt = "".join(getattr(c, "text", "") for c in res.content)
    try:
        return json.loads(txt)
    except ValueError:
        return txt


def client() -> Client:
    return Client(StdioServerParameters(command=sys.executable, args=[str(HERE / "server.py")]),
                  read_timeout_seconds=3600)


async def call(c: Client, tool: str, **args) -> object:
    return data(await c.call_tool(tool, args))


async def basic() -> None:
    async with client() as c:
        tools = {t.name for t in (await c.list_tools()).tools}
        want = {"list_testbenches", "lint", "run_test", "get_log_excerpt", "trace_signals", "start_regression",
                "regression_status", "cancel_job", "coverage_report", "check_inventory", "run_gate", "signoff",
                "compare_regressions", "ledger_append", "ledger_read", "list_known_bugs"}
        check("tools registered", want <= tools, sorted(want - tools))
        tbs = await call(c, "list_testbenches")
        check("list_testbenches has top+skid", isinstance(tbs, dict) and {"top", "skid"} <= set(tbs), tbs)
        r = await call(c, "lint", tb="skid")
        check("lint skid ok", isinstance(r, dict) and r.get("ok") is True, r)
        r = await call(c, "run_test", tb="skid", test="unit_smoke_test", seed="7")
        check("run_test skid smoke PASS (with provenance)", isinstance(r, dict) and r.get("verdict") == "PASS"
              and bool((r.get("provenance") or {}).get("hw_hash")), r)
        r = await call(c, "run_test", tb="skid", test="unit_post_reset_test", seed="7", rebuild=False)
        check("run_test BUG-001 reproducer XFAIL", isinstance(r, dict) and r.get("verdict") == "XFAIL", r)
        x = await call(c, "get_log_excerpt", tb="skid", test="unit_post_reset_test", seed="7", max_lines=20)
        check("get_log_excerpt shows scoreboard error", isinstance(x, dict) and "SB_" in x.get("excerpt", ""), x)
        for name, args in (("unknown tb", {"tool": "run_test", "tb": "skid; del *", "test": "x"}),
                           ("unsafe plusarg", {"tool": "run_test", "tb": "skid", "test": "unit_smoke_test",
                                               "plusargs": ["A=1 & calc"]}),
                           ("foreign workspace", {"tool": "lint", "tb": "skid", "workspace": str(Path.home())}),
                           ("bad HDL object", {"tool": "trace_signals", "tb": "skid", "objects": ["/a]; exec x"]})):
            tool = args.pop("tool")
            bad = await c.call_tool(tool, args)
            check(f"rejects {name}", bool(getattr(bad, "is_error", False)), bad)
        t = await call(c, "trace_signals", tb="skid", test="unit_post_reset_test", seed="1",
                       objects=["/tb_skid/dut/*"], t_from_ns=100, t_to_ns=126,
                       signals=["s_valid", "s_ready", "s_data", "m_valid", "m_data"])
        txt = t.get("text", "") if isinstance(t, dict) else ""
        check("trace_signals shows BUG-001 (s_valid=1 & s_ready=0 before 105ns, captured at 105ns)",
              "s_ready=0" in txt.splitlines()[0] and "s_valid=1" in txt.splitlines()[0]
              and any(l.strip().startswith("105.000ns") and "m_valid=1" in l for l in txt.splitlines()), t)
        print("      " + txt.replace("\n", "\n      "))
        bugs = await call(c, "list_known_bugs")
        check("list_known_bugs: BUG-001/002 and hypotheses H1-H6",
              isinstance(bugs, dict) and {"BUG-001", "BUG-002"} <= set(bugs.get("bugs", {}))
              and len(bugs.get("hypotheses", {})) >= 6, bugs)
        cov = await call(c, "coverage_report", tb="skid")
        check("coverage_report returns covergroups and uncovered list",
              isinstance(cov, dict) and cov.get("covergroups") and "uncovered_bins" in cov, cov)
        inv = await call(c, "check_inventory")
        check("check_inventory ok", isinstance(inv, dict) and inv.get("ok") is True, inv)
        led = await call(c, "ledger_append", loop_id="selftest", kind="note", summary="selftest entry",
                         data={"rerun": "python mcp/vivado_mcp/selftest.py"})
        rd = await call(c, "ledger_read", loop_id="selftest", last=1)
        check("ledger append/read round trip", isinstance(rd, dict) and rd.get("entries")
              and rd["entries"][-1]["summary"] == "selftest entry", (led, rd))
        if (ROOT / "out" / "regress" / "unit" / "summary.json").exists():
            cmpr = await call(c, "compare_regressions", a="unit", b="unit")
            check("compare_regressions(unit, unit) is same", isinstance(cmpr, dict) and cmpr.get("same") is True, cmpr)
        g = await call(c, "run_gate", stage="static")
        check("run_gate static PASS", isinstance(g, dict) and g.get("verdict") == "PASS", g)


async def full() -> None:
    async with client() as c:
        r = await call(c, "run_test", tb="top", test="dma_smoke_test", seed="3")
        check("run_test top smoke PASS", isinstance(r, dict) and r.get("verdict") == "PASS", r)
        st = await call(c, "start_regression", suite=None, tbs=["skid"], tests=["unit_smoke_test"], seeds=2)
        rid = st["id"]
        for _ in range(240):                                # 회귀는 서버가 살아 있는 동안 돎 (server.py _spawn_detached 참고)
            s = await call(c, "regression_status", id=rid)
            if s.get("state") != "running":
                break
            await asyncio.sleep(5)
        check("background regression done, 2 runs, 0 fail", s.get("state") == "done" and s.get("runs") == 2
              and s.get("fail") == 0, s)
    async with client() as c:                               # 새 서버 프로세스: 작업 상태가 파일에 남았는지
        s = await call(c, "regression_status", id=rid)
        check("regression status survives a server restart (read from out/mcp/jobs)",
              s.get("state") == "done" and s.get("runs") == 2 and s.get("fail") == 0, s)
        check("regression released the skid lock", not (ROOT / "out/mcp/locks/skid.lock").exists())
        st = await call(c, "start_regression", suite=None, tbs=["skid"], seeds=20)
        await asyncio.sleep(20)
        cj = await call(c, "cancel_job", id=st["id"])
        s = await call(c, "regression_status", id=st["id"])
        check("cancel_job stops the regression and frees the lock",
              cj.get("state") == "cancelled" and s.get("state") == "cancelled"
              and not (ROOT / "out/mcp/locks/skid.lock").exists(), (cj, s))
    with tempfile.TemporaryDirectory(prefix="mcp_wt_") as td:  # worktree 두 곳
        wts = [Path(td) / "wtA", Path(td) / "wtB"]
        for w in wts:
            subprocess.run(["git", "worktree", "add", "--detach", "-q", str(w), "HEAD"], cwd=ROOT, check=True)
        try:
            async def lint_in(w: Path) -> tuple[float, object]:
                async with client() as c:
                    t0 = time.time()
                    r = await call(c, "lint", tb="skid", workspace=str(w))
                    return time.time() - t0, r
            t0 = time.time()
            res = await asyncio.gather(lint_in(wts[0]), lint_in(wts[1]), lint_in(wts[0]))  # 둘은 같은 worktree
            wall = time.time() - t0
            check("concurrent lint in two worktrees (+ same worktree twice) all ok",
                  all(isinstance(r, dict) and r.get("ok") for _, r in res), res)
            check("each worktree has its own build",
                  all((w / "out/skid/build/build.json").exists() for w in wts)
                  and not any((w / "out/mcp/locks/skid.lock").exists() for w in wts))
            durs = sorted(d for d, _ in res)
            print(f"      lint durations {[round(d) for d in durs]}s, wall {wall:.0f}s "
                  f"(the two calls in the same worktree are serialized by the lock)")
        finally:
            for w in wts:
                subprocess.run(["git", "worktree", "remove", "--force", str(w)], cwd=ROOT)


async def main() -> int:
    await basic()
    if FULL:
        await full()
    print(f"\n{'ALL OK' if not fails else f'{fails} check(s) failed'}")
    return 1 if fails else 0


if __name__ == "__main__":
    t0 = time.time()
    rc = asyncio.run(main())
    print(f"({time.time() - t0:.0f}s)")
    sys.exit(rc)
