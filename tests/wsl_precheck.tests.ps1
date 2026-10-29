# Dependency-free, offline WSL query/repair regressions. Never changes host WSL state.
$ErrorActionPreference = 'Stop'
$precheckRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $precheckRepoRoot 'components\wsl_common.ps1')
$script:wslTestCount = 0
$script:wslTestFailures = New-Object System.Collections.Generic.List[string]

function Assert-WslTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Test-WslCase {
    param([string]$Name, [scriptblock]$Body)
    $script:wslTestCount++
    try {
        & $Body
        Write-Host "  PASS $Name" -ForegroundColor Green
    } catch {
        $script:wslTestFailures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "  FAIL ${Name}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-WslTestCommand {
    param([int]$ExitCode = 0, [string]$Text = '', [bool]$IsDecoded = $true, [string]$ErrorText = '')
    [pscustomobject]@{ ExitCode = $ExitCode; Text = $Text; ErrorText = $ErrorText; IsDecoded = $IsDecoded; Encoding = 'UTF-8'; Started = $true }
}

function New-WslTestVersion {
    param($Version = 2, [bool]$Known = $true)
    [pscustomobject]@{ Known = $Known; Version = $Version; Source = 'Registry'; Command = $null; Error = '' }
}

function New-WslTestInventory {
    param([object[]]$Distributions = @(), [bool]$Known = $true)
    [pscustomobject]@{ Known = $Known; Distributions = @($Distributions); Source = 'Registry'; Command = $null; Error = '' }
}

function New-WslTestDistro {
    param([string]$Name, $Version)
    [pscustomobject]@{ Name = $Name; Version = $Version; Known = ($Version -in 1, 2); Source = 'Registry' }
}

Test-WslCase 'UTF-8, BOM and UTF-16 LE/BE decode without losing localized names' {
    $text = "默认版本：2`r`nDebian Dev"
    $encodings = @(
        (New-Object Text.UTF8Encoding($false, $true)),
        (New-Object Text.UTF8Encoding($true, $true)),
        (New-Object Text.UnicodeEncoding($false, $true, $true)),
        (New-Object Text.UnicodeEncoding($true, $true, $true))
    )
    foreach ($encoding in $encodings) {
        [byte[]]$bytes = @($encoding.GetPreamble()) + @($encoding.GetBytes($text))
        $decoded = ConvertFrom-WslCommandBytes -Bytes $bytes
        Assert-WslTrue $decoded.IsDecoded 'valid encoded bytes must decode'
        Assert-WslTrue ($decoded.Text -ceq $text) 'text or localized names were changed'
    }
}

Test-WslCase 'BOM-less UTF-16 is recognized in both byte orders' {
    foreach ($encoding in @([Text.Encoding]::Unicode, [Text.Encoding]::BigEndianUnicode)) {
        foreach ($text in @('Default Version: 2', '默认版本：2')) {
            $decoded = ConvertFrom-WslCommandBytes -Bytes $encoding.GetBytes($text)
            Assert-WslTrue ($decoded.IsDecoded -and $decoded.Text -ceq $text) 'BOM-less UTF-16 was not decoded'
        }
    }
}

Test-WslCase 'invalid UTF-8 and truncated UTF-16 are unverifiable' {
    foreach ($bytes in @([byte[]](255, 253, 248), [byte[]](255, 254, 65))) {
        $decoded = ConvertFrom-WslCommandBytes -Bytes $bytes
        Assert-WslTrue (-not $decoded.IsDecoded) 'invalid bytes must not silently decode'
    }
}

Test-WslCase 'default-version parser accepts English, compact and Chinese labels' {
    foreach ($text in @('Default Version: 2', 'DefaultVersion : 2', '默认版本：2', "  DEFAULT VERSION : 2`r`nKernel version: 6.6")) {
        Assert-WslTrue ((ConvertFrom-WslDefaultVersionText -Text $text) -eq 2) "not recognized: $text"
    }
    Assert-WslTrue ((ConvertFrom-WslDefaultVersionText -Text 'Default Version: 1') -eq 1) 'version one was not recognized'
}

Test-WslCase 'unrelated, empty and invalid default-version text stays unknown' {
    foreach ($text in @('', 'Kernel version: 2', 'Default Version: 3', 'unreadable output')) {
        Assert-WslTrue ($null -eq (ConvertFrom-WslDefaultVersionText -Text $text)) 'parser guessed a version'
    }
}

Test-WslCase 'registry default two wins over unreadable, UTF-16 or empty status output' {
    foreach ($text in @('', 'garbled status', "D`0e`0f`0a`0u`0l`0t`0")) {
        $tracking = [pscustomobject]@{ Calls = 0; Text = $text }
        $state = Get-WslDefaultVersion -ReadRegistry { [pscustomobject]@{ Available = $true; DefaultVersion = 2; Distributions = @() } } -RunCommand {
            param($CommandArguments)
            $tracking.Calls++
            New-WslTestCommand -Text $tracking.Text -IsDecoded $false
        }
        Assert-WslTrue ($state.Known -and $state.Version -eq 2 -and $state.Source -eq 'Registry') 'registry fact was ignored'
        Assert-WslTrue ($tracking.Calls -eq 0) 'status output should not override an available registry fact'
    }
}

Test-WslCase 'missing registry falls back to decoded successful status' {
    $state = Get-WslDefaultVersion -ReadRegistry { [pscustomobject]@{ Available = $false } } -RunCommand {
        param($CommandArguments)
        Assert-WslTrue ($CommandArguments -contains '--status') 'unexpected fallback command'
        New-WslTestCommand -Text 'DefaultVersion : 2'
    }
    Assert-WslTrue ($state.Known -and $state.Version -eq 2 -and $state.Source -eq 'Command') 'CLI fallback did not establish version'
}

Test-WslCase 'unavailable registry plus undecodable, empty or failed command is unknown' {
    foreach ($command in @((New-WslTestCommand -IsDecoded $false), (New-WslTestCommand), (New-WslTestCommand -ExitCode 1 -Text 'Default Version: 2'))) {
        $state = Get-WslDefaultVersion -ReadRegistry { [pscustomobject]@{ Available = $false } } -RunCommand { param($CommandArguments) $command }
        Assert-WslTrue (-not $state.Known) 'a failed or unparseable query must not be treated as a fact'
    }
}

Test-WslCase 'registry read errors fall back, and command errors remain unknown' {
    $fallback = Get-WslDefaultVersion -ReadRegistry { throw 'registry access unavailable' } -RunCommand { param($CommandArguments) New-WslTestCommand -Text 'Default Version: 2' }
    Assert-WslTrue ($fallback.Known -and $fallback.Version -eq 2) 'registry access error bypassed the CLI fallback'
    $unknown = Get-WslDefaultVersion -ReadRegistry { throw 'registry access unavailable' } -RunCommand { param($CommandArguments) throw 'command unavailable' }
    Assert-WslTrue (-not $unknown.Known) 'failed fallback must remain unknown without crashing precheck'
}

Test-WslCase 'registry inventory separates multiple WSL1 and WSL2 distributions' {
    $tracking = [pscustomobject]@{ Calls = 0 }
    $state = Get-WslDistroVersions -ReadRegistry {
        [pscustomobject]@{ Available = $true; Distributions = @((New-WslTestDistro 'Debian Dev' 1), (New-WslTestDistro 'Debian-13' 2)) }
    } -RunCommand { param($CommandArguments) $tracking.Calls++; throw 'fallback must not run' }
    Assert-WslTrue ($state.Known -and @($state.Distributions).Count -eq 2) 'registry inventory is incomplete'
    Assert-WslTrue (@($state.Distributions | Where-Object { $_.Name -eq 'Debian Dev' -and $_.Version -eq 1 }).Count -eq 1) 'WSL1 distro name was changed'
    Assert-WslTrue ($tracking.Calls -eq 0) 'CLI should not replace an available inventory'
}

Test-WslCase 'invalid registry distro version stays unknown beside valid instances' {
    $state = Get-WslDistroVersions -ReadRegistry {
        [pscustomobject]@{ Available = $true; Distributions = @((New-WslTestDistro 'Unknown-version' 0), (New-WslTestDistro 'Debian' 2)) }
    } -RunCommand { param($CommandArguments) throw 'must not discard registry inventory' }
    $unknown = @($state.Distributions | Where-Object { $_.Name -eq 'Unknown-version' })
    Assert-WslTrue ($unknown.Count -eq 1 -and -not $unknown[0].Known) 'invalid distro version was hidden or guessed'
    Assert-WslTrue (@($state.Distributions | Where-Object { $_.Name -eq 'Debian' -and $_.Version -eq 2 }).Count -eq 1) 'valid distro was lost'
}

Test-WslCase 'verbose list parser handles localized headers, states and names with spaces' {
    $text = "  NAME            STATE          VERSION`r`n* Debian Dev      Running        1`r`n  Debian-13       Stopped        2"
    $state = ConvertFrom-WslDistroListText -Text $text
    Assert-WslTrue ($state.Known -and @($state.Distributions).Count -eq 2) 'English list did not parse'
    Assert-WslTrue ($state.Distributions[0].Name -ceq 'Debian Dev') 'space in distro name was lost'
    $localized = ConvertFrom-WslDistroListText -Text "  名称              状态           版本`r`n* 测试 Debian       正在运行       2"
    Assert-WslTrue ($localized.Known -and $localized.Distributions[0].Name -ceq '测试 Debian') 'localized list did not parse'
}

Test-WslCase 'header without distro rows is known empty; empty and error output are unknown' {
    $empty = ConvertFrom-WslDistroListText -Text '  NAME STATE VERSION'
    Assert-WslTrue ($empty.Known -and @($empty.Distributions).Count -eq 0) 'valid empty inventory was rejected'
    foreach ($text in @('', 'Error: 0x1bc', 'random unreadable text')) {
        $unknown = ConvertFrom-WslDistroListText -Text $text
        Assert-WslTrue (-not $unknown.Known) 'unrecognized inventory must remain unknown'
    }
}

Test-WslCase 'partially malformed verbose list cannot supply trusted conversion candidates' {
    $parsed = ConvertFrom-WslDistroListText -Text "  NAME STATE VERSION`n  Debian Dev    Running    1`n  Unreadable    Unknown    3"
    Assert-WslTrue (-not $parsed.Known) 'malformed row was silently ignored'
    Assert-WslTrue (@($parsed.Distributions | Where-Object { $_.Known }).Count -eq 0) 'partial CLI output left trusted conversion candidates'
}

Test-WslCase 'distro inventory falls back to verbose list only when registry is unavailable' {
    $state = Get-WslDistroVersions -ReadRegistry { [pscustomobject]@{ Available = $false } } -RunCommand {
        param($CommandArguments)
        Assert-WslTrue (($CommandArguments -contains '--list') -and ($CommandArguments -contains '--verbose')) 'incorrect inventory fallback'
        New-WslTestCommand -Text "  NAME STATE VERSION`n  Debian    Running    2"
    }
    Assert-WslTrue ($state.Known -and $state.Distributions[0].Version -eq 2) 'inventory fallback failed'
}

Test-WslCase 'default repair rereads state and succeeds only after it changes to two' {
    $tracking = [pscustomobject]@{ Queries = 0; Commands = 0 }
    $result = Set-WslDefaultVersion -Version 2 -Query {
        $tracking.Queries++
        if ($tracking.Queries -eq 1) { New-WslTestVersion 1 } else { New-WslTestVersion 2 }
    } -RunCommand {
        param($CommandArguments)
        $tracking.Commands++
        Assert-WslTrue (($CommandArguments -join ' ') -eq '--set-default-version 2') 'incorrect default modification command'
        New-WslTestCommand
    }
    Assert-WslTrue ($result.Success -and $result.Status -eq 'Verified') 'verified default change was not successful'
    Assert-WslTrue ($tracking.Queries -ge 2 -and $tracking.Commands -eq 1) 'repair must requery and only execute once'
}

Test-WslCase 'exit zero without changed default state is a failure' {
    $tracking = [pscustomobject]@{ Queries = 0 }
    $result = Set-WslDefaultVersion -Version 2 -Query { $tracking.Queries++; New-WslTestVersion 1 } -RunCommand { param($CommandArguments) New-WslTestCommand }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Failed' -and $tracking.Queries -ge 2) 'exit zero was incorrectly treated as a verified repair'
}

Test-WslCase 'unverifiable default before repair does not execute a modifying command' {
    $tracking = [pscustomobject]@{ Commands = 0 }
    $result = Set-WslDefaultVersion -Version 2 -Query { New-WslTestVersion -Version $null -Known $false } -RunCommand { param($CommandArguments) $tracking.Commands++; New-WslTestCommand }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Unknown' -and $tracking.Commands -eq 0) 'unknown state triggered a blind repair'
}

Test-WslCase 'unverifiable state after repair remains unknown' {
    $tracking = [pscustomobject]@{ Queries = 0 }
    $result = Set-WslDefaultVersion -Version 2 -Query {
        $tracking.Queries++
        if ($tracking.Queries -eq 1) { New-WslTestVersion 1 } else { New-WslTestVersion -Version $null -Known $false }
    } -RunCommand { param($CommandArguments) New-WslTestCommand }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Unknown') 'unverified result was reported successful'
}

Test-WslCase 'nonzero modifying command cannot be reported as successful' {
    $tracking = [pscustomobject]@{ Queries = 0 }
    $result = Set-WslDefaultVersion -Version 2 -Query {
        $tracking.Queries++
        if ($tracking.Queries -eq 1) { New-WslTestVersion 1 } else { New-WslTestVersion 2 }
    } -RunCommand { param($CommandArguments) New-WslTestCommand -ExitCode 444 -Text 'Error: 0x1bc' }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Failed') 'command failure was ignored'
}

Test-WslCase 'already correct default is verified without executing a command' {
    $tracking = [pscustomobject]@{ Commands = 0 }
    $result = Set-WslDefaultVersion -Version 2 -Query { New-WslTestVersion 2 } -RunCommand { param($CommandArguments) $tracking.Commands++; New-WslTestCommand }
    Assert-WslTrue ($result.Success -and $tracking.Commands -eq 0) 'already-correct default should not be modified'
}

Test-WslCase 'default query exception before repair returns unknown without mutation' {
    $tracking = [pscustomobject]@{ Commands = 0 }
    $result = Set-WslDefaultVersion -Version 2 -Query { throw 'fixture initial default query failure' } -RunCommand {
        param($CommandArguments)
        $tracking.Commands++
        New-WslTestCommand
    }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Unknown') 'initial query exception escaped or was treated as a verified state'
    Assert-WslTrue ($tracking.Commands -eq 0 -and $null -eq $result.Command) 'initial query failure must not execute a modifying command'
}

Test-WslCase 'default query exception after repair returns unknown and retains command evidence' {
    $tracking = [pscustomobject]@{ Queries = 0; Commands = 0 }
    $result = Set-WslDefaultVersion -Version 2 -Query {
        $tracking.Queries++
        if ($tracking.Queries -eq 1) { New-WslTestVersion 1 } else { throw 'fixture final default query failure' }
    } -RunCommand {
        param($CommandArguments)
        $tracking.Commands++
        New-WslTestCommand -Text 'fixture default command completed'
    }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Unknown') 'failed verification query must not report a successful repair'
    Assert-WslTrue ($tracking.Commands -eq 1 -and $result.Command.ExitCode -eq 0 -and $result.Command.Text -ceq 'fixture default command completed') 'completed command evidence was lost after verification query failed'
}

Test-WslCase 'single distro conversion preserves exact name and verifies its own version' {
    $tracking = [pscustomobject]@{ Queries = 0; Commands = 0 }
    $result = Set-WslDistroVersion -Name 'Debian Dev' -Version 2 -Query {
        $tracking.Queries++
        $version = if ($tracking.Queries -eq 1) { 1 } else { 2 }
        New-WslTestInventory @((New-WslTestDistro 'Debian Dev' $version), (New-WslTestDistro 'Other' 1))
    } -RunCommand {
        param($CommandArguments)
        $tracking.Commands++
        Assert-WslTrue ($CommandArguments.Count -eq 3 -and $CommandArguments[1] -ceq 'Debian Dev') 'distro name was split or changed'
        Assert-WslTrue ($CommandArguments[0] -eq '--set-version' -and $CommandArguments[2] -eq '2') 'wrong conversion command'
        New-WslTestCommand
    }
    Assert-WslTrue ($result.Success -and $tracking.Commands -eq 1 -and $tracking.Queries -ge 2) 'distro conversion was not verified'
}

Test-WslCase 'conversion exit zero with unchanged distro stays failed' {
    $result = Set-WslDistroVersion -Name 'Debian' -Version 2 -Query { New-WslTestInventory @((New-WslTestDistro 'Debian' 1)) } -RunCommand { param($CommandArguments) New-WslTestCommand }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Failed') 'unchanged distro version was reported successful'
}

Test-WslCase 'missing or unknown target distro never triggers conversion' {
    foreach ($inventory in @((New-WslTestInventory), (New-WslTestInventory @((New-WslTestDistro 'Debian' 0))))) {
        $tracking = [pscustomobject]@{ Commands = 0 }
        $result = Set-WslDistroVersion -Name 'Debian' -Version 2 -Query { $inventory } -RunCommand { param($CommandArguments) $tracking.Commands++; New-WslTestCommand }
        Assert-WslTrue (-not $result.Success -and $tracking.Commands -eq 0) 'unverified distro was converted'
    }
}

Test-WslCase 'distro query exception before conversion returns unknown without mutation' {
    $tracking = [pscustomobject]@{ Commands = 0 }
    $result = Set-WslDistroVersion -Name 'Debian' -Version 2 -Query { throw 'fixture initial inventory query failure' } -RunCommand {
        param($CommandArguments)
        $tracking.Commands++
        New-WslTestCommand
    }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Unknown') 'initial distro query exception escaped or was reported as verified'
    Assert-WslTrue ($tracking.Commands -eq 0 -and $null -eq $result.Command) 'initial inventory failure must not execute a conversion'
}

Test-WslCase 'distro query exception after conversion returns unknown and retains command evidence' {
    $tracking = [pscustomobject]@{ Queries = 0; Commands = 0 }
    $result = Set-WslDistroVersion -Name 'Debian' -Version 2 -Query {
        $tracking.Queries++
        if ($tracking.Queries -eq 1) { New-WslTestInventory @((New-WslTestDistro 'Debian' 1)) } else { throw 'fixture final inventory query failure' }
    } -RunCommand {
        param($CommandArguments)
        $tracking.Commands++
        New-WslTestCommand -Text 'fixture conversion command completed'
    }
    Assert-WslTrue (-not $result.Success -and $result.Status -eq 'Unknown') 'failed conversion verification query must not report success'
    Assert-WslTrue ($tracking.Commands -eq 1 -and $result.Command.ExitCode -eq 0 -and $result.Command.Text -ceq 'fixture conversion command completed') 'completed conversion command evidence was lost after verification query failed'
}

Test-WslCase 'kernel update diagnosis recognizes localized code and kernel message' {
    foreach ($command in @((New-WslTestCommand -ExitCode 444 -Text '错误：0x1bc'), (New-WslTestCommand -ExitCode 1 -ErrorText 'WSL 2 requires an update to its kernel component.'))) {
        Assert-WslTrue (Test-WslKernelUpdateRequired -CommandResult $command) 'kernel issue was not recognized'
    }
    Assert-WslTrue (-not (Test-WslKernelUpdateRequired -CommandResult (New-WslTestCommand -ExitCode 1 -Text 'Access denied'))) 'unrelated failure was misclassified'
}

Test-WslCase 'native argument quoting preserves switches and safely handles spaces and quotes' {
    Assert-WslTrue ((ConvertTo-WslCommandArgument -Argument '--status') -ceq '--status') 'WSL switch must remain unquoted'
    Assert-WslTrue ((ConvertTo-WslCommandArgument -Argument '') -ceq '""') 'empty argument must remain an argument'
    Assert-WslTrue ((ConvertTo-WslCommandArgument -Argument 'Debian Dev') -ceq '"Debian Dev"') 'space-containing name must be quoted'
    Assert-WslTrue ((ConvertTo-WslCommandArgument -Argument 'Debian Dev\') -ceq '"Debian Dev\\"') 'trailing slash must be escaped before closing quote'
    Assert-WslTrue ((ConvertTo-WslCommandArgument -Argument 'Debian"Dev') -ceq '"Debian\"Dev"') 'embedded quote must be escaped'
    $rejected = $false
    try { $null = ConvertTo-WslCommandArgument -Argument "Debian`0Dev" } catch { $rejected = $true }
    Assert-WslTrue $rejected 'NUL in an argument must be rejected'
}

# The orchestration tests below define only mocked read/query/execute functions.
. (Join-Path $precheckRepoRoot 'components\wsl_check.ps1') -NoRun

Test-WslCase 'version precheck keeps default two separate from WSL1 instances' {
    function Get-WslDefaultVersion { New-WslTestVersion 2 }
    function Get-WslDistroVersions { New-WslTestInventory @((New-WslTestDistro 'Old Debian' 1), (New-WslTestDistro 'Debian-13' 2)) }
    $state = Get-WslPrecheckVersionState
    Assert-WslTrue (-not $state.NeedDefaultFix -and @($state.Wsl1Distros).Count -eq 1 -and $state.HasIssue) 'default and existing instance versions were conflated'
}

Test-WslCase 'unknown version checks do not propose modifying commands' {
    function Get-WslDefaultVersion { New-WslTestVersion -Version $null -Known $false }
    function Get-WslDistroVersions { New-WslTestInventory -Known $false }
    $state = Get-WslPrecheckVersionState
    Assert-WslTrue ($state.HasUnknown -and -not $state.NeedDefaultFix -and @($state.Wsl1Distros).Count -eq 0) 'unknown status was turned into an actionable repair'
}

Test-WslCase 'each WSL1 conversion is confirmed separately and one failure does not hide other results' {
    $tracking = [pscustomobject]@{ Calls = (New-Object System.Collections.Generic.List[string]); Answers = (New-Object System.Collections.Generic.Queue[string]); Prompts = 0 }
    foreach ($answer in @('Y', 'N', 'Y')) { $tracking.Answers.Enqueue($answer) }
    function Write-Host { param($Object, $ForegroundColor) }
    function Read-Host { param($Prompt) $tracking.Prompts++; $tracking.Answers.Dequeue() }
    function Set-WslDefaultVersion {
        param($Version)
        $tracking.Calls.Add('default')
        [pscustomobject]@{ Success = $true; Status = 'Verified'; Command = $null; State = (New-WslTestVersion 2) }
    }
    function Set-WslDistroVersion {
        param($Name, $Version)
        $tracking.Calls.Add($Name)
        if ($Name -eq 'First Debian') { throw 'fixture conversion failure' }
        [pscustomobject]@{ Success = $true; Status = 'Verified'; Command = $null; State = (New-WslTestInventory @((New-WslTestDistro $Name 2))) }
    }
    $state = [pscustomobject]@{ NeedDefaultFix = $true; Wsl1Distros = @((New-WslTestDistro 'First Debian' 1), (New-WslTestDistro 'Keep Debian' 1), (New-WslTestDistro 'Last Debian' 1)) }
    $result = Invoke-WslVersionRepairs -VersionState $state
    Assert-WslTrue ($tracking.Prompts -eq 3 -and $tracking.Calls[0] -ceq 'default') 'default must precede individually confirmed conversions'
    Assert-WslTrue (($tracking.Calls -join ',') -ceq 'default,First Debian,Last Debian') 'a rejected distro was converted or a later one was skipped'
    Assert-WslTrue (($result.DistributionResults.Status -join ',') -eq 'Failed,Skipped,Verified') 'per-distro failure and skip results were not retained'
}

Test-WslCase 'pending prerequisites skip conversions without prompting or invoking WSL' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Read-Host { throw 'must not prompt to convert while prerequisites are pending' }
    function Set-WslDistroVersion { throw 'must not convert while prerequisites are pending' }
    $state = [pscustomobject]@{ NeedDefaultFix = $false; Wsl1Distros = @((New-WslTestDistro 'Debian' 1)) }
    $result = Invoke-WslVersionRepairs -VersionState $state -AllowConversion $false
    Assert-WslTrue ($result.DistributionResults[0].Status -eq 'Skipped') 'pending conversion was not reported as skipped'
}

function New-WslTestFeature {
    param([string]$State = 'Enabled', [bool]$Known = $true)
    [pscustomobject]@{ Known = $Known; State = $State; Enabled = ($State -eq 'Enabled'); Pending = ($State -in 'EnablePending', 'DisablePending') }
}

Test-WslCase 'non-admin feature repair is blocked while current-user default repair remains available' {
    $tracking = [pscustomobject]@{ DefaultCalls = 0; DismCalls = 0; Messages = (New-Object System.Collections.Generic.List[string]) }
    function Write-Host { param($Object, $ForegroundColor) $tracking.Messages.Add([string]$Object) }
    function Get-I18nStr { param($Key, $Args) $Key }
    function Get-CimInstance { param($ClassName, $ErrorAction) [pscustomobject]@{ HypervisorPresent = $true; VirtualizationFirmwareEnabled = $true } }
    function Get-WslFeatureState { param($Name) New-WslTestFeature 'Disabled' }
    function Get-WslRebootState { [pscustomobject]@{ Known = $true; Pending = $false } }
    function Get-WslDefaultVersion { New-WslTestVersion 1 }
    function Get-WslDistroVersions { New-WslTestInventory }
    function Get-Command { param($Name, $ErrorAction) [pscustomobject]@{ Name = $Name } }
    function Test-WslAdministrator { $false }
    function Get-PSDrive { param($Name, $ErrorAction) [pscustomobject]@{ Free = 20GB } }
    function Read-Host { param($Prompt) 'Y' }
    function Set-WslDefaultVersion {
        param($Version)
        $tracking.DefaultCalls++
        [pscustomobject]@{ Success = $true; Status = 'Verified'; Command = $null; State = (New-WslTestVersion 2) }
    }
    function Invoke-WslCommand { param($FilePath, $Arguments) $tracking.DismCalls++; throw 'DISM must not execute without elevation' }
    Invoke-WslPrecheck
    Assert-WslTrue ($tracking.DefaultCalls -eq 1 -and $tracking.DismCalls -eq 0) 'non-admin default repair was incorrectly blocked or DISM was executed'
    Assert-WslTrue (($tracking.Messages -join "`n").Contains('Check_AdminFeaturesOnly')) 'admin-only feature guidance was not displayed'
}

Test-WslCase 'DISM restart-required exit 3010 never reports features ready' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Invoke-WslCommand {
        param($FilePath, $Arguments)
        Assert-WslTrue ($FilePath -eq 'dism.exe' -and $Arguments -contains '/norestart') 'DISM must explicitly avoid automatic restart'
        New-WslTestCommand -ExitCode 3010
    }
    function Get-WslFeatureState { param($Name) New-WslTestFeature }
    function Get-WslRebootState { [pscustomobject]@{ Known = $true; Pending = $false } }
    $result = Invoke-WslFeatureRepairs -FeatureStates @([pscustomobject]@{ Name = 'VirtualMachinePlatform'; Result = (New-WslTestFeature 'Disabled') }) -IsAdmin $true
    Assert-WslTrue ($result.Pending -and -not $result.Ready -and -not $result.CanConvert -and -not $result.Failed) '3010 was treated as completed activation or a hard failure'
}

Test-WslCase 'DISM zero with EnablePending state still requires restart' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Invoke-WslCommand { param($FilePath, $Arguments) New-WslTestCommand }
    function Get-WslFeatureState { param($Name) New-WslTestFeature 'EnablePending' }
    function Get-WslRebootState { [pscustomobject]@{ Known = $true; Pending = $false } }
    $result = Invoke-WslFeatureRepairs -FeatureStates @([pscustomobject]@{ Name = 'VirtualMachinePlatform'; Result = (New-WslTestFeature 'Disabled') }) -IsAdmin $true
    Assert-WslTrue ($result.Pending -and -not $result.Ready -and -not $result.CanConvert) 'pending feature state was reported enabled'
}

