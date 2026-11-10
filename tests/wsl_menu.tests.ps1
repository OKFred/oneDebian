# Offline menu checks: load the actual functions without starting the main loop.
$ErrorActionPreference = 'Stop'
$menuRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $menuRepoRoot 'components\wsl_i18n.ps1')
$tokens = $null
$parseErrors = $null
$menuAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $menuRepoRoot 'menu.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Menu source contains parser errors.' }
foreach ($name in @('Invoke-SubScript', 'Main')) {
    $definition = $menuAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $definition) { throw "Menu function is missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$menuOriginalLanguage = $global:CurrentLang
$script:menuTestCount = 0
$script:menuFailures = New-Object System.Collections.Generic.List[string]

function Assert-Menu {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Test-MenuCase {
    param([string]$Name, [scriptblock]$Body)
    $script:menuTestCount++
    try { & $Body; Write-Host "  PASS $Name" -ForegroundColor Green }
    catch { $script:menuFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "  FAIL ${Name}: $($_.Exception.Message)" -ForegroundColor Red }
}

try {
    Test-MenuCase 'subscript errors preserve diagnostics and pause without blaming menu input' {
        foreach ($language in @('zh-CN', 'en-US')) {
            $global:CurrentLang = $language
            $state = [pscustomobject]@{ Messages = (New-Object System.Collections.Generic.List[string]); Pauses = 0 }
            function Write-Host { param($Object, $ForegroundColor) $state.Messages.Add([string]$Object) }
            function Pause-Menu { $state.Pauses++ }
            Invoke-SubScript { throw '/bin/sh: 1: set: Illegal option -' }
            $output = $state.Messages -join "`n"
            Assert-Menu ($output.Contains((Get-I18nStr 'Err_OperationFailed')) -and $output.Contains('/bin/sh: 1: set: Illegal option -')) 'the operation label or original exception was lost'
            Assert-Menu (-not $output.Contains((Get-I18nStr 'Err_InvalidChoice'))) 'a subscript failure was labeled as invalid menu input'
            Assert-Menu ($state.Pauses -eq 1) 'failed execution did not pause exactly once'
        }
    }
    Test-MenuCase 'successful subscript output and pause remain unchanged' {
        $state = [pscustomobject]@{ Messages = (New-Object System.Collections.Generic.List[string]); Pauses = 0 }
        function Write-Host { param($Object, $ForegroundColor) $state.Messages.Add([string]$Object) }
        function Pause-Menu { $state.Pauses++ }
        $result = Invoke-SubScript { 'completed' }
        Assert-Menu ($result -ceq 'completed' -and $state.Messages.Count -eq 0 -and $state.Pauses -eq 1) 'successful execution changed output, printed an error, or did not pause'
    }
    Test-MenuCase 'an invalid menu choice keeps its own input error label' {
        $global:CurrentLang = 'zh-CN'
        $state = [pscustomobject]@{ Messages = (New-Object System.Collections.Generic.List[string]); Reads = 0; Sleeps = 0 }
        function Write-Host { param($Object, $ForegroundColor) $state.Messages.Add([string]$Object) }
        function Clear-Host { }
        function Start-Sleep { param($Seconds) $state.Sleeps++ }
        function Read-Host {
            param($Prompt)
            $state.Reads++
            if ($state.Reads -gt 1) { throw 'end private menu fixture' }
            'invalid-menu-choice'
        }
        try { Main } catch { if ($_.Exception.Message -cne 'end private menu fixture') { throw } }
        $output = $state.Messages -join "`n"
        Assert-Menu ($output.Contains((Get-I18nStr 'Err_InvalidChoice')) -and -not $output.Contains((Get-I18nStr 'Err_OperationFailed'))) 'invalid input was labeled as an operation failure'
        Assert-Menu ($state.Reads -eq 2 -and $state.Sleeps -eq 1) 'invalid input did not return to the menu'
    }
} finally {
    $global:CurrentLang = $menuOriginalLanguage
}
Write-Host "WSL menu regressions: $script:menuTestCount tests, $($script:menuFailures.Count) failures."
if ($script:menuFailures.Count -gt 0) { throw ($script:menuFailures -join "`n") }
