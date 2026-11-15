<#
  stop-jenkins.ps1 - ci\start-jenkins.ps1로 시작한 로컬 Jenkins를 멈춥니다
#>
param([string]$JenkinsDir = "$env:USERPROFILE\jenkins")
$pidFile = Join-Path $JenkinsDir "home\jenkins.pid"
if (-not (Test-Path $pidFile)) { Write-Host "no pid file ($pidFile)"; exit 0 }
$procId = [int](Get-Content $pidFile)
$p = Get-Process -Id $procId -ErrorAction SilentlyContinue
if ($p) { Stop-Process -Id $procId -Confirm:$false; Write-Host "stopped Jenkins (pid $procId)" }
else    { Write-Host "Jenkins (pid $procId) is not running" }
Remove-Item $pidFile -Confirm:$false
