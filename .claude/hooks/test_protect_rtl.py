#!/usr/bin/env python3
"""protect_rtl.py 단위 테스트: python .claude/hooks/test_protect_rtl.py"""  # 파일 설명과 실행 방법
import json                                                 # hook 입력 JSON 만들기
import subprocess                                           # hook 실행
import sys                                                  # Python 경로, 종료 코드
from pathlib import Path                                    # 경로 처리

HOOK = Path(__file__).with_name("protect_rtl.py")           # 검사할 hook 파일
ROOT = HOOK.parents[2]                                      # 저장소 루트
CASES = [  # (도구, 입력, 기대 종료 코드)
    ("Edit", {"file_path": str(ROOT / "HW/peri_ip/skid_buffer.v")}, 2),  # HW/ 파일 Edit (절대 경로) -> 막음
    ("Write", {"file_path": "HW/x.v"}, 2),                  # HW/ 파일 Write -> 막음
    ("Edit", {"file_path": "verif/../HW/a.v"}, 2),          # ..로 돌아 HW/로 가는 Edit -> 막음
    ("Edit", {"file_path": "verif/BUGS.md"}, 0),            # verif/ 파일 Edit -> 허용
    ("Write", {"file_path": str(ROOT / "verif/tests/top/new_test.sv")}, 0),  # verif/ 새 파일 Write -> 허용
    ("Bash", {"command": "sed -i s/a/b/ HW/dma_ip/WDMA/wdma.v"}, 2),  # sed -i로 HW/ 수정 -> 막음
    ("Bash", {"command": "echo x >> HW/dma_ip/dma_ip_top.v"}, 2),  # HW/로 리디렉션 -> 막음
    ("PowerShell", {"command": "Set-Content -Path .\\HW\\x.v -Value 1"}, 2),  # PowerShell Set-Content로 HW/ 쓰기 -> 막음
    ("Bash", {"command": "git checkout -- HW/peri_ip/sync_fifo.v"}, 2),  # git checkout으로 HW/ 되돌리기 -> 막음
    ("Bash", {"command": "grep -n WVALID HW/dma_ip/WDMA/wdma.v"}, 0),  # grep으로 HW/ 읽기 -> 허용
    ("Bash", {"command": "python scripts/sim.py run --tb top > out/x.txt"}, 0),  # out/으로 리디렉션 -> 허용
    ("Read", {"file_path": "HW/dma_ip/dma_ip_top.v"}, 0),  # HW/ 파일 Read -> 허용
    # heredoc 본문은 명령이 아니라 파일 내용
    ("Bash", {"command": "cat > .claude/agents/a.md <<'EOF'\nRead the RTL in HW/ (read-only); never edit HW/x.v\nEOF\nls"}, 0),  # heredoc 본문에 HW/가 있어도 -> 허용
    ("Bash", {"command": "cat > HW/x.v <<'EOF'\nmodule x; endmodule\nEOF"}, 2),  # heredoc으로 HW/ 파일 생성 -> 막음
    ("Bash", {"command": "python scripts/sim.py lint --tb top > out/lint.txt 2>&1; grep HW/ out/lint.txt"}, 0),  # 명령 뒤 grep에 HW/ -> 허용
    ("Bash", {"command": "cp out/fixed.v C:/Users/abc/Downloads/DMA_Verification/PRJ/HW/peri_ip/a.v"}, 2),  # 절대 경로로 HW/에 복사 -> 막음
]                                                           # 목록 끝
bad = 0                                                     # 실패 수
for tool, ti, want in CASES:                                # 경우마다
    r = subprocess.run([sys.executable, str(HOOK)], input=json.dumps({"tool_name": tool, "tool_input": ti}),  # hook을 실행하고 JSON을 stdin으로 전달
                       capture_output=True, text=True)      # 출력 캡처
    ok = r.returncode == want                               # 종료 코드가 기대와 같은지
    bad += not ok                                           # 다르면 실패 수 증가
    print(f"[{'OK ' if ok else 'BAD'}] {tool:10s} want={want} got={r.returncode}  {json.dumps(ti)[:70]}")  # 결과 한 줄 출력
print("ALL OK" if not bad else f"{bad} failed")             # 최종 결과
sys.exit(1 if bad else 0)                                   # 실패가 있으면 1
