#!/usr/bin/env python3
"""
check_jenkins_mcp.py - Jenkins MCP 서버(mcp-server 플러그인)에 접속해 도구 목록을 보여 주고,
MCP로 dma-uvm 잡의 마지막 빌드를 읽습니다.

  mcp/.venv/Scripts/python.exe mcp/check_jenkins_mcp.py

인증: 사용자 'admin' + 다음 파일의 API 토큰
%USERPROFILE%\\jenkins\\home\\secrets\\claude_mcp_api_token (Claude Code용으로 만든 것. git에는 절대 넣지 않음).
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

import httpx2
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client

URL = os.environ.get("JENKINS_MCP_URL", "http://localhost:8090/mcp-server/mcp")
TOKEN_FILE = Path.home() / "jenkins" / "home" / "secrets" / "claude_mcp_api_token"


async def main() -> int:
    token = TOKEN_FILE.read_text().strip()
    async with httpx2.AsyncClient(auth=("admin", token), timeout=60) as http:
        async with streamable_http_client(URL, http_client=http) as streams:
            read, write = streams[0], streams[1]
            async with ClientSession(read, write) as s:
                await s.initialize()
                tools = (await s.list_tools()).tools
                print(f"{len(tools)} tools:", ", ".join(sorted(t.name for t in tools)))
                names = {t.name for t in tools}
                for cand in ("getBuild", "get_build", "getJob"):
                    if cand in names:
                        r = await s.call_tool(cand, {"jobFullName": "dma-uvm"})
                        txt = "".join(getattr(c, "text", "") for c in r.content)
                        try:
                            d = json.loads(txt)
                            keep = {k: d.get(k) for k in ("number", "result", "description", "duration") if k in d}
                            print(f"{cand}(dma-uvm) ->", keep or txt[:300])
                        except ValueError:
                            print(f"{cand}(dma-uvm) ->", txt[:300])
                        break
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
