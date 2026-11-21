"""
common.py - scripts/ 아래 스크립트가 같이 쓰는 함수.

  - 저장소 루트, UTF-8 출력 설정
  - Vivado / Vitis 도구 찾기 (환경 변수는 도구마다 하나: XILINX_VIVADO, XILINX_VITIS)
  - Windows .bat 도구용 명령줄 만들기
  - 결과 출처(provenance): git 커밋, 수정 여부, HW/ 내용 해시
  - 시간 제한이 있는 실행과 프로세스 트리 전체 종료

이 모듈은 표준 라이브러리만 씁니다 (CI 노드에 패키지를 따로 설치하지 않음).
"""
from __future__ import annotations                          # 타입 힌트를 문자열로 지연 평가

import hashlib                                              # HW/ 내용 해시
import os                                                   # 환경 변수, OS 종류
import re                                                   # 명령줄 따옴표 판단
import shutil                                               # PATH에서 실행 파일 찾기
import signal                                               # POSIX 프로세스 그룹 종료
import subprocess                                           # 외부 도구 실행
import sys                                                  # 표준 출력
import time                                                 # 시각 문자열
from pathlib import Path                                    # 경로 처리

ROOT = Path(__file__).resolve().parent.parent               # 저장소 루트 (scripts/의 상위)
HW_DIR = "HW"                                               # 읽기 전용 RTL 폴더 (저장소 루트 기준)
TOOL_VERSION = "2022.2"                                     # Vivado / Vitis 버전 (기본 설치 위치 계산용)
TIMEOUT_RC = 124                                            # 시간 초과 종료 코드 (timeout 명령 관례)


def setup_utf8() -> None:                                   # 출력 인코딩을 UTF-8로 고정
    """한글 출력이 Jenkins/MCP(UTF-8로 읽음)와 Windows 콘솔(cp949)에서 깨지지 않게 함."""
    for s in (sys.stdout, sys.stderr):                      # 표준 출력과 표준 오류 각각
        if hasattr(s, "reconfigure"):                       # reconfigure를 지원하면
            s.reconfigure(encoding="utf-8", errors="replace")  # UTF-8로, 못 바꾸는 문자는 ?로


# --------------------------------------------------------------------------- #
# 도구 찾기
# --------------------------------------------------------------------------- #
def tool_root(product: str = "Vivado") -> Path:             # Vivado 또는 Vitis 설치 폴더
    """XILINX_VIVADO / XILINX_VITIS -> PATH -> C:/Xilinx/<product>/<버전> 순으로 찾음."""
    env = os.environ.get("XILINX_" + product.upper())       # 도구마다 환경 변수 하나
    if env and (Path(env) / "bin").is_dir():                # 설정돼 있고 bin이 있으면
        return Path(env)                                    # 그 위치
    probe = {"Vivado": "xvlog", "Vitis": "xsct"}.get(product, product.lower())  # PATH에서 찾을 대표 실행 파일
    found = shutil.which(probe)                             # PATH 검색
    if found:                                               # 찾았으면
        return Path(found).resolve().parent.parent          # bin의 상위 = 설치 폴더
    default = Path(f"C:/Xilinx/{product}/{TOOL_VERSION}")   # 기본 설치 위치
    if (default / "bin").is_dir():                          # 있으면
        return default                                      # 그 위치
    sys.exit(f"ERROR: {product} not found. Set XILINX_{product.upper()} or add {product}/bin to PATH.")


def tool(name: str, product: str = "Vivado") -> str:       # 도구 실행 파일 경로 (xvlog, xsim, xcrg, vivado, xsdb, xsct ...)
    b = tool_root(product) / "bin"                          # bin 폴더
    return str(b / (name + ".bat")) if os.name == "nt" else str(b / name)  # Windows는 .bat wrapper


def win_cmdline(cmd: list[str]) -> str:                     # 명령 목록을 Windows 명령줄 문자열로
    """Windows의 Vivado 도구는 .bat wrapper라서 cmd.exe가 따옴표 없는 인자를 '=' ',' ';'에서 나눔
    (예: UVM_TESTNAME=foo -> 'UVM_TESTNAME' 'foo'). 그래서 그런 인자는 따옴표로 감쌈.
    역슬래시 경로는 XSim이 만드는 C 문자열 안에 들어가 코드 커버리지 elaboration을 깨뜨리므로 슬래시로 바꿈."""
    out = []                                                # 결과 인자 목록
    for c in cmd:                                           # 인자마다
        c = c.replace("\\", "/")                            # 역슬래시를 슬래시로
        out.append(f'"{c}"' if re.search(r'[\s=,;&()^]', c) and not c.startswith('"') else c)  # 특수문자가 있으면 따옴표
    return " ".join(out)                                    # 공백으로 이어 붙임


# --------------------------------------------------------------------------- #
# 실행: 시간 초과 때 프로세스 트리 전체 종료
# --------------------------------------------------------------------------- #
def kill_tree(p: subprocess.Popen) -> None:                 # 프로세스와 그 자식들을 모두 종료
    """Windows에서 .bat를 거쳐 실행하면 p는 cmd.exe라서 p.kill()로는 xsim/vivado가 남음.
    taskkill /T로 자식까지 종료하고, POSIX에서는 프로세스 그룹 전체에 SIGKILL."""
    if p.poll() is not None:                                # 이미 끝났으면
        return                                              # 할 일 없음
    if os.name == "nt":                                     # Windows
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)],  # 트리 전체 강제 종료
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:                                                   # POSIX
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)    # start_new_session으로 만든 그룹 전체
        except ProcessLookupError:                          # 그사이 끝났으면
            pass                                            # 무시
    try:
        p.wait(timeout=30)                                  # 정리될 때까지 잠시 대기
    except subprocess.TimeoutExpired:                       # 그래도 안 끝나면
        p.kill()                                            # 마지막 수단


