# Offline checks: guest execution and batch mutations are stubbed.
$ErrorActionPreference = 'Stop'
$bootstrapRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $bootstrapRepoRoot 'components\wsl_common.ps1')
. (Join-Path $bootstrapRepoRoot 'components\wsl_bootstrap.ps1')
$script:bootstrapCount = 0
$script:bootstrapFailures = New-Object System.Collections.Generic.List[string]

function Assert-Bootstrap {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Test-BootstrapCase {
    param([string]$Name, [scriptblock]$Body)
    $script:bootstrapCount++
    try { & $Body; Write-Host "  PASS $Name" -ForegroundColor Green }
    catch { $script:bootstrapFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "  FAIL ${Name}: $($_.Exception.Message)" -ForegroundColor Red }
}
function New-BootstrapCommand {
    param([string]$Text = "ONEDEBIAN_BOOTSTRAP_OK`n", [int]$ExitCode = 0, [bool]$IsDecoded = $true, [string]$ErrorText = '')
    [pscustomobject]@{ Text = $Text; ErrorText = $ErrorText; ExitCode = $ExitCode; IsDecoded = $IsDecoded }
}

Test-BootstrapCase 'bundle contains the actual shared components and one explicit entry call' {
    $bundle = Get-WslBootstrapScript
    foreach ($file in @('components\the_os_release.sh', 'components\the_repo_localization.sh', 'components\the_basic_setup.sh', 'bootstrap.sh')) {
        $source = [IO.File]::ReadAllText((Join-Path $bootstrapRepoRoot $file), [Text.Encoding]::UTF8).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
        Assert-Bootstrap ($bundle.Contains($source)) "bundle did not reuse $file"
    }
    Assert-Bootstrap (-not $bundle.Contains("`r") -and -not $bundle.Contains([string][char]0xFEFF)) 'BOM or CRLF leaked into the Linux script'
    Assert-Bootstrap ($bundle.EndsWith("`nthe_bootstrap`n")) 'the bundle has no explicit initialization entry'
    $arguments = @('--distribution', 'Debian QA', '--user', 'root', '--exec', '/bin/bash', '--noprofile', '--norc', '-c', $bundle)
    $command = ($arguments | ForEach-Object { ConvertTo-WslCommandArgument $_ }) -join ' '
    Assert-Bootstrap ($command.Length -lt 30000) 'bundle exceeded the Windows native command-line budget'
}
Test-BootstrapCase 'root invocation preserves the exact selected distribution and verifies completion' {
    $tracking = [pscustomobject]@{ Arguments = @(); Logs = (New-Object System.Collections.Generic.List[string]) }
    function Invoke-WslCommand { param($Arguments) $tracking.Arguments = $Arguments; New-BootstrapCommand }
    function Write-Host { param($Object, $ForegroundColor) $tracking.Logs.Add([string]$Object) }
    $name = 'Debian QA''s 中文'
    Invoke-WslBootstrap -Distro $name
    Assert-Bootstrap ($tracking.Arguments[1] -ceq $name) 'the distribution name was interpolated or changed'
    Assert-Bootstrap (($tracking.Arguments[2..8] -join ' ') -ceq '--user root --exec /bin/bash --noprofile --norc -c') 'initialization did not use root with an explicit clean Bash'
    Assert-Bootstrap ($tracking.Arguments[-1] -ceq (Get-WslBootstrapScript)) 'invocation used a different script from the verified bundle'
}
Test-BootstrapCase 'failed execution, decoding and missing final markers cannot report success' {
    function Write-Host { param($Object, $ForegroundColor) }
    foreach ($command in @(
        (New-BootstrapCommand -ExitCode 7),
        (New-BootstrapCommand -IsDecoded $false),
        (New-BootstrapCommand -Text 'package installation incomplete'),
        (New-BootstrapCommand -Text "ONEDEBIAN_BOOTSTRAP_OK`nunexpected trailing output")
    )) {
        function Invoke-WslCommand { param($Arguments) $command }
        $failed = $false
        try { Invoke-WslBootstrap -Distro 'Debian QA' } catch { $failed = $true }
        Assert-Bootstrap $failed 'unverified initialization was reported as complete'
    }
}
Test-BootstrapCase 'package output and native error details stay visible on failure' {
    $logs = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object, $ForegroundColor) $logs.Add([string]$Object) }
    function Invoke-WslCommand { param($Arguments) New-BootstrapCommand -ExitCode 100 -Text 'APT fixture stdout' -ErrorText 'APT fixture stderr' }
    try { Invoke-WslBootstrap -Distro 'Debian QA' } catch { }
    Assert-Bootstrap (($logs -contains 'APT fixture stdout') -and ($logs -contains 'APT fixture stderr')) 'failure diagnostics were hidden'
}

function Invoke-BootstrapBatchFixture {
    param([scriptblock]$Body)
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('oneDebian bootstrap batch ' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'components') -Force
    $batch = [pscustomobject]@{ Registered = @('Debian QA', 'Debian 中文', 'Debian 03'); Fail = ''; Calls = (New-Object System.Collections.Generic.List[string]) }
    try {
        Copy-Item -LiteralPath (Join-Path $bootstrapRepoRoot 'initialize-via-wsl.ps1') -Destination (Join-Path $fixtureRoot 'initialize-via-wsl.ps1')
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'components\wsl_i18n.ps1'), '', (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'components\wsl_common.ps1'), 'function Get-WslDistros { $batch.Registered }', (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'components\wsl_bootstrap.ps1'), 'function Invoke-WslBootstrap { param($Distro) $batch.Calls.Add($Distro); if ($Distro -ceq $batch.Fail) { throw "fixture package failure" } }', (New-Object Text.UTF8Encoding($true)))
        & $Body (Join-Path $fixtureRoot 'initialize-via-wsl.ps1') $batch
    } finally {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot -ErrorAction Stop).ProviderPath
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -cne [IO.Path]::GetFileName($fixtureRoot)) { throw 'Unsafe bootstrap fixture cleanup target.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Test-BootstrapCase 'batch applies the exact requested existing instances once each' {
    Invoke-BootstrapBatchFixture {
        param($entry, $batch)
        & $entry -DistroName @('Debian 中文', 'Debian QA', 'Debian 中文')
        Assert-Bootstrap (($batch.Calls -join ',') -ceq 'Debian 中文,Debian QA') 'batch changed the names or initialized an instance twice'
    }
}
Test-BootstrapCase 'batch validates all names before applying any instance' {
    Invoke-BootstrapBatchFixture {
        param($entry, $batch)
        $failed = $false
        try { & $entry -DistroName @('Debian QA', 'not-registered') } catch { $failed = $true }
        Assert-Bootstrap ($failed -and $batch.Calls.Count -eq 0) 'an invalid batch partly ran before name validation'
    }
}
Test-BootstrapCase 'batch stops after the first package initialization failure' {
    Invoke-BootstrapBatchFixture {
        param($entry, $batch)
        $batch.Fail = 'Debian 中文'
        $failed = $false
        try { & $entry -DistroName @('Debian QA', 'Debian 中文', 'Debian 03') } catch { $failed = $true }
        Assert-Bootstrap ($failed -and ($batch.Calls -join ',') -ceq 'Debian QA,Debian 中文') 'batch swallowed a failure or continued to later instances'
    }
}

Write-Host "WSL bootstrap regressions: $script:bootstrapCount tests, $($script:bootstrapFailures.Count) failures."
if ($script:bootstrapFailures.Count -gt 0) { throw ($script:bootstrapFailures -join "`n") }
