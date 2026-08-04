# ==============================================================================
# components/wsl_purge.ps1
# Description: 08. WSL 环境全量彻底清理与重置 (100% 全量双语 i18n 兼容)
# Author: Fred
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslPurge {
    Write-Host "`n==========================================" -ForegroundColor Red
    Write-Host "     $(Get-I18nStr 'Purge_Title')        " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red

    $distros = Get-WslDistros
    $archiveDir = Join-Path $DefaultWslRoot 'images'
    $backupDir = Join-Path $DefaultWslRoot 'backups'

    Write-Host "`n$(Get-I18nStr 'Purge_Scan_Summary')" -ForegroundColor Yellow
    $noneStr = if ($global:CurrentLang -eq 'zh-CN') { '无' } else { 'None' }
    $distroStr = if ($distros.Count -gt 0) { $distros -join ', ' } else { $noneStr }

    Write-Host "  • $(Get-I18nStr 'Purge_Detected_Distros'): $distroStr" -ForegroundColor Cyan
    Write-Host "  • $(Get-I18nStr 'Purge_Install_Root'):   $DefaultWslRoot" -ForegroundColor Cyan
    Write-Host "  • $(Get-I18nStr 'Purge_Image_Cache'):  $archiveDir" -ForegroundColor Gray
    Write-Host "  • $(Get-I18nStr 'Purge_Backup_Dir'):    $backupDir" -ForegroundColor Gray

    Write-Host "`n$(Get-I18nStr 'Purge_Scope_Title')" -ForegroundColor Yellow
    Write-Host " $(Get-I18nStr 'Purge_Opt_All')" -ForegroundColor Red
    Write-Host " $(Get-I18nStr 'Purge_Opt_Single')" -ForegroundColor Yellow
    Write-Host " [0] $(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray

    $modeChoice = Read-Host "`n$(Get-I18nStr 'Purge_Prompt_Choice')"
    if ($modeChoice -eq '0' -or -not $modeChoice) { return }

    $targetDistros = @()
    $cleanImages = $false
    $cleanBackups = $false

    if ($modeChoice -in 'A', 'a', 'ALL', 'all') {
        $targetDistros = $distros
        $cleanImages = $true
        $cleanBackups = $true
    } elseif ($modeChoice -in 'S', 's') {
        $single = Select-WslDistro -Title $(Get-I18nStr 'Select_Distro_Title')
        if (-not $single) { return }
        $targetDistros = @($single)
    } else {
        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
        return
    }

    # 1/2 第一次确认
    Write-Host "`n==========================================" -ForegroundColor Red
    Write-Host "       $(Get-I18nStr 'Purge_Warn')       " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    if ($targetDistros.Count -gt 0) {
        foreach ($d in $targetDistros) {
            Write-Host "   • $(Get-I18nStr 'Purge_Unregister_Delete'): $DefaultWslRoot\$d" -ForegroundColor Yellow
        }
    }
    if ($cleanImages -and (Test-Path -LiteralPath $archiveDir)) {
        Write-Host "   • $(Get-I18nStr 'Purge_Delete_Cache'): $archiveDir" -ForegroundColor Yellow
    }
    if ($cleanBackups -and (Test-Path -LiteralPath $backupDir)) {
        Write-Host "   • $(Get-I18nStr 'Purge_Delete_Backups'): $backupDir" -ForegroundColor Yellow
    }

    $confirm1 = Read-Host "`n$(Get-I18nStr 'Purge_Confirm_Step1')"
    if ($confirm1 -ne 'Y' -and $confirm1 -ne 'y') {
        Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
        return
    }

    # 2/2 第二次确认
    $confirm2 = Read-Host "`n$(Get-I18nStr 'Purge_Confirm_Step2')"
    if ($confirm2 -ne 'PURGE') {
        Write-Host "`n[!] $(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Yellow
        return
    }

    # 执行清理
    Write-Host "`n$(Get-I18nStr 'Purge_Shutting_Down')" -ForegroundColor Red
    & wsl.exe --shutdown 2>$null

    foreach ($d in $targetDistros) {
        Write-Host "`n[1/3] $(Get-I18nStr 'Purge_Unregistering'): $d ..." -ForegroundColor Red
        & wsl.exe --unregister $d 2>$null

        $distroDir = Join-Path $DefaultWslRoot $d
        if (Test-Path -LiteralPath $distroDir) {
            Write-Host "     $(Get-I18nStr 'Purge_Deleting_Dir'): $distroDir ..." -ForegroundColor Yellow
            Remove-Item -LiteralPath $distroDir -Recurse -Force 2>$null
        }
    }

    if ($cleanImages -and (Test-Path -LiteralPath $archiveDir)) {
        Write-Host "`n[2/3] $(Get-I18nStr 'Purge_Deleting_Cache_Dir'): $archiveDir ..." -ForegroundColor Red
        Remove-Item -LiteralPath $archiveDir -Recurse -Force 2>$null
    }

    if ($cleanBackups -and (Test-Path -LiteralPath $backupDir)) {
        Write-Host "`n[3/3] $(Get-I18nStr 'Purge_Deleting_Backup_Dir'): $backupDir ..." -ForegroundColor Red
        Remove-Item -LiteralPath $backupDir -Recurse -Force 2>$null
    }

    Write-Host "`n$(Get-I18nStr 'Purge_Resetting_Stack')" -ForegroundColor Green
    & wsl.exe --shutdown 2>$null

    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host "       [✓] $(Get-I18nStr 'Purge_Success')       " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
}

Invoke-WslPurge
