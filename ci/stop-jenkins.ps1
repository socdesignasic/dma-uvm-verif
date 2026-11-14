<#
  stop-jenkins.ps1 - stop the local Jenkins started by ci\start-jenkins.ps1
#>
param([string]$JenkinsDir = "$env:USERPROFILE\jenkins")
$pidFile = Join-Path $JenkinsDir "home\jenkins.pid"
if (-not (Test-Path $pidFile)) { Write-Host "no pid file ($pidFile)"; exit 0 }
$procId = [int](Get-Content $pidFile)
$p = Get-Process -Id $procId -ErrorAction SilentlyContinue
if ($p) { Stop-Process -Id $procId -Confirm:$false; Write-Host "stopped Jenkins (pid $procId)" }
else    { Write-Host "Jenkins (pid $procId) is not running" }
Remove-Item $pidFile -Confirm:$false
