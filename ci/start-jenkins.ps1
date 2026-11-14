<#
  start-jenkins.ps1 - start the local Jenkins controller for dma-uvm CI.

  Usage (PowerShell):  powershell -ExecutionPolicy Bypass -File ci\start-jenkins.ps1
  Then open http://localhost:8090  (user: admin, password: printed below)

  - Jenkins binaries live in  $JenkinsDir  (jenkins.war, jenkins-plugin-manager.jar)
  - Jenkins state lives in   $JenkinsDir\home  (JENKINS_HOME, outside the git repo)
  - All configuration comes from ci\jenkins.yaml (Configuration as Code); the job
    'dma-uvm' builds Jenkinsfile from GitHub main.
  - Secrets (GitHub token from `gh auth token`, admin password) go to files in
    JENKINS_HOME\secrets\casc, which JCasC reads through SECRETS. They are NOT put in
    the controller's environment, so build steps cannot see them, and they never
    enter the repository. Jenkins stores the token encrypted as credential 'github'.
  - Listens on 127.0.0.1 only.
#>
param(
  [string]$JenkinsDir  = "$env:USERPROFILE\jenkins",
  [string]$JavaExe     = "C:\Program Files\Java\jdk-25.0.5.0.3\bin\java.exe",
  [string]$PythonExe   = "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
  [string]$VivadoDir   = "C:\Xilinx\Vivado\2022.2",
  [string]$GhExe       = "C:\Program Files\GitHub CLI\gh.exe",
  [string]$GithubRepo  = "socdesignasic/dma-uvm",
  [int]   $Port        = 8090,       # 8080 is taken by the Jenkins Windows service
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
# Jenkins uses its default git installation, i.e. `git` on PATH (no tool block in jenkins.yaml)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git is not on PATH" }
New-Item -ItemType Directory -Force $JHome | Out-Null

# already running?
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) { Write-Host "Jenkins (or something else) already listens on port $Port."; exit 0 }

# ---- plugins: (re)install when ci\plugins.txt changes ----
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

# ---- secrets for JCasC: one file per variable, read via SECRETS (not env) ----
$secrets = Join-Path $JHome "secrets\casc"
New-Item -ItemType Directory -Force $secrets | Out-Null
$pwFile = Join-Path $secrets "JENKINS_ADMIN_PASSWORD"
if (-not (Test-Path $pwFile)) {          # admin password: generated once
  $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
  [IO.File]::WriteAllText($pwFile, (-join (1..20 | ForEach-Object { $chars | Get-Random })))
}
$token = (& $GhExe auth token).Trim()
if (-not $token) { throw "gh is not logged in (run: gh auth login)" }
[IO.File]::WriteAllText((Join-Path $secrets "GITHUB_TOKEN"), $token)   # refreshed every start
Remove-Variable token

# ---- non-secret environment consumed by ci\jenkins.yaml ----
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
# No stdout/stderr redirection: a redirected child keeps the caller's console handles
# open and the script never returns. Jenkins writes its own log via --logfile.
$jargs = @("-Djenkins.install.runSetupWizard=false",
          "-jar", "`"$War`"", "--httpPort=$Port", "--httpListenAddress=127.0.0.1",
          "--logfile=`"$log`"")
$p = Start-Process -FilePath $JavaExe -ArgumentList $jargs -WindowStyle Hidden -PassThru
Set-Content -Path (Join-Path $JHome "jenkins.pid") -Value $p.Id -Encoding ascii

Write-Host "Jenkins starting (pid $($p.Id)), log: $log"
Write-Host "URL      : http://localhost:$Port/job/dma-uvm/"
Write-Host "User     : admin"
Write-Host "Password : stored in $pwFile"
