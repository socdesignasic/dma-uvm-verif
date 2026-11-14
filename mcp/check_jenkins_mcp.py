#!/usr/bin/env python3
"""
check_jenkins_mcp.py - connect to the Jenkins MCP server (mcp-server plugin) and list its
tools, then read the dma-uvm job's last build through MCP.

  mcp/.venv/Scripts/python.exe mcp/check_jenkins_mcp.py

Credentials: user 'admin' + the API token in
%USERPROFILE%\\jenkins\\home\\secrets\\claude_mcp_api_token (created for Claude Code; never in git).
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
