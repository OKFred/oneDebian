# Offline shell-boundary checks. WSL calls are captured or redirected to private Git shell fixtures.
$ErrorActionPreference = 'Stop'
$shellRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $shellRepoRoot 'components\wsl_common.ps1')
$script:shellTestCount = 0
$script:shellFailures = New-Object System.Collections.Generic.List[string]

function Assert-Shell {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Test-ShellCase {
    param([string]$Name, [scriptblock]$CaseBody)
    $script:shellTestCount++
    try { & $CaseBody; Write-Host "  PASS $Name" -ForegroundColor Green }
    catch {
        $script:shellFailures.Add(('{0}: {1}' -f $Name, $_.Exception.Message))
        Write-Host ('  FAIL {0}: {1}' -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

Test-ShellCase 'only the Linux script is normalized; caller arrays and trailing data stay unchanged' {
    $capture = [pscustomobject]@{ Arguments = @(); Timeout = 0 }
    $native = [pscustomobject]@{ ExitCode = 17; Text = 'partial output'; ErrorText = 'native failure'; IsDecoded = $false }
    function Invoke-WslCommand {
        param($Arguments, $TimeoutMilliseconds)
        $capture.Arguments = $Arguments; $capture.Timeout = $TimeoutMilliseconds
        return $native
    }
    $literal = "C:\literal\path`r`nsecond line"
    foreach ($source in @("set -eu`r`nprintf done`r`n", "set -eu`nprintf done`n")) {
        [string[]]$arguments = @('--distribution', '-c', '--user', 'root', '--exec', '/bin/bash', '--noprofile', '--norc', '-c', $source, '--', '-c', $literal)
        $before = [string[]]$arguments.Clone()
        $result = Invoke-WslShellScript -Arguments $arguments -TimeoutMilliseconds 4321
        Assert-Shell ([object]::ReferenceEquals($result, $native)) 'native exit/output/error/decoding result was replaced'
        Assert-Shell ($capture.Timeout -eq 4321) 'the timeout was not forwarded'
        Assert-Shell ($capture.Arguments[9] -ceq "set -eu`nprintf done`n") 'script newlines were not normalized to LF'
        for ($index = 0; $index -lt $arguments.Count; $index++) {
            Assert-Shell ($arguments[$index] -ceq $before[$index]) 'the caller argument array was mutated'
            if ($index -ne 9) { Assert-Shell ($capture.Arguments[$index] -ceq $before[$index]) 'a non-script argument was changed' }
        }
    }
}
Test-ShellCase 'missing scripts and non-shell command shapes fail before native execution' {
    function Invoke-WslCommand { throw 'invalid shell arguments reached the native executor' }
    foreach ($arguments in @(
        @('--list'),
        @('--exec', '/bin/sh', '-c'),
        @('--exec', '/bin/sh', 'script.sh', '-c', "data`r`n"),
        @('--exec', 'powershell.exe', '-c', "Write-Output done`r`n")
    )) {
        $failed = $false
        try { Invoke-WslShellScript -Arguments $arguments | Out-Null } catch {
            $failed = $true
            Assert-Shell (-not $_.Exception.Message.Contains('reached the native executor')) 'the boundary validated after execution'
        }
        Assert-Shell $failed 'an unsupported command was accepted as a Linux script'
    }
}

function Invoke-ShellSourceFixture {
    param([scriptblock]$FixtureAction)
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('oneDebian CRLF shell tests ' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    try {
        # Model core.autocrlf=true: load actual product PS1 files with CRLF, not cleaned test scripts.
        foreach ($file in @('wsl_common.ps1', 'wsl_firstboot.ps1', 'wsl_network.ps1')) {
            $source = [IO.File]::ReadAllText((Join-Path $shellRepoRoot "components\$file"), [Text.Encoding]::UTF8)
            $source = $source.Replace("`r`n", "`n").Replace("`n", "`r`n")
            [IO.File]::WriteAllText((Join-Path $fixtureRoot $file), $source, (New-Object Text.UTF8Encoding($true)))
        }
        . (Join-Path $fixtureRoot 'wsl_common.ps1')
        $nativeInvoker = (Get-Command Invoke-WslCommand).ScriptBlock
        . (Join-Path $fixtureRoot 'wsl_firstboot.ps1')
        . (Join-Path $fixtureRoot 'wsl_network.ps1')
        $firstBootFactory = (Get-Command Get-WslFirstBootProtectionScript).ScriptBlock
        $bash = 'C:\Program Files\Git\bin\bash.exe'
        $sh = 'C:\Program Files\Git\bin\sh.exe'
        $converted = & $nativeInvoker -FilePath $bash -Arguments @('--noprofile', '--norc', '-c', 'cygpath -u "$1"', '--', $fixtureRoot) -TimeoutMilliseconds 10000
        Assert-Shell ($converted.ExitCode -eq 0 -and $converted.IsDecoded) 'could not resolve the private shell fixture path'
        & $FixtureAction ([pscustomobject]@{
            Root = $fixtureRoot; UnixRoot = $converted.Text.Trim(); Bash = $bash; Sh = $sh
            NativeInvoker = $nativeInvoker; FirstBootFactory = $firstBootFactory
        })
    } finally {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot -ErrorAction Stop).ProviderPath
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -cne [IO.Path]::GetFileName($fixtureRoot)) { throw 'Unsafe shell fixture cleanup target.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Test-ShellCase 'CRLF firstboot source reaches a real shell through the production boundary' {
    Invoke-ShellSourceFixture {
        param($fixture)
        $capture = [pscustomobject]@{ Raw = ''; Sent = ''; Timeout = 0; Distro = '' }
        $escapedRoot = $fixture.UnixRoot.Replace(' ', '\ ')
        function Get-WslFirstBootProtectionScript {
            $raw = & $fixture.FirstBootFactory
            $capture.Raw = $raw
            return [regex]::Replace($raw, '/(?:etc|usr/lib|lib|proc)/', { param($match) "$escapedRoot$($match.Value)" })
        }
        function Invoke-WslCommand {
            param($Arguments, $TimeoutMilliseconds)
            $capture.Sent = $Arguments[-1]; $capture.Timeout = $TimeoutMilliseconds; $capture.Distro = $Arguments[1]
            & $fixture.NativeInvoker -FilePath $fixture.Sh -Arguments @('-c', $capture.Sent) -TimeoutMilliseconds $TimeoutMilliseconds
        }
        $result = Set-WslFirstBootProtection -Distro 'private CRLF fixture'
        Assert-Shell ($capture.Raw.Contains("`r`n")) 'the fixture did not exercise a CRLF product here-string'
        Assert-Shell (-not $capture.Sent.Contains("`r")) 'CRLF reached the POSIX shell'
        Assert-Shell ($result.Success -and -not $result.Present -and -not $result.Changed) 'the actual shell could not execute the normalized firstboot script'
        Assert-Shell ($capture.Distro -ceq 'private CRLF fixture' -and $capture.Timeout -eq 45000) 'firstboot execution metadata changed'
        Assert-Shell (-not (Test-Path -LiteralPath (Join-Path $fixture.Root 'etc\systemd\system\systemd-firstboot.service'))) 'the absent-service fixture created a mask'
    }
}
Test-ShellCase 'CRLF network source reaches the same boundary without executing network changes' {
    Invoke-ShellSourceFixture {
        param($fixture)
        $capture = [pscustomobject]@{ Sent = ''; ExitCode = -1; Timeout = 0 }
        function Get-WslConfiguredNetworkMode { 'nat' }
        function Invoke-WslCommand {
            param($Arguments, $TimeoutMilliseconds)
            $capture.Sent = $Arguments[-1]; $capture.Timeout = $TimeoutMilliseconds
            $parsed = & $fixture.NativeInvoker -FilePath $fixture.Sh -Arguments @('-n', '-c', $capture.Sent) -TimeoutMilliseconds $TimeoutMilliseconds
            $capture.ExitCode = $parsed.ExitCode
            return $parsed
        }
        Assert-Shell ((Get-WslEth0RepairScript).Contains("`r`n")) 'the network fixture source was not CRLF'
        $null = Get-WslNetworkState -Distro 'private network fixture'
        Assert-Shell ($capture.ExitCode -eq 0 -and -not $capture.Sent.Contains("`r")) 'the network probe bypassed newline normalization'
        Assert-Shell ($capture.Timeout -eq 30000) 'network query timeout changed'
        $null = Invoke-WslShellScript -Arguments @('--distribution','private network fixture','--user','root','--exec','/bin/sh','-c',(Get-WslEth0RepairScript)) -TimeoutMilliseconds 1234
        Assert-Shell ($capture.ExitCode -eq 0 -and -not $capture.Sent.Contains("`r") -and $capture.Timeout -eq 1234) 'the repair script was not LF-safe at the native boundary'
    }
}
Test-ShellCase 'generic Windows native commands retain CRLF literal data' {
    Invoke-ShellSourceFixture {
        param($fixture)
        $echoPath = Join-Path $fixture.Root 'echo native argument.ps1'
        $echoSource = @'
param([string]$Value)
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
'@
        [IO.File]::WriteAllText($echoPath, $echoSource, (New-Object Text.UTF8Encoding($true)))
        $literal = "C:\path with spaces\file`r`n-c literal data"
        $expected = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($literal))
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $result = & $fixture.NativeInvoker -FilePath $powershell -Arguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$echoPath,'-Value',$literal) -TimeoutMilliseconds 10000
        Assert-Shell ($result.ExitCode -eq 0 -and $result.IsDecoded -and $result.Text.Trim() -ceq $expected) 'generic Windows arguments were normalized or misquoted'
    }
}

Write-Host "WSL shell regressions: $script:shellTestCount tests, $($script:shellFailures.Count) failures."
if ($script:shellFailures.Count -gt 0) { throw ($script:shellFailures -join "`n") }
