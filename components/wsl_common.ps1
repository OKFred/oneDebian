# ==============================================================================
# components/wsl_common.ps1
# Description: WSL 管理脚本公共辅助函数 (修复 -f 格式化输出 System.String[] 的 Bug)
# Author: Fred
# ==============================================================================

function Get-WslDistros {
    $distros = New-Object System.Collections.Generic.List[string]

    try {
        $raw = & wsl.exe --list --quiet 2>$null
        if ($raw) {
            $lines = ($raw | Out-String) -replace "`0", "" -split "`r?`n"
            foreach ($line in $lines) {
                $name = $line.Trim()
                # 过滤无已安装分发时的系统提示词条
                if ($name -and 
                    $name -ne 'NAME' -and 
                    $name -notlike '*no installed distributions*' -and 
                    $name -notlike '*没有已安装的分发*' -and 
                    $name -notlike '*Use *wsl.exe*' -and 
                    -not $distros.Contains($name)) {
                    $distros.Add($name)
                }
            }
        }
    } catch {}

    # 返回纯粹打平的一维字符串数组
    return [string[]]$distros.ToArray()
}

function Select-WslDistro {
    param(
        [string]$Title = $(Get-I18nStr 'Select_Distro_Title')
    )

    [string[]]$distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Host "`n[!] $(Get-I18nStr 'No_Distro_Found')" -ForegroundColor Red
        return $null
    }

    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $distros.Count; $i++) {
        $name = [string]$distros[$i]
        Write-Host " [$($i + 1)] $name"
    }

    while ($true) {
        $inputVal = Read-Host "`n$(Get-I18nStr 'Select_Index_Prompt') [1-$($distros.Count)] (输入 0 取消)"
        if ($inputVal -eq '0') {
            Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
            return $null
        }

        if ($inputVal -match '^\d+$') {
            $index = [int]$inputVal - 1
            if ($index -ge 0 -and $index -lt $distros.Count) {
                return [string]$distros[$index]
            }
        }

        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
    }
}
