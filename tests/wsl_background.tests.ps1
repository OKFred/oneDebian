# Native launcher checks use harmless child processes; no WSL or task changes.
$ErrorActionPreference = 'Stop'
$backgroundRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $backgroundRepoRoot 'components\wsl_common.ps1')

function Assert-Background {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

$compiler = @('Framework64', 'Framework') | ForEach-Object {
    Join-Path $env:SystemRoot "Microsoft.NET\$_\v4.0.30319\csc.exe"
} | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
Assert-Background ([bool]$compiler) 'Windows .NET Framework C# compiler is unavailable'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('oneDebian-background-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $launcher = Join-Path $testRoot 'background launcher.exe'
    $source = Join-Path $backgroundRepoRoot 'components\wsl_background.cs'
    $compileOutput = & $compiler /nologo /target:winexe /platform:anycpu "/out:$launcher" $source 2>&1 | Out-String
    Assert-Background ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $launcher)) "launcher compilation failed: $compileOutput"
    $bytes = [IO.File]::ReadAllBytes($launcher)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    # PE signature (4) + COFF header (20) + Optional Header Subsystem offset (68).
    Assert-Background ([BitConverter]::ToUInt16($bytes, $peOffset + 92) -eq 2) 'launcher uses the visible console subsystem instead of Windows GUI'
    Write-Host '  PASS launcher is a Windows GUI executable'

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childArguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 600; exit 37"'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-WslCommand -FilePath $launcher -Arguments @($powershell, $childArguments) -TimeoutMilliseconds 15000
    Assert-Background ($result.ExitCode -eq 37 -and $watch.ElapsedMilliseconds -ge 600) 'launcher detached or lost the child exit code'
    Write-Host '  PASS launcher waits and propagates the child exit code'

    $result = Invoke-WslCommand -FilePath $launcher -Arguments @((Join-Path $testRoot 'missing.exe'), '') -TimeoutMilliseconds 15000
    Assert-Background ($result.ExitCode -eq 1) 'missing child executable was reported as success'
    Write-Host '  PASS child launch failure returns an error'

    $result = Invoke-WslCommand -FilePath $launcher -Arguments @() -TimeoutMilliseconds 15000
    Assert-Background ($result.ExitCode -eq 2) 'invalid launcher arguments were accepted'
    Write-Host '  PASS invalid launcher arguments are rejected'

    $fixture = Join-Path $testRoot 'argument fixture.ps1'
    $outputFile = Join-Path $testRoot 'received argument.txt'
    $fixtureSource = @'
param([string]$OutputFile, [string]$Value)
[IO.File]::WriteAllText($OutputFile, $Value, [Text.Encoding]::UTF8)
exit 0
'@
    [IO.File]::WriteAllText($fixture, $fixtureSource, (New-Object Text.UTF8Encoding($true)))
    $expected = '中文 Debian''s $name; $(exit 99) "quotes" trailing\'
    $childArguments = (@('-NoProfile', '-NonInteractive', '-File', $fixture, '-OutputFile', $outputFile, '-Value', $expected) | ForEach-Object { ConvertTo-WslCommandArgument $_ }) -join ' '
    $result = Invoke-WslCommand -FilePath $launcher -Arguments @($powershell, $childArguments) -TimeoutMilliseconds 15000
    Assert-Background ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $outputFile) -and [IO.File]::ReadAllText($outputFile) -ceq $expected) 'literal child arguments were changed or interpreted as code'
    Write-Host '  PASS Unicode spaces quotes and shell-looking arguments remain literal'
    Write-Host 'WSL background launcher regressions: 5 tests, 0 failures.'
}
finally {
    $resolvedRoot = (Resolve-Path -LiteralPath $testRoot -ErrorAction Stop).ProviderPath
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedRoot) -cne [IO.Path]::GetFileName($testRoot)) {
        throw 'Temporary launcher test cleanup target could not be verified.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