def pid_alive(pid: int) -> bool:                            # 프로세스가 살아 있는지 (Windows에서 os.kill(pid, 0)은 프로세스를 끝내므로 쓰지 않음)
    if os.name == "nt":
        import ctypes                                       # Windows API
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(h)
        return bool(ok) and code.value == 259               # STILL_ACTIVE
    try:
        os.kill(int(pid), 0)                                # POSIX: 신호 0은 존재 확인만
        return True
    except OSError:
        return False


def kill_pid_tree(pid: int) -> None:                        # pid만 알 때 프로세스 트리 종료 (MCP 작업 취소)
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        try:
            os.killpg(os.getpgid(int(pid)), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def run_cmd(cmd: list[str] | str, cwd: Path, timeout: float | None = None, echo: bool = True,
            **popen_kw) -> int:                             # 도구를 실행하고 종료 코드를 돌려줌
    """명령 목록이면 Windows에서 win_cmdline으로 바꿔 실행. 시간 초과면 트리를 종료하고 124."""
    line = win_cmdline(cmd) if (os.name == "nt" and isinstance(cmd, list)) else cmd  # Windows는 문자열 명령줄
    if echo:                                                # 명령 출력
        print(">>", line if isinstance(line, str) else " ".join(line), flush=True)
    if os.name != "nt":                                     # POSIX: 새 세션으로 띄워 그룹 종료 가능하게
        popen_kw.setdefault("start_new_session", True)
    p = subprocess.Popen(line, cwd=cwd, **popen_kw)         # 실행 시작
    try:
        p.wait(timeout=timeout)                             # 끝날 때까지 대기 (시간 제한)
        return p.returncode                                 # 종료 코드
    except subprocess.TimeoutExpired:                       # 시간 초과
        kill_tree(p)                                        # 자식까지 모두 종료
        print(f"ERROR: timeout after {timeout}s (process tree killed)", flush=True)
        return TIMEOUT_RC                                   # 124


# --------------------------------------------------------------------------- #
# 결과 출처 (provenance)
# --------------------------------------------------------------------------- #
def _git(args: list[str], root: Path) -> str | None:       # git 명령 출력 (실패하면 None)
    try:
        r = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=30)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):            # git이 없거나 멈추면
        return None


def hw_hash(root: Path = ROOT) -> str | None:               # HW/ 내용 해시 (작업 트리 기준)
    """git이 추적하는 HW/ 파일의 (경로, 내용)을 정렬해 sha256. 커밋 여부와 상관없이
    지금 디스크에 있는 RTL을 나타내므로, 수정된 RTL로 낸 결과도 구별됨. 앞 16자리만 씀.
    텍스트 파일은 CRLF를 LF로 바꾼 뒤 해시함: checkout마다 줄바꿈 설정(core.autocrlf)이 달라도
    같은 RTL이면 같은 값 (2026-11-20 Jenkins 브랜치 빌드에서 로컬과 값이 달라 S11이 FAIL했던 문제)."""
    files = _git(["ls-files", "-z", "--", HW_DIR], root)    # 추적 중인 HW/ 파일 목록
    if files is None:                                       # git이 아니면
        return None
    h = hashlib.sha256()                                    # 해시 시작
    for rel in sorted(f for f in files.split("\0") if f):   # 경로 순서대로
        p = root / rel                                      # 절대 경로
        h.update(rel.encode("utf-8") + b"\0")               # 경로
        data = p.read_bytes() if p.exists() else b"<deleted>"  # 내용 (지워졌으면 표시)
        h.update(data if b"\0" in data else data.replace(b"\r\n", b"\n"))  # 텍스트는 줄바꿈을 LF로
        h.update(b"\0")                                     # 구분자
    return h.hexdigest()[:16]                               # 앞 16자리


def provenance(root: Path = ROOT) -> dict:                  # 결과 파일마다 남기는 출처 정보
    """commit: HEAD 커밋, dirty: 추적 파일이 수정됐는지, hw_hash: HW/ 내용 해시."""
    commit = _git(["rev-parse", "HEAD"], root)              # 전체 커밋 해시
    status = _git(["status", "--porcelain", "--untracked-files=no"], root)  # 수정된 추적 파일
    return {
        "commit": commit,                                   # 커밋
        "dirty": bool(status) if status is not None else None,  # 수정 여부
        "branch": _git(["rev-parse", "--abbrev-ref", "HEAD"], root),  # 브랜치
        "hw_hash": hw_hash(root),                           # RTL 내용 해시
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),         # 기록 시각
    }


def files_hash(paths: list[str | Path], extra: list[str] | None = None) -> str:  # 파일 내용 + 추가 문자열 해시
    """빌드 입력(소스 파일 내용과 define)이 바뀌었는지 비교할 때 씀."""
    h = hashlib.sha256()                                    # 해시 시작
    for p in sorted(str(x) for x in paths):                 # 경로 순서대로
        h.update(p.encode("utf-8") + b"\0")                 # 경로
        try:
            h.update(Path(p).read_bytes())                  # 내용
        except OSError:                                     # 없는 파일
            h.update(b"<missing>")                          # 표시
        h.update(b"\0")                                     # 구분자
    for e in extra or []:                                   # define 등
        h.update(e.encode("utf-8") + b"\0")
    return h.hexdigest()[:16]                               # 앞 16자리
