---
name: sync-public
description: 비공개 저장소(dma-uvm)의 커밋된 내용을 공개 저장소(dma-uvm-verif)에 반영합니다. RTL과 받은 자료를 빼고 원본 IP 이름 접두어를 지운 뒤 금지어와 개인 경로를 검사하고, diff를 사용자에게 보여 확인을 받은 다음 GitHub noreply 작성자로 커밋합니다. 사용자가 공개 저장소 반영을 요청할 때만 사용합니다.
---
# sync-public: 공개 저장소 반영 절차

정해진 변환과 검사는 `scripts/sync_public.py`가 합니다. 이 스킬은 순서와 사람 확인 지점만 정합니다.
사용자가 요청할 때만 진행하고, push 전에 반드시 확인을 받습니다.

## 지켜야 할 것
- 공개 저장소에는 RTL(`HW/`), `SW/`, `uvm_reference/`, `ci/vivado/ip/`가 없고 원본 IP 이름 접두어(`scripts/sync_public.py`의 PREFIX)가 어디에도 없습니다.
- 저장소 규칙의 금지어(`.githooks/check_commit.py`)와 개인 경로, 개인 이메일을 올리지 않습니다.
- 공개 저장소 전용 파일은 건드리지 않습니다: 공개 저장소의 README.md, .gitattributes, docs/index.html, docs/.nojekyll.
- 커밋 작성자는 GitHub noreply 주소이고, Claude 트레일러를 붙이지 않습니다.
- 공개 저장소의 이력을 다시 쓰지 않습니다(force push 금지). 필요하면 사용자에게 먼저 묻습니다.

## 순서
1. 비공개 저장소의 반영할 내용이 커밋돼 있는지 확인합니다(`git status`). 스크립트는 HEAD만 옮깁니다.
2. 공개 저장소를 scratchpad에 새로 받습니다:
   `gh repo clone socdesignasic/dma-uvm-verif <scratchpad>/public`
3. 미리 보기: `python scripts/sync_public.py --public-dir <scratchpad>/public`
   - `PROBLEM` 줄이 있으면 멈추고, 비공개 저장소에서 고칠 곳을 사용자에게 보고합니다.
4. 적용: `python scripts/sync_public.py --public-dir <scratchpad>/public --apply`
5. **사용자 확인:** `git -C <scratchpad>/public diff --stat`과 주요 변경을 보여 주고, 커밋 메시지 초안과 함께
   진행 여부를 묻습니다.
6. 확인을 받으면 noreply 작성자로 커밋합니다:
   `gh api user -q '"\(.id)+\(.login)@users.noreply.github.com"'`로 주소를 얻어
   `git -C <scratchpad>/public -c user.name=<login> -c user.email=<noreply> commit -am "<메시지>"`
   (새 파일이 있으면 먼저 `git -C <scratchpad>/public add -A`)
7. push도 사용자가 요청한 경우에만 합니다: `git -C <scratchpad>/public push`
8. 결과(공개 커밋 해시, 바뀐 파일 수)를 보고합니다.
