#!/usr/bin/env python3
"""
check_jenkins_mcp.py - Jenkins MCP 서버(mcp-server 플러그인)에 접속해 도구 목록을 보여 주고,
MCP로 dma-uvm 잡의 마지막 빌드를 읽습니다.

  mcp/.venv/Scripts/python.exe mcp/check_jenkins_mcp.py

인증: 사용자 'admin' + 다음 파일의 API 토큰
%USERPROFILE%\\jenkins\\home\\secrets\\claude_mcp_api_token (Claude Code용으로 만든 것. git에는 절대 넣지 않음).
"""
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가

import asyncio                                              # 비동기 실행
import json                                                 # 도구 결과 JSON 파싱
import os                                                   # 환경 변수
import sys                                                  # 종료 코드
from pathlib import Path                                    # 경로 처리

import httpx2                                               # HTTP 클라이언트
from mcp.client.session import ClientSession                # MCP 클라이언트 세션
from mcp.client.streamable_http import streamable_http_client  # Streamable HTTP 전송

URL = os.environ.get("JENKINS_MCP_URL", "http://localhost:8090/mcp-server/mcp")  # Jenkins MCP 주소 (환경 변수로 바꿀 수 있음)
TOKEN_FILE = Path.home() / "jenkins" / "home" / "secrets" / "claude_mcp_api_token"  # API 토큰 파일 경로


async def main() -> int:                                    # 비동기 진입점
    token = TOKEN_FILE.read_text().strip()                  # 토큰 읽기
    async with httpx2.AsyncClient(auth=("admin", token), timeout=60) as http:  # admin + 토큰으로 HTTP 클라이언트 생성
        async with streamable_http_client(URL, http_client=http) as streams:  # MCP 연결
            read, write = streams[0], streams[1]            # 읽기/쓰기 스트림
            async with ClientSession(read, write) as s:     # MCP 세션 시작
                await s.initialize()                        # 초기화
                tools = (await s.list_tools()).tools        # 도구 목록
                print(f"{len(tools)} tools:", ", ".join(sorted(t.name for t in tools)))  # 도구 수와 이름 출력
                names = {t.name for t in tools}             # 도구 이름 집합
                for cand in ("getBuild", "get_build", "getJob"):  # 빌드 조회 도구 후보마다
                    if cand in names:                       # 있으면
                        r = await s.call_tool(cand, {"jobFullName": "dma-uvm"})  # dma-uvm 잡 조회
                        txt = "".join(getattr(c, "text", "") for c in r.content)  # text content를 이어 붙임
                        try:                                # JSON 파싱 시도
                            d = json.loads(txt)             # 파싱
                            keep = {k: d.get(k) for k in ("number", "result", "description", "duration") if k in d}  # 빌드 번호, 결과, 설명, 걸린 시간만
                            print(f"{cand}(dma-uvm) ->", keep or txt[:300])  # 출력
                        except ValueError:                  # JSON이 아니면
                            print(f"{cand}(dma-uvm) ->", txt[:300])  # 앞 300자 출력
                        break                               # 하나만 호출
    return 0                                                # 성공


if __name__ == "__main__":                                  # 스크립트로 실행될 때만
    sys.exit(asyncio.run(main()))                           # 비동기 main 실행
