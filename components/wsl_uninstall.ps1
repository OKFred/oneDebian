# ==============================================================================
# components/wsl_uninstall.ps1
# Description: 05. 卸载 (注销) WSL 发行版 (支持 i18n 多语言)
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

    $distros = Get-WslDistros
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

    # 1/2 第一次确认
    Write-Host "`n$(Get-I18nStr 'Uninstall_Warn_Step1')" -ForegroundColor Red
    foreach ($d in $targetDistros) { Write-Host "  • $d" -ForegroundColor Yellow }

    $confirm1 = Read-Host "`n$(Get-I18nStr 'Uninstall_Confirm_Step1')"
    if ($confirm1 -ne 'Y' -and $confirm1 -ne 'y') {
        Write-Host "$(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray
        return
    }

    # 2/2 第二次确认
    $confirm2 = Read-Host "`n$(Get-I18nStr 'Uninstall_Confirm_Step2')"
    if ($confirm2 -ne 'DELETE') {
        Write-Host "`n[!] 二次确认未通过，卸载注销操作已安全取消。" -ForegroundColor Yellow
        return
    }

    # 执行卸载
    foreach ($name in $targetDistros) {
        Write-Host "`n正在注销 WSL 发行版: $name ..." -ForegroundColor Red
        & wsl.exe --unregister $name
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[✓] 已成功注销 $name" -ForegroundColor Green
            $localDir = Join-Path $DefaultWslRoot $name
            if (Test-Path -LiteralPath $localDir) {
                Write-Host "提示: 本地残留数据文件夹依然保留在: $localDir (可手动删除)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "[!] 注销 $name 失败！" -ForegroundColor Red
        }
    }
}

Invoke-WslUninstall
