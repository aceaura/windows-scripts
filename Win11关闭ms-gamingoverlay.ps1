$gameDVRPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"
$gameConfigPath = "HKCU:\System\GameConfigStore"

if (-not (Test-Path $gameDVRPath)) {
    New-Item -Path $gameDVRPath -Force | Out-Null
}
Set-ItemProperty -Path $gameDVRPath -Name "AppCaptureEnabled" -Value 0 -Type DWord

if (-not (Test-Path $gameConfigPath)) {
    New-Item -Path $gameConfigPath -Force | Out-Null
}
Set-ItemProperty -Path $gameConfigPath -Name "GameDVR_Enabled" -Value 0 -Type DWord

Write-Host "ms-gamingoverlay 已关闭" -ForegroundColor Green
