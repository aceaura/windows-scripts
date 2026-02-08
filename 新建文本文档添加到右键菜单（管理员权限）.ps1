if (-not (Test-Path "HKCR:")) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
}

# 设置 .txt 关联
New-Item -Path "HKCR:\.txt" -Force | Out-Null
Set-ItemProperty -Path "HKCR:\.txt" -Name "(Default)" -Value "txtfile"
Set-ItemProperty -Path "HKCR:\.txt" -Name "Content Type" -Value "text/plain"

# 添加 ShellNew 以启用右键新建
New-Item -Path "HKCR:\.txt\ShellNew" -Force | Out-Null
Set-ItemProperty -Path "HKCR:\.txt\ShellNew" -Name "NullFile" -Value ""

# 设置 txtfile 类型
New-Item -Path "HKCR:\txtfile" -Force | Out-Null
Set-ItemProperty -Path "HKCR:\txtfile" -Name "(Default)" -Value "文本文档"

New-Item -Path "HKCR:\txtfile\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "HKCR:\txtfile\shell\open\command" -Name "(Default)" -Value "NOTEPAD.EXE %1"

Write-Host "新建文本文档已添加到右键菜单" -ForegroundColor Green
