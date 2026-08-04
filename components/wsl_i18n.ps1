# ==============================================================================
# components/wsl_i18n.ps1
# Description: WSL 管理工具箱多语言 (i18n) 动态 JSON 语言包加载器
# Author: Fred
# ==============================================================================

# 在点号引入的顶层，锁定当前脚本所在目录与 locales 绝对路径
$global:I18nLocalesDir = Join-Path $PSScriptRoot "locales"

# 默认根据当前 Windows 系统语言自动初始化
if (-not $global:CurrentLang) {
    $uiLang = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    $global:CurrentLang = if ($uiLang -like 'zh*') { 'zh-CN' } else { 'en-US' }
}

if (-not $global:LoadedLocales) {
    $global:LoadedLocales = New-Object 'System.Collections.Generic.Dictionary[string, object]'
}

function Load-LocaleJson {
    param(
        [string]$Lang
    )

    if ($global:LoadedLocales.ContainsKey($Lang)) {
        return $global:LoadedLocales[$Lang]
    }

    $jsonPath = Join-Path $global:I18nLocalesDir "$Lang.json"

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
            Write-Host "[!] Error loading JSON ${jsonPath}: $($_.Exception.Message)" -ForegroundColor Red
        }
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
