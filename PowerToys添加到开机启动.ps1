$powerToysPath = "C:\Program Files\PowerToys\PowerToys.exe"
$startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"

$ws = New-Object -ComObject WScript.Shell
$shortcut = $ws.CreateShortcut("$startupFolder\PowerToys.lnk")
$shortcut.TargetPath = $powerToysPath
$shortcut.Save()

Write-Host "PowerToys 已添加到开机启动" -ForegroundColor Green
