# Dependency-free checks for Windows PowerShell 5.1 and later.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

Write-Host '[1/5] Parsing PowerShell files...' -ForegroundColor Cyan
foreach ($file in (Get-ChildItem $repoRoot -Recurse -Filter '*.ps1')) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "$($file.FullName) contains parser errors"
}

Write-Host '[2/5] Checking Windows PowerShell encoding compatibility...' -ForegroundColor Cyan
$configPath = Join-Path $repoRoot 'components\wsl_config.ps1'
$configBytes = [System.IO.File]::ReadAllBytes($configPath)
$hasUtf8Bom = $configBytes.Length -ge 3 -and $configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB -and $configBytes[2] -eq 0xBF
Assert-True $hasUtf8Bom 'wsl_config.ps1 must use UTF-8 BOM for Windows PowerShell 5.1'

Write-Host '[3/5] Testing incremental INI updates...' -ForegroundColor Cyan
. (Join-Path $repoRoot 'components\wsl_config.ps1')

$original = @'
; keep this comment
[wsl2]
kernel=C:\custom\kernel
memory=4GB
memory=6GB
dnsTunneling=true

[custom]
unknown=value
'@

$updated = Set-IniValue -Content $original -Section 'wsl2' -Key 'memory' -Value '8GB'
$updated = Set-IniValue -Content $updated -Section 'wsl2' -Key 'dnsTunneling' -Remove
$updated = Set-IniValue -Content $updated -Section 'wsl2' -Key 'autoProxy' -Value 'true'

Assert-True ((Get-IniValue $updated 'wsl2' 'memory') -eq '8GB') 'existing key was not updated'
Assert-True ($null -eq (Get-IniValue $updated 'wsl2' 'dnsTunneling')) 'removed key is still present'
Assert-True ((Get-IniValue $updated 'wsl2' 'autoProxy') -eq 'true') 'new key was not inserted'
Assert-True (($updated -split "`r?`n" | Where-Object { $_ -match '^memory=' }).Count -eq 1) 'duplicate keys were not collapsed'
Assert-True ($updated.Contains('; keep this comment')) 'comment was not preserved'
Assert-True ($updated.Contains('kernel=C:\custom\kernel')) 'unknown key was not preserved'
Assert-True ($updated.Contains('[custom]')) 'unknown section was not preserved'

$nullPromptResult = & {
    function Read-Host { param([string]$Prompt) return '' }
    Read-ConfigPrompt -Message 'test' -CurrentValue $null
}
Assert-True ($null -eq $nullPromptResult.Value) 'an unset value must remain null instead of becoming an empty string'

Show-ConfigDiff -OldContent "[wsl2]`r`nmemory=4GB`r`n" -NewContent "[wsl2]`nmemory=8GB`n" -TargetTitle 'Regression test'

Write-Host '[4/5] Validating locale JSON files...' -ForegroundColor Cyan
foreach ($locale in (Get-ChildItem $repoRoot -Recurse -Filter '*.json' | Where-Object { $_.DirectoryName -match 'locales$' })) {
    $parsed = Get-Content -LiteralPath $locale.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($null -ne $parsed) "$($locale.FullName) is not valid JSON"
}
$rootEnglishHash = (Get-FileHash (Join-Path $repoRoot 'locales\en-US.json')).Hash
$componentEnglishHash = (Get-FileHash (Join-Path $repoRoot 'components\locales\en-US.json')).Hash
$rootChineseHash = (Get-FileHash (Join-Path $repoRoot 'locales\zh-CN.json')).Hash
$componentChineseHash = (Get-FileHash (Join-Path $repoRoot 'components\locales\zh-CN.json')).Hash
Assert-True ($rootEnglishHash -eq $componentEnglishHash) 'English locale copies are out of sync'
Assert-True ($rootChineseHash -eq $componentChineseHash) 'Chinese locale copies are out of sync'

Write-Host '[5/5] Checking destructive-operation guardrails...' -ForegroundColor Cyan
$purgeSource = Get-Content -LiteralPath (Join-Path $repoRoot 'components\wsl_purge.ps1') -Raw -Encoding UTF8
$uninstallSource = Get-Content -LiteralPath (Join-Path $repoRoot 'components\wsl_uninstall.ps1') -Raw -Encoding UTF8
Assert-True (-not $purgeSource.Contains('Remove-Item -LiteralPath $distroDir')) 'purge must not guess and recursively delete distro directories'
Assert-True (-not $uninstallSource.Contains('Remove-Item -LiteralPath $localDir')) 'uninstall must not guess and recursively delete distro directories'
Assert-True ($purgeSource.Contains("-cne 'PURGE'")) 'purge must require the PURGE confirmation token'
Assert-True ($uninstallSource.Contains("-cne 'DELETE'")) 'uninstall must require the DELETE confirmation token'

Write-Host 'All WSL logic tests passed.' -ForegroundColor Green
