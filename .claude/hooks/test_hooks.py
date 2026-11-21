#!/usr/bin/env python3
"""hook 회귀 테스트: python .claude/hooks/test_hooks.py  (Jenkins Lint 단계와 gate.py static에서 돌림)

1) 실행 전 hook(protect_rtl.py, guard_rules.py): 기존 16개 + 2026-11-19 우회 사례 15개 + 규칙 hook
2) 실행 후 hook(post_tool_use.py): 임시 git 저장소에서 HW/를 바꾸면 되돌리는지, 사람이 고친 상태는 두는지
3) git hook(.githooks/check_commit.py): Claude 트레일러와 금지어를 거부하는지
기대 값: 0 = 허용, 2 = 막음, "ask" = 사용자 확인 요청
"""
import json                                                 # hook 입력
import os                                                   # 환경 변수
import subprocess                                           # hook 실행
import sys                                                  # Python 경로
import tempfile                                             # 임시 저장소
from pathlib import Path                                    # 경로

HOOKS = Path(__file__).resolve().parent                     # .claude/hooks/
ROOT = HOOKS.parents[1]                                     # 저장소 루트
R = str(ROOT).replace("\\", "/")                            # 절대 경로 (슬래시)
BS = chr(92)                                                # 역슬래시
TMP = tempfile.TemporaryDirectory()                         # 형제 worktree 흉내용 폴더
SIB = Path(TMP.name) / "PRJ-wt1"                            # .git 파일이 있는 다른 작업 트리
(SIB / "HW").mkdir(parents=True)
(SIB / ".git").write_text("gitdir: elsewhere\n", encoding="utf-8")

P, G = "protect_rtl.py", "guard_rules.py"
CASES = [  # (hook, 도구, 입력, 기대)
    # --- 기존 16개 (protect_rtl)
    (P, "Edit", {"file_path": R + "/HW/peri_ip/skid_buffer.v"}, 2),
    (P, "Write", {"file_path": "HW/x.v"}, 2),
    (P, "Edit", {"file_path": "verif/../HW/a.v"}, 2),
    (P, "Edit", {"file_path": "verif/BUGS.md"}, 0),
    (P, "Write", {"file_path": R + "/verif/top/test/new_test.sv"}, 0),
    (P, "Bash", {"command": "sed -i s/a/b/ HW/dma_ip/WDMA/wdma.v"}, 2),
    (P, "Bash", {"command": "echo x >> HW/dma_ip/dma_ip_top.v"}, 2),
    (P, "PowerShell", {"command": "Set-Content -Path ." + BS + "HW" + BS + "x.v -Value 1"}, 2),
    (P, "Bash", {"command": "git checkout -- HW/peri_ip/sync_fifo.v"}, 2),
    (P, "Bash", {"command": "grep -n WVALID HW/dma_ip/WDMA/wdma.v"}, 0),
    (P, "Bash", {"command": "python scripts/sim.py run --tb top > out/x.txt"}, 0),
    (P, "Read", {"file_path": "HW/dma_ip/dma_ip_top.v"}, 0),
    (P, "Bash", {"command": "cat > .claude/agents/a.md <<'EOF'\nRead the RTL in HW/ (read-only); never edit HW/x.v\nEOF\nls"}, 0),
    (P, "Bash", {"command": "cat > HW/x.v <<'EOF'\nmodule x; endmodule\nEOF"}, 2),
    (P, "Bash", {"command": "python scripts/sim.py lint --tb top > out/lint.txt 2>&1; grep HW/ out/lint.txt"}, 0),
    (P, "Bash", {"command": "cp out/fixed.v " + R + "/HW/peri_ip/a.v"}, 2),
    # --- 우회 사례 15개 (2026-11-19 점검에서 모두 통과했던 것)
    (P, "Edit", {"file_path": R + "/.claude/worktrees/wt1/HW/dma_ip/WDMA/wdma.v"}, 2),
    (P, "Edit", {"file_path": str(SIB / "HW" / "a.v")}, 2),
    (P, "Bash", {"command": "cd HW && sed -i s/a/b/ dma_ip/WDMA/wdma.v"}, 2),
    (P, "Bash", {"command": "F=HW/x.v; sed -i s/a/b/ $F"}, 2),
    (P, "Bash", {"command": "python -c \"open('HW/x.v','w').write('')\""}, 2),
    (P, "Bash", {"command": "perl -pi -e 's/a/b/' HW/x.v"}, 2),
    (P, "Bash", {"command": "git stash"}, "ask"),
    (P, "Bash", {"command": "git checkout main -- ."}, "ask"),
    (P, "Bash", {"command": "git apply fix.patch"}, "ask"),
    (P, "PowerShell", {"command": "[IO.File]::WriteAllText('HW" + BS + "x.v','')"}, 2),
    (P, "PowerShell", {"command": "sc HW" + BS + "x.v 1"}, 2),
    (P, "Bash", {"command": "cmd /c copy out" + BS + "a.v HW" + BS + "a.v"}, 2),
    (P, "mcp__github__create_or_update_file", {"path": "HW/x.v", "content": "x"}, 2),
    (G, "Bash", {"command": "xvlog --sv verif/top/tb_dma.sv"}, 2),
    ("commit", "msg", "fix x\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n", 1),
    # --- 오탐이 없어야 하는 경우와 규칙 hook
    (P, "Bash", {"command": "git stash list"}, 0),
    (P, "Bash", {"command": "git status && git diff -- HW"}, 0),
    (P, "Bash", {"command": "python scripts/regress.py --suite all --seeds 2 --jobs 6"}, 0),
    (P, "mcp__github__create_or_update_file", {"path": "verif/README.md", "content": "x"}, 0),
    (G, "Bash", {"command": "python scripts/sim.py run --tb top --test dma_smoke_test"}, 0),
    (G, "Bash", {"command": "grep -c xsim out/top/runs/a/run.log"}, 0),
    # heredoc 본문: python/cat에 넘기는 메모 글자는 통과, 셸에 넘기는 본문과 heredoc 뒤의 실제 호출은 막음
    (G, "Bash", {"command": "PYTHONIOENCODING=utf-8 python -I - <<'PYEOF'\nnote = \"(XSim xelab 크래시)\"\nPYEOF"}, 0),
    (G, "Bash", {"command": "cd x && cat >> notes.md <<EOF\n- 순서; xelab 메모 '(XSim '\nEOF"}, 0),
    (G, "Bash", {"command": "bash <<'EOF'\nxelab tb\nEOF"}, 2),
    (G, "Bash", {"command": "cat > f.txt <<EOF\nmemo\nEOF\nxvlog a.sv"}, 2),
    (G, "PowerShell", {"command": "& \"C:" + BS + "Xilinx" + BS + "Vivado" + BS + "2022.2" + BS + "bin" + BS + "xelab.bat\" tb"}, 2),
    (G, "Edit", {"file_path": R + "/verif/sim_cfg.json", "old_string": "x",
                 "new_string": "\"dma_x_test\": \"BUG-099: none\""}, 2),
    (G, "Edit", {"file_path": R + "/verif/sim_cfg.json", "old_string": "x",
                 "new_string": "\"dma_x_test\": \"BUG-002: x\""}, 0),
    (G, "Bash", {"command": "python scripts/check_inventory.py --save --reason x"}, "ask"),
    ("commit", "msg", "sim: 판정에 XSim 오류 추가\n", 0),
    ("commit", "msg", "docs: of c" + "ourse\n", 1),
]


