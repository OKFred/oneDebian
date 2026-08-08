# ==============================================================================
# components/wsl_status.ps1
# Description: 07. WSL 运维诊断与实例状态仪表盘 (100% 全量双语 i18n 兼容)
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
    Write-Host "`n$(Get-I18nStr 'Status_Step1')" -ForegroundColor Yellow
    $wslVerRaw = & wsl.exe --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $wslVerRaw) {
        $firstLine = ($wslVerRaw | Select-Object -First 1) -replace "`0", ""
        Write-Host "  • $(if ($global:CurrentLang -eq 'zh-CN') { 'WSL 核心服务' } else { 'WSL Service Status' }): $(if ($global:CurrentLang -eq 'zh-CN') { '正常运行' } else { 'Normal' }) ($firstLine)" -ForegroundColor Green
    } else {
        Write-Host "  • $(if ($global:CurrentLang -eq 'zh-CN') { 'WSL 核心服务' } else { 'WSL Service Status' }): $(if ($global:CurrentLang -eq 'zh-CN') { '已安装' } else { 'Installed' })" -ForegroundColor Gray
    }

    # 2. 读取所有已安装的 WSL 发行版与 Disk VHDX 大小
    Write-Host "`n$(Get-I18nStr 'Status_Step2')" -ForegroundColor Yellow
    
    [string[]]$distros = Get-WslDistros

    if ($distros.Count -eq 0) {
        Write-Host "  $(Get-I18nStr 'No_Distro_Found')" -ForegroundColor Red
        return
    }

    $verboseList = & wsl.exe --list --verbose 2>$null

    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "$(Get-I18nStr 'Status_Header')" -ForegroundColor Cyan
    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray

    for ($i = 0; $i -lt $distros.Count; $i++) {
        $name = [string]$distros[$i]

        
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

Show-WslDashboard
