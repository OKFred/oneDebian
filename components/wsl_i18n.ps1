# ==============================================================================
# components/wsl_i18n.ps1
# Description: WSL 管理工具箱多语言 (i18n) 动态 JSON 语言包加载器
# Author: Fred
# ==============================================================================

# 默认根据当前 Windows 系统语言自动初始化 (提升为 $global 作用域以跨子脚本保持同步)
if (-not $global:CurrentLang) {
    $uiLang = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    $global:CurrentLang = if ($uiLang -like 'zh*') { 'zh-CN' } else { 'en-US' }
}

# 内存中缓存解析好的 JSON 语言包
if (-not $global:LoadedLocales) {
    $global:LoadedLocales = @{}
}

function Load-LocaleJson {
    param(
        [string]$Lang
    )

    if ($global:LoadedLocales.ContainsKey($Lang)) {
        return $global:LoadedLocales[$Lang]
    }

    $jsonPath = Join-Path $PSScriptRoot "locales\$Lang.json"
    if (Test-Path -LiteralPath $jsonPath) {
        try {
            $rawJson = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8
            $jsonObject = $rawJson | ConvertFrom-Json
            
            # 转为 PowerShell 哈希表
            $dict = @{}
            foreach ($prop in $jsonObject.PSObject.Properties) {
                $dict[$prop.Name] = $prop.Value
            }

            $global:LoadedLocales[$Lang] = $dict
            return $dict
        } catch {
            Write-Host "[!] Failed to parse locale JSON '$jsonPath': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    return @{}
}

function Get-I18nStr {
    param(
        [string]$Key,
        [object[]]$Args = @()
    )

    $currentDict = Load-LocaleJson -Lang $global:CurrentLang
    $text = $null

    if ($currentDict.ContainsKey($Key)) {
        $text = $currentDict[$Key]
    } else {
        # Fallback 机制：若当前语言丢失 key，退回到 zh-CN.json 寻全
        $fallbackDict = Load-LocaleJson -Lang 'zh-CN'
        if ($fallbackDict.ContainsKey($Key)) {
            $text = $fallbackDict[$Key]
        } else {
            $text = $Key
        }
    }

    if ($Args.Count -gt 0) {
        return [string]::Format($text, $Args)
    }
    return $text
}

function Toggle-Language {
    if ($global:CurrentLang -eq 'zh-CN') {
        $global:CurrentLang = 'en-US'
        Write-Host "`n[✓] Language switched to English!" -ForegroundColor Green
    } else {
        $global:CurrentLang = 'zh-CN'
        Write-Host "`n[✓] 界面语言已切换为 简体中文！" -ForegroundColor Green
    }
    Start-Sleep -Seconds 1
}
