# ==============================================================================
# oneDebian - WSL Debian 管理工具箱 (Windows PowerShell)
# Author: Fred
# Description: 主控制菜单，调用 components/ 下的各个 WSL 管理子脚本
# ==============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 导入多语言与公共函数组件
. "$PSScriptRoot\components\wsl_i18n.ps1"
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
        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice'): $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Pause-Menu
    }
}

# ------------------------------------------------------------------------------
# 1. 安装 (Install) 包装调用
# ------------------------------------------------------------------------------
function Invoke-Install-Wrapper {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "          $(Get-I18nStr 'Install_Title')        " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $versionInput = Read-Host "$(Get-I18nStr 'Install_Version_Prompt')"
    if (-not $versionInput) {
        $version = 13
    } elseif ($versionInput -in '12', '13') {
        $version = [int]$versionInput
    } else {
        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
        return
    }

    $wslRoot = Read-Host "$(Get-I18nStr 'Install_Dir_Prompt') (默认 $DefaultWslRoot)"
    if (-not $wslRoot) { $wslRoot = $DefaultWslRoot }

    $installScript = Join-Path $PSScriptRoot 'components\wsl_install.ps1'
    if (Test-Path -LiteralPath $installScript) {
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
    Write-Host " 项目描述: Debian WSL 自动化安装与运维管理工具 (Automated Debian WSL Management Tool)"
    Write-Host " 作者    : Fred"
    Write-Host " 支持版本: Debian 12 (Bookworm) / Debian 13 (Trixie)"
    Write-Host " 当前语言: $script:CurrentLang"
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
        Write-Host "       $(Get-I18nStr 'Menu_Title')       " -ForegroundColor Green
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host " $(Get-I18nStr 'Menu_Install')" -ForegroundColor Yellow
        Write-Host " $(Get-I18nStr 'Menu_Update')" -ForegroundColor Yellow
        Write-Host " $(Get-I18nStr 'Menu_Backup')" -ForegroundColor Yellow
        Write-Host " $(Get-I18nStr 'Menu_Restore')" -ForegroundColor Yellow
        Write-Host " $(Get-I18nStr 'Menu_Uninstall')" -ForegroundColor Yellow
        Write-Host " $(Get-I18nStr 'Menu_Config')" -ForegroundColor Yellow
        Write-Host " $(Get-I18nStr 'Menu_Status')" -ForegroundColor Yellow
        Write-Host " $(Get-I18nStr 'Menu_Purge')" -ForegroundColor Yellow
        Write-Host " ------------------------------------------------"
        Write-Host " $(Get-I18nStr 'Menu_Lang')" -ForegroundColor Cyan
        Write-Host " $(Get-I18nStr 'Menu_About')"
        Write-Host " $(Get-I18nStr 'Menu_Exit')"
        Write-Host "==================================================" -ForegroundColor Green

        $choice = Read-Host "`n$(Get-I18nStr 'Prompt_Select')"

        switch ($choice) {
            { $_ -in '01', '1' }  { Invoke-SubScript { Invoke-Install-Wrapper } }
            { $_ -in '02', '2' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_update.ps1" } }
            { $_ -in '03', '3' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_backup.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '04', '4' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_restore.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '05', '5' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_uninstall.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '06', '6' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_config.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '07', '7' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_status.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in '08', '8' }  { Invoke-SubScript { & "$PSScriptRoot\components\wsl_purge.ps1" -DefaultWslRoot $DefaultWslRoot } }
            { $_ -in 'L', 'l' }   { Toggle-Language }
            { $_ -in '99' }       { Show-About; Pause-Menu }
            { [string]::IsNullOrWhiteSpace($_) -or $_ -in '00', '0', 'exit' } { Write-Host "`n$(Get-I18nStr 'Msg_Bye')" -ForegroundColor Gray; exit }
            default {
                Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
                Start-Sleep -Seconds 1.5
            }
        }



    }
}

Main
