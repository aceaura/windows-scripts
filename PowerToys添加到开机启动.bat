@echo off
set POWERTOYS_PATH="C:\Program Files\PowerToys\PowerToys.exe"
set STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup

powershell "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('%STARTUP_FOLDER%\PowerToys.lnk'); $s.TargetPath = '%POWERTOYS_PATH%'; $s.Save()"

echo PowerToys added to startup