# Offline WSL network checks. No real distribution is started or modified.
$ErrorActionPreference = 'Stop'
$networkRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $networkRepoRoot 'components\wsl_common.ps1')
. (Join-Path $networkRepoRoot 'components\wsl_i18n.ps1')
. (Join-Path $networkRepoRoot 'components\wsl_network.ps1')
$script:networkTestCount = 0
$script:networkFailures = New-Object System.Collections.Generic.List[string]

function Assert-Network {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Test-NetworkCase {
    param([string]$Name, [scriptblock]$Body)
    $script:networkTestCount++
    try { & $Body; Write-Host "  PASS $Name" -ForegroundColor Green }
    catch { $script:networkFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "  FAIL ${Name}: $($_.Exception.Message)" -ForegroundColor Red }
}
function New-NetworkCommand {
    param([string]$Text = '', [int]$ExitCode = 0, [bool]$IsDecoded = $true)
    [pscustomobject]@{ Text = $Text; ErrorText = ''; ExitCode = $ExitCode; IsDecoded = $IsDecoded }
}
function New-NetworkProbe {
    param([hashtable]$Values = @{})
    $fields = [ordered]@{
        SYSTEMD = 'true'; IPV4 = 'yes'; ROUTE = 'yes'; IFACE = 'eth0'; ETH0 = 'yes'
        NM = 'no'; NETWORKD = 'no'; NM_ENABLED = 'yes'; NETWORKD_ENABLED = 'yes'; NM_ACTIVE = 'yes'; NETWORKD_ACTIVE = 'yes'
        NM_PROTECTED = 'yes'; NETWORKD_PROTECTED = 'yes'; MODE = 'nat'
    }
    foreach ($key in $Values.Keys) { $fields[$key] = $Values[$key] }
    $lines = @('__WSL_NETWORK_V1__') + @($fields.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) + @('__WSL_NETWORK_END__')
    return $lines -join "`n"
}
function New-NetworkState {
    param([bool]$Risk = $true, [bool]$Known = $true, [bool]$Supported = $true)
    [pscustomobject]@{
        Known = $Known; SystemdEnabled = $true; HasIPv4 = $true; HasDefaultRoute = $true
        Interface = 'eth0'; NetworkManagerManaged = $Risk; NetworkdManaged = $false; Risk = $Risk
        NetworkManagerProtected = $false; NetworkdProtected = $false
        RepairSupported = $Supported; Mode = 'nat'; Error = ''
    }
}

Test-NetworkCase 'enabled managers that both ignore eth0 are not a conflict' {
    function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) New-NetworkCommand -Text (New-NetworkProbe) }
    $state = Get-WslNetworkState -Distro 'Debian QA' -PrepareSystemd
    Assert-Network ($state.Known -and -not $state.Risk -and -not $state.NetworkManagerManaged -and -not $state.NetworkdManaged) 'enabled services alone caused a false conflict'
}
Test-NetworkCase 'either manager taking eth0 is sufficient to report risk' {
    foreach ($manager in @('NM', 'NETWORKD')) {
        $text = New-NetworkProbe -Values @{ $manager = 'yes' }
        function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) New-NetworkCommand -Text $text }
        $state = Get-WslNetworkState -Distro 'Debian QA'
        Assert-Network ($state.Known -and $state.Risk) 'one active owner was overlooked'
    }
}
Test-NetworkCase 'preparing systemd detects enabled but unprotected future management' {
    function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) New-NetworkCommand -Text (New-NetworkProbe -Values @{ SYSTEMD = 'false'; NM_ACTIVE = 'no'; NM_PROTECTED = 'no' }) }
    $state = Get-WslNetworkState -Distro 'Debian QA' -PrepareSystemd
    Assert-Network ($state.Known -and $state.Risk -and $state.RepairSupported) 'future startup risk was ignored because the manager is not running yet'
}
Test-NetworkCase 'mirrored networking can be healthy on another interface without eth0 repair' {
    function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) New-NetworkCommand -Text (New-NetworkProbe -Values @{ IFACE = 'eth1'; MODE = 'mirrored'; ETH0 = 'no' }) }
    $state = Get-WslNetworkState -Distro 'Debian QA'
    Assert-Network ($state.Known -and $state.HasIPv4 -and $state.HasDefaultRoute -and -not $state.RepairSupported) 'another healthy interface was treated as eth0 loss'
}
Test-NetworkCase 'unknown or custom network mode cannot authorize automatic repair' {
    foreach ($mode in @('unknown', 'bridged')) {
        $text = New-NetworkProbe -Values @{ MODE = $mode; NM = 'yes'; IPV4 = 'no'; ROUTE = 'no' }
        function Get-WslConfiguredNetworkMode { $mode }
        function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) New-NetworkCommand -Text $text }
        $state = Get-WslNetworkState -Distro 'Debian QA'
        Assert-Network (-not $state.RepairSupported) 'custom/unknown mode authorized writes'
    }
}
Test-NetworkCase 'failed undecodable or truncated network output remains unverifiable' {
    foreach ($command in @(
        (New-NetworkCommand -ExitCode 1),
        (New-NetworkCommand -Text (New-NetworkProbe) -IsDecoded $false),
        (New-NetworkCommand -Text ((New-NetworkProbe) -replace '__WSL_NETWORK_END__', ''))
    )) {
        function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) $command }
        Assert-Network (-not (Get-WslNetworkState -Distro 'Debian QA').Known) 'unknown probe output became a verified network state'
    }
}
Test-NetworkCase 'declining a repair does not change a distribution or restart WSL' {
    $tracking = [pscustomobject]@{ Prompts = 0 }
    function Write-Host { param($Object, $ForegroundColor) }
    function Read-Host { param($Prompt) $tracking.Prompts++; 'N' }
    function Repair-WslEth0Management { throw 'declined repair must not execute' }
    function Invoke-WslCommand { throw 'confirmation must precede native commands' }
    $result = Invoke-WslNetworkRepairPrompt -Distro 'Debian QA' -State (New-NetworkState)
    Assert-Network (-not $result -and $tracking.Prompts -eq 1) 'declined repair was not returned safely'
}
Test-NetworkCase 'missing IPv4 or default route offers confirmed repair even without a manager conflict' {
    $tracking = [pscustomobject]@{ Prompts = 0 }
    function Write-Host { param($Object, $ForegroundColor) }
    function Read-Host { param($Prompt) $tracking.Prompts++; 'N' }
    function Repair-WslEth0Management { throw 'declined repair must not execute' }
    foreach ($field in @('HasIPv4', 'HasDefaultRoute')) {
        $state = New-NetworkState -Risk $false
        $state.$field = $false
        Assert-Network (-not (Invoke-WslNetworkRepairPrompt -Distro 'Debian QA' -State $state)) 'missing connectivity was treated as healthy'
    }
    Assert-Network ($tracking.Prompts -eq 2) 'missing IPv4/default route did not offer a repair'
}
Test-NetworkCase 'healthy or unsupported states do not ask to rewrite eth0' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Read-Host { throw 'healthy/custom/unknown state must not ask for an automatic rewrite' }
    function Repair-WslEth0Management { throw 'must not write for healthy/custom/unknown state' }
    $healthy = Invoke-WslNetworkRepairPrompt -Distro 'Debian QA' -State (New-NetworkState -Risk $false)
    $custom = Invoke-WslNetworkRepairPrompt -Distro 'Debian QA' -State (New-NetworkState -Supported $false)
    $unknown = Invoke-WslNetworkRepairPrompt -Distro 'Debian QA' -State (New-NetworkState -Known $false)
    Assert-Network ($healthy -and -not $custom -and -not $unknown) 'healthy and unverifiable states were conflated'
}
Test-NetworkCase 'confirmed repair reports staged configuration rather than restarting a live instance' {
    $tracking = [pscustomobject]@{ Repairs = 0; Messages = (New-Object System.Collections.Generic.List[string]) }
    function Write-Host { param($Object, $ForegroundColor) $tracking.Messages.Add([string]$Object) }
    function Read-Host { param($Prompt) 'Y' }
    function Get-I18nStr { param($Key, $Args) $Key }
    function Repair-WslEth0Management {
        param($Distro)
        $tracking.Repairs++
        [pscustomobject]@{ Success = $true; BackupPath = '/root/fixture-backup'; Error = ''; RestartRequired = $true }
    }
    function Invoke-WslCommand { throw 'the prompt must not terminate or shut down WSL' }
    $result = Invoke-WslNetworkRepairPrompt -Distro 'Debian QA' -State (New-NetworkState)
    Assert-Network ($result -and $tracking.Repairs -eq 1) 'confirmed repair did not run exactly once'
    Assert-Network (($tracking.Messages -join "`n") -match '(?i)restart') 'staged configuration was not distinguished from live recovery'
}
Test-NetworkCase 'failed repair cannot be reported as successful' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Read-Host { param($Prompt) 'Y' }
    function Repair-WslEth0Management { param($Distro) [pscustomobject]@{ Success = $false; BackupPath = ''; Error = 'fixture backup failure'; RestartRequired = $false } }
    Assert-Network (-not (Invoke-WslNetworkRepairPrompt -Distro 'Debian QA' -State (New-NetworkState))) 'backup/verification failure became success'
}

