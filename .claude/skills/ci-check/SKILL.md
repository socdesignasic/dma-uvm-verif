---
name: ci-check
description: Jenkins CI 결과를 확인하고, 실패가 있으면 분류까지 합니다. ci-watcher로 빌드 상태와 실패 목록을 받고, 실패마다 sim-triage로 분류합니다. 코드는 고치지 않습니다. 사용자가 "CI 어때", "빌드 왜 실패했어", "브랜치 빌드 확인해" 처럼 CI 상태나 실패 원인을 물을 때 사용합니다.
---
# ci-check: CI 확인과 실패 분류

코드는 고치지 않습니다. 결과와 분류만 보고합니다. 고칠 일이 생기면 사용자에게 묻고 verify-stage나
file-rtl-bug로 넘깁니다.

1. **상태:** ci-watcher에 대상(잡 이름과 빌드 번호, 없으면 main 잡과 지금 브랜치의 최근 빌드)을 줍니다.
   빌드 결과, 단계, sign-off의 FAIL 기준, GitHub 커밋 상태, rerun 명령이 붙은 실패 목록을 받습니다.
2. **분류:** 실패 실행마다 sim-triage를 띄웁니다(서로 다른 tb/test는 병렬로). 같은 test의 여러 seed는 하나로 묶어
   대표 seed 하나만 맡깁니다.
3. **sign-off FAIL(UNSTABLE):** 기준 ID별로 원인을 적습니다. 결과 파일 문제(출처, 해시, 빠진 TB)는 로컬에서
   `python scripts/signoff.py --level <수준>`으로 재현해 봅니다.
4. **보고:** 표 하나(잡, 빌드, 커밋, 결과, 실패 수)와 실패별 분류(TB / RTL / 알려진 버그 / 환경 / 모름),
   증거 한 줄, rerun 명령, 다음 행동 제안. RTL 버그로 보이면 "file-rtl-bug로 등록할지" 묻습니다.
