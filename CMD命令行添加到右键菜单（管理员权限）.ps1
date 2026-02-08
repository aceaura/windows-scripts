$paths = @(
    "HKCR:\Directory\shell\OpenCmdHere",
    "HKCR:\Directory\Background\shell\OpenCmdHere",
    "HKCR:\Drive\shell\OpenCmdHere",
    "HKCR:\LibraryFolder\background\shell\OpenCmdHere"
)

# 挂载 HKCR 驱动器
if (-not (Test-Path "HKCR:")) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
}

foreach ($path in $paths) {
    New-Item -Path $path -Force | Out-Null
    Set-ItemProperty -Path $path -Name "(Default)" -Value "在此处打开命令行"
    Set-ItemProperty -Path $path -Name "Icon" -Value "cmd.exe"

    New-Item -Path "$path\command" -Force | Out-Null
    Set-ItemProperty -Path "$path\command" -Name "(Default)" -Value 'cmd.exe /s /k pushd "%V"'
}

Write-Host "CMD 命令行已添加到右键菜单" -ForegroundColor Green
