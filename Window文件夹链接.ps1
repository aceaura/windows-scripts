# 获取源路径
$sourcePath = Read-Host "请输入源文件夹路径"
if (-not (Test-Path $sourcePath)) {
    Write-Host "源路径不存在！" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit
}

# 获取目标路径
$targetPath = Read-Host "请输入目标文件夹路径"
if (-not (Test-Path $targetPath)) {
    Write-Host "目标路径不存在！" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit
}

# 获取源文件夹名称
$sourceFolderName = Split-Path $sourcePath -Leaf
$linkPath = Join-Path $targetPath $sourceFolderName

try {
    # 创建目录链接
    cmd /c "mklink /J `"$linkPath`" `"$sourcePath`""
    Write-Host "链接创建成功！" -ForegroundColor Green
    Write-Host "源路径: $sourcePath"
    Write-Host "链接路径: $linkPath"
}
catch {
    Write-Host "链接创建失败: $($_.Exception.Message)" -ForegroundColor Red
}

Read-Host "按回车键退出"