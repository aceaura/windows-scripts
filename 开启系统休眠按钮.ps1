powercfg /hibernate on
Write-Host "休眠功能已启用" -ForegroundColor Green

# 修改注册表显示休眠按钮
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
Set-ItemProperty -Path $regPath -Name "ShowHibernateOption" -Value 1 -Type DWord
Write-Host "休眠按钮已添加到电源菜单" -ForegroundColor Green

Write-Host "`n请注销或重启电脑后生效" -ForegroundColor Yellow