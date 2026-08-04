# ==============================================================================
# components/wsl_i18n.ps1
# Description: WSL 管理工具箱多语言 (i18n) 动态 JSON 语言包加载器
# Author: Fred
# ==============================================================================

# 默认初始化语言为 简体中文 (zh-CN) (按 L 可随时切换为 English)
if (-not $global:CurrentLang) {
    $global:CurrentLang = 'zh-CN'
}


if (-not $global:LoadedLocales) {
    $global:LoadedLocales = New-Object 'System.Collections.Generic.Dictionary[string, object]'
}

# 动态多重查找 locales 语言包目录
function Get-LocalesDirectory {
    $possiblePaths = @(
        "$PSScriptRoot\locales",
        "$PSScriptRoot\components\locales",
        "D:\workspace\okfred\oneDebian\components\locales",
        "D:\workspace\okfred\oneDebian\locales"
    )

    foreach ($path in $possiblePaths) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return $null
}

function Load-LocaleJson {
    param(
        [string]$Lang
    )

    if ($global:LoadedLocales.ContainsKey($Lang)) {
        $existingDict = $global:LoadedLocales[$Lang]
        if ($existingDict -and $existingDict.Count -gt 0) {
            return $existingDict
        }
    }

    $localesDir = Get-LocalesDirectory
    if (-not $localesDir) {
        Write-Host "[!] Error: locales directory not found!" -ForegroundColor Red
        return (New-Object 'System.Collections.Generic.Dictionary[string, string]')
    }

    $jsonPath = Join-Path $localesDir "$Lang.json"

    if (Test-Path -LiteralPath $jsonPath) {
        try {
            $rawJson = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8
            $jsonObject = $rawJson | ConvertFrom-Json
            
            $dict = New-Object 'System.Collections.Generic.Dictionary[string, string]'
            foreach ($prop in $jsonObject.PSObject.Properties) {
                $dict[$prop.Name] = [string]$prop.Value
            }

            $global:LoadedLocales[$Lang] = $dict
            return $dict
        } catch {
            Write-Host "[!] Error parsing JSON ${jsonPath}: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "[!] Locale file not found at: $jsonPath" -ForegroundColor Red
    }
    return (New-Object 'System.Collections.Generic.Dictionary[string, string]')
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

    if ($Args.Count -gt 0 -and $text) {
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