def run_hook(name: str, tool: str, ti) -> object:           # hook 하나 실행 -> 0 / 2 / "ask" / 기타 종료 코드
    if name == "commit":                                    # git hook
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as f:
            f.write(ti)
        r = subprocess.run([sys.executable, str(ROOT / ".githooks" / "check_commit.py"), "msg", f.name],
                           capture_output=True, text=True)
        os.unlink(f.name)
        return r.returncode
    r = subprocess.run([sys.executable, str(HOOKS / name)],
                       input=json.dumps({"tool_name": tool, "tool_input": ti, "cwd": str(ROOT)}),
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode == 0 and '"permissionDecision": "ask"' in r.stdout:
        return "ask"
    return r.returncode


def post_hook_cases() -> list[tuple[str, bool]]:            # 실행 후 hook: 임시 git 저장소에서 확인
    res = []
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        g = lambda *a: subprocess.run(["git", *a], cwd=t, capture_output=True, text=True)
        g("init", "-q"); g("config", "user.email", "t@example.com"); g("config", "user.name", "t")
        (t / "HW").mkdir(); (t / "HW" / "a.v").write_text("module a; endmodule\n")
        g("add", "."); g("commit", "-qm", "init")
        post = lambda: subprocess.run([sys.executable, str(HOOKS / "post_tool_use.py")],
                                      input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "x"},
                                                        "cwd": str(t)}), capture_output=True, text=True)
        res.append(("post: clean HW/ -> allow", post().returncode == 0))
        (t / "HW" / "a.v").write_text("module a; wire w; endmodule\n"); (t / "HW" / "new.v").write_text("x\n")
        r = post()
        res.append(("post: command changed HW/ -> block and revert", r.returncode == 2 and
                    (t / "HW" / "a.v").read_text() == "module a; endmodule\n" and not (t / "HW" / "new.v").exists()))
        (t / "HW" / "a.v").write_text("module a; // human edit\nendmodule\n")
        gd = Path(g("rev-parse", "--absolute-git-dir").stdout.strip())
        st = subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, r'%s'); import post_tool_use as p; "
                             "print(p.hw_state(__import__('pathlib').Path(r'%s')))" % (HOOKS, t)],
                            capture_output=True, text=True).stdout.strip()
        (gd / "claude_hw_state").write_text(st)            # 사람이 고친 상태를 "호출 전" 상태로 기록
        r = post()
        res.append(("post: human edit already present -> leave it", r.returncode == 0 and
                    "human edit" in (t / "HW" / "a.v").read_text()))
    return res


def main() -> int:
    bad = 0
    for hook, tool, ti, want in CASES:
        got = run_hook(hook, tool, ti)
        ok = got == want
        bad += not ok
        print(f"[{'OK ' if ok else 'BAD'}] {hook[:8]:8s} {tool[:12]:12s} want={want!s:4s} got={got!s:4s} "
              f"{json.dumps(ti, ensure_ascii=True)[:70]}")
    for name, ok in post_hook_cases():
        bad += not ok
        print(f"[{'OK ' if ok else 'BAD'}] {name}")
    n = len(CASES) + 3
    print(f"{n - bad}/{n} OK" if not bad else f"{bad} of {n} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        TMP.cleanup()
