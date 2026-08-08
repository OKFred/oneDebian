# ==============================================================================
# components/wsl_update.ps1
# Description: 02. 更新 系统软件包与 WSL 核心 (支持 i18n 多语言)
# ==============================================================================

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslUpdate {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     $(Get-I18nStr 'Update_Title')       " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    Write-Host "`n$(Get-I18nStr 'Update_Opt_Apt')" -ForegroundColor Yellow
    Write-Host "$(Get-I18nStr 'Update_Opt_Core')" -ForegroundColor Yellow
    Write-Host "[0] $(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray

    $choice = Read-Host "`n$(Get-I18nStr 'Prompt_Select')"
    if ($choice -eq '0' -or -not $choice) { return }

    if ($choice -in '1', '01') {
        $targetDistro = Select-WslDistro -Title $(Get-I18nStr 'Select_Distro_Title')
        if (-not $targetDistro) { return }

        $confirm = Read-Host "`n$(Get-I18nStr 'Update_Confirm_Prompt')"
        if ($confirm -in 'Y', 'y') {
            Write-Host "`nExecuting: apt-get update && apt-get dist-upgrade -y in $targetDistro ..." -ForegroundColor Green
            & wsl.exe -d $targetDistro -u root -- bash -c "apt-get update && apt-get dist-upgrade -y"
            if ($LASTEXITCODE -eq 0) {
                Write-Host "`n[✓] Update complete!" -ForegroundColor Green
            } else {
                Write-Host "`n[!] Package update failed (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
            }
        }
    } elseif ($choice -in '2', '02') {
        $confirm = Read-Host "`nExecuting wsl --update. $(Get-I18nStr 'Update_Confirm_Prompt')"
        if ($confirm -in 'Y', 'y') {
            Write-Host "`nExecuting: wsl --update ..." -ForegroundColor Green
            & wsl.exe --update
            if ($LASTEXITCODE -eq 0) {
                Write-Host "`n[✓] WSL core update complete!" -ForegroundColor Green
            } else {
                Write-Host "`n[!] WSL core update failed (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
            }
        }
    } else {
        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
    }
}

Invoke-WslUpdate
