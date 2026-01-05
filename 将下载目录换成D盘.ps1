$RegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
Set-ItemProperty -Path $RegPath -Name "{374DE290-123F-4565-9164-39C4925E467B}" -Value "D:\"
Stop-Process -Name explorer -Force
Start-Process explorer