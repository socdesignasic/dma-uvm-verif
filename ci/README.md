# dma-uvm 로컬 Jenkins CI

이 PC에서 도는 전용 Jenkins controller이고, 포트는 **8090**입니다. 8080 포트는 따로 설치된
Jenkins Windows 서비스가 쓰고 있으며, 이 구성은 그 서비스를 건드리지 않습니다.
Jenkins 설정은 모두 코드입니다: `ci/jenkins.yaml` (JCasC) + `ci/plugins.txt` + `Jenkinsfile`.

## 시작 / 중지
```powershell
powershell -ExecutionPolicy Bypass -File ci\start-jenkins.ps1   # 처음 실행 때 플러그인 설치
powershell -ExecutionPolicy Bypass -File ci\stop-jenkins.ps1
```
- 화면: http://localhost:8090/job/dma-uvm/ (127.0.0.1에서만 접속 가능, 익명 접근 차단)
- 사용자 `admin`. 비밀번호는 `%USERPROFILE%\jenkins\home\secrets\casc\JENKINS_ADMIN_PASSWORD`에 있습니다
  (처음 시작할 때 생성).
- 재부팅 후 Jenkins는 자동으로 시작하지 않습니다. `start-jenkins.ps1`을 다시 실행하거나,
  로그온 작업으로 등록하세요.

| 경로 | 내용 |
|---|---|
| `%USERPROFILE%\jenkins\jenkins.war` | Jenkins 2.580.2 LTS (sha256 확인함) |
| `%USERPROFILE%\jenkins\home` | JENKINS_HOME (잡, 빌드, 플러그인, `jenkins.log`) |
| `...\home\secrets\casc\` | JCasC 비밀값: GitHub 토큰 (시작할 때마다 `gh auth token`으로 갱신), admin 비밀번호 |

비밀값은 JCasC가 `SECRETS`로 읽습니다. controller 환경 변수에 없으므로 빌드 단계에서 볼 수 없고,
git에도 들어가지 않습니다.

## 파이프라인 (`Jenkinsfile`)
| 계기 | 모드 | 실행 내용 |
|---|---|---|
| `main`에 push (SCM poll, 5분마다) | smoke | lint, unit 테스트 전부, top smoke 묶음, seed 1개 |
| 매일 02:00 무렵 | full | 모든 TB의 모든 테스트 × seed 5개 + 기능 커버리지 HTML |
| "Build with Parameters" | 둘 중 선택 | `MODE`, `SEEDS` 직접 지정 |

단계: Plan → Lint → Unit regression → Top regression → Coverage (full에서만).
결과: JUnit 추이 그래프 (XFAIL인 알려진 버그는 *skipped*로 표시), 보관된 `run.log`/`result.json`,
"Coverage <tb>" HTML 보고서. 실패마다 `rerun` 명령이 출력되고, 그 명령으로 로컬에서 재현됩니다:
```bash
python scripts/sim.py run --tb top --test dma_rand_test --seed 123456
```

## 노드 환경 (`ci/jenkins.yaml`에서 설정)
`PYTHON`, `XILINX_VIVADO`, `REGRESS_JOBS` (빌드 하나 안에서 병렬로 도는 xsim 수, 기본 6).
경로를 바꾸려면 `start-jenkins.ps1`에 파라미터를 넘기고 (예: `-RegressJobs 4`) 다시 시작하세요.

## FPGA 구현 / CD (`scripts/fpga.py`, `ci/vivado/`)
| 명령 | 내용 | 시간 |
|---|---|---|
| `python scripts/fpga.py ooc [--period 10]` | `dma_ip_top` 단독: 합성 + 배치 + 배선, 타이밍과 사용량 | 약 3분 |
| `python scripts/fpga.py system` | PS7 + DMA block design → `design_1_wrapper.bit` + `design_1_wrapper.xsa` | 약 10–20분 |

- RTL은 `HW/`에서만 가져옵니다. IP repo는 `HW/` + `ci/vivado/ip/`(component.xml, xgui)로 조립하므로,
  비트스트림에는 항상 검증한 RTL이 그대로 들어갑니다.
- `ci/vivado/bd/design_1.tcl`은 block design입니다. 손으로 만든 프로젝트를 읽기 전용으로 열어
  `ci/vivado/export_bd.tcl`로 한 번 export했습니다. PS7 설정이 명시돼 있어서 보드 파일이 필요 없습니다.
- 결과는 `out/fpga/<mode>/result.json`에 씁니다 (판정, WNS/WHS, 사용량, bit/xsa의 sha256).
  종료 코드 1 = 타이밍 위반, 2 = 빌드 오류.
- Jenkins: 모든 빌드에서 `ooc`를 실행합니다. nightly/full (또는 `BITSTREAM=true`)이면 `system`도 실행합니다.
  `.bit`/`.xsa`는 보관되고 **fingerprint**가 남아서, 보드 이미지가 어느 빌드와 커밋에서 나왔는지 추적할 수 있습니다.
- 보드 프로그래밍은 수동입니다 (XSA로 Vitis 또는 Hardware Manager 사용). CI에는 보드가 연결돼 있지 않습니다.

## 알려진 로그 메시지: "Selected Git installation does not exist. Using Default"
무해합니다. 일부러 그대로 뒀습니다.

- **위치:** SCM polling 로그와 `Declarative: Checkout SCM` 단계. 뒤에
  `The recommended git tool is: NONE`이 이어집니다.
- **원인 (git 플러그인 5.11.0, 바이트코드를 읽어 확인):** `GitToolChooser.determineSwitchOnSize`가
  저장소가 5 MB보다 작은 것을 보고 **JGit**을 추천하려고 합니다. 그래서 이름이 `jgit`인 git 설치를
  찾는데 (`GitUtils.resolveGitTool("jgit")`), `Default`만 있으므로 찾지 못하고 이 메시지를 출력합니다.
  추천은 `NONE`이 되고 잡 자체의 도구 `Default`(PATH의 `git.exe`)를 쓰므로, checkout과 polling은 정상입니다.
- 저장소 크기가 캐시된 뒤에만 나옵니다. Jenkins를 재시작한 직후의 poll에서는 안 나올 수 있습니다.
- **정정:** 커밋 `bca3c5d`의 메시지에는 이 경고가 `tool: git: home: "${GIT_EXE}"` 항목이 글자 그대로
  저장돼서 생겼다고 적혀 있습니다. 그것은 틀렸습니다. 고친 뒤에도 경고는 남았습니다 (빌드 #9).
  그래도 그 항목은 잘못된 경로였으므로 지운 것은 맞습니다.
- **없애려면** (동작이 바뀌므로 하지 않음): `ci/jenkins.yaml`에 `jgit` 설치를 추가해 작은 저장소는
  git CLI 대신 JGit으로 checkout하게 하거나, 잡의 git tool chooser를 끕니다.