Test-WslCase 'DISM zero without effective feature change is not ready' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Invoke-WslCommand { param($FilePath, $Arguments) New-WslTestCommand }
    function Get-WslFeatureState { param($Name) New-WslTestFeature 'Disabled' }
    function Get-WslRebootState { [pscustomobject]@{ Known = $true; Pending = $false } }
    $result = Invoke-WslFeatureRepairs -FeatureStates @([pscustomobject]@{ Name = 'VirtualMachinePlatform'; Result = (New-WslTestFeature 'Disabled') }) -IsAdmin $true
    Assert-WslTrue (-not $result.Ready -and -not $result.CanConvert) 'DISM exit zero was accepted without rechecked effective state'
}

Test-WslCase 'DISM failure is retained even if subsequent feature query says enabled' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Invoke-WslCommand { param($FilePath, $Arguments) New-WslTestCommand -ExitCode 5 }
    function Get-WslFeatureState { param($Name) New-WslTestFeature }
    function Get-WslRebootState { [pscustomobject]@{ Known = $true; Pending = $false } }
    $result = Invoke-WslFeatureRepairs -FeatureStates @([pscustomobject]@{ Name = 'VirtualMachinePlatform'; Result = (New-WslTestFeature 'Disabled') }) -IsAdmin $true
    Assert-WslTrue ($result.Failed -and -not $result.Ready -and -not $result.CanConvert) 'DISM error was hidden'
}

