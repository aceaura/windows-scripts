$regPath = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"

New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name "(Default)" -Value ""

Write-Host "Win11 右键菜单已恢复为经典样式" -ForegroundColor Green
Write-Host "请重启资源管理器或重启电脑后生效" -ForegroundColor Yellow
