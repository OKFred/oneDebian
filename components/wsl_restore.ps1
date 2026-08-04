# ==============================================================================
# components/wsl_restore.ps1
# Description: 04. 还原 (导入) WSL 发行版 (支持 i18n 多语言)
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslRestore {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     $(Get-I18nStr 'Restore_Title')      " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $distroName = Read-Host "`nEnter New Distro Name to Import (e.g. Debian-13-Restored)"
    if (-not $distroName) {
        Write-Host "`n[!] Distro name cannot be empty." -ForegroundColor Red
        return
    }

    $importFile = Read-Host "`nEnter Backup File Path (.tar / .vhdx)"
    if (-not $importFile -or -not (Test-Path -LiteralPath $importFile)) {
        Write-Host "`n[!] Backup file not found: $importFile" -ForegroundColor Red
        return
    }

    $installDir = Join-Path $DefaultWslRoot $distroName

    $confirm = Read-Host "`nConfirm Import '$distroName' from '$importFile' to '$installDir'? [Y/N]"
    if ($confirm -in 'Y', 'y') {
        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }

        Write-Host "`nImporting WSL distro '$distroName'..." -ForegroundColor Green
        if ($importFile.EndsWith('.vhdx', [System.StringComparison]::OrdinalIgnoreCase)) {
            & wsl.exe --import-in-place $distroName $importFile
        } else {
            & wsl.exe --import $distroName $installDir $importFile --version 2
        }

        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n[✓] Import Restore Successful! Run 'wsl -d $distroName' to launch." -ForegroundColor Green
        } else {
            Write-Host "`n[!] Import Failed!" -ForegroundColor Red
        }
    } else {
        Write-Host "`n$(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray
    }
}

Invoke-WslRestore
