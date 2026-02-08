$label = "获取超级管理员权限"
$icon = "C:\Windows\System32\imageres.dll,-78"
$fileCmd = 'cmd.exe /c takeown /f "%1" && icacls "%1" /grant administrators:F'
$dirCmd = 'cmd.exe /c takeown /f "%1" /r /d y && icacls "%1" /grant administrators:F /t'

# 文件右键（用 Registry:: 前缀避免 * 被当通配符）
$starRunas = "Registry::HKEY_CLASSES_ROOT\*\shell\runas"
$starCmd = "Registry::HKEY_CLASSES_ROOT\*\shell\runas\command"
Remove-Item -LiteralPath $starRunas -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $starRunas -Force | Out-Null
Set-ItemProperty -LiteralPath $starRunas -Name "(Default)" -Value $label
Set-ItemProperty -LiteralPath $starRunas -Name "Icon" -Value $icon
Set-ItemProperty -LiteralPath $starRunas -Name "NoWorkingDirectory" -Value ""
New-Item -Path $starCmd -Force | Out-Null
Set-ItemProperty -LiteralPath $starCmd -Name "(Default)" -Value $fileCmd
Set-ItemProperty -LiteralPath $starCmd -Name "IsolatedCommand" -Value $fileCmd

# 文件夹右键
$dirRunas = "Registry::HKEY_CLASSES_ROOT\Directory\shell\runas"
$dirRunasCmd = "Registry::HKEY_CLASSES_ROOT\Directory\shell\runas\command"
Remove-Item -LiteralPath $dirRunas -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $dirRunas -Force | Out-Null
Set-ItemProperty -LiteralPath $dirRunas -Name "(Default)" -Value $label
Set-ItemProperty -LiteralPath $dirRunas -Name "Icon" -Value $icon
Set-ItemProperty -LiteralPath $dirRunas -Name "NoWorkingDirectory" -Value ""
New-Item -Path $dirRunasCmd -Force | Out-Null
Set-ItemProperty -LiteralPath $dirRunasCmd -Name "(Default)" -Value $dirCmd
Set-ItemProperty -LiteralPath $dirRunasCmd -Name "IsolatedCommand" -Value $dirCmd

# DLL 文件右键
$dllShell = "Registry::HKEY_CLASSES_ROOT\dllfile\shell"
$dllRunas = "Registry::HKEY_CLASSES_ROOT\dllfile\shell\runas"
$dllCmd = "Registry::HKEY_CLASSES_ROOT\dllfile\shell\runas\command"
Remove-Item -LiteralPath $dllShell -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $dllRunas -Force | Out-Null
Set-ItemProperty -LiteralPath $dllRunas -Name "(Default)" -Value $label
Set-ItemProperty -LiteralPath $dllRunas -Name "HasLUAShield" -Value ""
Set-ItemProperty -LiteralPath $dllRunas -Name "NoWorkingDirectory" -Value ""
New-Item -Path $dllCmd -Force | Out-Null
Set-ItemProperty -LiteralPath $dllCmd -Name "(Default)" -Value $fileCmd
Set-ItemProperty -LiteralPath $dllCmd -Name "IsolatedCommand" -Value $fileCmd

# 驱动器右键
$driveRunas = "Registry::HKEY_CLASSES_ROOT\Drive\shell\runas"
$driveCmd = "Registry::HKEY_CLASSES_ROOT\Drive\shell\runas\command"
Remove-Item -LiteralPath $driveRunas -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $driveRunas -Force | Out-Null
Set-ItemProperty -LiteralPath $driveRunas -Name "(Default)" -Value $label
Set-ItemProperty -LiteralPath $driveRunas -Name "Icon" -Value $icon
Set-ItemProperty -LiteralPath $driveRunas -Name "NoWorkingDirectory" -Value ""
New-Item -Path $driveCmd -Force | Out-Null
Set-ItemProperty -LiteralPath $driveCmd -Name "(Default)" -Value $dirCmd
Set-ItemProperty -LiteralPath $driveCmd -Name "IsolatedCommand" -Value $dirCmd

Write-Host "获取超级管理员权限已添加到右键菜单" -ForegroundColor Green
