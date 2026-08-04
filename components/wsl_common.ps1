# ==============================================================================
# components/wsl_common.ps1
# Description: WSL 管理脚本公共辅助函数 (防止 PowerShell 数组解包导致 $distros[0] 变成首字符 'd')
# Author: Fred
# ==============================================================================

function Get-WslDistros {
    $distros = New-Object System.Collections.Generic.List[string]

    # 1. 第一最高优先级：从 Windows 注册表 Lxss 中精确获取
    try {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (Test-Path -Path $regPath) {
            $regKeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
            foreach ($k in $regKeys) {
                $rawProp = (Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue).DistributionName
                if ($rawProp) {
                    $cleanName = ($rawProp -replace '[^a-zA-Z0-9._-]', '').Trim()
                    if ($cleanName -and -not $distros.Contains($cleanName)) {
                        $distros.Add($cleanName)
                    }
                }
            }
        }
    } catch {}

    # 2. 备用降级方案：解析 wsl.exe --list --quiet
    if ($distros.Count -eq 0) {
        try {
            $rawList = & wsl.exe --list --quiet 2>$null
            if ($rawList) {
                foreach ($item in $rawList) {
                    $cleanName = ($item -replace '[^a-zA-Z0-9._-]', '').Trim()
                    if ($cleanName -and $cleanName -ne 'NAME' -and -not $distros.Contains($cleanName)) {
                        $distros.Add($cleanName)
                    }
                }
            }
        } catch {}
    }

    # 强力逗号运算符前缀，防止 PowerShell pipeline 展开单元素数组导致变成 String 标量
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
