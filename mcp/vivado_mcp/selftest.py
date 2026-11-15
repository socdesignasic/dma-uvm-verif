#!/usr/bin/env python3
"""
selftest.py - 실제 stdio MCP로 vivado-mcp에 접속해 모든 도구를 한 번씩 실행합니다.

  mcp/.venv/Scripts/python.exe mcp/vivado_mcp/selftest.py          # 빠른 확인 (unit TB)
  mcp/.venv/Scripts/python.exe mcp/vivado_mcp/selftest.py --full   # + top 테스트 + 회귀

모든 확인을 통과하면 종료 코드 0.
"""
from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path

from mcp import Client
from mcp.client.stdio import StdioServerParameters

HERE = Path(__file__).resolve().parent
FULL = "--full" in sys.argv
fails = 0


def check(name: str, cond: bool, detail: object = "") -> None:
    global fails
    print(f"[{'OK ' if cond else 'BAD'}] {name}" + (f"  {detail}" if detail and not cond else ""))
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


async def main() -> int:
    params = StdioServerParameters(command=sys.executable, args=[str(HERE / "server.py")])
    async with Client(params, read_timeout_seconds=1800) as c:
        tools = {t.name for t in (await c.list_tools()).tools}
        want = {"list_testbenches", "lint", "run_test", "get_log_excerpt", "start_regression",
                "regression_status", "coverage_report", "list_known_bugs"}
        check("tools registered", want <= tools, sorted(tools))

        tbs = data(await c.call_tool("list_testbenches", {}))
        check("list_testbenches has top+skid", isinstance(tbs, dict) and {"top", "skid"} <= set(tbs), tbs)

        r = data(await c.call_tool("lint", {"tb": "skid"}))
        check("lint skid ok", isinstance(r, dict) and r.get("ok") is True, r)

        r = data(await c.call_tool("run_test", {"tb": "skid", "test": "unit_smoke_test", "seed": "7"}))
        check("run_test skid smoke PASS", isinstance(r, dict) and r.get("verdict") == "PASS", r)

        r = data(await c.call_tool("run_test", {"tb": "skid", "test": "unit_post_reset_test",
                                                "seed": "7", "rebuild": False}))
        check("run_test BUG-001 reproducer XFAIL", isinstance(r, dict) and r.get("verdict") == "XFAIL", r)

        x = data(await c.call_tool("get_log_excerpt", {"tb": "skid", "test": "unit_post_reset_test",
                                                       "seed": "7", "max_lines": 20}))
        check("get_log_excerpt shows scoreboard error",
              isinstance(x, dict) and "SB_" in x.get("excerpt", ""), x)

        bad = await c.call_tool("run_test", {"tb": "skid; del *", "test": "x"})
        check("rejects unknown tb", bool(getattr(bad, "is_error", False)), bad)
        bad = await c.call_tool("run_test", {"tb": "skid", "test": "unit_smoke_test",
                                             "plusargs": ["A=1 & calc"]})
        check("rejects unsafe plusarg", bool(getattr(bad, "is_error", False)), bad)

        bugs = data(await c.call_tool("list_known_bugs", {}))
        check("list_known_bugs BUG-001/002", isinstance(bugs, dict) and {"BUG-001", "BUG-002"} <= set(bugs), bugs)

        cov = data(await c.call_tool("coverage_report", {"tb": "skid"}))
        check("coverage_report returns covergroups", isinstance(cov, dict) and len(cov.get("covergroups", {})) > 0, cov)

        if FULL:
            r = data(await c.call_tool("run_test", {"tb": "top", "test": "dma_smoke_test", "seed": "3"}))
            check("run_test top smoke PASS", isinstance(r, dict) and r.get("verdict") == "PASS", r)
            st = data(await c.call_tool("start_regression", {"suite": None, "tbs": ["skid"],
                                                             "tests": ["unit_smoke_test"], "seeds": 2}))
            rid = st["id"]
            for _ in range(120):
                s = data(await c.call_tool("regression_status", {"id": rid}))
                if s.get("state") == "done":
                    break
                await asyncio.sleep(5)
            check("regression done, 2 runs, 0 fail", s.get("state") == "done" and s.get("runs") == 2
                  and s.get("fail") == 0, s)

    print(f"\n{'ALL OK' if not fails else f'{fails} check(s) failed'}")
    return 1 if fails else 0


if __name__ == "__main__":
    t0 = time.time()
    rc = asyncio.run(main())
    print(f"({time.time() - t0:.0f}s)")
    sys.exit(rc)
