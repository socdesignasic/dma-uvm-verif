<#
  start-jenkins.ps1 - dma-uvm CI용 로컬 Jenkins controller를 시작합니다.

  사용법 (PowerShell):  powershell -ExecutionPolicy Bypass -File ci\start-jenkins.ps1
  그다음 http://localhost:8090 을 엽니다 (사용자: admin, 비밀번호: 아래에 출력됨)

  - Jenkins 실행 파일 위치:  $JenkinsDir  (jenkins.war, jenkins-plugin-manager.jar)
  - Jenkins 상태 위치:       $JenkinsDir\home  (JENKINS_HOME, git 저장소 밖)
  - 모든 설정은 ci\jenkins.yaml(Configuration as Code)에서 옵니다. 'dma-uvm' 잡은
    GitHub main의 Jenkinsfile로 빌드합니다.
  - 비밀값(`gh auth token`으로 얻은 GitHub 토큰, admin 비밀번호)은
    JENKINS_HOME\secrets\casc의 파일로 저장하고, JCasC가 SECRETS로 읽습니다.
    controller 환경 변수에 넣지 않으므로 빌드 단계에서 볼 수 없고, 저장소에도
    들어가지 않습니다. Jenkins는 토큰을 'github' credential로 암호화해 저장합니다.
  - 127.0.0.1에서만 접속을 받습니다.
#>
param(                                                      # 스크립트 인자 정의 시작
  [string]$JenkinsDir  = "$env:USERPROFILE\jenkins",        # Jenkins 실행 파일과 상태를 두는 디렉터리
  [string]$JavaExe     = "C:\Program Files\Java\jdk-25.0.5.0.3\bin\java.exe",  # Java 실행 파일
  [string]$PythonExe   = "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",  # 시뮬레이션 스크립트를 돌릴 Python
  [string]$VivadoDir   = "C:\Xilinx\Vivado\2022.2",         # Vivado 설치 위치
  [string]$GhExe       = "C:\Program Files\GitHub CLI\gh.exe",  # GitHub CLI (토큰을 얻는 데 사용)
  [string]$GithubRepo  = "socdesignasic/dma-uvm",           # 빌드할 GitHub 저장소
  [int]   $Port        = 8090,       # 8080은 Jenkins Windows 서비스가 사용 중
  [int]   $RegressJobs = 6,                                  # 회귀 병렬 실행 수
  [switch]$CatchUpNightly                                   # 마지막 nightly가 24시간보다 오래됐으면 full 빌드 한 번 (로그온 자동 시작용)
)                                                           # 인자 정의 끝
$ErrorActionPreference = "Stop"                             # 오류가 나면 바로 멈춤
$RepoCi = $PSScriptRoot                                     # 이 스크립트가 있는 ci 디렉터리
$War    = Join-Path $JenkinsDir "jenkins.war"               # Jenkins war 파일
$Pm     = Join-Path $JenkinsDir "jenkins-plugin-manager.jar"  # 플러그인 설치 도구
$JHome  = Join-Path $JenkinsDir "home"                      # JENKINS_HOME

foreach ($f in @($JavaExe, $War, $Pm, $PythonExe, $GhExe, "$VivadoDir\bin\xsim.bat")) {  # 필요한 파일마다
  if (-not (Test-Path $f)) { throw "missing: $f" }          # 없으면 오류로 멈춤
}                                                           # foreach 끝
# Jenkins는 기본 git 설치, 즉 PATH의 `git`을 사용 (jenkins.yaml에 tool 블록 없음)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git is not on PATH" }  # git이 PATH에 없으면 오류
New-Item -ItemType Directory -Force $JHome | Out-Null       # JENKINS_HOME 생성 (있으면 그대로)

# 이미 실행 중인가?
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue  # 포트를 이미 누가 듣고 있는지 확인
if ($busy) { Write-Host "Jenkins (or something else) already listens on port $Port."; exit 0 }  # 있으면 안내 후 종료

