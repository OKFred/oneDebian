# ==============================================================================
# components/wsl_common.ps1
# Description: WSL 管理脚本公共辅助函数 (防解包纯净版)
# Author: Fred
# ==============================================================================

function Get-WslDistros {
    $distros = New-Object System.Collections.Generic.List[string]

    try {
        $rawList = & wsl.exe --list --quiet 2>$null
        if ($rawList) {
            foreach ($item in $rawList) {
                # 正则清洗杂质与 UTF-16 字节，仅保留 Linux 发行版标准合法字符
                $cleanName = ($item -replace '[^a-zA-Z0-9._-]', '').Trim()
                if ($cleanName -and $cleanName -ne 'NAME' -and -not $distros.Contains($cleanName)) {
                    $distros.Add($cleanName)
                }
            }
        }
    } catch {}

    # 逗号运算符前缀，防止 PowerShell pipeline 展开单元素数组
    return ,($distros.ToArray())
}

function Select-WslDistro {
    param(
        [string]$Title = $(Get-I18nStr 'Select_Distro_Title')
    )

    # 强制 @() 数组包裹，防护单字符串索引 [0] 误拆成首字符
    $distros = @(Get-WslDistros)
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
            Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
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
