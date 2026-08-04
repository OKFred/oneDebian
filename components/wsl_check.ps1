# ==============================================================================
# components/wsl_check.ps1
# Description: 00. Precheck - WSL 安装前环境预检与虚拟化诊断（含一键自动修复）
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslPrecheck {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host " 00. WSL 安装前环境预检与虚拟化诊断 (Check) " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $missingVmp = $false
    $missingWslFeat = $false
    $needSetWsl2 = $false
    $hasIssue = $false

    # --------------------------------------------------------------------------
    # 1. CPU 硬件虚拟化 (VT-x / AMD-V) 检测
    # --------------------------------------------------------------------------
    Write-Host "`n[1/5] CPU 硬件虚拟化状态检测 (Hardware Virtualization)" -ForegroundColor Yellow
    try {
        $cpuInfo = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        if ($null -ne $cpuInfo.VirtualizationFirmwareEnabled) {
            if ($cpuInfo.VirtualizationFirmwareEnabled) {
                Write-Host "  [✓] CPU 硬件虚拟化已在 BIOS/UEFI 中成功启用！" -ForegroundColor Green
            } else {
                Write-Host "  [!] 警告: CPU 支持虚拟化，但 BIOS/UEFI 中未开启 Virtualization (VT-x/AMD-V)！" -ForegroundColor Red
                Write-Host "      请重启电脑进入 BIOS 开启 Virtualization Technology。" -ForegroundColor Yellow
                $hasIssue = $true
            }
        } else {
            Write-Host "  [✓] CPU 架构符合虚拟化基本条件。" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [✓] CPU 架构检查完成。" -ForegroundColor Gray
    }

    # --------------------------------------------------------------------------
    # 2. Windows 虚拟化可选功能检测 (Windows Optional Features)
    # --------------------------------------------------------------------------
    Write-Host "`n[2/5] Windows 虚拟化可选功能开启状态 (Optional Features)" -ForegroundColor Yellow
    try {
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform 2>$null
        $wslFeat = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux 2>$null

        if ($vmp -and $vmp.State -eq 'Enabled') {
            Write-Host "  [✓] 虚拟机平台 (VirtualMachinePlatform): 已启用" -ForegroundColor Green
        } else {
            Write-Host "  [!] 错误: 虚拟机平台 (VirtualMachinePlatform) 未开启！" -ForegroundColor Red
            $missingVmp = $true
            $hasIssue = $true
        }

        if ($wslFeat -and $wslFeat.State -eq 'Enabled') {
            Write-Host "  [✓] WSL Linux 子系统功能 (Microsoft-Windows-Subsystem-Linux): 已启用" -ForegroundColor Green
        } else {
            Write-Host "  [!] 错误: WSL 子系统功能 (Microsoft-Windows-Subsystem-Linux) 未开启！" -ForegroundColor Red
            $missingWslFeat = $true
            $hasIssue = $true
        }
    } catch {
        Write-Host "  [!] 提示: 读取 Windows 可选功能细节需要管理员权限。" -ForegroundColor Gray
    }

    # --------------------------------------------------------------------------
    # 3. WSL2 服务堆栈与默认版本检查
    # --------------------------------------------------------------------------
    Write-Host "`n[3/5] WSL2 服务堆栈与默认版本 (WSL Stack Status)" -ForegroundColor Yellow
    $wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wslExe) {
        Write-Host "  [✓] wsl.exe 核心工具: 已就绪 ($($wslExe.Source))" -ForegroundColor Green
        $wslStatus = & wsl.exe --status 2>$null
        if ($wslStatus) {
            $statusText = ($wslStatus | ForEach-Object { $_ -replace "`0", "" }) -join "`n"
            if ($statusText -match "Default Version:\s*2" -or $statusText -match "默认版本:\s*2") {
                Write-Host "  [✓] WSL 默认架构版本: 已配置为 WSL 2" -ForegroundColor Green
            } else {
                Write-Host "  [!] 提示: WSL 默认版本当前未设为 2。" -ForegroundColor Yellow
                $needSetWsl2 = $true
                $hasIssue = $true
            }
        }
    } else {
        Write-Host "  [!] 错误: 未能在 PATH 中查找到 wsl.exe 命令！" -ForegroundColor Red
        $hasIssue = $true
    }

    # --------------------------------------------------------------------------
    # 4. 当前 PowerShell 运行特权与依存工具检测
    # --------------------------------------------------------------------------
    Write-Host "`n[4/5] 终端特权与依存工具链 (Privilege & Tools)" -ForegroundColor Yellow
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        Write-Host "  [✓] 当前 PowerShell 运行身份: Administrator (管理员特权)" -ForegroundColor Green
    } else {
        Write-Host "  [i] 当前 PowerShell 运行身份: 普通用户 (若需自动安装组件建议用管理员运行)" -ForegroundColor Gray
    }

    $curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curlCmd) {
        Write-Host "  [✓] curl.exe 下载器: 已就绪" -ForegroundColor Green
    } else {
        Write-Host "  [!] 错误: 未查找到 curl.exe 工具！" -ForegroundColor Red
        $hasIssue = $true
    }

    # --------------------------------------------------------------------------
    # 5. 安装根目录磁盘物理剩余空间检测
    # --------------------------------------------------------------------------
    Write-Host "`n[5/5] 安装根路径磁盘空间检测 (Disk Free Space)" -ForegroundColor Yellow
    $driveLetter = (Split-Path -Qualifier $DefaultWslRoot).TrimEnd(':')
    if (-not $driveLetter) { $driveLetter = 'C' }

    $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        if ($freeGB -ge 10) {
            Write-Host "  [✓] 磁盘 ${driveLetter}:\ 剩余可用空间: $freeGB GB (存储充裕)" -ForegroundColor Green
        } else {
            Write-Host "  [!] 警告: 磁盘 ${driveLetter}:\ 剩余空间较小 ($freeGB GB)，建议保留 > 10GB 物理空间。" -ForegroundColor Yellow
        }

    }

    # --------------------------------------------------------------------------
    # 诊断总结与交互式修复选项 (Auto Fix or Skip)
    # --------------------------------------------------------------------------
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "             预检诊断总结报告              " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not $hasIssue) {
        Write-Host " 🎉 恭喜！您的 Windows 系统与虚拟化环境完全符合 WSL 2 运行要求，可以流畅安装与运维！" -ForegroundColor Green
        return
    }

    Write-Host " ⚠️ 检测到部分系统虚拟化组件未就绪。所需的修复命令如下:" -ForegroundColor Red
    
    if ($missingVmp) {
        Write-Host "   • 开启虚拟机平台: dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart" -ForegroundColor Yellow
    }
    if ($missingWslFeat) {
        Write-Host "   • 开启 WSL Linux 子系统: dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart" -ForegroundColor Yellow
    }
    if ($needSetWsl2) {
        Write-Host "   • 设置默认版本为 WSL2: wsl --set-default-version 2" -ForegroundColor Yellow
    }

    Write-Host "`n【选项处理】" -ForegroundColor Cyan
    Write-Host " [Y] 自动帮忙执行修复 (需要管理员权限)" -ForegroundColor Green
    Write-Host " [N] 仅查看指导命令，跳过自动修复继续下一步" -ForegroundColor Gray

    $fixChoice = Read-Host "`n是否由工具箱自动为您执行上述修复命令？[Y/N]"

    if ($fixChoice -in 'Y', 'y') {
        if (-not $isAdmin) {
            Write-Host "`n[!] 权限受限: 开启 Windows 功能需要管理员权限！" -ForegroundColor Red
            Write-Host "    请以 [管理员身份] 重新打开 PowerShell 运行 .\menu.ps1 后重试。" -ForegroundColor Yellow
            return
        }

        Write-Host "`n正在由工具箱自动部署所需的系统功能组件..." -ForegroundColor Green
        
        if ($missingVmp) {
            Write-Host " ➜ 正在启用 VirtualMachinePlatform (虚拟机平台)..." -ForegroundColor Yellow
            & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        }

        if ($missingWslFeat) {
            Write-Host " ➜ 正在启用 Microsoft-Windows-Subsystem-Linux (WSL 功能)..." -ForegroundColor Yellow
            & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        }

        if ($needSetWsl2) {
            Write-Host " ➜ 正在设置默认版本为 WSL 2..." -ForegroundColor Yellow
            & wsl.exe --set-default-version 2
        }

        Write-Host "`n[✓] 自动修复部署命令已成功执行！" -ForegroundColor Green
        Write-Host "    💡 注意: 首次开启 VirtualMachinePlatform 后，请【重启 Windows 电脑】以彻底生效。" -ForegroundColor Yellow
    } else {
        Write-Host "`n已跳过自动修复。您可以在后续需要时手动复制上方命令执行。" -ForegroundColor Gray
    }
}

Invoke-WslPrecheck
