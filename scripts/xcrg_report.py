"""
xcrg_report.py - xcrg 2022.2 기능 커버리지 텍스트 보고서(xcrg_func_cov_report.txt)를 읽습니다.

ml_regress.py(실행별 bin 적중표)와 vivado MCP 서버(coverage_report의 못 친 bin 목록)가 같이 씁니다.
import할 때 출력 설정을 바꾸지 않습니다 (MCP stdio 서버에서도 안전).
처리하는 xcrg 2022.2의 특징: 두 번째 cross 표가 첫 번째를 그대로 다시 찍음, 못 친 cross bin이 "(a b)"/"*"로 묶임,
weight 0인 coverpoint는 목표가 아님.
"""
from __future__ import annotations

import re


def parse_report(txt: str) -> dict[str, int]:               # xcrg 텍스트 보고서 -> {bin 키: 적중 수}
    bins: dict[str, int] = {}                               # 결과
    table = None                                            # 지금 읽는 coverpoint 표 이름
    mode = None                                             # 'bins' 섹션 안이면 True
    seen: set[str] = set()                                  # 이미 읽은 표 이름
    zero_w: set[str] = set()                                # weight 0인 coverpoint/cross (목표가 아닌 참고용)
    inst = None                                             # 요약 섹션의 현재 인스턴스
    for line in txt.splitlines():                           # 요약 섹션에서 weight 읽기
        m = re.match(r"\s*Instance (\S+) (?:Cross )?Cover Point Details", line)  # 인스턴스 요약 시작
        if m:                                               # 찾으면
            inst = m[1]                                     # 기억
            continue                                        # 다음 줄
        f = [x.strip() for x in line.split(",")]            # 쉼표로 나눔
        if inst and len(f) >= 8 and f[2].isdigit() and f[7].isdigit():  # 이름, tag, 기대 bin 수, ..., weight
            if int(f[7]) == 0:                              # weight 0이면
                zero_w.add(f"{inst}.{f[0]}")                # 제외 목록에 추가
    for line in txt.splitlines():                           # 줄마다
        m = re.match(r"\s*(?:Cross )?Cover Point Table for Inst : (.+?), Variable :, (\S+)", line)  # 표 시작
        if m:                                               # 새 표면
            base = f"{m[1].strip()}.{m[2]}"                 # 인스턴스.변수
            # xcrg 2022.2는 covergroup의 두 번째 cross 표에 첫 번째 cross의 이름과 내용을 그대로 다시 찍음
            # (예: x_dir_4k 자리에 x_dir_len). 같은 이름이 또 나오면 그 표는 버림.
            table = None if base in seen or base in zero_w else base  # 중복 표와 weight 0 표는 읽지 않음
            seen.add(base)                                  # 기록
            mode = None                                     # 섹션 초기화
            continue                                        # 다음 줄
        s = line.strip()                                    # 앞뒤 공백 제거
        if s.endswith("Uncovered bins") or s.endswith("Covered bins"):  # bin 목록 섹션 시작
            mode = True                                     # 목록 읽기 시작
            continue                                        # 다음 줄
        if not s:                                           # 빈 줄이면
            mode = None if mode == "data" else mode         # 데이터 뒤의 빈 줄은 섹션 끝
            continue                                        # 다음 줄
        if mode and table and "Hit Count" in s:             # 열 이름 줄
            mode = "data"                                   # 다음 줄부터 데이터
            continue                                        # 다음 줄
        if mode == "data" and table:                        # 데이터 줄이면
            f = [x.strip() for x in s.split(",")]           # 쉼표로 나눔 (끝에 빈 칸 하나)
            f = f[:-1] if f and f[-1] == "" else f          # 끝 빈 칸 제거
            if any("*" in x or "(" in x for x in f[:-2]):   # 못 친 cross bin 묶음 ("one x *", "(one mid ) x rd")은 개별 bin이 아님
                continue                                    # 건너뜀 (친 bin만 목표로 쓰므로 영향 없음)
            if len(f) >= 3 and f[-2].isdigit():             # 이름..., 적중 수, AtLeast
                bins[f"{table}:{'x'.join(f[:-2])}"] = int(f[-2])  # bin 키 = 표:이름 (cross는 x로 연결)
    return bins                                             # 결과


def uncovered(txt: str) -> list[str]:                       # 적중 수 0인 개별 bin (묶인 미적중 행은 제외)
    return sorted(k for k, v in parse_report(txt).items() if v == 0)