# ---- 플러그인: ci\plugins.txt가 바뀌면 (다시) 설치 ----
$pluginsTxt = Join-Path $RepoCi "plugins.txt"               # 플러그인 목록 파일
$hashFile   = Join-Path $JHome "plugins.sha256"             # 마지막으로 설치한 목록의 해시 파일
$hash = (Get-FileHash $pluginsTxt -Algorithm SHA256).Hash   # 지금 목록의 SHA256 해시
if (-not (Test-Path $hashFile) -or (Get-Content $hashFile) -ne $hash) {  # 해시 파일이 없거나 해시가 다르면
  Write-Host "Installing plugins from $pluginsTxt ..."      # 설치 안내
  # 플러그인 설치 도구 실행: war 기준으로 plugins 디렉터리에 목록의 플러그인을 내려받음
  & $JavaExe -jar $Pm --war $War --plugin-download-directory (Join-Path $JHome "plugins") `
                     --plugin-file $pluginsTxt
  if ($LASTEXITCODE -ne 0) { throw "plugin installation failed" }  # 설치 실패면 멈춤
  Set-Content -Path $hashFile -Value $hash -Encoding ascii  # 새 해시 저장
}                                                           # if 끝

# ---- JCasC용 비밀값: 변수마다 파일 하나, 환경 변수가 아니라 SECRETS로 읽음 ----
$secrets = Join-Path $JHome "secrets\casc"                  # 비밀값 디렉터리
New-Item -ItemType Directory -Force $secrets | Out-Null     # 생성 (있으면 그대로)
$pwFile = Join-Path $secrets "JENKINS_ADMIN_PASSWORD"       # admin 비밀번호 파일
if (-not (Test-Path $pwFile)) {          # admin 비밀번호: 한 번만 생성
  $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'  # 헷갈리는 글자(0, O, 1, l, I)를 뺀 문자 집합
  [IO.File]::WriteAllText($pwFile, (-join (1..20 | ForEach-Object { $chars | Get-Random })))  # 20자 랜덤 비밀번호를 파일로 저장
}                                                           # if 끝
$token = (& $GhExe auth token).Trim()                       # gh에서 GitHub 토큰 얻기
if (-not $token) { throw "gh is not logged in (run: gh auth login)" }  # 없으면 로그인 안내 후 멈춤
[IO.File]::WriteAllText((Join-Path $secrets "GITHUB_TOKEN"), $token)   # 시작할 때마다 갱신
Remove-Variable token                                       # 메모리에서 토큰 변수 삭제

# ---- ci\jenkins.yaml이 쓰는 비밀이 아닌 환경 값 ----
$env:JENKINS_HOME           = $JHome                        # Jenkins 상태 디렉터리
$env:CASC_JENKINS_CONFIG    = Join-Path $RepoCi "jenkins.yaml"  # JCasC 설정 파일
$env:SECRETS                = $secrets                      # JCasC가 비밀값을 읽을 디렉터리
$env:GITHUB_USER            = (& $GhExe api user -q .login).Trim()  # GitHub 사용자 이름
$env:GITHUB_REPO            = $GithubRepo                   # 저장소 이름
$env:PYTHON_EXE             = $PythonExe                    # Python 경로 (노드 환경으로 전달)
$env:XILINX_VIVADO          = $VivadoDir                    # Vivado 경로
$env:REGRESS_JOBS           = "$RegressJobs"                # 회귀 병렬 실행 수
$env:JENKINS_PORT           = "$Port"                       # 포트 (Jenkins URL 설정용)

$log = Join-Path $JHome "jenkins.log"                       # Jenkins 로그 파일
# stdout/stderr를 리디렉션하지 않음: 리디렉션된 자식 프로세스가 호출자의 콘솔 핸들을
# 계속 잡고 있어 스크립트가 끝나지 않음. Jenkins는 --logfile로 자기 로그를 씀.
$jargs = @("-Djenkins.install.runSetupWizard=false",        # Java 인자: 설치 마법사 끄기
          "-jar", "`"$War`"", "--httpPort=$Port", "--httpListenAddress=127.0.0.1",  # war 실행, 포트, 로컬 접속만 허용
          "--logfile=`"$log`"")                             # 로그 파일
$p = Start-Process -FilePath $JavaExe -ArgumentList $jargs -WindowStyle Hidden -PassThru  # 창 없이 백그라운드로 시작
Set-Content -Path (Join-Path $JHome "jenkins.pid") -Value $p.Id -Encoding ascii  # pid 저장 (stop-jenkins.ps1이 사용)

Write-Host "Jenkins starting (pid $($p.Id)), log: $log"     # 시작 안내
Write-Host "URL      : http://localhost:$Port/job/dma-uvm/"  # 잡 URL
Write-Host "User     : admin"                               # 사용자 이름
Write-Host "Password : stored in $pwFile"                   # 비밀번호 파일 위치
if ($CatchUpNightly) {                                       # 밀린 nightly 보충 (ci/install-autostart.ps1이 켬)
  & $PythonExe (Join-Path $RepoCi "catchup_nightly.py") --port $Port --password-file $pwFile
}
