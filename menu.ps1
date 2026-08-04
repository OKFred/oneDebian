# ==============================================================================
# oneDebian - WSL Debian 管理工具箱 (Windows PowerShell)
# Author: Fred
# Description: 主控制菜单，调用 components/ 下的各个 WSL 管理子脚本
# ==============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 导入公共函数组件
. "$PSScriptRoot\components\wsl_common.ps1"

# 默认基础配置
$DefaultWslRoot = 'D:\wsl'

# ------------------------------------------------------------------------------
# 辅助函数: 安全执行子脚本（捕获所有报错并退回主菜单）
# ------------------------------------------------------------------------------
function Invoke-SubScript {
    param(
        [scriptblock]$ScriptBlock
    )
    try {
        & $ScriptBlock
    } catch {
        Write-Host "`n[!] 执行过程中发生错误: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Pause-Menu
    }
}

# ------------------------------------------------------------------------------
# 1. 安装 (Install) 包装调用
# ------------------------------------------------------------------------------
function Invoke-Install-Wrapper {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "          1. 安装 Debian WSL 发行版        " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $versionInput = Read-Host "选择 Debian 版本 (支持 12 / 13，默认 13)"
    if (-not $versionInput) {
        $version = 13
    } elseif ($versionInput -in '12', '13') {
        $version = [int]$versionInput
    } else {
        Write-Host "`n[!] 输入版本 '$versionInput' 不支持，仅支持 12 或 13，请正确输入！" -ForegroundColor Red
        return
    }

    $wslRoot = Read-Host "输入安装根目录 (默认 $DefaultWslRoot)"
    if (-not $wslRoot) { $wslRoot = $DefaultWslRoot }

    $installScript = Join-Path $PSScriptRoot 'components\wsl_install.ps1'
    if (Test-Path -LiteralPath $installScript) {
        Write-Host "`n正在调用 $installScript 进行安装..." -ForegroundColor Green
        & $installScript -Version $version -WslRoot $wslRoot
    } else {
        Write-Host "错误: 未找到组件脚本 $installScript" -ForegroundColor Red
    }
}

# ------------------------------------------------------------------------------
# 99. 关于 (About)
# ------------------------------------------------------------------------------
function Show-About {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "             关于 oneDebian WSL            " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " 项目描述: Debian WSL 自动化安装与运维管理工具"
    Write-Host " 作者    : Fred"
    Write-Host " 支持版本: Debian 12 (Bookworm) / Debian 13 (Trixie)"
    Write-Host " 工具箱路径: $PSScriptRoot"
    Write-Host " 组件库路径: $PSScriptRoot\components"
    Write-Host " 默认 WSL 安装根目录: $DefaultWslRoot"
}

# ------------------------------------------------------------------------------
# 主控制循环
# ------------------------------------------------------------------------------
function Main {
    while ($true) {
        Clear-Host
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "       oneDebian WSL 管理工具箱 (Windows PS)       " -ForegroundColor Green
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host " 01. Install   - 安装 Debian WSL 发行版" -ForegroundColor Yellow
        Write-Host " 02. Update    - 更新 系统软件包与 WSL 核心" -ForegroundColor Yellow
        Write-Host " 03. Backup    - 备份 (导出) WSL 发行版" -ForegroundColor Yellow
        Write-Host " 04. Restore   - 还原 (导入) WSL 发行版" -ForegroundColor Yellow
        Write-Host " 05. Uninstall - 卸载 (注销) WSL 发行版" -ForegroundColor Yellow
        Write-Host " 06. Config    - WSL 配置向导 (.wslconfig and wsl.conf)" -ForegroundColor Yellow
        Write-Host " ------------------------------------------------"
        Write-Host " 99. About     - 关于工具箱"
        Write-Host " 00. Exit      - 退出程序"
        Write-Host "==================================================" -ForegroundColor Green

        $choice = Read-Host "`n请输入功能编号 [01-06, 99, 00]"

        switch ($choice) {
            { $_ -in '01', '1' }  { Invoke-SubScript { Invoke-Install-Wrapper } }
            { $_ -in '02', '2' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_update.ps1" } }
            { $_ -in '03', '3' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_backup.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '04', '4' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_restore.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '05', '5' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_uninstall.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '06', '6' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_config.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '99' }       { Show-About; Pause-Menu }
            { $_ -in '00', '0', 'exit' } { Write-Host "`n已退出工具箱。 Bye!" -ForegroundColor Gray; exit }
            default {
                Write-Host "`n[!] 输入未匹配到有效选项，请正确输入！" -ForegroundColor Red
                Start-Sleep -Seconds 1.5
            }
        }

    }
}

Main
