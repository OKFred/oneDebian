# ==============================================================================
# components/wsl_status.ps1
# Description: 07. WSL 运维诊断与实例状态仪表盘 (100% 全量双语 i18n 兼容)
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Get-WslDistroStorageInfo {
    param([string]$DistroName)

    $lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxssRoot)) { return $null }

    foreach ($key in (Get-ChildItem $lxssRoot -ErrorAction SilentlyContinue)) {
        $properties = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        if (-not $properties -or $properties.DistributionName -cne $DistroName) { continue }

        $basePath = [Environment]::ExpandEnvironmentVariables([string]$properties.BasePath)
        if (-not $basePath) { return $null }

        $vhdName = if ($properties.VhdFileName) { [string]$properties.VhdFileName } else { 'ext4.vhdx' }
        $vhdPath = Join-Path $basePath $vhdName
        if (-not (Test-Path -LiteralPath $vhdPath)) {
            $vhdPath = Get-ChildItem -LiteralPath $basePath -Filter '*.vhdx' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
        }

        if ($vhdPath -and (Test-Path -LiteralPath $vhdPath)) {
            $vhd = Get-Item -LiteralPath $vhdPath
            return [pscustomobject]@{ Path = $vhd.FullName; Length = $vhd.Length }
        }
        return $null
    }

    return $null
}

function Show-WslNetworkHealth {
    param([string]$DistroName)

    $probeScript = 'echo __IPV4__; ip -4 -brief address show dev eth0 scope global 2>/dev/null; echo __ROUTE__; ip route show default 2>/dev/null; echo __NM__; systemctl is-active NetworkManager.service 2>/dev/null; echo __NETWORKD__; systemctl is-active systemd-networkd.service 2>/dev/null; true'
    $probeLines = @(& wsl.exe -d $DistroName -u root -- sh -c $probeScript 2>$null)
    $probeExitCode = $LASTEXITCODE
    if ($probeExitCode -ne 0) {
        Write-Host "  • $DistroName : unable to run network probe (Exit Code: $probeExitCode)" -ForegroundColor Yellow
        return
    }

    $values = @{ IPV4 = ''; ROUTE = ''; NM = ''; NETWORKD = '' }
    $currentKey = $null
    foreach ($line in $probeLines) {
        $trimmedLine = ([string]$line).Trim()
        if ($trimmedLine -match '^__(IPV4|ROUTE|NM|NETWORKD)__$') {
            $currentKey = $Matches[1]
            continue
        }
        if ($currentKey -and -not $values[$currentKey]) {
            $values[$currentKey] = $trimmedLine
        }
    }

    if (-not $values['IPV4'] -or -not $values['ROUTE']) {
        Write-Host "  • $DistroName : unhealthy - eth0 IPv4 address or default route is missing" -ForegroundColor Red
    } elseif ($values['NM'] -eq 'active' -and $values['NETWORKD'] -eq 'active') {
        Write-Host "  • $DistroName : conflict - NetworkManager and systemd-networkd both manage networking" -ForegroundColor Red
    } else {
        Write-Host "  • $DistroName : healthy - IPv4 and default route are present" -ForegroundColor Green
    }
}

