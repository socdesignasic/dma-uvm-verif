#!/usr/bin/env python3
"""
selftest.py - 실제 stdio MCP로 vivado-mcp에 접속해 모든 도구를 한 번씩 실행합니다.

  mcp/.venv/Scripts/python.exe mcp/vivado_mcp/selftest.py          # 빠른 확인 (unit TB)
  mcp/.venv/Scripts/python.exe mcp/vivado_mcp/selftest.py --full   # + top 테스트 + 회귀

모든 확인을 통과하면 종료 코드 0.
"""
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가

import asyncio                                              # 비동기 실행 (MCP 클라이언트)
import json                                                 # 도구 결과 JSON 파싱
import sys                                                  # 명령줄 인자, Python 경로, 종료 코드
import time                                                 # 걸린 시간 측정
from pathlib import Path                                    # 경로 처리

from mcp import Client                                      # MCP 클라이언트
from mcp.client.stdio import StdioServerParameters          # stdio 서버 실행 설정

HERE = Path(__file__).resolve().parent                      # 이 파일이 있는 디렉터리
FULL = "--full" in sys.argv                                 # --full이면 top 테스트와 회귀도 확인
fails = 0                                                   # 실패한 확인 수


def check(name: str, cond: bool, detail: object = "") -> None:  # 확인 하나의 결과를 출력하는 함수
    global fails                                            # 전역 실패 수를 바꿈
    print(f"[{'OK ' if cond else 'BAD'}] {name}" + (f"  {detail}" if detail and not cond else ""))  # OK/BAD와 이름, 실패면 상세 내용도 출력
    fails += 0 if cond else 1                               # 실패면 1 더함


def data(res) -> object:                                    # 도구 결과에서 데이터를 꺼내는 함수
    """structured content가 있으면 그것을, 없으면 text content를 JSON으로 파싱해 반환"""  # 함수 설명
    if getattr(res, "structured_content", None) is not None:  # structured content가 있으면
        sc = res.structured_content                         # 그것을 꺼냄
        return sc.get("result", sc) if isinstance(sc, dict) and set(sc) == {"result"} else sc  # {"result": x} 꼴이면 x만, 아니면 그대로
    txt = "".join(getattr(c, "text", "") for c in res.content)  # text content를 이어 붙임
    try:                                                    # JSON 파싱 시도
        return json.loads(txt)                              # 파싱 결과 반환
    except ValueError:                                      # JSON이 아니면
        return txt                                          # 문자열 그대로 반환


async def main() -> int:                                    # 비동기 진입점
    params = StdioServerParameters(command=sys.executable, args=[str(HERE / "server.py")])  # server.py를 지금 Python으로 실행하는 설정
    async with Client(params, read_timeout_seconds=1800) as c:  # stdio로 서버에 접속 (응답 대기 최대 30분)
        tools = {t.name for t in (await c.list_tools()).tools}  # 등록된 도구 이름 집합
        want = {"list_testbenches", "lint", "run_test", "get_log_excerpt", "start_regression",  # 있어야 하는 도구
                "regression_status", "coverage_report", "list_known_bugs"}  # (도구 목록 계속)
        check("tools registered", want <= tools, sorted(tools))  # 모두 등록됐는지 확인

        tbs = data(await c.call_tool("list_testbenches", {}))  # list_testbenches 호출
        check("list_testbenches has top+skid", isinstance(tbs, dict) and {"top", "skid"} <= set(tbs), tbs)  # top과 skid가 있는지 확인

        r = data(await c.call_tool("lint", {"tb": "skid"}))  # lint 호출 (skid)
        check("lint skid ok", isinstance(r, dict) and r.get("ok") is True, r)  # 성공했는지 확인

        r = data(await c.call_tool("run_test", {"tb": "skid", "test": "unit_smoke_test", "seed": "7"}))  # run_test 호출 (skid smoke, seed 7)
        check("run_test skid smoke PASS", isinstance(r, dict) and r.get("verdict") == "PASS", r)  # PASS인지 확인

        r = data(await c.call_tool("run_test", {"tb": "skid", "test": "unit_post_reset_test",  # run_test 호출 (BUG-001 재현 테스트)
                                                "seed": "7", "rebuild": False}))  # seed 7, 다시 빌드하지 않음
        check("run_test BUG-001 reproducer XFAIL", isinstance(r, dict) and r.get("verdict") == "XFAIL", r)  # XFAIL인지 확인

        x = data(await c.call_tool("get_log_excerpt", {"tb": "skid", "test": "unit_post_reset_test",  # get_log_excerpt 호출
                                                       "seed": "7", "max_lines": 20}))  # 같은 실행, 최대 20줄
        check("get_log_excerpt shows scoreboard error",     # scoreboard 오류가 보이는지 확인
              isinstance(x, dict) and "SB_" in x.get("excerpt", ""), x)  # (조건 계속)

        bad = await c.call_tool("run_test", {"tb": "skid; del *", "test": "x"})  # 위험한 TB 이름으로 호출
        check("rejects unknown tb", bool(getattr(bad, "is_error", False)), bad)  # 오류로 거부되는지 확인
        bad = await c.call_tool("run_test", {"tb": "skid", "test": "unit_smoke_test",  # 위험한 plusarg로 호출
                                             "plusargs": ["A=1 & calc"]})  # (인자 계속)
        check("rejects unsafe plusarg", bool(getattr(bad, "is_error", False)), bad)  # 오류로 거부되는지 확인

        bugs = data(await c.call_tool("list_known_bugs", {}))  # list_known_bugs 호출
        check("list_known_bugs BUG-001/002", isinstance(bugs, dict) and {"BUG-001", "BUG-002"} <= set(bugs), bugs)  # BUG-001, BUG-002가 있는지 확인

        cov = data(await c.call_tool("coverage_report", {"tb": "skid"}))  # coverage_report 호출 (skid)
        check("coverage_report returns covergroups", isinstance(cov, dict) and len(cov.get("covergroups", {})) > 0, cov)  # covergroup 점수가 있는지 확인

        if FULL:                                            # --full이면
            r = data(await c.call_tool("run_test", {"tb": "top", "test": "dma_smoke_test", "seed": "3"}))  # run_test 호출 (top smoke)
            check("run_test top smoke PASS", isinstance(r, dict) and r.get("verdict") == "PASS", r)  # PASS인지 확인
            st = data(await c.call_tool("start_regression", {"suite": None, "tbs": ["skid"],  # start_regression 호출 (skid smoke)
                                                             "tests": ["unit_smoke_test"], "seeds": 2}))  # seed 2개
            rid = st["id"]                                  # 회귀 id
            for _ in range(120):                            # 최대 120번 (10분)
                s = data(await c.call_tool("regression_status", {"id": rid}))  # 상태 확인
                if s.get("state") == "done":                # 끝났으면
                    break                                   # 대기 종료
                await asyncio.sleep(5)                      # 5초 대기
            check("regression done, 2 runs, 0 fail", s.get("state") == "done" and s.get("runs") == 2  # 끝났고 2회 실행, 실패 0인지 확인
                  and s.get("fail") == 0, s)                # (조건 계속)

    print(f"\n{'ALL OK' if not fails else f'{fails} check(s) failed'}")  # 최종 결과 출력
    return 1 if fails else 0                                # 실패가 있으면 1


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    t0 = time.time()                                        # 시작 시각
    rc = asyncio.run(main())                                # 비동기 main 실행
    print(f"({time.time() - t0:.0f}s)")                     # 걸린 시간 출력
    sys.exit(rc)                                            # 종료 코드
