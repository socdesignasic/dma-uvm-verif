<#
  stop-jenkins.ps1 - ci\start-jenkins.ps1로 시작한 로컬 Jenkins를 멈춥니다
#>
param([string]$JenkinsDir = "$env:USERPROFILE\jenkins")     # Jenkins 디렉터리 인자
$pidFile = Join-Path $JenkinsDir "home\jenkins.pid"         # pid 파일 경로
if (-not (Test-Path $pidFile)) { Write-Host "no pid file ($pidFile)"; exit 0 }  # pid 파일이 없으면 안내 후 종료
$procId = [int](Get-Content $pidFile)                       # pid 읽기
$p = Get-Process -Id $procId -ErrorAction SilentlyContinue  # 그 프로세스 찾기 (없으면 null)
if ($p) { Stop-Process -Id $procId -Confirm:$false; Write-Host "stopped Jenkins (pid $procId)" }  # 있으면 멈추고 안내
else    { Write-Host "Jenkins (pid $procId) is not running" }  # 없으면 안내
Remove-Item $pidFile -Confirm:$false                        # pid 파일 삭제
