<#
  install-autostart.ps1 - 로그온할 때 dma-uvm Jenkins(8090)를 자동으로 띄우는 작업 스케줄러 항목을 등록합니다.
  사용법 (PowerShell):  powershell -ExecutionPolicy Bypass -File ci\install-autostart.ps1
  지우기:               powershell -ExecutionPolicy Bypass -File ci\install-autostart.ps1 -Remove

  - 작업 이름: dma-uvm-jenkins (현재 사용자, 로그온 시, 관리자 권한 없음)
  - 실행: ci\start-jenkins.ps1 -CatchUpNightly  (이미 떠 있으면 아무것도 안 함, 밀린 nightly는 한 번 보충)
  - 8080 포트의 Jenkins Windows 서비스는 건드리지 않습니다.
#>
param([switch]$Remove)
$ErrorActionPreference = "Stop"
$Name = "dma-uvm-jenkins"
if ($Remove) {
  Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "removed scheduled task $Name"
  exit 0
}
$start = Join-Path $PSScriptRoot "start-jenkins.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$start`" -CatchUpNightly" `
  -WorkingDirectory (Split-Path $PSScriptRoot -Parent)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable
Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings `
  -Description "dma-uvm local Jenkins (port 8090) at logon" -Force | Out-Null
Write-Host "registered scheduled task $Name (at logon: $start -CatchUpNightly)"