function Show-WslDashboard {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     $(Get-I18nStr 'Status_Title')      " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    # 1. 读取 WSL 核心环境信息
    Write-Host "`n$(Get-I18nStr 'Status_Step1')" -ForegroundColor Yellow
    $wslVerRaw = & wsl.exe --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $wslVerRaw) {
        $firstLine = ($wslVerRaw | Select-Object -First 1) -replace "`0", ""
        Write-Host "  • $(if ($global:CurrentLang -eq 'zh-CN') { 'WSL 核心服务' } else { 'WSL Service Status' }): $(if ($global:CurrentLang -eq 'zh-CN') { '正常运行' } else { 'Normal' }) ($firstLine)" -ForegroundColor Green
    } else {
        Write-Host "  • $(if ($global:CurrentLang -eq 'zh-CN') { 'WSL 核心服务状态无法验证' } else { 'Unable to verify WSL service status' })" -ForegroundColor Yellow
    }

    # 2. 读取所有已安装的 WSL 发行版与 Disk VHDX 大小
    Write-Host "`n$(Get-I18nStr 'Status_Step2')" -ForegroundColor Yellow
    
    [string[]]$distros = Get-WslDistros

    if ($distros.Count -eq 0) {
        Write-Host "  $(Get-I18nStr 'No_Distro_Found')" -ForegroundColor Red
        return
    }

    $verboseList = & wsl.exe --list --verbose 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [!] Unable to query verbose WSL status (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
        return
    }
    $runningRaw = & wsl.exe --list --running --quiet 2>$null
    $runningExitCode = $LASTEXITCODE
    if ($runningExitCode -ne 0) {
        Write-Host "  [!] Unable to query running WSL distributions (Exit Code: $runningExitCode)." -ForegroundColor Yellow
        $runningList = @()
    } else {
        $runningList = @(($runningRaw | ForEach-Object { ($_ -replace "`0", '').Trim() }) | Where-Object { $_ })
    }

    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "$(Get-I18nStr 'Status_Header')" -ForegroundColor Cyan
    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray

    for ($i = 0; $i -lt $distros.Count; $i++) {
        $name = [string]$distros[$i]

        
        $state = if ($runningList -contains $name) { 'Running' } else { 'Stopped' }
        $wslVer = "2"
        if ($verboseList) {
            foreach ($line in $verboseList) {
                $cleanLine = ($line -replace "`0", "").Trim()
                $escapedName = [regex]::Escape($name)
                if ($cleanLine -match "^\*?\s*$escapedName\s+\S+\s+(?<ver>\d)") {
                    $wslVer = $Matches['ver']
                    break
                }
            }
        }

        $vhdxSizeStr = "N/A"
        $storageInfo = Get-WslDistroStorageInfo -DistroName $name
        if ($storageInfo) {
            $sizeGB = [math]::Round($storageInfo.Length / 1GB, 2)
            $vhdxSizeStr = "$sizeGB GB"
        }

        $stateColor = if ($state -eq 'Running') { 'Green' } else { 'Gray' }
        Write-Host ("  [{0}]   |  {1,-12} |  {2,-12} |  WSL {3}     |  {4}" -f ($i + 1), $name, $state, $wslVer, $vhdxSizeStr) -ForegroundColor $stateColor
    }
    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray

    Write-Host "`n[3/4 Running distro network health]" -ForegroundColor Yellow
    if ($runningList.Count -eq 0) {
        Write-Host '  No running distributions; network probes were skipped.' -ForegroundColor Gray
    } else {
        foreach ($runningDistro in $runningList) {
            Show-WslNetworkHealth -DistroName $runningDistro
        }
    }

    # 4. 运维操作管理
    Write-Host "`n$(Get-I18nStr 'Status_Step3')" -ForegroundColor Yellow
    Write-Host " $(Get-I18nStr 'Status_Opt_Term')"
    Write-Host " $(Get-I18nStr 'Status_Opt_Shutdown')"
    Write-Host " [0] $(Get-I18nStr 'Cancel_Operation')"

    $opChoice = Read-Host "`n$(Get-I18nStr 'Prompt_Select') [T / S / 0]"
    if ($opChoice -in 'T', 't') {
        $target = Select-WslDistro -Title $(Get-I18nStr 'Select_Distro_Title')
        if ($target) {
            Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { "正在停止发行版: $target ..." } else { "Stopping $target ..." })" -ForegroundColor Yellow
            & wsl.exe --terminate $target
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[✓] $(if ($global:CurrentLang -eq 'zh-CN') { "已成功停止 $target" } else { "Terminated $target successfully." })" -ForegroundColor Green
            } else {
                Write-Host "[!] Failed to terminate $target (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
            }
        }
    } elseif ($opChoice -in 'S', 's') {
        $confirm = Read-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { '确认要执行全局 wsl --shutdown 重启 WSL 吗？所有运行中的 WSL 将被关闭！[Y/N]' } else { 'Confirm execute global wsl --shutdown? All running WSL instances will be stopped! [Y/N]' })"
        if ($confirm -in 'Y', 'y') {
            Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { '正在执行全局 shutdown...' } else { 'Shutting down WSL ...' })" -ForegroundColor Red
            & wsl.exe --shutdown
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[✓] $(if ($global:CurrentLang -eq 'zh-CN') { '全局 WSL 堆栈已关闭重置。' } else { 'Global WSL shutdown complete.' })" -ForegroundColor Green
            } else {
                Write-Host "[!] WSL shutdown failed (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Show-WslDashboard
}
