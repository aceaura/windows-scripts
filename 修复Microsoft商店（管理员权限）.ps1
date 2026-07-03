#Requires -RunAsAdministrator
# ============================================================
# 修复Microsoft商店
# 适用场景：商店能打开但一直加载/无法连接（使用本地代理时常见）
# 使用方法：以管理员身份运行
# 原理：UWP应用（商店）运行在沙盒中，默认禁止访问localhost，
#       导致无法走本地代理（如127.0.0.1:7897）。本脚本添加
#       loopback豁免，并清理商店缓存、重新注册商店。
# ============================================================

# ---- 检测本地代理 ----
$inetKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$proxyEnable = (Get-ItemProperty $inetKey -Name "ProxyEnable" -ErrorAction SilentlyContinue).ProxyEnable
$proxyServer = (Get-ItemProperty $inetKey -Name "ProxyServer" -ErrorAction SilentlyContinue).ProxyServer

if ($proxyEnable -eq 1 -and $proxyServer -match "127\.0\.0\.1|localhost") {
    Write-Host "检测到本地代理: $proxyServer" -ForegroundColor Cyan
    Write-Host "UWP应用默认无法访问localhost，这通常是商店无法加载的原因。" -ForegroundColor Yellow
} else {
    Write-Host "未检测到本地代理，将执行通用修复（缓存清理+重新注册）。" -ForegroundColor Yellow
}

# ---- 显示当前loopback豁免列表 ----
Write-Host "`n当前loopback豁免列表:" -ForegroundColor Cyan
CheckNetIsolation LoopbackExempt -c

# ---- 待添加loopback豁免的UWP应用包 ----
$pfns = @(
    "Microsoft.WindowsStore_8wekyb3d8bbwe",
    "Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy",
    "Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy",
    "Microsoft.AccountsControl_cw5n1h2txyewy",
    "Microsoft.WindowsMaps_8wekyb3d8bbwe",
    "Microsoft.BingWeather_8wekyb3d8bbwe",
    "Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
    "Microsoft.Win32WebViewHost_cw5n1h2txyewy"
)

# ---- 添加loopback豁免 ----
Write-Host "`n添加UWP应用loopback豁免..." -ForegroundColor Cyan
$added = 0
foreach ($pfn in $pfns) {
    $result = CheckNetIsolation LoopbackExempt -a -n=$pfn 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  已豁免: $pfn" -ForegroundColor Green
        $added++
    } else {
        Write-Host "  跳过(可能未安装): $pfn" -ForegroundColor Gray
    }
}
Write-Host "共添加 $added 个应用的loopback豁免" -ForegroundColor Green

# ---- 显示添加后的豁免列表 ----
Write-Host "`n添加后loopback豁免列表:" -ForegroundColor Cyan
CheckNetIsolation LoopbackExempt -c

# ---- 清理商店缓存 ----
Write-Host "`n清理Microsoft商店缓存..." -ForegroundColor Cyan
try {
    wsreset.exe
    Write-Host "缓存已清理" -ForegroundColor Green
} catch {
    Write-Host "缓存清理失败，继续后续步骤" -ForegroundColor Yellow
}

# ---- 重置商店应用数据 ----
Write-Host "`n重置商店应用数据..." -ForegroundColor Cyan
$store = Get-AppxPackage *WindowsStore*
if ($store) {
    try {
        $store | Reset-AppxPackage -ErrorAction Stop
        Write-Host "应用数据已重置" -ForegroundColor Green
    } catch {
        Write-Host "重置失败，尝试重新注册" -ForegroundColor Yellow
    }
} else {
    Write-Host "未找到商店包" -ForegroundColor Red
}

# ---- 重新注册商店 ----
Write-Host "`n重新注册Microsoft商店..." -ForegroundColor Cyan
$store = Get-AppxPackage -AllUsers *WindowsStore*
if ($store) {
    foreach ($p in $store) {
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($p.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
            Write-Host "  已注册: $($p.Name)" -ForegroundColor Green
        } catch {
            Write-Host "  注册失败: $($p.Name) - $_" -ForegroundColor Yellow
        }
    }
}

# ---- 关闭并重启商店 ----
Write-Host "`n重启Microsoft商店..." -ForegroundColor Cyan
Get-Process | Where-Object { $_.PackageFamilyName -eq "Microsoft.WindowsStore_8wekyb3d8bbwe" } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process RuntimeBroker -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-Process "winstore:"

# ---- 完成 ----
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " 修复完成！" -ForegroundColor Green
Write-Host "" -ForegroundColor Green
Write-Host " 已执行：" -ForegroundColor White
Write-Host "  1. 添加UWP应用loopback豁免（解决代理访问）" -ForegroundColor White
Write-Host "  2. 清理商店缓存" -ForegroundColor White
Write-Host "  3. 重置应用数据" -ForegroundColor White
Write-Host "  4. 重新注册商店" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Green
Write-Host " 如商店仍无法加载，请重启电脑后再试。" -ForegroundColor Yellow
Read-Host "按回车退出"
