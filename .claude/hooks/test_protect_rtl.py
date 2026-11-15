#!/usr/bin/env python3
"""protect_rtl.py 단위 테스트: python .claude/hooks/test_protect_rtl.py"""
import json
import subprocess
import sys
from pathlib import Path

HOOK = Path(__file__).with_name("protect_rtl.py")
ROOT = HOOK.parents[2]
CASES = [  # (도구, 입력, 기대 종료 코드)
    ("Edit", {"file_path": str(ROOT / "HW/peri_ip/skid_buffer.v")}, 2),
    ("Write", {"file_path": "HW/x.v"}, 2),
    ("Edit", {"file_path": "verif/../HW/a.v"}, 2),
    ("Edit", {"file_path": "verif/BUGS.md"}, 0),
    ("Write", {"file_path": str(ROOT / "verif/tests/top/new_test.sv")}, 0),
    ("Bash", {"command": "sed -i s/a/b/ HW/dma_ip/WDMA/wdma.v"}, 2),
    ("Bash", {"command": "echo x >> HW/dma_ip/dma_ip_top.v"}, 2),
    ("PowerShell", {"command": "Set-Content -Path .\\HW\\x.v -Value 1"}, 2),
    ("Bash", {"command": "git checkout -- HW/peri_ip/sync_fifo.v"}, 2),
    ("Bash", {"command": "grep -n WVALID HW/dma_ip/WDMA/wdma.v"}, 0),
    ("Bash", {"command": "python scripts/sim.py run --tb top > out/x.txt"}, 0),
    ("Read", {"file_path": "HW/dma_ip/dma_ip_top.v"}, 0),
    # heredoc 본문은 명령이 아니라 파일 내용
    ("Bash", {"command": "cat > .claude/agents/a.md <<'EOF'\nRead the RTL in HW/ (read-only); never edit HW/x.v\nEOF\nls"}, 0),
    ("Bash", {"command": "cat > HW/x.v <<'EOF'\nmodule x; endmodule\nEOF"}, 2),
    ("Bash", {"command": "python scripts/sim.py lint --tb top > out/lint.txt 2>&1; grep HW/ out/lint.txt"}, 0),
    ("Bash", {"command": "cp out/fixed.v C:/Users/abc/Downloads/DMA_Verification/PRJ/HW/peri_ip/a.v"}, 2),
]
bad = 0
for tool, ti, want in CASES:
    r = subprocess.run([sys.executable, str(HOOK)], input=json.dumps({"tool_name": tool, "tool_input": ti}),
                       capture_output=True, text=True)
    ok = r.returncode == want
    bad += not ok
    print(f"[{'OK ' if ok else 'BAD'}] {tool:10s} want={want} got={r.returncode}  {json.dumps(ti)[:70]}")
print("ALL OK" if not bad else f"{bad} failed")
sys.exit(1 if bad else 0)
