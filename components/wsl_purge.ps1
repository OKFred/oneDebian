# ==============================================================================
# components/wsl_purge.ps1
# Description: 08. WSL 环境全量彻底清理与重置 (支持 i18n 多语言)
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

    Write-Host "`n[!] WSL Environment Scan Summary:" -ForegroundColor Yellow
    Write-Host "  • Detected WSL Distros: $(if ($distros.Count -gt 0) { $distros -join ', ' } else { 'None' })" -ForegroundColor Cyan
    Write-Host "  • Install Root Path:   $DefaultWslRoot" -ForegroundColor Cyan
    Write-Host "  • Rootfs Image Cache:  $archiveDir" -ForegroundColor Gray
    Write-Host "  • Backup Directory:    $backupDir" -ForegroundColor Gray

    Write-Host "`nSelect Purge Scope:" -ForegroundColor Yellow
    Write-Host " [A] Full Purge - Unregister all distros, remove data folders, rootfs & backups" -ForegroundColor Red
    Write-Host " [S] Single Purge - Unregister & remove single specified distro" -ForegroundColor Yellow
    Write-Host " [0] $(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray

    $modeChoice = Read-Host "`n$(Get-I18nStr 'Prompt_Select') [A / S / 0]"
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
            Write-Host "   • Unregister & delete folder: $DefaultWslRoot\$d" -ForegroundColor Yellow
        }
    }
    if ($cleanImages -and (Test-Path -LiteralPath $archiveDir)) {
        Write-Host "   • Delete rootfs cache: $archiveDir" -ForegroundColor Yellow
    }
    if ($cleanBackups -and (Test-Path -LiteralPath $backupDir)) {
        Write-Host "   • Delete all backups: $backupDir" -ForegroundColor Yellow
    }

    $confirm1 = Read-Host "`n$(Get-I18nStr 'Purge_Confirm_Step1')"
    if ($confirm1 -ne 'Y' -and $confirm1 -ne 'y') {
        Write-Host "$(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray
        return
    }

    # 2/2 第二次确认
    $confirm2 = Read-Host "`n$(Get-I18nStr 'Purge_Confirm_Step2')"
    if ($confirm2 -ne 'PURGE') {
        Write-Host "`n[!] Confirmation failed. Purge operation cancelled." -ForegroundColor Yellow
        return
    }

    # 执行清理
    Write-Host "`nShutting down WSL ..." -ForegroundColor Red
    & wsl.exe --shutdown 2>$null

    foreach ($d in $targetDistros) {
        Write-Host "`n[1/3] Unregistering WSL distro: $d ..." -ForegroundColor Red
        & wsl.exe --unregister $d 2>$null

        $distroDir = Join-Path $DefaultWslRoot $d
        if (Test-Path -LiteralPath $distroDir) {
            Write-Host "     Deleting storage directory: $distroDir ..." -ForegroundColor Yellow
            Remove-Item -LiteralPath $distroDir -Recurse -Force 2>$null
        }
    }

    if ($cleanImages -and (Test-Path -LiteralPath $archiveDir)) {
        Write-Host "`n[2/3] Deleting image cache: $archiveDir ..." -ForegroundColor Red
        Remove-Item -LiteralPath $archiveDir -Recurse -Force 2>$null
    }

    if ($cleanBackups -and (Test-Path -LiteralPath $backupDir)) {
        Write-Host "`n[3/3] Deleting backup directory: $backupDir ..." -ForegroundColor Red
        Remove-Item -LiteralPath $backupDir -Recurse -Force 2>$null
    }

    Write-Host "`nResetting WSL core stack..." -ForegroundColor Green
    & wsl.exe --shutdown 2>$null

    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host "       [✓] Full WSL Purge Complete!       " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
}

Invoke-WslPurge