Test-NetworkCase 'post-import checks skip protection when systemd is not configured' {
    $state = New-NetworkState
    $state.SystemdEnabled = $false
    function Read-Host { throw 'systemd-off installation must not prompt for network protection' }
    function Repair-WslEth0Management { throw 'systemd-off installation must not change network configuration' }
    Assert-Network (Invoke-WslNetworkRepairPrompt -Distro 'Debian QA' -State $state -OnlyIfSystemd) 'systemd-off import was treated as a failed protection check'
}
Test-NetworkCase 'repair success requires configuration readback rather than a zero write exit' {
    $tracking = [pscustomobject]@{ Queries = 0 }
    function Get-WslNetworkState { param($Distro) $tracking.Queries++; New-NetworkState }
    function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) New-NetworkCommand -Text "__WSL_NETWORK_REPAIRED__`nBACKUP=/root/fixture`n__WSL_NETWORK_END__" }
    $result = Repair-WslEth0Management -Distro 'Debian QA'
    Assert-Network (-not $result.Success -and $tracking.Queries -eq 2 -and $result.BackupPath -eq '/root/fixture') 'a success marker replaced verification of installed protection'
}

# Execute only the file-writing shell against private temporary directories.
function Invoke-NetworkRepairFixture {
    param([scriptblock]$Body)
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('oneDebian network tests ' + [guid]::NewGuid().ToString('N'))
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    try {
        $converted = Invoke-WslCommand -FilePath $bash -Arguments @('--noprofile', '--norc', '-c', 'cygpath -u "$1"', '--', $fixtureRoot) -TimeoutMilliseconds 10000
        Assert-Network ($converted.ExitCode -eq 0) 'could not resolve the private shell fixture path'
        $unixRoot = $converted.Text.Trim()
        foreach ($directory in @('etc\NetworkManager\conf.d', 'etc\systemd\network', 'root')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $directory) -Force
        }
        $scriptPath = Join-Path $fixtureRoot 'repair fixture.sh'
        $script = [regex]::Replace((Get-WslEth0RepairScript), '/(?:etc|root|run|usr/lib|lib)/', { param($match) "$unixRoot$($match.Value)" })
        [IO.File]::WriteAllText($scriptPath, ($script -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        & $Body ([pscustomobject]@{ Root = $fixtureRoot; UnixRoot = $unixRoot; Bash = $bash; Script = $scriptPath.Replace('\', '/') })
    } finally {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot -ErrorAction Stop).ProviderPath
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -cne [IO.Path]::GetFileName($fixtureRoot)) { throw 'Unsafe fixture cleanup target.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Test-NetworkCase 'the live probe finds IPv4 and a default route on a non-eth0 interface' {
    $capture = [pscustomobject]@{ Script = '' }
    & {
        function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) $capture.Script = $Arguments[-1]; New-NetworkCommand -ExitCode 1 }
        $null = Get-WslNetworkState -Distro 'Debian QA'
    }
    Invoke-NetworkRepairFixture {
        param($fixture)
        $script = [regex]::Replace($capture.Script, '/(?:etc|root|run|usr/lib|lib)/', { param($match) "$($fixture.UnixRoot)$($match.Value)" })
        # Stub the read-only guest commands; the production query must select the actual interface.
        $commands = @'
ip() {
  case "$*" in
    '-4 -o address show scope global') printf '3: eth1 inet 192.0.2.2/24 scope global eth1\n';;
    '-4 route show default') printf 'default via 192.0.2.1 dev eth1\n';;
    'link show dev eth0') return 1;;
    *) return 1;;
  esac
}
systemctl() { return 1; }
wslinfo() { printf 'mirrored\n'; }
'@
        $queryPath = Join-Path $fixture.Root 'query fixture.sh'
        [IO.File]::WriteAllText($queryPath, (($commands + "`n" + $script) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        $probe = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $queryPath.Replace('\', '/')) -TimeoutMilliseconds 10000
        Assert-Network ($probe.ExitCode -eq 0) 'fixture probe did not complete'
        & {
            function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) $probe }
            $state = Get-WslNetworkState -Distro 'Debian QA'
            Assert-Network ($state.Known -and $state.HasIPv4 -and $state.HasDefaultRoute -and $state.Interface -eq 'eth1' -and -not $state.RepairSupported) 'query assumed all WSL network connectivity must use eth0'
        }
    }
}
Test-NetworkCase 'repair shell creates protection, backs up existing files and reruns without new backups' {
    Invoke-NetworkRepairFixture {
        param($fixture)
        $nmPath = Join-Path $fixture.Root 'etc\NetworkManager\conf.d\99-wsl-eth0-unmanaged.conf'
        $ndPath = Join-Path $fixture.Root 'etc\systemd\network\00-wsl-eth0-unmanaged.network'
        $unrelated = Join-Path $fixture.Root 'etc\systemd\network\eth0.network'
        [IO.File]::WriteAllText($unrelated, "[Match]`nName=eth0`n[Network]`nDHCP=true`n")
        $first = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script) -TimeoutMilliseconds 10000
        Assert-Network ($first.ExitCode -eq 0 -and $first.Text.Contains('__WSL_NETWORK_REPAIRED__')) 'new protection files were not verified'
        Assert-Network ([IO.File]::ReadAllText($nmPath).Contains('managed=0') -and [IO.File]::ReadAllText($ndPath).Contains('Unmanaged=yes')) 'protection content is incomplete'
        $nmOriginal = "# existing custom NM fixture`n"
        $ndOriginal = "# existing custom networkd fixture`n"
        [IO.File]::WriteAllText($nmPath, $nmOriginal)
        [IO.File]::WriteAllText($ndPath, $ndOriginal)
        $second = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script) -TimeoutMilliseconds 10000
        Assert-Network ($second.ExitCode -eq 0) 'replacement of existing protection files failed'
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'root') -File -Recurse | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
        Assert-Network ($backups -contains $nmOriginal -and $backups -contains $ndOriginal) 'existing file content was not backed up'
        Assert-Network ([IO.File]::ReadAllText($unrelated).Contains('DHCP=true')) 'an unrelated network profile was rewritten'
        $before = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'root') -Directory).Count
        $again = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script) -TimeoutMilliseconds 10000
        $after = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'root') -Directory).Count
        Assert-Network ($again.ExitCode -eq 0 -and $before -eq $after -and $again.Text -match '(?m)^BACKUP=\r?$') 'an unchanged rerun made another backup or failed'
    }
}
Test-NetworkCase 'backup failure leaves existing network configuration intact' {
    Invoke-NetworkRepairFixture {
        param($fixture)
        $nmPath = Join-Path $fixture.Root 'etc\NetworkManager\conf.d\99-wsl-eth0-unmanaged.conf'
        $ndPath = Join-Path $fixture.Root 'etc\systemd\network\00-wsl-eth0-unmanaged.network'
        [IO.File]::WriteAllText($nmPath, 'original NM fixture')
        [IO.File]::WriteAllText($ndPath, 'original networkd fixture')
        $blockedRoot = Join-Path $fixture.Root 'root'
        Remove-Item -LiteralPath $blockedRoot
        [IO.File]::WriteAllText($blockedRoot, 'not a backup directory')
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script) -TimeoutMilliseconds 10000
        Assert-Network ($result.ExitCode -ne 0 -and [IO.File]::ReadAllText($nmPath) -ceq 'original NM fixture' -and [IO.File]::ReadAllText($ndPath) -ceq 'original networkd fixture') 'failed backup still changed configuration'
    }
}
Test-NetworkCase 'an earlier custom networkd profile requires review before any writes' {
    Invoke-NetworkRepairFixture {
        param($fixture)
        $earlier = Join-Path $fixture.Root 'etc\systemd\network\00-default.network'
        [IO.File]::WriteAllText($earlier, "[Match]`nName=eth0`n[Network]`nDHCP=true`n")
        $nmPath = Join-Path $fixture.Root 'etc\NetworkManager\conf.d\99-wsl-eth0-unmanaged.conf'
        $ndPath = Join-Path $fixture.Root 'etc\systemd\network\00-wsl-eth0-unmanaged.network'
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script) -TimeoutMilliseconds 10000
        Assert-Network ($result.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $nmPath) -and -not (Test-Path -LiteralPath $ndPath)) 'a higher-priority custom rule was silently overridden'
        Assert-Network (@(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'root')).Count -eq 0) 'manual-review refusal still made a backup'
    }
}

