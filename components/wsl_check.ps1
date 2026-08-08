# ==============================================================================
# components/wsl_check.ps1
# Description: 00. Precheck - WSL 安装前环境预检与虚拟化诊断（100% 全量双语 i18n 兼容）
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslPrecheck {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     $(Get-I18nStr 'Check_Title')     " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $missingVmp = $false
    $missingWslFeat = $false
    $needSetWsl2 = $false
    $hasIssue = $false
    $unknownChecks = New-Object System.Collections.Generic.List[string]

    # 1. CPU 硬件虚拟化
    Write-Host "`n$(Get-I18nStr 'Check_Step1')" -ForegroundColor Yellow
    try {
        $csInfo = Get-CimInstance -ClassName Win32_ComputerSystem 2>$null
        $cpuInfo = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1 2>$null

        # 科学严谨判断 1: 若 HypervisorPresent 为 True，说明 Hyper-V 虚拟化已经在运行，BIOS 绝对已开启！
        if ($csInfo -and $csInfo.HypervisorPresent) {
            Write-Host "  [✓] $(if ($global:CurrentLang -eq 'zh-CN') { 'CPU 硬件虚拟化已在 BIOS/UEFI 中开启且 Hyper-V 监控程序正在运行！' } else { 'CPU Hardware Virtualization is enabled in BIOS and Hyper-V is running!' })" -ForegroundColor Green
        }
        # 判断 2: 若未检测到 Hypervisor 运行，再去查看 BIOS 标志
        elseif ($null -ne $cpuInfo.VirtualizationFirmwareEnabled -and $cpuInfo.VirtualizationFirmwareEnabled) {
            Write-Host "  [✓] $(if ($global:CurrentLang -eq 'zh-CN') { 'CPU 硬件虚拟化已在 BIOS/UEFI 中成功启用！' } else { 'CPU Hardware Virtualization is enabled in BIOS/UEFI!' })" -ForegroundColor Green
        }
        else {
            Write-Host "  [!] $(if ($global:CurrentLang -eq 'zh-CN') { '警告: 未检测到虚拟化监控程序运行，请确认 BIOS 中已开启 VT-x/AMD-V！' } else { 'Warning: Hypervisor not present. Ensure VT-x/AMD-V is enabled in BIOS.' })" -ForegroundColor Red
            $hasIssue = $true
        }
    } catch {
        Write-Host "  [?] Unable to verify CPU virtualization: $($_.Exception.Message)" -ForegroundColor Yellow
        $unknownChecks.Add('CPU virtualization')
        $hasIssue = $true
    }


    # 2. Windows 虚拟化可选功能检测
    Write-Host "`n$(Get-I18nStr 'Check_Step2')" -ForegroundColor Yellow
    try {
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform 2>$null
        $wslFeat = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux 2>$null

        if ($vmp -and $vmp.State -eq 'Enabled') {
            Write-Host "  [✓] VirtualMachinePlatform: $(if ($global:CurrentLang -eq 'zh-CN') { '已启用' } else { 'Enabled' })" -ForegroundColor Green
        } else {
            Write-Host "  [!] VirtualMachinePlatform: $(if ($global:CurrentLang -eq 'zh-CN') { '未开启' } else { 'Disabled' })" -ForegroundColor Red
            $missingVmp = $true
            $hasIssue = $true
        }

        if ($wslFeat -and $wslFeat.State -eq 'Enabled') {
            Write-Host "  [✓] Microsoft-Windows-Subsystem-Linux: $(if ($global:CurrentLang -eq 'zh-CN') { '已启用' } else { 'Enabled' })" -ForegroundColor Green
        } else {
            Write-Host "  [!] Microsoft-Windows-Subsystem-Linux: $(if ($global:CurrentLang -eq 'zh-CN') { '未开启' } else { 'Disabled' })" -ForegroundColor Red
            $missingWslFeat = $true
            $hasIssue = $true
        }
    } catch {
        Write-Host "  [?] Unable to verify Windows optional features: $($_.Exception.Message)" -ForegroundColor Yellow
        $unknownChecks.Add('Windows optional features')
        $hasIssue = $true
    }

    # 3. WSL2 服务堆栈与默认版本检查
    Write-Host "`n$(Get-I18nStr 'Check_Step3')" -ForegroundColor Yellow
    $wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wslExe) {
        Write-Host "  [✓] wsl.exe: $(if ($global:CurrentLang -eq 'zh-CN') { '已就绪' } else { 'Ready' })" -ForegroundColor Green
        $wslStatus = & wsl.exe --status 2>$null
        $wslStatusExitCode = $LASTEXITCODE
        if ($wslStatusExitCode -eq 0 -and $wslStatus) {
            $statusText = ($wslStatus | ForEach-Object { $_ -replace "`0", "" }) -join "`n"
            if ($statusText -match "Default Version:\s*2" -or $statusText -match "默认版本:\s*2") {
                Write-Host "  [✓] WSL Default Version: 2" -ForegroundColor Green
            } else {
                Write-Host "  [!] WSL Default Version is not 2." -ForegroundColor Yellow
                $needSetWsl2 = $true
                $hasIssue = $true
            }
        } else {
            Write-Host "  [?] Unable to query WSL status (Exit Code: $wslStatusExitCode)." -ForegroundColor Yellow
            $unknownChecks.Add('WSL service status')
            $hasIssue = $true
        }
    } else {
        Write-Host "  [!] wsl.exe not found!" -ForegroundColor Red
        $hasIssue = $true
    }

    # 4. 当前 PowerShell 运行特权与依存工具检测
    Write-Host "`n$(Get-I18nStr 'Check_Step4')" -ForegroundColor Yellow
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        Write-Host "  [✓] Privilege Mode: Administrator" -ForegroundColor Green
    } else {
        Write-Host "  [i] Privilege Mode: Normal User" -ForegroundColor Gray
    }

    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curlCmd) {
        Write-Host "  [✓] curl.exe: $(if ($global:CurrentLang -eq 'zh-CN') { '已就绪' } else { 'Ready' })" -ForegroundColor Green
    } else {
        Write-Host "  [!] curl.exe missing!" -ForegroundColor Red
        $hasIssue = $true
    }

    # 5. 安装根目录磁盘物理剩余空间检测
    Write-Host "`n$(Get-I18nStr 'Check_Step5')" -ForegroundColor Yellow
    $driveLetter = (Split-Path -Qualifier $DefaultWslRoot).TrimEnd(':')
    if (-not $driveLetter) { $driveLetter = 'C' }

    $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        if ($freeGB -ge 10) {
            Write-Host "  [✓] Disk ${driveLetter}:\ Free Space: $freeGB GB" -ForegroundColor Green
        } else {
            Write-Host "  [!] Warning: Disk ${driveLetter}:\ Free Space ($freeGB GB) < 10GB." -ForegroundColor Yellow
            $hasIssue = $true
        }
    } else {
        Write-Host "  [?] Unable to query free space for drive ${driveLetter}:." -ForegroundColor Yellow
        $unknownChecks.Add("Drive ${driveLetter}: free space")
        $hasIssue = $true
    }

    # 诊断总结与交互式修复选项
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "             Diagnostic Summary            " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not $hasIssue) {
        Write-Host " 🎉 $(if ($global:CurrentLang -eq 'zh-CN') { '恭喜！您的 Windows 系统与虚拟化环境完全符合 WSL 2 运行要求！' } else { 'Congratulations! Your system is fully ready for WSL 2!' })" -ForegroundColor Green
        return
    }

    Write-Host " ⚠️ $(if ($global:CurrentLang -eq 'zh-CN') { '检测到问题或存在无法验证的检查项。' } else { 'Issues or unverifiable checks were detected.' })" -ForegroundColor Red

    if ($unknownChecks.Count -gt 0) {
        Write-Host "   $(if ($global:CurrentLang -eq 'zh-CN') { '无法验证' } else { 'Unable to verify' }): $($unknownChecks -join ', ')" -ForegroundColor Yellow
    }
    
    if ($missingVmp) {
        Write-Host "   • dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart" -ForegroundColor Yellow
    }
    if ($missingWslFeat) {
        Write-Host "   • dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart" -ForegroundColor Yellow
    }
    if ($needSetWsl2) {
        Write-Host "   • wsl --set-default-version 2" -ForegroundColor Yellow
    }

    $hasAutomatedFix = $missingVmp -or $missingWslFeat -or $needSetWsl2
    if (-not $hasAutomatedFix) {
        Write-Host "`nNo safe automated fix is available for the reported checks." -ForegroundColor Gray
        return
    }

    Write-Host "`n[Y] $(if ($global:CurrentLang -eq 'zh-CN') { '自动帮忙执行修复 (需要管理员权限)' } else { 'Auto-execute fixes for me (Admin required)' })" -ForegroundColor Green
    Write-Host " [N] $(if ($global:CurrentLang -eq 'zh-CN') { '仅查看指导命令，跳过自动修复继续下一步' } else { 'Skip and view instructions only' })" -ForegroundColor Gray

    $fixChoice = Read-Host "`n$(Get-I18nStr 'Check_Fix_Prompt')"

    if ($fixChoice -in 'Y', 'y') {
        if (-not $isAdmin) {
            Write-Host "`n[!] Administrator privileges required!" -ForegroundColor Red
            return
        }

        Write-Host "`nAuto executing DISM fixes..." -ForegroundColor Green
        $fixFailed = $false
        if ($missingVmp) {
            & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
            if ($LASTEXITCODE -ne 0) { $fixFailed = $true }
        }
        if ($missingWslFeat) {
            & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
            if ($LASTEXITCODE -ne 0) { $fixFailed = $true }
        }
        if ($needSetWsl2) {
            & wsl.exe --set-default-version 2
            if ($LASTEXITCODE -ne 0) { $fixFailed = $true }
        }

        if ($fixFailed) {
            Write-Host "`n[!] One or more fixes failed. Review the command output above." -ForegroundColor Red
        } else {
            Write-Host "`n[✓] Fixes deployed! Please reboot Windows if required." -ForegroundColor Green
        }
    } else {
        Write-Host "`n$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
    }
}

Invoke-WslPrecheck
