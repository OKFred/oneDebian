# ==============================================================================
# components/wsl_uninstall.ps1
# Description: 05. 卸载 (注销) WSL 发行版 (单次 Y/N 确认，防误输入)
# Author: Fred
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslUninstall {
    Write-Host "`n==========================================" -ForegroundColor Red
    Write-Host "     $(Get-I18nStr 'Uninstall_Title')    " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red

    $distros = @(Get-WslDistros)

    if ($distros.Count -eq 0) {
        Write-Host "`n$(Get-I18nStr 'No_Distro_Found')" -ForegroundColor Red
        return
    }

    Write-Host "`n$(Get-I18nStr 'Uninstall_Select_Title')" -ForegroundColor Cyan
    for ($i = 0; $i -lt $distros.Count; $i++) {
        Write-Host " [$($i + 1)] $($distros[$i])"
    }
    Write-Host " [A] 全选 (Select All) - 卸载全部已安装的 WSL 发行版" -ForegroundColor Red
    Write-Host " [0] $(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray

    $choice = Read-Host "`n请输入序号 [1-$($distros.Count), A, 0]"
    if ($choice -eq '0' -or -not $choice) { return }

    $targetDistros = @()
    if ($choice -in 'A', 'a', 'ALL', 'all') {
        $targetDistros = $distros
    } elseif ($choice -match '^\d+$') {
        $idx = [int]$choice - 1
        if ($idx -ge 0 -and $idx -lt $distros.Count) {
            $targetDistros = @($distros[$idx])
        }
    }

    if ($targetDistros.Count -eq 0) {
        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
        return
    }

    # 确认注销（单次 Y/N 确认）
    Write-Host "`n$(Get-I18nStr 'Uninstall_Warn_Step1')" -ForegroundColor Red
    foreach ($d in $targetDistros) { Write-Host "  • $d" -ForegroundColor Yellow }

    $confirm = Read-Host "`n确认要卸载注销上述 WSL 发行版吗？[Y/N]"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
        return
    }

    # 执行卸载
    foreach ($name in $targetDistros) {
        Write-Host "`n正在注销 WSL 发行版: $name ..." -ForegroundColor Red
        & wsl.exe --unregister $name 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[✓] 已成功注销 $name" -ForegroundColor Green
            $localDir = Join-Path $DefaultWslRoot $name
            if (Test-Path -LiteralPath $localDir) {
                Write-Host "提示: 本地残留数据文件夹已物理清除: $localDir" -ForegroundColor Yellow
                Remove-Item -LiteralPath $localDir -Recurse -Force 2>$null
            }
        } else {
            Write-Host "[!] 注销 $name 失败！" -ForegroundColor Red
        }
    }
}

Invoke-WslUninstall
