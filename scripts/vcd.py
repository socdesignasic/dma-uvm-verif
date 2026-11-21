"""
vcd.py - VCD 파일에서 시간 구간의 신호 변화를 텍스트로 뽑습니다 (MCP trace_signals, 가설 확인용).

  python scripts/vcd.py out/skid/runs/trace/unit_post_reset_test_1/trace.vcd --from 100 --to 130
  python scripts/vcd.py <vcd> --from 100 --to 130 --signals s_valid s_ready m_data

시각 단위는 ns입니다. 결과는 "구간 시작 때의 값"과 "구간 안의 변화(시각, 신호, 값)"입니다.
폭이 4비트보다 넓은 값은 16진수로, x/z가 섞이면 2진수 그대로 보여 줍니다.
import할 때 출력 설정을 바꾸지 않습니다 (MCP stdio 서버에서도 안전).
"""
from __future__ import annotations

import argparse
import re
import sys

_UNIT_PS = {"s": 10**12, "ms": 10**9, "us": 10**6, "ns": 10**3, "ps": 1, "fs": 10**-3}


def _fmt(bits: str, width: int) -> str:                     # 값 표시
    if width <= 4 or re.search(r"[xzXZ]", bits):
        return bits if width > 1 else bits[-1]
    return "0x" + format(int(bits, 2), "0%dx" % ((width + 3) // 4))


def parse(text: str, t_from_ns: float | None = None, t_to_ns: float | None = None,
          signals: list[str] | None = None) -> dict:
    """VCD 텍스트 -> {"signals": {이름: 폭}, "initial": {이름: 값}, "changes": [(ns, 이름, 값)]}.
    signals는 전체 경로(/a/b/c) 또는 끝 이름(c)으로 고름. 없으면 전부."""
    tok = text.split()
    i, scope, ids, width, scale_ps = 0, [], {}, {}, 1.0
    while i < len(tok):                                     # 머리 부분
        t = tok[i]
        if t == "$timescale":
            j = tok.index("$end", i)
            m = re.match(r"(\d+)\s*([a-z]+)", " ".join(tok[i + 1:j]))
            scale_ps = int(m[1]) * _UNIT_PS[m[2]] if m else 1.0
            i = j + 1
        elif t == "$scope":
            scope.append(tok[i + 2])
            i = tok.index("$end", i) + 1
        elif t == "$upscope":
            scope.pop()
            i = tok.index("$end", i) + 1
        elif t == "$var":                                   # $var wire 1 ! name [3:0] $end
            j = tok.index("$end", i)
            w, code, name = int(tok[i + 2]), tok[i + 3], tok[i + 4]
            full = "/" + "/".join(scope + [name])
            ids.setdefault(code, []).append(full)
            width[full] = w
            i = j + 1
        elif t == "$enddefinitions":
            i = tok.index("$end", i) + 1
            break
        else:
            i += 1

    def want(name: str) -> bool:
        return not signals or any(name == s or name.endswith("/" + s.lstrip("/")) for s in signals)

    now_ps, cur, init, changes = 0.0, {}, None, []
    lo = None if t_from_ns is None else t_from_ns * 1000
    hi = None if t_to_ns is None else t_to_ns * 1000
    while i < len(tok):                                     # 값 변화
        t = tok[i]
        i += 1
        if t.startswith("#"):
            now_ps = int(t[1:]) * scale_ps
            if lo is not None and init is None and now_ps >= lo:
                init = dict(cur)                            # 구간 시작 때의 값
            if hi is not None and now_ps > hi:
                break
            continue
        if t.startswith("$"):                               # $dumpvars, $end 등
            continue
        if t[0] in "bBrR":                                  # 여러 비트: b1010 <id>
            val, code = t[1:], tok[i]
            i += 1
        else:                                               # 1비트: 1<id>
            val, code = t[0], t[1:]
        for name in ids.get(code, []):
            if not want(name):
                continue
            v = _fmt(val.zfill(width[name]) if val[0] in "01" else val, width[name])
            cur[name] = v
            if (lo is None or now_ps >= lo) and (hi is None or now_ps <= hi):
                changes.append((round(now_ps / 1000, 3), name, v))
    if init is None:
        init = dict(cur)
    return {"signals": {n: w for n, w in width.items() if want(n)}, "initial": init, "changes": changes}


def as_text(res: dict, max_changes: int = 400) -> str:      # 사람과 모델이 읽기 쉬운 텍스트
    lines = ["initial: " + ", ".join(f"{n.rsplit('/', 1)[-1]}={v}" for n, v in sorted(res["initial"].items()))]
    by_t: dict[float, list[str]] = {}
    for t, n, v in res["changes"][:max_changes]:
        by_t.setdefault(t, []).append(f"{n.rsplit('/', 1)[-1]}={v}")
    lines += [f"{t:>10.3f}ns  " + " ".join(vs) for t, vs in sorted(by_t.items())]
    if len(res["changes"]) > max_changes:
        lines.append(f"... {len(res['changes']) - max_changes} more changes")
    return "\n".join(lines)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vcd")
    ap.add_argument("--from", dest="t_from", type=float)
    ap.add_argument("--to", dest="t_to", type=float)
    ap.add_argument("--signals", nargs="*")
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    with open(a.vcd, encoding="utf-8", errors="replace") as f:
        print(as_text(parse(f.read(), a.t_from, a.t_to, a.signals)))
