#Requires -RunAsAdministrator
# ============================================================
# 修改中文用户名路径为英文
# 使用方法：以内置 Administrator 账户登录后，以管理员身份运行
# ============================================================

param(
    [string]$NewName = ""
)

# ---- 检查是否以内置 Administrator 登录 ----
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($currentUser -notlike "*\Administrator") {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " 请先用内置 Administrator 账户登录后再运行！" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host " 步骤：" -ForegroundColor Yellow
    Write-Host " 1. 以管理员身份打开 PowerShell" -ForegroundColor Yellow
    Write-Host " 2. 运行: net user Administrator /active:yes" -ForegroundColor Yellow
    Write-Host " 3. 注销当前账户，登录 Administrator" -ForegroundColor Yellow
    Write-Host " 4. 再次运行本脚本" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

# ---- 列出所有非系统用户，找出中文路径的 ----
$profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$profiles = @()

Get-ChildItem $profileListPath | ForEach-Object {
    $sid = $_.PSChildName
    # 跳过短 SID（系统账户）
    if ($sid.Length -lt 20) { return }
    $profilePath = (Get-ItemProperty $_.PSPath).ProfileImagePath
    if (-not $profilePath) { return }
    $folderName = Split-Path $profilePath -Leaf
    # 检测是否包含非 ASCII 字符
    if ($folderName -match '[^\x00-\x7F]') {
        $profiles += [PSCustomObject]@{
            SID         = $sid
            RegPath     = $_.PSPath
            ProfilePath = $profilePath
            FolderName  = $folderName
        }
    }
}

if ($profiles.Count -eq 0) {
    Write-Host "未找到包含中文的用户路径，无需修改。" -ForegroundColor Green
    Read-Host "按回车退出"
    exit 0
}

# ---- 显示找到的中文路径用户 ----
Write-Host "`n找到以下中文路径用户：" -ForegroundColor Cyan
for ($i = 0; $i -lt $profiles.Count; $i++) {
    Write-Host "  [$i] $($profiles[$i].ProfilePath)" -ForegroundColor White
}

# ---- 选择要修改的用户 ----
if ($profiles.Count -eq 1) {
    $selected = $profiles[0]
    Write-Host "`n将修改: $($selected.ProfilePath)" -ForegroundColor Yellow
} else {
    $idx = Read-Host "`n请输入要修改的编号"
    $selected = $profiles[[int]$idx]
}

$oldPath = $selected.ProfilePath
$oldName = $selected.FolderName
$usersDir = Split-Path $oldPath -Parent

# ---- 输入新英文名 ----
if ($NewName -eq "") {
    $NewName = Read-Host "请输入新的英文文件夹名（如 Tony）"
}
$newPath = Join-Path $usersDir $NewName

if (Test-Path $newPath) {
    Write-Host "目标路径 $newPath 已存在，请换一个名字。" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

# ---- 检查是否有进程占用旧目录 ----
Write-Host "`n检查是否有进程占用 $oldPath ..." -ForegroundColor Cyan
$busyProcs = Get-Process | Where-Object {
    try { $_.Path -and $_.Path.StartsWith($oldPath, [System.StringComparison]::OrdinalIgnoreCase) }
    catch { $false }
}
if ($busyProcs) {
    Write-Host "以下进程正在使用旧目录，请确保目标用户已注销：" -ForegroundColor Red
    $busyProcs | Format-Table Name, Id, Path -AutoSize
    $confirm = Read-Host "是否强制继续？(y/N)"
    if ($confirm -ne "y") { exit 1 }
}

# ---- 确认操作 ----
Write-Host ""
Write-Host "============================================" -ForegroundColor Yellow
Write-Host " 即将执行以下操作：" -ForegroundColor Yellow
Write-Host "  1. 重命名 $oldPath -> $newPath" -ForegroundColor White
Write-Host "  2. 创建链接 $oldPath -> $newPath" -ForegroundColor White
Write-Host "  3. 修改注册表 ProfileImagePath" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Yellow
$confirm = Read-Host "确认执行？(y/N)"
if ($confirm -ne "y") {
    Write-Host "已取消。" -ForegroundColor Gray
    exit 0
}

# ---- 备份注册表 ----
$backupFile = Join-Path $usersDir "profile_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
Write-Host "`n备份注册表到 $backupFile ..." -ForegroundColor Cyan
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" $backupFile /y | Out-Null
Write-Host "备份完成" -ForegroundColor Green

# ---- 执行重命名 ----
Write-Host "`n重命名文件夹..." -ForegroundColor Cyan
try {
    Rename-Item -LiteralPath $oldPath -NewName $NewName -Force -ErrorAction Stop
    Write-Host "重命名成功: $oldPath -> $newPath" -ForegroundColor Green
} catch {
    Write-Host "重命名失败: $_" -ForegroundColor Red
    Write-Host "请确保目标用户已完全注销，没有进程占用该目录。" -ForegroundColor Yellow
    Read-Host "按回车退出"
    exit 1
}

# ---- 创建 Junction 链接（兼容旧路径） ----
Write-Host "创建目录链接 $oldPath -> $newPath ..." -ForegroundColor Cyan
cmd /c mklink /J "$oldPath" "$newPath" | Out-Null
if (Test-Path $oldPath) {
    Write-Host "链接创建成功" -ForegroundColor Green
} else {
    Write-Host "链接创建失败，请手动执行: mklink /J `"$oldPath`" `"$newPath`"" -ForegroundColor Red
}

# ---- 修改注册表 ProfileImagePath ----
Write-Host "修改注册表 ProfileImagePath..." -ForegroundColor Cyan
Set-ItemProperty -Path $selected.RegPath -Name "ProfileImagePath" -Value $newPath
$verify = (Get-ItemProperty $selected.RegPath).ProfileImagePath
if ($verify -eq $newPath) {
    Write-Host "注册表修改成功: $verify" -ForegroundColor Green
} else {
    Write-Host "注册表修改可能失败，请手动检查。" -ForegroundColor Red
}

# ---- 修复常见的环境变量和快捷方式 ----
Write-Host "`n扫描并修复环境变量..." -ForegroundColor Cyan
@("User", "Machine") | ForEach-Object {
    $scope = $_
    $envVars = [System.Environment]::GetEnvironmentVariables($scope)
    foreach ($key in $envVars.Keys) {
        $val = $envVars[$key]
        if ($val -like "*$oldPath*") {
            $newVal = $val.Replace($oldPath, $newPath)
            Write-Host "  修复 [$scope] $key" -ForegroundColor Yellow
            [System.Environment]::SetEnvironmentVariable($key, $newVal, $scope)
        }
    }
}

# ---- 完成 ----
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " 修改完成！" -ForegroundColor Green
Write-Host "" -ForegroundColor Green
Write-Host " 注册表已备份到: $backupFile" -ForegroundColor White
Write-Host " 如需回滚，双击该 .reg 文件恢复注册表，" -ForegroundColor White
Write-Host " 然后删除链接并将文件夹改回原名。" -ForegroundColor White
Write-Host "" -ForegroundColor Green
Write-Host " 请重启电脑后用原账户登录验证。" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Green
Read-Host "按回车退出"
