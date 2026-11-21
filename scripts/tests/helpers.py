"""테스트용 임시 저장소: 실제 verif/를 복사하고, 가설 근거 파일 자리에 빈 HW/ 파일을 둠."""
import json
import shutil
import tempfile
import tomllib
from pathlib import Path

from common import ROOT


class TempRepo:
    def __init__(self):
        self.td = tempfile.TemporaryDirectory()
        self.root = Path(self.td.name)
        shutil.copytree(ROOT / "verif", self.root / "verif")
        plan = tomllib.loads((ROOT / "verif" / "plan.toml").read_text(encoding="utf-8"))
        for h in plan.get("hypotheses", []):                # 가설 근거 파일 자리 (RTL 내용은 복사하지 않음)
            for e in h.get("evidence", []):
                p = self.root / e.split(":")[0]
                p.parent.mkdir(parents=True, exist_ok=True)
                p.touch()

    def cfg(self) -> dict:
        return json.loads((self.root / "verif" / "sim_cfg.json").read_text(encoding="utf-8"))

    def write_cfg(self, cfg: dict):
        (self.root / "verif" / "sim_cfg.json").write_text(json.dumps(cfg, indent=2, ensure_ascii=False),
                                                          encoding="utf-8")

    def edit(self, rel: str, old: str, new: str):
        p = self.root / rel
        s = p.read_text(encoding="utf-8")
        assert old in s, (rel, old)
        p.write_text(s.replace(old, new, 1), encoding="utf-8")

    def cleanup(self):
        self.td.cleanup()
