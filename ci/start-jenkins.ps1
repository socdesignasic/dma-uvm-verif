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
param(
  [string]$JenkinsDir  = "$env:USERPROFILE\jenkins",
  [string]$JavaExe     = "C:\Program Files\Java\jdk-25.0.5.0.3\bin\java.exe",
  [string]$PythonExe   = "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
  [string]$VivadoDir   = "C:\Xilinx\Vivado\2022.2",
  [string]$GhExe       = "C:\Program Files\GitHub CLI\gh.exe",
  [string]$GithubRepo  = "socdesignasic/dma-uvm",
  [int]   $Port        = 8090,       # 8080은 Jenkins Windows 서비스가 사용 중
  [int]   $RegressJobs = 6
)
$ErrorActionPreference = "Stop"
$RepoCi = $PSScriptRoot
$War    = Join-Path $JenkinsDir "jenkins.war"
$Pm     = Join-Path $JenkinsDir "jenkins-plugin-manager.jar"
$JHome  = Join-Path $JenkinsDir "home"

foreach ($f in @($JavaExe, $War, $Pm, $PythonExe, $GhExe, "$VivadoDir\bin\xsim.bat")) {
  if (-not (Test-Path $f)) { throw "missing: $f" }
}
# Jenkins는 기본 git 설치, 즉 PATH의 `git`을 사용 (jenkins.yaml에 tool 블록 없음)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git is not on PATH" }
New-Item -ItemType Directory -Force $JHome | Out-Null

# 이미 실행 중인가?
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) { Write-Host "Jenkins (or something else) already listens on port $Port."; exit 0 }

# ---- 플러그인: ci\plugins.txt가 바뀌면 (다시) 설치 ----
$pluginsTxt = Join-Path $RepoCi "plugins.txt"
$hashFile   = Join-Path $JHome "plugins.sha256"
$hash = (Get-FileHash $pluginsTxt -Algorithm SHA256).Hash
if (-not (Test-Path $hashFile) -or (Get-Content $hashFile) -ne $hash) {
  Write-Host "Installing plugins from $pluginsTxt ..."
  & $JavaExe -jar $Pm --war $War --plugin-download-directory (Join-Path $JHome "plugins") `
                     --plugin-file $pluginsTxt
  if ($LASTEXITCODE -ne 0) { throw "plugin installation failed" }
  Set-Content -Path $hashFile -Value $hash -Encoding ascii
}

# ---- JCasC용 비밀값: 변수마다 파일 하나, 환경 변수가 아니라 SECRETS로 읽음 ----
$secrets = Join-Path $JHome "secrets\casc"
New-Item -ItemType Directory -Force $secrets | Out-Null
$pwFile = Join-Path $secrets "JENKINS_ADMIN_PASSWORD"
if (-not (Test-Path $pwFile)) {          # admin 비밀번호: 한 번만 생성
  $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
  [IO.File]::WriteAllText($pwFile, (-join (1..20 | ForEach-Object { $chars | Get-Random })))
}
$token = (& $GhExe auth token).Trim()
if (-not $token) { throw "gh is not logged in (run: gh auth login)" }
[IO.File]::WriteAllText((Join-Path $secrets "GITHUB_TOKEN"), $token)   # 시작할 때마다 갱신
Remove-Variable token

# ---- ci\jenkins.yaml이 쓰는 비밀이 아닌 환경 값 ----
$env:JENKINS_HOME           = $JHome
$env:CASC_JENKINS_CONFIG    = Join-Path $RepoCi "jenkins.yaml"
$env:SECRETS                = $secrets
$env:GITHUB_USER            = (& $GhExe api user -q .login).Trim()
$env:GITHUB_REPO            = $GithubRepo
$env:PYTHON_EXE             = $PythonExe
$env:XILINX_VIVADO          = $VivadoDir
$env:REGRESS_JOBS           = "$RegressJobs"
$env:JENKINS_PORT           = "$Port"

$log = Join-Path $JHome "jenkins.log"
# stdout/stderr를 리디렉션하지 않음: 리디렉션된 자식 프로세스가 호출자의 콘솔 핸들을
# 계속 잡고 있어 스크립트가 끝나지 않음. Jenkins는 --logfile로 자기 로그를 씀.
$jargs = @("-Djenkins.install.runSetupWizard=false",
          "-jar", "`"$War`"", "--httpPort=$Port", "--httpListenAddress=127.0.0.1",
          "--logfile=`"$log`"")
$p = Start-Process -FilePath $JavaExe -ArgumentList $jargs -WindowStyle Hidden -PassThru
Set-Content -Path (Join-Path $JHome "jenkins.pid") -Value $p.Id -Encoding ascii

Write-Host "Jenkins starting (pid $($p.Id)), log: $log"
Write-Host "URL      : http://localhost:$Port/job/dma-uvm/"
Write-Host "User     : admin"
Write-Host "Password : stored in $pwFile"
