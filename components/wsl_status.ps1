# ==============================================================================
# components/wsl_status.ps1
# Description: 07. WSL 运维诊断与实例状态仪表盘 (支持 i18n 多语言)
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Show-WslDashboard {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     $(Get-I18nStr 'Status_Title')      " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    # 1. 读取 WSL 核心环境信息
    Write-Host "`n[1/3 WSL 基础架构环境诊断]" -ForegroundColor Yellow
    $wslVerRaw = & wsl.exe --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $wslVerRaw) {
        $firstLine = ($wslVerRaw | Select-Object -First 1) -replace "`0", ""
        Write-Host "  • WSL Service Status: Normal ($firstLine)" -ForegroundColor Green
    } else {
        Write-Host "  • WSL Service Status: Installed" -ForegroundColor Gray
    }

    # 2. 读取所有已安装的 WSL 发行版与 Disk VHDX 大小
    Write-Host "`n[2/3 已安装 WSL 发行版资源清单]" -ForegroundColor Yellow
    
    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Host "  $(Get-I18nStr 'No_Distro_Found')" -ForegroundColor Red
        return
    }

    $verboseList = & wsl.exe --list --verbose 2>$null

    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "$(Get-I18nStr 'Status_Header')" -ForegroundColor Cyan
    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray

    for ($i = 0; $i -lt $distros.Count; $i++) {
        $name = $distros[$i]
        
        $state = "Stopped"
        $wslVer = "2"
        if ($verboseList) {
            foreach ($line in $verboseList) {
                $cleanLine = ($line -replace "`0", "").Trim()
                if ($cleanLine -match "^\*?\s*$name\s+(?<state>Running|Stopped)\s+(?<ver>\d)") {
                    $state = $Matches['state']
                    $wslVer = $Matches['ver']
                    break
                }
            }
        }

        $vhdxSizeStr = "N/A"
        $foundFile = $null
        if (Test-Path -LiteralPath (Join-Path $DefaultWslRoot "$name\ext4.vhdx")) {
            $foundFile = Get-Item -LiteralPath (Join-Path $DefaultWslRoot "$name\ext4.vhdx")
        }

        if ($foundFile) {
            $sizeGB = [math]::Round($foundFile.Length / 1GB, 2)
            $vhdxSizeStr = "$sizeGB GB"
        }

        $stateColor = if ($state -eq 'Running') { 'Green' } else { 'Gray' }
        Write-Host ("  [{0}]   |  {1,-12} |  {2,-12} |  WSL {3}     |  {4}" -f ($i + 1), $name, $state, $wslVer, $vhdxSizeStr) -ForegroundColor $stateColor
    }
    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray

    # 3. 运维操作管理
    Write-Host "`n[3/3 实例管理操作]" -ForegroundColor Yellow
    Write-Host " [T] 强制终止某个指定的僵死发行版 (wsl --terminate)"
    Write-Host " [S] 全局软重启 WSL 堆栈 (wsl --shutdown)"
    Write-Host " [0] $(Get-I18nStr 'Cancel_Operation')"

    $opChoice = Read-Host "`n$(Get-I18nStr 'Prompt_Select') [T / S / 0]"
    if ($opChoice -in 'T', 't') {
        $target = Select-WslDistro -Title $(Get-I18nStr 'Select_Distro_Title')
        if ($target) {
            Write-Host "`nStopping $target ..." -ForegroundColor Yellow
            & wsl.exe --terminate $target
            Write-Host "[✓] Terminated $target successfully." -ForegroundColor Green
        }
    } elseif ($opChoice -in 'S', 's') {
        $confirm = Read-Host "`nConfirm execute global wsl --shutdown? All running WSL instances will be stopped! [Y/N]"
        if ($confirm -in 'Y', 'y') {
            Write-Host "`nShutting down WSL ..." -ForegroundColor Red
            & wsl.exe --shutdown
            Write-Host "[✓] Global WSL shutdown complete." -ForegroundColor Green
        }
    }
}

Show-WslDashboard
