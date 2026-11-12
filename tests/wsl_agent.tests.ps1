# Offline Agent boundary tests; never starts, changes or stops a real WSL.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. "$repo\components\wsl_common.ps1"
. "$repo\components\wsl_agent.ps1"
$script:count = 0
$script:failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Agent { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }
function Test-Agent { param([string]$Name, [scriptblock]$Body)
    $script:count++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:failures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function New-AgentResult { param([string]$Text = '', [int]$Code = 0, [bool]$Decoded = $true)
    return [pscustomobject]@{ Text = $Text; ErrorText = ''; ExitCode = $Code; IsDecoded = $Decoded }
}

Test-Agent 'component sourcing and names are read-only' {
    function Invoke-WslCommand { throw 'unexpected WSL command' }
    . "$repo\components\wsl_agent.ps1"
    Assert-Agent ([bool](Get-Command Invoke-WslAgent)) 'Agent entry was not defined'
}
Test-Agent 'new target collision fails before import or transfer' {
    function Get-WslDistros { @('ai-dev', 'other') }
    function Send-WslAgentBundle { throw 'unexpected bundle' }
    $failed = $false
    try { Invoke-WslAgent -Action Create -DistroName ai-dev -Yes } catch {
        $failed = $_.Exception.Message.Contains('already exists')
    }
    Assert-Agent $failed 'existing distribution was not rejected'
}
Test-Agent 'existing action requires an explicit registered target' {
    function Get-WslDistros { @('other') }
    function Invoke-WslAgentCommand { throw 'unexpected command' }
    foreach ($name in @('', '-bad', "bad`nname", 'missing')) {
        $failed = $false
        try { Invoke-WslAgent -Action Install -DistroName $name -Yes } catch { $failed = -not $_.Exception.Message.Contains('unexpected') }
        Assert-Agent $failed 'implicit, invalid or unregistered target accepted'
    }
}
Test-Agent 'existing WSL1 or unverifiable target never starts installation' {
    function Get-WslDistros { @('ai-dev') }
    function Send-WslAgentBundle { throw 'unexpected transfer' }
    foreach ($version in @(1, $null)) {
        function Get-WslDistroVersions { [pscustomobject]@{ Distributions = @([pscustomobject]@{ Name = 'ai-dev'; Version = $version }) } }
        $failed = $false
        try { Invoke-WslAgent -Action Install -DistroName ai-dev -Yes } catch { $failed = $_.Exception.Message.Contains('verified WSL2') }
        Assert-Agent $failed 'non-WSL2 target accepted or converted'
    }
}
Test-Agent 'new instance lifecycle failures retain the instance and stop before the install job' {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixture
    $originalProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $fixture
        [IO.File]::WriteAllText((Join-Path $fixture 'wsl_agent.ps1'), [IO.File]::ReadAllText("$repo\components\wsl_agent.ps1"), (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $fixture 'wsl_install.ps1'), @'
param($Version, $DistroName, $WslRoot, [switch]$AgentImportOnly, [switch]$Confirmed)
$fixtureState.Imported = $true
$fixtureState.Registered = @($DistroName)
'@)
        . (Join-Path $fixture 'wsl_agent.ps1')
        function Get-WslDistros { $fixtureState.Registered }
        function Test-WslAgentPorts { }
        function Confirm-WslAgentResources { $false }
        function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
        function Initialize-WslAgentSystemd { $fixtureState.Prepared = $true }
        function Set-WslDistroResidency {
            param($DistroName, $KeepAlive)
            Assert-Agent ($DistroName -ceq 'fixture-ai-dev' -and $KeepAlive -and $fixtureState.Prepared) 'wrong instance or lifecycle order'
            [pscustomobject]@{ Success = $case.Residency; Error = 'fixture residency denied' }
        }
        function Set-WslDistroAutostart {
            param($DistroName, $Enabled)
            Assert-Agent ($DistroName -ceq 'fixture-ai-dev' -and $Enabled) 'wrong startup target'
            $fixtureState.StartupCalls++
            [pscustomobject]@{ Success = $case.Startup; Error = 'fixture startup denied' }
        }
        function Invoke-WslAgentCommand { $fixtureState.JobCalls++; New-AgentResult }
        function Wait-WslAgentInstall { throw 'unexpected wait' }
        function Complete-WslAgentAccess { throw 'unexpected viewer setup' }
        foreach ($case in @(
            [pscustomobject]@{ Residency = $false; Startup = $true; Autostart = $true; Error = 'fixture residency denied'; StartupCalls = 0; Jobs = 0 },
            [pscustomobject]@{ Residency = $true; Startup = $false; Autostart = $true; Error = 'fixture startup denied'; StartupCalls = 1; Jobs = 0 },
            [pscustomobject]@{ Residency = $true; Startup = $true; Autostart = $true; Error = ''; StartupCalls = 1; Jobs = 1 },
            [pscustomobject]@{ Residency = $true; Startup = $false; Autostart = $false; Error = ''; StartupCalls = 0; Jobs = 1 }
        )) {
            $fixtureState = [pscustomobject]@{ Imported = $false; Registered = @(); Prepared = $false; StartupCalls = 0; JobCalls = 0 }
            $failure = ''
            try { Invoke-WslAgent -Action Create -DistroName fixture-ai-dev -WslRoot (Join-Path $fixture 'wsl') -Autostart:$case.Autostart -Yes -NoWait }
            catch { $failure = $_.Exception.Message }
            Assert-Agent ($fixtureState.Imported -and $fixtureState.Registered -contains 'fixture-ai-dev') 'failure removed or lost the imported instance'
            Assert-Agent ($fixtureState.StartupCalls -eq $case.StartupCalls -and $fixtureState.JobCalls -eq $case.Jobs) 'lifecycle failure submitted installation or skipped a verified success'
            if ($case.Error) {
                Assert-Agent ($failure.Contains($case.Error) -and $failure.Contains('retained') -and $failure.Contains('menu 07') -and $failure.Contains('Resume')) 'original failure or accurate recovery guidance was lost'
            } else { Assert-Agent (-not $failure) "verified lifecycle was rejected: $failure" }
        }
    } finally {
        $env:USERPROFILE = $originalProfile
        Remove-WslAgentBundle -Root $fixture
    }
}
Test-Agent 'failed or undecoded native execution cannot report success' {
    foreach ($value in @((New-AgentResult -Text failure -Code 1), (New-AgentResult -Decoded $false))) {
        function Invoke-WslShellScript { return $value }
        $failed = $false
        try { Invoke-WslAgentShell -Distro ai-dev -Script true | Out-Null } catch { $failed = $true }
        Assert-Agent $failed 'command error was swallowed'
    }
}
Test-Agent 'null or empty option collections add no argv while a literal empty option is preserved' {
    $nativeInvoker = (Get-Command Invoke-WslCommand).ScriptBlock
    function Invoke-WslAgentShell {
        param($Distro, $Script, $Data, $Timeout, [switch]$AllowFailure)
        & $nativeInvoker -FilePath 'C:\Program Files\Git\bin\bash.exe' -Arguments (@('--noprofile','--norc','-c','printf "<%s>\n" "$@"','--') + $Data) -TimeoutMilliseconds 10000
    }
    foreach ($case in @(
        [pscustomobject]@{ Options = $null; Expected = "<fixture agent.sh>`n<status>`n" },
        [pscustomobject]@{ Options = @(); Expected = "<fixture agent.sh>`n<status>`n" },
        [pscustomobject]@{ Options = @(''); Expected = "<fixture agent.sh>`n<status>`n<>`n" },
        [pscustomobject]@{ Options = @('--yes'); Expected = "<fixture agent.sh>`n<status>`n<--yes>`n" }
    )) {
        $result = Invoke-WslAgentCommand -Distro fixture-only -Entry 'fixture agent.sh' -Command status -Options $case.Options
        Assert-Agent ($result.ExitCode -eq 0 -and $result.IsDecoded -and $result.Text.Replace("`r`n","`n") -ceq $case.Expected) 'native argv gained or lost an option'
    }
}
Test-Agent 'systemd configuration alone is not runtime proof' {
    $state = [pscustomobject]@{ Reads = 0; Terminations = @() }
    function Invoke-WslAgentCommand { New-AgentResult }
    function Invoke-WslAgentShell { $state.Reads++; New-AgentResult 'init(ai-dev)' }
    function Get-WslNetworkState { [pscustomobject]@{ Known = $true; Risk = $false; HasIPv4 = $true; HasDefaultRoute = $true } }
    function Invoke-WslCommand { param($Arguments) $state.Terminations += ,$Arguments; New-AgentResult }
    $failed = $false
    try { Initialize-WslAgentSystemd -Distro ai-dev -Entry /source/agent.sh -NewInstance } catch { $failed = $_.Exception.Message.Contains('PID 1') }
    Assert-Agent ($failed -and $state.Reads -eq 2) 'systemd runtime was not rechecked'
    Assert-Agent ($state.Terminations.Count -eq 1 -and ($state.Terminations[0] -join '|') -ceq '--terminate|ai-dev') 'restart affected another instance or used shutdown'
}
Test-Agent 'existing systemd instance does not restart' {
    function Invoke-WslAgentCommand { New-AgentResult }
    function Invoke-WslAgentShell { New-AgentResult 'systemd' }
    function Invoke-WslCommand { throw 'unexpected terminate' }
    Initialize-WslAgentSystemd -Distro ai-dev -Entry /source/agent.sh
}
Test-Agent 'new systemd startup protects WSL networking before the restart' {
    $state = [pscustomobject]@{ Calls = @(); Reads = 0 }
    function Invoke-WslAgentShell { $state.Reads++; New-AgentResult $(if($state.Reads -gt 1){'systemd'}else{'init'}) }
    function Get-WslNetworkState { [pscustomobject]@{ Known = $true; Risk = $true; RepairSupported = $true; HasIPv4 = $true; HasDefaultRoute = $true } }
    function Repair-WslEth0Management { $state.Calls += 'network'; [pscustomobject]@{ Success = $true } }
    function Invoke-WslAgentCommand { param($Command) $state.Calls += $(if ($Command -eq 'prepare-undo') { 'capture' } else { 'prepare' }); New-AgentResult }
    function Invoke-WslCommand { param($Arguments) $state.Calls += ($Arguments -join '|'); New-AgentResult }
    Initialize-WslAgentSystemd -Distro ai-dev -Entry /source/agent.sh -NewInstance
    Assert-Agent (($state.Calls -join ',') -ceq 'capture,network,prepare,--terminate|ai-dev') 'undo baseline or WSL network protection was not captured before systemd boot'
}
Test-Agent 'unknown networking blocks a new systemd restart' {
    function Invoke-WslAgentShell { New-AgentResult 'init' }
    function Get-WslNetworkState { [pscustomobject]@{ Known = $false } }
    function Invoke-WslAgentCommand { param($Command) if ($Command -eq 'prepare-undo') { New-AgentResult } else { throw 'unexpected prepare' } }
    function Invoke-WslCommand { throw 'unexpected restart' }
    $failed = $false
    try { Initialize-WslAgentSystemd -Distro ai-dev -Entry /source/agent.sh -NewInstance } catch { $failed = $_.Exception.Message.Contains('Cannot verify WSL network') }
    Assert-Agent $failed 'unknown network state continued into restart'
}
Test-Agent 'deferred existing restart remains deferred' {
    function Invoke-WslAgentCommand { New-AgentResult }
    function Invoke-WslAgentShell { New-AgentResult 'init' }
    function Invoke-WslCommand { throw 'unexpected terminate' }
    function Read-Host { '' }
    $failed = $false
    try { Initialize-WslAgentSystemd -Distro ai-dev -Entry /source/agent.sh } catch { $failed = $_.Exception.Message.Contains('deferred') }
    Assert-Agent $failed 'default answer restarted an existing instance'
}
Test-Agent 'status stops a lost job and accepts actual ready states' {
    function Get-WslAgentStatus { [pscustomobject]@{ state = 'PACKAGES'; phase = 'apt'; job_active = $false } }
    function Start-Sleep { throw 'unexpected wait' }
    $failed = $false
    try { Wait-WslAgentInstall -Distro ai-dev } catch { $failed = $_.Exception.Message -match 'not running' }
    Assert-Agent $failed 'lost install job waited forever or was duplicated'
    function Get-WslAgentStatus { [pscustomobject]@{ state = 'READY_SOFTWARE'; phase = 'done'; job_active = $false } }
    Assert-Agent ((Wait-WslAgentInstall -Distro ai-dev).state -eq 'READY_SOFTWARE') 'software fallback was not accepted'
}
Test-Agent 'progress names explain every installation stage and terminal state' {
    foreach ($case in @(
        @('PRECHECK', '1/5', '准备安装'),
        @('PACKAGES', '2/5', '安装系统依赖'),
        @('RUNTIME', '3/5', '安装开发工具'),
        @('SERVICES', '4/5', '工作环境'),
        @('VERIFY', '5/5', '检查'),
        @('READY_SOFTWARE', '', '软件渲染'),
        @('READY_GPU', '', '硬件加速'),
        @('ERROR', '', '安装失败'),
        @('INTERRUPTED', '', '安装已中断'),
        @('NOT_INSTALLED', '', '尚未安装'),
        @('UNINSTALLED', '', '已卸载')
    )) {
        $text = Get-WslAgentProgressText -Status ([pscustomobject]@{ state = $case[0]; phase = $case[0] })
        Assert-Agent ($text.Contains($case[1]) -and $text.Contains($case[2])) "unexplained progress state: $($case[0])"
        Assert-Agent ($text -notmatch 'PACKAGES\s+PACKAGES|RUNTIME\s+RUNTIME') 'duplicate internal phase codes remain'
    }
    $text = Get-WslAgentProgressText -Status ([pscustomobject]@{ state = 'RUNTIME'; phase = 'RUNTIME' })
    foreach ($tool in @('fnm', 'Node', 'Codex', 'MCP')) { Assert-Agent ($text -match [regex]::Escape($tool)) "runtime task missing: $tool" }
    $interrupted = Get-WslAgentProgressText -Status ([pscustomobject]@{ state = 'INTERRUPTED'; phase = 'RUNTIME' })
    Assert-Agent ($interrupted.Contains('安装已中断') -and $interrupted.Contains('安装开发工具')) 'interruption lost its retained original stage'
    $failed = Get-WslAgentProgressText -Status ([pscustomobject]@{ state = 'ERROR'; phase = 'RUNTIME' })
    Assert-Agent ($failed.Contains('安装失败') -and -not $failed.Contains('安装开发工具')) 'error invented a previous stage that the installer does not retain'
    $unknown = Get-WslAgentProgressText -Status ([pscustomobject]@{ state = 'FUTURE_STAGE'; phase = 'FUTURE_STAGE' })
    Assert-Agent ($unknown.Contains('未知') -and $unknown.Contains('FUTURE_STAGE')) 'unknown progress was hidden or presented as ready'
}
Test-Agent 'polling prints elapsed wait and readable transitions without real sleeps' {
    $capture = [pscustomobject]@{ Index = 0; Sleeps = 0; Lines = (New-Object 'System.Collections.Generic.List[string]') }
    $stages = @('PRECHECK', 'PACKAGES', 'RUNTIME', 'SERVICES', 'VERIFY', 'READY_SOFTWARE')
    function Get-WslAgentStatus {
        param($Distro)
        Assert-Agent ($Distro -ceq 'fixture-main') 'progress queried another distro'
        $current = $stages[$capture.Index]; $capture.Index++
        [pscustomobject]@{ state = $current; phase = $current; job_active = $true }
    }
    function Write-Host { param($Object, $ForegroundColor) $capture.Lines.Add([string]$Object) }
    function Start-Sleep { param($Seconds) Assert-Agent ($Seconds -eq 10) 'poll interval changed'; $capture.Sleeps++ }
    $result = Wait-WslAgentInstall -Distro fixture-main
    Assert-Agent ($result.state -eq 'READY_SOFTWARE' -and $capture.Index -eq 6 -and $capture.Sleeps -eq 5) 'progress changed installation control flow'
    Assert-Agent ($capture.Lines.Count -eq 6) 'polling omitted or duplicated a progress update'
    foreach ($line in $capture.Lines) {
        Assert-Agent ($line -match '\[\d{2}:\d{2}:\d{2}\]' -and $line.Contains('fixture-main')) 'elapsed wait or selected distro is unclear'
        Assert-Agent ($line -notmatch 'PACKAGES\s+PACKAGES|RUNTIME\s+RUNTIME') 'polling still prints duplicate phase codes'
    }
    Assert-Agent ($capture.Lines[1].Contains('安装系统依赖') -and $capture.Lines[2].Contains('安装开发工具')) 'reported phase transitions remain untranslated'
}
Test-Agent 'translated failures preserve diagnostics and unknown states cannot finish installation' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Start-Sleep { throw 'unexpected sleep after a stopped job' }
    foreach ($code in @('ERROR', 'INTERRUPTED', 'FUTURE_STAGE')) {
        function Get-WslAgentStatus { [pscustomobject]@{ state = $code; phase = 'RUNTIME'; job_active = $false; error = 'fixture download failed'; log = '/var/lib/onedebian-agent/install.log' } }
        $failure = ''
        try { Wait-WslAgentInstall -Distro fixture-main } catch { $failure = $_.Exception.Message }
        Assert-Agent ($failure -and $failure -notmatch 'unexpected sleep') 'stopped or unknown state was treated as completed'
        if ($code -ne 'FUTURE_STAGE') {
            Assert-Agent ($failure.Contains('fixture download failed') -and $failure.Contains('/var/lib/onedebian-agent/install.log') -and $failure.Contains('Resume')) 'failure translation lost the original diagnostic, log path or recovery action'
            Assert-Agent ($failure -match '继续安装|恢复') 'recovery guidance remains English only'
        }
    }
}
Test-Agent 'malformed status is unknown rather than ready' {
    function Invoke-WslAgentCommand { New-AgentResult 'not-json' }
    $failed = $false
    try { Get-WslAgentStatus -Distro ai-dev } catch { $failed = $_.Exception.Message.Contains('unknown') }
    Assert-Agent $failed 'malformed status was accepted'
}
Test-Agent 'an error status remains readable despite its nonzero CLI exit' {
    $capture = [pscustomobject]@{ Allowed = $false }
    function Invoke-WslAgentCommand {
        param($Distro, $Command, $Options, [switch]$AllowFailure)
        $capture.Allowed = [bool]$AllowFailure
        New-AgentResult -Code 1 -Text '{"state":"ERROR","error":"package failed"}'
    }
    $status = Get-WslAgentStatus -Distro ai-dev
    Assert-Agent ($capture.Allowed -and $status.state -eq 'ERROR' -and $status.error -eq 'package failed') 'error status lost its structured error'
}
Test-Agent 'port group must be distinct and unprivileged' {
    foreach ($ports in @(@(16080,16080,19222), @(80,18931,19222), @(65536,18931,19222))) {
        $failed = $false
        try { Test-WslAgentPorts -Ports $ports } catch { $failed = $true }
        Assert-Agent $failed 'invalid ports accepted'
    }
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $busy = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $failed = $false
        try { Test-WslAgentPorts -Ports @($busy, 18931, 19222) } catch { $failed = $_.Exception.Message.Contains('in use') }
        Assert-Agent $failed 'active Windows listener was not detected'
    } finally { $listener.Stop() }
}
Test-Agent 'disabled localhost forwarding warns before confirmation without changing global config' {
    $state = [pscustomobject]@{ Events = @() }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixture
    $originalProfile = $env:USERPROFILE
    function Get-WslDistros { @() }
    function Test-WslAgentPorts { }
    function Confirm-WslAgentResources { $false }
    function Test-Path { param($LiteralPath) return $LiteralPath -like '*\.wslconfig' }
    function Write-Host { param($Object, $ForegroundColor) $state.Events += [string]$Object }
    function Read-Host { param($Prompt) $state.Events += "PROMPT:$Prompt"; 'N' }
    function Set-Content { throw 'unexpected global config write' }
    function Out-File { throw 'unexpected global config write' }
    function Invoke-WslCommand { throw 'unexpected import' }
    try {
        # Scope the child's config lookup to a disposable fixture, never the real profile.
        $env:USERPROFILE = $fixture
        $fixtureConfig = "[wsl2]`nlocalhostForwarding = false # keep current policy`n[experimental]`nfoo=bar`n"
        [IO.File]::WriteAllText((Join-Path $fixture '.wslconfig'), $fixtureConfig)
        Invoke-WslAgent -Action Create -DistroName fixture-agent -WslRoot D:\fixture-agent
        $warning = @($state.Events | Where-Object { $_.Contains('localhostForwarding=false') })
        $prompt = @($state.Events | Where-Object { $_.StartsWith('PROMPT:') })
        Assert-Agent ($warning.Count -eq 1 -and $prompt.Count -eq 1) 'warning or explicit confirmation was absent'
        Assert-Agent ([Array]::IndexOf($state.Events, $warning[0]) -lt [Array]::IndexOf($state.Events, $prompt[0])) 'forwarding warning appeared only after confirmation/import'
        Assert-Agent ([IO.File]::ReadAllText((Join-Path $fixture '.wslconfig')) -ceq $fixtureConfig) 'existing config changed'
        foreach ($fixtureConfig in @("[wsl2]`nlocalhostForwarding=true`n", "[experimental]`nlocalhostForwarding=false`n")) {
            [IO.File]::WriteAllText((Join-Path $fixture '.wslconfig'), $fixtureConfig)
            $state.Events = @()
            Invoke-WslAgent -Action Create -DistroName fixture-agent -WslRoot D:\fixture-agent
            Assert-Agent (@($state.Events | Where-Object { $_.Contains('localhostForwarding=false') }).Count -eq 0) 'unrelated section or enabled forwarding caused a false warning'
            Assert-Agent ([IO.File]::ReadAllText((Join-Path $fixture '.wslconfig')) -ceq $fixtureConfig) 'unrelated config changed'
        }
    } finally { $env:USERPROFILE = $originalProfile; Remove-WslAgentBundle -Root $fixture }
}
Test-Agent 'viewer rejects non-local destinations without opening a browser' {
    function Start-Process { throw 'unexpected browser' }
    foreach ($url in @('http://evil.example/#token=secret', 'https://127.0.0.1/#token=x', 'http://user:pass@127.0.0.1:16080/', "not-url")) {
        function Invoke-WslAgentShell { New-AgentResult $url }
        $failed = $false
        try { Open-WslAgentDesktop -Distro ai-dev } catch { $failed = $_.Exception.Message.Contains('invalid localhost URL') }
        Assert-Agent $failed 'remote or malformed viewer URL accepted'
    }
}
Test-Agent 'resource shortage does not piggyback on -Yes' {
    function Invoke-WslAgentShell { New-AgentResult "2`n4194304`n1048576`n" }
    $failed = $false
    try { Confirm-WslAgentResources -Distro ai-dev -Yes } catch { $failed = $_.Exception.Message.Contains('Insufficient') }
    Assert-Agent $failed 'ordinary confirmation enabled low resource override'
    Assert-Agent (Confirm-WslAgentResources -Distro ai-dev -Yes -AllowLowResources) 'explicit low resource override failed'
}
Test-Agent 'bundle normalizes CRLF and streams bounded hash-checked chunks without automount' {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path "$fixture\agent", "$fixture\components"
    try {
        foreach ($relative in @('agent.sh', 'agent/runtime.py', 'agent/cdp-probe.mjs', 'components/the_repo_localization.sh', 'components/the_os_release.sh')) {
            $content = "first`r`nsecond`r`n" + ('x' * 50000)
            [IO.File]::WriteAllText((Join-Path $fixture $relative), $content, (New-Object Text.UTF8Encoding($false)))
        }
        $capture = [pscustomobject]@{ Bytes = (New-Object IO.MemoryStream); Hash = ''; Scripts = @(); MaxLength = 0 }
        function Invoke-WslAgentShell {
            param($Distro, $Script, $Data, $Timeout)
            $capture.Scripts += $Script
            $length = ($Script + ($Data -join ' ')).Length
            $capture.MaxLength = [Math]::Max($capture.MaxLength, $length)
            if ($Script.Contains('mktemp')) { return New-AgentResult '/var/tmp/onedebian-agent.ABCDef1234' }
            if ($Script.Contains('base64 -d')) {
                $chunk = [Convert]::FromBase64String($Data[1])
                $capture.Bytes.Write($chunk, 0, $chunk.Length)
                return New-AgentResult
            }
            if ($Script.Contains('sha256sum')) { $capture.Hash = $Data[1]; return New-AgentResult }
            throw 'unexpected transfer step'
        }
        $entry = Send-WslAgentBundle -Distro ai-dev -RepoRoot $fixture
        Assert-Agent ($entry -ceq '/var/tmp/onedebian-agent.ABCDef1234/agent.sh') 'wrong staged entry'
        Assert-Agent ($capture.MaxLength -lt 30000) 'Windows command line limit exceeded'
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = ([BitConverter]::ToString($sha.ComputeHash($capture.Bytes.ToArray()))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        Assert-Agent ($actual -ceq $capture.Hash) 'payload hash does not match the sent bytes'
        Assert-Agent (-not ($capture.Scripts -join '').Contains('/mnt/')) 'transfer relies on mounted Windows drives'
        $archive = Join-Path $fixture 'received.tar'
        [IO.File]::WriteAllBytes($archive, $capture.Bytes.ToArray())
        $out = Join-Path $fixture 'extracted'
        $null = New-Item -ItemType Directory -Path $out
        $result = Invoke-WslCommand -FilePath tar.exe -Arguments @('-xf', $archive, '-C', $out)
        Assert-Agent ($result.ExitCode -eq 0) 'received archive cannot be extracted'
        $text = [IO.File]::ReadAllText((Join-Path $out 'agent.sh'))
        Assert-Agent (-not $text.Contains("`r") -and $text.StartsWith("first`nsecond`n")) 'checked-out CRLF reached Linux payload'
        $module = [IO.File]::ReadAllText((Join-Path $out 'agent/cdp-probe.mjs'))
        Assert-Agent (-not $module.Contains("`r") -and $module.StartsWith("first`nsecond`n")) 'Node module was omitted or retained CRLF'
        $capture.Bytes.Dispose()
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Test-Agent 'Agent import and menus preserve the existing workflows and locale mirrors' {
    $install = [IO.File]::ReadAllText("$repo\components\wsl_install.ps1")
    Assert-Agent ($install -match '(?s)if \(\$AgentImportOnly\) \{\s*Invoke-WslFirstBootSetup -Distro \$DistroName\s*return\s*\}') 'Agent import must protect firstboot, skip its interactive wizard and skip package upgrades'
    $menu = [IO.File]::ReadAllText("$repo\menu.ps1")
    Assert-Agent ($menu.Contains("'09', '9'") -and $menu.Contains('Menu_Agent')) 'menu09 not wired'
    foreach ($lang in @('zh-CN', 'en-US')) {
        $rootLocale = [IO.File]::ReadAllText("$repo\locales\$lang.json")
        Assert-Agent ($rootLocale -ceq [IO.File]::ReadAllText("$repo\components\locales\$lang.json")) 'locale mirrors differ'
        Assert-Agent ([bool]($rootLocale | ConvertFrom-Json).Menu_Agent) 'Agent translation absent'
    }
}
Write-Host "WSL Agent regressions: $script:count tests, $($script:failures.Count) failures."
if ($script:failures.Count) { throw ($script:failures -join "`n") }
