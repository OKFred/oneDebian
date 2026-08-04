# ==============================================================================
# components/wsl_common.ps1
# Description: WSL 管理脚本公共辅助函数
# ==============================================================================

function Get-WslDistros {
    $rawList = & wsl.exe --list --quiet 2>$null
    if (-not $rawList) { return @() }
    
    $distros = @(
        $rawList | ForEach-Object { $_ -replace "`0", "" } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    return $distros
}

function Select-WslDistro {
    param(
        [string]$Title = $(Get-I18nStr 'Select_Distro_Title')
    )

    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Host "`n[!] $(Get-I18nStr 'No_Distro_Found')" -ForegroundColor Red
        return $null
    }

    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $distros.Count; $i++) {
        Write-Host " [$($i + 1)] $($distros[$i])"
    }

    while ($true) {
        $inputVal = Read-Host "`n$(Get-I18nStr 'Select_Index_Prompt') [1-$($distros.Count)] (输入 0 取消)"
        if ($inputVal -eq '0') {
            Write-Host "$(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray
            return $null
        }

        if ($inputVal -match '^\d+$') {
            $index = [int]$inputVal - 1
            if ($index -ge 0 -and $index -lt $distros.Count) {
                return $distros[$index]
            }
        }

        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
    }
}

function Pause-Menu {
    Write-Host "`n$(Get-I18nStr 'Msg_Pause')" -ForegroundColor Gray
    $null = [Console]::ReadKey($true)
}