Test-WslCase 'unknown optional feature cannot trigger DISM' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Invoke-WslCommand { throw 'unknown feature must not be repaired blindly' }
    function Get-WslFeatureState { param($Name) New-WslTestFeature -State 'Unknown' -Known $false }
    function Get-WslRebootState { [pscustomobject]@{ Known = $true; Pending = $false } }
    $result = Invoke-WslFeatureRepairs -FeatureStates @([pscustomobject]@{ Name = 'VirtualMachinePlatform'; Result = (New-WslTestFeature -State 'Unknown' -Known $false) }) -IsAdmin $true
    Assert-WslTrue (-not $result.Ready) 'unknown feature was reported ready'
}

Test-WslCase 'read-only feature access uncertainty does not impose an admin gate on individually confirmed conversions' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Invoke-WslCommand { throw 'unknown feature must not trigger DISM' }
    function Get-WslFeatureState { param($Name) New-WslTestFeature -State 'Unknown' -Known $false }
    function Get-WslRebootState { [pscustomobject]@{ Known = $false; Pending = $false } }
    $result = Invoke-WslFeatureRepairs -FeatureStates @([pscustomobject]@{ Name = 'VirtualMachinePlatform'; Result = (New-WslTestFeature -State 'Unknown' -Known $false) }) -IsAdmin $false
    Assert-WslTrue (-not $result.Ready -and $result.CanConvert) 'query permissions must not be confused with a proven disabled prerequisite'
}

