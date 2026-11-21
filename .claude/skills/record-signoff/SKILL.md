---
name: record-signoff
description: Jenkins 빌드 하나의 결과를 signoff.py로 판정하고 verif/SIGNOFF.md의 판정 기록 표(smoke 추이 또는 nightly 추이)에 한 줄을 넣습니다. 계산은 scripts/record_signoff.py가 하고, 이 스킬은 빌드 정보 확인과 사람 확인 지점만 맡습니다. 사용자가 "이 빌드 기록해", "nightly 결과 정리해"라고 할 때 사용합니다.
---
# record-signoff: 빌드 판정 기록

Jenkins 작업 폴더에는 그 잡의 **마지막 빌드 결과만** 남습니다. 기록은 빌드가 끝난 직후에 합니다.

1. **빌드 정보:** ci-watcher(또는 Jenkins MCP `getBuild`)로 잡, 빌드 번호, 결과, 걸린 시간, 커밋, 모드(smoke/full)를
   확인합니다. 그 빌드가 **끝났고** 그 잡의 마지막 빌드인지 봅니다. 다음 빌드가 돌기 시작했으면 작업 폴더의
   `out/`이 지워졌거나 다른 빌드 것이므로 멈춥니다.
2. **미리 보기:**
   `python scripts/record_signoff.py --root <Jenkins 작업 폴더> --build "#<번호>" --mode <smoke|full>
    --result <결과> --minutes <분> --dry-run`
   작업 폴더: `<JENKINS_HOME>/workspace/dma-uvm`(main) 또는 `<JENKINS_HOME>/workspace/dma-uvm-branches_<브랜치>`.
   판정 결과와 넣을 줄을 사용자에게 보여 줍니다. 판정은 스크립트가 signoff.py로 직접 계산한 값만 씁니다.
3. **기록:** 확인을 받으면 `--dry-run` 없이 다시 실행해 SIGNOFF.md에 넣습니다. 표 아래에 특이사항이 있으면
   (새 FAIL 기준, 처음 나온 단계 등) 한 줄 메모를 덧붙입니다.
4. **release 판정**은 이 스킬로 하지 않습니다. 보드 시험 결과가 필요하므로 사람이 `signoff.py --level release`를 돌리고
   SIGNOFF.md의 release 절을 직접 씁니다.
5. 커밋은 사용자가 요청할 때만 합니다.
