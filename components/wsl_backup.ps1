# ==============================================================================
# components/wsl_backup.ps1
# Description: 03. 备份 (导出) WSL 发行版 (支持 i18n 多语言)
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslBackup {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     $(Get-I18nStr 'Backup_Title')       " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $distro = Select-WslDistro -Title $(Get-I18nStr 'Select_Distro_Title')
    if (-not $distro) { return }

    $backupDir = Join-Path $DefaultWslRoot 'backups'
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Write-Host "`n [1] TAR（默认，兼容性最好）"
    Write-Host " [2] VHDX（仅 WSL 2，通常更快）"
    $formatChoice = Read-Host 'Select backup format [1/2]'
    $useVhd = $formatChoice -eq '2'
    $extension = if ($useVhd) { '.vhdx' } else { '.tar' }
    $defaultFile = Join-Path $backupDir "$distro-backup-$timestamp$extension"

    $fileInput = Read-Host "`nEnter Backup Export File Path (Default: $defaultFile)"
    $exportPath = if ($fileInput) { $fileInput } else { $defaultFile }
    if ($useVhd -and -not $exportPath.EndsWith('.vhdx', [System.StringComparison]::OrdinalIgnoreCase)) {
        $exportPath = "$exportPath.vhdx"
        Write-Host "Adjusted VHDX backup path: $exportPath" -ForegroundColor Yellow
    } elseif (-not $useVhd -and -not $exportPath.EndsWith('.tar', [System.StringComparison]::OrdinalIgnoreCase)) {
        $exportPath = "$exportPath.tar"
        Write-Host "Adjusted TAR backup path: $exportPath" -ForegroundColor Yellow
    }

    $confirm = Read-Host "`nConfirm Export '$distro' to '$exportPath'? [Y/N]"
    if ($confirm -in 'Y', 'y') {
        Write-Host "`nExporting WSL distro '$distro' to '$exportPath'..." -ForegroundColor Green
        if ($useVhd) {
            & wsl.exe --export $distro $exportPath --vhd
        } else {
            & wsl.exe --export $distro $exportPath
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n[✓] Export Backup Successful! File: $exportPath" -ForegroundColor Green
        } else {
            Write-Host "`n[!] Export Backup Failed!" -ForegroundColor Red
        }
    } else {
        Write-Host "`n$(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray
    }
}

Invoke-WslBackup