Test-WslCase 'effective enabled features plus known no restart verifies readiness after DISM' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Invoke-WslCommand { param($FilePath, $Arguments) New-WslTestCommand }
    function Get-WslFeatureState { param($Name) New-WslTestFeature }
    function Get-WslRebootState { [pscustomobject]@{ Known = $true; Pending = $false } }
    $result = Invoke-WslFeatureRepairs -FeatureStates @([pscustomobject]@{ Name = 'VirtualMachinePlatform'; Result = (New-WslTestFeature 'Disabled') }) -IsAdmin $true
    Assert-WslTrue ($result.Ready -and $result.CanConvert -and -not $result.Pending -and -not $result.Failed) 'verified activated feature was not accepted'
}

Test-WslCase 'DISM execution followed by unknown feature state cannot permit conversion' {
    function Write-Host { param($Object, $ForegroundColor) }
    function Invoke-WslCommand { param($FilePath, $Arguments) New-WslTestCommand }
    function Get-WslFeatureState { param($Name) New-WslTestFeature -State 'Unknown' -Known $false }
    function Get-WslRebootState { [pscustomobject]@{ Known = $true; Pending = $false } }
    $result = Invoke-WslFeatureRepairs -FeatureStates @([pscustomobject]@{ Name = 'VirtualMachinePlatform'; Result = (New-WslTestFeature 'Disabled') }) -IsAdmin $true
    Assert-WslTrue (-not $result.Ready -and -not $result.CanConvert) 'an unverified DISM change should require another precheck'
}

Test-WslCase 'kernel guidance offers both WSL update commands for localized error 0x1bc' {
    $tracking = [pscustomobject]@{ Messages = (New-Object System.Collections.Generic.List[string]) }
    function Write-Host { param($Object, $ForegroundColor) $tracking.Messages.Add([string]$Object) }
    $oldLang = $global:CurrentLang
    try {
        foreach ($lang in @('en-US', 'zh-CN')) {
            $global:CurrentLang = $lang
            Show-WslKernelGuidance -CommandResult (New-WslTestCommand -ExitCode 444 -Text '错误：0x1bc')
        }
    } finally { $global:CurrentLang = $oldLang }
    $text = $tracking.Messages -join "`n"
    Assert-WslTrue ($text.Contains('wsl --update') -and $text.Contains('wsl --update --web-download')) 'kernel update commands are missing'
}

Write-Host "WSL Precheck regressions: $script:wslTestCount tests, $($script:wslTestFailures.Count) failures."
if ($script:wslTestFailures.Count -gt 0) {
    throw ($script:wslTestFailures -join "`n")
}
