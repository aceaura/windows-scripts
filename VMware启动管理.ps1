$vmwarePath = "C:\Program Files (x86)\VMware\VMware Workstation\vmware.exe"
$startupFolder = [Environment]::GetFolderPath('Startup')

function Show-Menu {
    Clear-Host
    Write-Host "========================================"
    Write-Host "VMware 开机启动管理工具"
    Write-Host "========================================"
    Write-Host "1. 添加虚拟机到开机启动"
    Write-Host "2. 移除虚拟机开机启动"
    Write-Host "3. 退出"
    Write-Host ""
}

function Get-VirtualMachines {
    $vms = @()
    $paths = @("C:\Virtual Machines", "$env:USERPROFILE\Documents\Virtual Machines")
    
    foreach ($path in $paths) {
        if (Test-Path $path) {
            $vms += Get-ChildItem -Path $path -Filter "*.vmx" -File -Recurse -ErrorAction SilentlyContinue
        }
    }
    return $vms
}

function Add-VMStartup {
    Write-Host "扫描虚拟机..."
    $vms = Get-VirtualMachines
    
    if ($vms.Count -eq 0) {
        Write-Host "未找到虚拟机"
        $manualPath = Read-Host "输入查询目录"
        if (Test-Path $manualPath -PathType Container) {
            Write-Host "正在搜索目录: $manualPath"
            $vms = Get-ChildItem -Path $manualPath -Filter "*.vmx" -File -Recurse -ErrorAction SilentlyContinue
            if ($vms.Count -eq 0) {
                Write-Host "该目录下未找到虚拟机"
                Read-Host "按回车继续"
                return
            }
        } else {
            Write-Host "目录不存在"
            Read-Host "按回车继续"
            return
        }
    }
    
    $available = @()
    foreach ($vm in $vms) {
        $shortcutName = "$($vm.BaseName)_VMware.lnk"
        if (-not (Test-Path "$startupFolder\$shortcutName")) {
            $available += $vm
        }
    }
    
    if ($available.Count -eq 0) {
        Write-Host "所有虚拟机已在启动项中"
        Read-Host "按回车继续"
        return
    }
    
    Write-Host "可添加的虚拟机:"
    for ($i = 0; $i -lt $available.Count; $i++) {
        Write-Host "$($i + 1). $($available[$i].BaseName) ($($available[$i].FullName))"
    }
    
    $choice = Read-Host "选择编号"
    $index = [int]$choice - 1
    
    if ($index -ge 0 -and $index -lt $available.Count) {
        Create-Shortcut $available[$index].FullName $available[$index].BaseName
    } else {
        Write-Host "无效选择"
    }
    Read-Host "按回车继续"
}

function Remove-VMStartup {
    Write-Host "扫描启动项..."
    $shortcuts = Get-ChildItem -Path $startupFolder -Filter "*_VMware.lnk" -ErrorAction SilentlyContinue
    
    if ($shortcuts.Count -eq 0) {
        Write-Host "无VMware启动项"
        Read-Host "按回车继续"
        return
    }
    
    Write-Host "启动项:"
    for ($i = 0; $i -lt $shortcuts.Count; $i++) {
        $name = $shortcuts[$i].BaseName -replace '_VMware$', ''
        Write-Host "$($i + 1). $name"
    }
    
    $choice = Read-Host "选择编号"
    $index = [int]$choice - 1
    
    if ($index -ge 0 -and $index -lt $shortcuts.Count) {
        Remove-Item $shortcuts[$index].FullName -Force
        $name = $shortcuts[$index].BaseName -replace '_VMware$', ''
        Write-Host "已移除 $name"
    } else {
        Write-Host "无效选择"
    }
    Read-Host "按回车继续"
}

function Create-Shortcut($vmPath, $vmName) {
    $shortcutPath = "$startupFolder\$($vmName)_VMware.lnk"
    $ws = New-Object -ComObject WScript.Shell
    $shortcut = $ws.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $vmwarePath
    $shortcut.Arguments = "-x `"$vmPath`""
    $shortcut.WindowStyle = 7
    $shortcut.WorkingDirectory = Split-Path $vmPath
    $shortcut.Save()
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($ws) | Out-Null
    Write-Host "已添加 $vmName"
}

while ($true) {
    Show-Menu
    $choice = Read-Host "请选择操作 (1-3)"
    
    switch ($choice) {
        "1" { Add-VMStartup }
        "2" { Remove-VMStartup }
        "3" { exit }
        default { Write-Host "无效选择"; Start-Sleep -Seconds 1 }
    }
}
