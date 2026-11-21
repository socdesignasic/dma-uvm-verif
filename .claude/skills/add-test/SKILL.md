---
name: add-test
description: 새 UVM 테스트 하나를 CLAUDE.md의 "테스트 추가 방법" 그대로 추가합니다(클래스 파일, 패키지 include, sim_cfg.json, plan.toml 기능, vplan.md 재생성, lint, seed 3개, 영향받는 회귀, gate static). 사용자가 테스트 추가를 요청하거나 다른 스킬(confirm-hypothesis, verify-stage)이 테스트를 만들 때 사용합니다.
---
# add-test: 테스트 하나 추가

입력: TB(unit 또는 top), 테스트 이름, 목적(어떤 기능, 어떤 검사 ID, 어떤 커버포인트). 이름은 CLAUDE.md와
docs/UVM_STRUCTURE.md의 규칙을 따릅니다. 일은 uvm-builder가 worktree에서 하고, 이 순서를 그대로 지킵니다.

1. **클래스:** 테스트 폴더에 테스트 이름과 같은 파일 하나, 클래스 하나. 기존 테스트에서 가장 가까운 것을 본떠
   설정값(configure)과 sequence만 바꿉니다. 자극은 sequence에 둡니다.
2. **패키지:** 그 폴더의 `*_test_pkg.sv`에 `` `include `` 한 줄.
3. **sim_cfg.json:** 그 TB의 `tests` 목록에 추가 (CI와 regress.py가 돌리는 목록).
4. **plan.toml:** 이 테스트가 확인하는 기능의 `tests`에 `"<tb>/<test>"`를 넣거나 새 기능을 만들고, `checks`와
   `covers`를 적습니다. 그다음 `python scripts/plan_check.py --write`.
5. **lint:** `lint`(workspace 지정). 에러는 CLAUDE.md의 XSim 주의사항을 봅니다.
6. **실행:** seed 1과 랜덤 seed 2개 이상. 판정과 rerun 명령을 남깁니다.
7. **회귀:** 영향받는 suite(unit이면 unit, top이면 top)를 `regress.py`로 돌려 fail 0인지 봅니다.
8. **정적 검사:** `python scripts/gate.py static` PASS. 검사 목록 기준선에 새 검사가 생겼으면 그대로 둡니다
   (기준선은 줄어들 때만 문제).
9. tb-reviewer 검토 뒤 병합은 사람이 정합니다. 커밋은 요청이 있을 때만.