. (Join-Path $networkRepoRoot 'components\wsl_config.ps1')
Test-NetworkCase 'cancelling final systemd save never invokes network repair or writes wsl.conf' {
    $tracking = [pscustomobject]@{ Writes = 0 }
    function Write-Host { param($Object, $ForegroundColor) }
    function Select-WslDistro { param($Title) 'Debian QA' }
    function Read-ConfigPrompt {
        param($Message, $CurrentValue, $AllowedValues, $Normalizer, $Validator, $HintText)
        if ($Message -like '启用 systemd*') { return [pscustomobject]@{ Action = 'Set'; Value = 'true' } }
        return [pscustomobject]@{ Action = 'Keep'; Value = $CurrentValue }
    }
    function Show-ConfigDiff { param($OldContent, $NewContent, $TargetTitle) }
    function Read-Host { param($Prompt) 'N' }
    function Invoke-WslNetworkRepairPrompt { throw 'repair cannot run before save confirmation' }
    function wsl.exe { $global:LASTEXITCODE = 0; if (($args -join ' ') -match 'if \[ -f /etc/wsl.conf \]; then cat') { "[boot]`nsystemd=false`n" } else { $tracking.Writes++ } }
    Configure-SingleDistroConf
    Assert-Network ($tracking.Writes -eq 0) 'cancelled save wrote configuration'
}
Test-NetworkCase 'declining protection and unsafe continuation leaves wsl.conf unchanged' {
    $tracking = [pscustomobject]@{ Writes = 0; Checks = 0 }
    $answers = New-Object System.Collections.Generic.Queue[string]
    $answers.Enqueue('Y'); $answers.Enqueue('N')
    function Write-Host { param($Object, $ForegroundColor) }
    function Select-WslDistro { param($Title) 'Debian QA' }
    function Read-ConfigPrompt {
        param($Message, $CurrentValue, $AllowedValues, $Normalizer, $Validator, $HintText)
        if ($Message -like '启用 systemd*') { return [pscustomobject]@{ Action = 'Set'; Value = 'true' } }
        return [pscustomobject]@{ Action = 'Keep'; Value = $CurrentValue }
    }
    function Show-ConfigDiff { param($OldContent, $NewContent, $TargetTitle) }
    function Read-Host { param($Prompt) $answers.Dequeue() }
    function Invoke-WslNetworkRepairPrompt { param($Distro, [switch]$PrepareSystemd) $tracking.Checks++; $false }
    function wsl.exe { $global:LASTEXITCODE = 0; if (($args -join ' ') -match 'if \[ -f /etc/wsl.conf \]; then cat') { "[boot]`nsystemd=false`n" } else { $tracking.Writes++ } }
    Configure-SingleDistroConf
    Assert-Network ($tracking.Checks -eq 1 -and $tracking.Writes -eq 0 -and $answers.Count -eq 0) 'declined protection still saved systemd without explicit continuation'
}

Write-Host "WSL network regressions: $script:networkTestCount tests, $($script:networkFailures.Count) failures."
if ($script:networkFailures.Count -gt 0) { throw ($script:networkFailures -join "`n") }
