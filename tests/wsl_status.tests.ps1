# Offline status/lifecycle regressions. Native WSL and task mutations are stubbed.
$ErrorActionPreference = 'Stop'
$statusRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $statusRepoRoot 'components\wsl_status.ps1') -NoRun
$script:statusTestCount = 0
$script:statusTestFailures = New-Object System.Collections.Generic.List[string]

function Assert-Status {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Test-StatusCase {
    param([string]$Name, [scriptblock]$Body)
    $script:statusTestCount++
    try { & $Body; Write-Host "  PASS $Name" -ForegroundColor Green }
    catch {
        $script:statusTestFailures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "  FAIL ${Name}: $($_.Exception.Message)" -ForegroundColor Red
    }
}
function New-StatusCommand {
    param([string]$Text = '', [int]$ExitCode = 0, [bool]$IsDecoded = $true)
    [pscustomobject]@{ Text = $Text; ErrorText = ''; ExitCode = $ExitCode; IsDecoded = $IsDecoded }
}
function New-StatusRow {
    param([string]$Name = 'Debian', [string]$State = 'Running')
    [pscustomobject]@{
        Name = $Name; State = $State; Created = [datetime]'2025-03-04T05:06:00'; CreatedSource = 'Storage'
        UptimeSeconds = 3661; SizeBytes = 2GB; Autostart = $true; KeepAlive = $false
    }
}
function New-StatusUptimeText {
    param([double]$VmSeconds = 10000, [long]$StartTicks = 900000, [int]$Hz = 100)
    $fields = @('S') + @(1..18 | ForEach-Object { '0' }) + @([string]$StartTicks)
    "__UPTIME__`n$VmSeconds 50.00`n__INIT__`n1 (systemd (fixture)) $($fields -join ' ')`n__HZ__`n$Hz`n"
}

Test-StatusCase 'duration fields remain short and unavailable duration is a dash' {
    foreach ($case in @(@($null,'-'), @(-1,'-'), @(0,'0s'), @(59,'59s'), @(61,'1m01s'), @(3661,'1h01m'), @(90000,'1d01h'))) {
        Assert-Status ((Format-WslStatusDuration -Seconds $case[0]) -ceq $case[1]) "incorrect duration for $($case[0])"
    }
}
Test-StatusCase 'per-instance uptime subtracts init start instead of reporting shared VM uptime' {
    $first = ConvertFrom-WslInstanceUptime -Text (New-StatusUptimeText -StartTicks 900000)
    $second = ConvertFrom-WslInstanceUptime -Text (New-StatusUptimeText -StartTicks 950000)
    Assert-Status ($first -eq 1000 -and $second -eq 500) 'different init times in one VM were conflated'
}
Test-StatusCase 'invalid and incomplete uptime probes remain unknown' {
    $valid = New-StatusUptimeText
    foreach ($text in @('', 'not uptime', ($valid -replace '__HZ__','bad'), (New-StatusUptimeText -Hz 0), (New-StatusUptimeText -StartTicks 2000000), ($valid -replace '900000','bad'))) {
        Assert-Status ($null -eq (ConvertFrom-WslInstanceUptime -Text $text)) 'invalid uptime was accepted'
    }
}
Test-StatusCase 'running inventory accepts only registered exact names and uses a query command' {
    $tracking = [pscustomobject]@{ Arguments = @() }
    function Invoke-WslCommand { param($Arguments,$TimeoutMilliseconds) $tracking.Arguments = $Arguments; New-StatusCommand "Debian QA`nDebian-13`n" }
    $result = Get-WslRunningDistroNames -DistroNames @('Debian QA','Debian-13','Off Debian')
    Assert-Status ($result.Known -and ($result.Names -join ',') -ceq 'Debian QA,Debian-13') 'running names were lost'
    Assert-Status (($tracking.Arguments -join ' ') -ceq '--list --running --quiet') 'inventory entered a distribution'
}
Test-StatusCase 'empty running list is a known empty inventory' {
    function Invoke-WslCommand { param($Arguments,$TimeoutMilliseconds) New-StatusCommand }
    $result = Get-WslRunningDistroNames -DistroNames @('Debian')
    Assert-Status ($result.Known -and @($result.Names).Count -eq 0) 'empty successful running inventory became an error'
}
Test-StatusCase 'failed undecodable or unrecognized running output never means stopped' {
    foreach ($command in @((New-StatusCommand -ExitCode 1), (New-StatusCommand -IsDecoded $false), (New-StatusCommand 'localized query error'), (New-StatusCommand "Debian`nDebian"))) {
        $fixture = $command
        function Invoke-WslCommand { param($Arguments,$TimeoutMilliseconds) $fixture }
        $result = Get-WslRunningDistroNames -DistroNames @('Debian')
        Assert-Status (-not $result.Known -and @($result.Names).Count -eq 0) 'uncertain output was accepted as running inventory'
    }
}
Test-StatusCase 'rows probe uptime only for confirmed running instances' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Get-WslDistroVersions { [pscustomobject]@{Source='Registry';Distributions=@([pscustomobject]@{Name='Running Debian'},[pscustomobject]@{Name='Stopped Debian'})} }
    function Get-WslRunningDistroNames { param($DistroNames) [pscustomobject]@{Known=$true;Names=@('Running Debian')} }
    function Get-WslDistroStorageInfo { param($DistroName) [pscustomobject]@{Length=1GB;Created=[datetime]'2025-01-01';CreatedSource='Storage'} }
    function Get-WslInstanceUptime { param($DistroName) $tracking.Add($DistroName); 123 }
    function Get-WslDistroLifecycle { param($DistroName) [pscustomobject]@{Known=$true;Autostart=$false;KeepAlive=$true} }
    $rows = @(Get-WslStatusRows)
    Assert-Status (($tracking -join ',') -ceq 'Running Debian') 'a stopped instance was entered'
    Assert-Status ($rows[0].UptimeSeconds -eq 123 -and $null -eq $rows[1].UptimeSeconds -and $rows[1].State -eq 'Stopped') 'uptime/state separation failed'
    Assert-Status ($rows[0].CreatedSource -eq 'Storage' -and $rows[0].SizeBytes -eq 1GB -and -not $rows[0].Autostart -and $rows[0].KeepAlive) 'metadata fields were lost'
    Assert-Status ($null -eq $rows[0].PSObject.Properties['Version']) 'WSL version leaked back into status rows'
}
Test-StatusCase 'unknown running inventory never probes or labels an instance stopped' {
    function Get-WslDistroVersions { [pscustomobject]@{Source='Registry';Distributions=@([pscustomobject]@{Name='Debian'})} }
    function Get-WslRunningDistroNames { param($DistroNames) [pscustomobject]@{Known=$false;Names=@()} }
    function Get-WslDistroStorageInfo { param($DistroName) $null }
    function Get-WslInstanceUptime { throw 'must not wake an unverified instance' }
    function Get-WslDistroLifecycle { param($DistroName) [pscustomobject]@{Known=$false;Autostart=$false;KeepAlive=$false} }
    $row = @(Get-WslStatusRows)[0]
    Assert-Status ($row.State -eq 'Unknown' -and $null -eq $row.UptimeSeconds -and $null -eq $row.Autostart -and $null -eq $row.KeepAlive) 'unknown values were changed to false/stopped'
}
Test-StatusCase 'unverified registered inventory aborts before any distribution probe' {
    function Get-WslDistroVersions { [pscustomobject]@{Source='Unknown';Distributions=@()} }
    function Get-WslRunningDistroNames { throw 'must not query further' }
    $threw = $false
    try { Get-WslStatusRows } catch { $threw = $true }
    Assert-Status $threw 'unverified registered inventory was accepted'
}
Test-StatusCase 'storage date uses the Windows folder creation value and never the VHD modified date' {
    $folder = Join-Path ([IO.Path]::GetTempPath()) 'status-fixture'
    function Get-ChildItem { param($LiteralPath,$ErrorAction,$Filter,[switch]$File) [pscustomobject]@{PSPath='Registry::fixture'} }
    function Get-ItemProperty { param($LiteralPath,$ErrorAction) [pscustomobject]@{DistributionName='Debian';BasePath=$folder;VhdFileName='ext4.vhdx'} }
    function Get-Item {
        param($LiteralPath,$ErrorAction)
        if ($LiteralPath -eq $folder) { [pscustomobject]@{CreationTime=[datetime]'2021-02-03'} }
        else { [pscustomobject]@{FullName=$LiteralPath;Length=2GB;LastWriteTime=[datetime]'2026-01-01'} }
    }
    $storage = Get-WslDistroStorageInfo -DistroName Debian
    Assert-Status ($storage.Created -eq [datetime]'2021-02-03' -and $storage.CreatedSource -eq 'Storage' -and $storage.Length -eq 2GB) 'storage creation approximation was misrepresented'
}
Test-StatusCase 'storage query errors are unavailable rather than fabricated dates' {
    function Get-ChildItem { throw 'registry unavailable' }
    Assert-Status ($null -eq (Get-WslDistroStorageInfo -DistroName Debian)) 'missing storage was fabricated'
}
Test-StatusCase 'table has eight short columns no WSL version and labelled creation estimates' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object,$ForegroundColor) $tracking.Add([string]$Object) }
    $oldLang = $global:CurrentLang
    try { $global:CurrentLang='en-US'; Show-WslStatusTable -Rows @((New-StatusRow)) }
    finally { $global:CurrentLang=$oldLang }
    $text = $tracking -join "`n"
    $header = @($tracking | Where-Object {$_ -match '\| Name\s+\| St'})
    Assert-Status ($header.Count -eq 1 -and ($header[0] -split '\|').Count -eq 8) 'header is not the compact eight-column layout'
    Assert-Status (-not $text.Contains('WSL Ver') -and $text.Contains('~2025-03-04 05:06') -and $text.Contains('1h01m') -and $text.Contains('2G')) 'required shortened fields are incorrect'
}
Test-StatusCase 'stopped row hides uptime even if stale timing data exists' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object,$ForegroundColor) $tracking.Add([string]$Object) }
    Show-WslStatusTable -Rows @((New-StatusRow -State Stopped))
    Assert-Status (-not ($tracking -join "`n").Contains('1h01m')) 'stale uptime was shown for a stopped instance'
}
Test-StatusCase 'Chinese cells and size labels stay bounded and short' {
    Assert-Status ((Get-WslStatusTextWidth '实例') -eq 4) 'CJK width was counted as ASCII'
    Assert-Status ((Get-WslStatusTextWidth (Format-WslStatusCell -Text '很长的实例名称' -Width 6)) -eq 6) 'CJK truncation exceeded its column'
    Assert-Status ((Format-WslStatusSize 1TB) -eq '1T' -and (Format-WslStatusSize $null) -eq '-') 'size abbreviations changed'
}
Test-StatusCase 'all six instance actions require confirmation before mutation' {
    $tracking = [pscustomobject]@{Count=0}
    function Write-Host { param($Object,$ForegroundColor) }
    function Select-WslDistro { param($Title) 'Debian' }
    function Read-Host { param($Prompt) 'N' }
    function Set-WslDistroAutostart { $tracking.Count++ }
    function Set-WslDistroResidency { $tracking.Count++ }
    function Invoke-WslCommand { $tracking.Count++ }
    foreach ($choice in @('A','N','K','R','T','S')) { Invoke-WslStatusAction -Choice $choice }
    Assert-Status ($tracking.Count -eq 0) 'an unconfirmed action mutated state'
}
Test-StatusCase 'autostart and residency choices address only the selected setting' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object,$ForegroundColor) }
    function Select-WslDistro { param($Title) 'Debian QA' }
    function Read-Host { param($Prompt) 'Y' }
    function Set-WslDistroAutostart { param($DistroName,[bool]$Enabled) $tracking.Add("Auto:$DistroName`:$Enabled"); [pscustomobject]@{Success=$true;Error=''} }
    function Set-WslDistroResidency { param($DistroName,[bool]$KeepAlive) $tracking.Add("Keep:$DistroName`:$KeepAlive"); [pscustomobject]@{Success=$true;Error=''} }
    function Invoke-WslCommand { throw 'lifecycle choices must not directly terminate or shut down WSL' }
    foreach ($choice in @('a','n','k','r')) { Invoke-WslStatusAction -Choice $choice }
    Assert-Status (($tracking -join ',') -ceq 'Auto:Debian QA:True,Auto:Debian QA:False,Keep:Debian QA:True,Keep:Debian QA:False') 'setting independence or selected instance was lost'
}
Test-StatusCase 'empty invalid or cancelled selection performs no mutation' {
    function Write-Host { param($Object,$ForegroundColor) }
    function Select-WslDistro { param($Title) $null }
    function Read-Host { throw 'cancelled selection must not ask confirmation' }
    function Set-WslDistroAutostart { throw 'must not mutate' }
    function Set-WslDistroResidency { throw 'must not mutate' }
    foreach ($choice in @('','0','bad','A','R')) { Invoke-WslStatusAction -Choice $choice }
}
Test-StatusCase 'stop operations invoke exact native switches only after confirmation' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object,$ForegroundColor) }
    function Select-WslDistro { param($Title) 'Debian QA' }
    function Read-Host { param($Prompt) 'Y' }
    function Invoke-WslCommand { param($Arguments) $tracking.Add(($Arguments -join '|')); New-StatusCommand }
    Invoke-WslStatusAction -Choice T
    Invoke-WslStatusAction -Choice S
    Assert-Status (($tracking -join ',') -ceq '--terminate|Debian QA,--shutdown') 'stop selected the wrong instance or arguments'
}
Test-StatusCase 'failed lifecycle verification is reported as failure' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object,$ForegroundColor) $tracking.Add([string]$Object) }
    function Select-WslDistro { param($Title) 'Debian' }
    function Read-Host { param($Prompt) 'Y' }
    function Set-WslDistroAutostart { param($DistroName,[bool]$Enabled) [pscustomobject]@{Success=$false;Error='fixture readback failed'} }
    Invoke-WslStatusAction -Choice A
    Assert-Status (($tracking -join "`n").Contains('fixture readback failed') -and -not ($tracking -join "`n").Contains('[OK]')) 'failed readback was labelled successful'
}
Test-StatusCase 'network probe never enters a stopped or unverified instance' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object,$ForegroundColor) }
    function Invoke-WslCommand { param($Arguments,$TimeoutMilliseconds) $tracking.Add(($Arguments -join '|')); New-StatusCommand -Text '' }
    Show-WslNetworkHealth -DistroName Debian
    Assert-Status (($tracking -join ',') -ceq '--list|--running|--quiet') 'a stopped instance was entered for a network probe'
}
Test-StatusCase 'dashboard probes only rows confirmed running' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object,$ForegroundColor) }
    function Get-Command { param($Name,$CommandType,$ErrorAction) [pscustomobject]@{Name=$Name} }
    function Get-WslStatusRows { New-StatusRow -Name 'Run Debian'; New-StatusRow -Name 'Off Debian' -State Stopped; New-StatusRow -Name 'Unknown Debian' -State Unknown }
    function Show-WslNetworkHealth { param($DistroName) $tracking.Add($DistroName) }
    function Read-Host { param($Prompt) '0' }
    Show-WslDashboard
    Assert-Status (($tracking -join ',') -ceq 'Run Debian') 'dashboard probed a stopped or unknown row'
}

Test-StatusCase 'real English and Chinese locale formatting substitutes single and multiple arguments' {
    $oldLang = $global:CurrentLang
    try {
        foreach ($lang in @('en-US','zh-CN')) {
            $global:CurrentLang = $lang
            $single = Get-I18nStr 'Status_ConfirmAutoOn' -Args @('Debian QA')
            $double = Get-I18nStr 'Status_ActionFailed' -Args @('Debian QA','fixture failure')
            Assert-Status ($single.Contains('Debian QA') -and -not $single.Contains('{0}')) 'single-format argument was lost'
            Assert-Status ($double.Contains('Debian QA') -and $double.Contains('fixture failure') -and $double -notmatch '\{[01]\}') 'multiple-format arguments were lost'
        }
    } finally { $global:CurrentLang = $oldLang }
}
# Lifecycle mutation tests are appended below; all task/WSL commands use fixtures.
function New-StatusLifecycleContext {
    [pscustomobject]@{
        DistroName='Debian QA'; Sid='S-1-5-21-1000'; Token='fixture-token'; WslExe='C:\Windows\System32\wsl.exe'
        TaskName='oneDebian-WSL-fixture-token'; TaskPath='\'; Description='oneDebian fixture owned task'
        StartArguments='--distribution "Debian QA" --exec /bin/true'; ResidentArguments='--distribution "Debian QA" --exec fixture-keeper'
    }
}
function New-StatusLifecycleTask {
    param($Context, [bool]$Autostart = $false, [bool]$KeepAlive = $false, [string]$State='Ready')
    $triggers = @()
    if ($Autostart) { $triggers = @([pscustomobject]@{CimClass=[pscustomobject]@{CimClassName='MSFT_TaskLogonTrigger'};UserId=$Context.Sid}) }
    [pscustomobject]@{
        TaskName=$Context.TaskName;TaskPath=$Context.TaskPath;Description=$Context.Description
        Actions=@([pscustomobject]@{Execute=$Context.WslExe;Arguments=$(if($KeepAlive){$Context.ResidentArguments}else{$Context.StartArguments})})
        Principal=[pscustomobject]@{UserId=$Context.Sid;LogonType='Interactive';RunLevel='Limited'}
        Triggers=$triggers;Settings=[pscustomobject]@{Enabled=$true;ExecutionTimeLimit='PT0S';MultipleInstances='IgnoreNew'};State=$State
    }
}
function Initialize-StatusLifecycleFixture {
    $lifecycleFixture = [pscustomobject]@{
        Context=(New-StatusLifecycleContext);Task=$null;Calls=(New-Object System.Collections.Generic.List[string])
        Known=$true;Running=$false
    }
    function Get-WslLifecycleContext { param($DistroName) $lifecycleFixture.Context }
    function Get-WslLifecycleTask { param($Context) $lifecycleFixture.Task }
    function Set-WslLifecycleTask {
        param($Context,[bool]$Autostart,[bool]$KeepAlive)
        $lifecycleFixture.Calls.Add("Policy:$Autostart`:$KeepAlive")
        if(-not $Autostart -and -not $KeepAlive){$lifecycleFixture.Task=$null}
        else{$lifecycleFixture.Task=New-StatusLifecycleTask -Context $Context -Autostart $Autostart -KeepAlive $KeepAlive}
    }
    function Get-WslDistroRunningState { param($DistroName) [pscustomobject]@{Known=$lifecycleFixture.Known;Running=$lifecycleFixture.Running} }
    function Start-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $lifecycleFixture.Calls.Add('Start');$lifecycleFixture.Task.State='Running';$lifecycleFixture.Running=$true }
    function Stop-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $lifecycleFixture.Calls.Add('Stop');$lifecycleFixture.Task.State='Ready' }
    function Stop-WslLifecycleKeeper { param($Context) $lifecycleFixture.Calls.Add('Release') }
    function Get-WslLifecycleKeeperState { param($Context) [pscustomobject]@{Known=$lifecycleFixture.Known;Running=$lifecycleFixture.Running} }
    function Start-Sleep { param($Milliseconds) }
    function Invoke-WslCommand { throw 'unexpected native WSL command in lifecycle policy test' }
}

Test-StatusCase 'uptime probe rechecks current running state before entering an instance' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Invoke-WslCommand { param($Arguments,$TimeoutMilliseconds) $tracking.Add(($Arguments -join '|')); New-StatusCommand }
    Assert-Status ($null -eq (Get-WslInstanceUptime -DistroName 'Debian')) 'stopped instance was given an uptime'
    Assert-Status (($tracking -join ',') -ceq '--list|--running|--quiet') 'stopped instance was entered by timing probe'
}
Test-StatusCase 'uptime probe skips an undecodable running recheck' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Invoke-WslCommand { param($Arguments,$TimeoutMilliseconds) $tracking.Add(($Arguments -join '|')); New-StatusCommand -Text Debian -IsDecoded $false }
    Assert-Status ($null -eq (Get-WslInstanceUptime -DistroName 'Debian')) 'unverified instance was entered'
    Assert-Status ($tracking.Count -eq 1) 'probe continued after undecodable running output'
}
Test-StatusCase 'uptime probe enters only the selected currently running instance' {
    $tracking = New-Object System.Collections.Generic.List[string]
    function Invoke-WslCommand {
        param($Arguments,$TimeoutMilliseconds)
        $tracking.Add(($Arguments -join '|'))
        if($Arguments[0] -eq '--list'){New-StatusCommand -Text "Other Debian`nDebian QA`n"}
        else {New-StatusCommand -Text (New-StatusUptimeText)}
    }
    Assert-Status ((Get-WslInstanceUptime -DistroName 'Debian QA') -eq 1000) 'selected instance timing was not parsed'
    Assert-Status ($tracking.Count -eq 2 -and $tracking[1].StartsWith('--distribution|Debian QA|--exec|')) 'probe targeted another distribution'
}
Test-StatusCase 'task ownership requires exact marker action user and login scope' {
    $context=New-StatusLifecycleContext
    $owned=New-StatusLifecycleTask -Context $context -Autostart $true -KeepAlive $true
    Assert-Status (Test-WslLifecycleTaskOwnership -Task $owned -Context $context) 'valid managed task was rejected'
    foreach($field in @('Description','Execute','Arguments','Sid','LogonType','RunLevel','TriggerUser','TriggerType')){
        $task=New-StatusLifecycleTask -Context $context -Autostart $true -KeepAlive $true
        switch($field){
            Description{$task.Description='someone else'}
            Execute{$task.Actions[0].Execute='C:\unrelated.exe'}
            Arguments{$task.Actions[0].Arguments='unrelated action'}
            Sid{$task.Principal.UserId='S-1-5-18'}
            LogonType{$task.Principal.LogonType='ServiceAccount'}
            RunLevel{$task.Principal.RunLevel='Highest'}
            TriggerUser{$task.Triggers[0].UserId='S-1-5-18'}
            TriggerType{$task.Triggers[0].CimClass.CimClassName='MSFT_TaskBootTrigger'}
        }
        Assert-Status (-not (Test-WslLifecycleTaskOwnership -Task $task -Context $context)) "unowned task accepted: $field"
    }
}
Test-StatusCase 'residency-only task with no login trigger remains owned without enabling autostart' {
    $context=New-StatusLifecycleContext
    $task=New-StatusLifecycleTask -Context $context -KeepAlive $true
    $task.Triggers=$null
    Assert-Status (Test-WslLifecycleTaskOwnership -Task $task -Context $context) 'empty trigger collection was rejected'
    $policy=Get-WslLifecycleTaskPolicy -Task $task -Context $context
    Assert-Status ($policy.KeepAlive -and -not $policy.Autostart) 'residency-only became sign-in autostart'
}
Test-StatusCase 'same-name foreign task prevents every mutation' {
    $context=New-StatusLifecycleContext
    $task=New-StatusLifecycleTask -Context $context
    $task.Description='foreign task'
    function Get-WslLifecycleContext {param($DistroName)$context}
    function Get-ScheduledTask {param($TaskPath,$ErrorAction)$task}
    function Register-ScheduledTask {throw 'foreign task must not be replaced'}
    function Unregister-ScheduledTask {throw 'foreign task must not be removed'}
    $result=Set-WslDistroAutostart -DistroName 'Debian QA' -Enabled $true
    Assert-Status (-not $result.Success -and $result.Error.Contains('not the verified')) 'foreign task was not rejected'
}
Test-StatusCase 'absent managed task is a known disabled policy while access failure is unknown' {
    $context=New-StatusLifecycleContext
    function Get-WslLifecycleContext {param($DistroName)$context}
    function Get-ScheduledTask {param($TaskPath,$ErrorAction) @()}
    $state=Get-WslDistroLifecycle -DistroName 'Debian QA'
    Assert-Status ($state.Known -and -not $state.Autostart -and -not $state.KeepAlive) 'absent task was not disabled'
    function Get-ScheduledTask {throw 'denied fixture'}
    $state=Get-WslDistroLifecycle -DistroName 'Debian QA'
    Assert-Status (-not $state.Known) 'access failure was mistaken for disabled startup'
}
Test-StatusCase 'autostart changes preserve the selected residency setting and do not start WSL' {
    . Initialize-StatusLifecycleFixture
    $lifecycleFixture.Task=New-StatusLifecycleTask -Context $lifecycleFixture.Context -KeepAlive $true
    $result=Set-WslDistroAutostart -DistroName 'Debian QA' -Enabled $true
    Assert-Status ($result.Success -and $result.State.Autostart -and $result.State.KeepAlive) 'enable auto discarded residency'
    $result=Set-WslDistroAutostart -DistroName 'Debian QA' -Enabled $false
    Assert-Status ($result.Success -and -not $result.State.Autostart -and $result.State.KeepAlive) 'disable auto discarded residency'
    Assert-Status (-not $lifecycleFixture.Calls.Contains('Start') -and -not $lifecycleFixture.Calls.Contains('Release')) 'startup configuration started or stopped the instance'
}
Test-StatusCase 'keep-running preserves autostart and verifies task and distro running state' {
    . Initialize-StatusLifecycleFixture
    $lifecycleFixture.Task=New-StatusLifecycleTask -Context $lifecycleFixture.Context -Autostart $true
    $result=Set-WslDistroResidency -DistroName 'Debian QA' -KeepAlive $true
    Assert-Status ($result.Success -and $result.State.Autostart -and $result.State.KeepAlive -and $result.State.ResidentRunning) 'keep-running was not verified'
    Assert-Status ($lifecycleFixture.Calls.Contains('Start')) 'keep-running did not start its managed task'
}
Test-StatusCase 'unverified running state after task start is a failure' {
    . Initialize-StatusLifecycleFixture
    function Start-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$lifecycleFixture.Calls.Add('Start')}
    $result=Set-WslDistroResidency -DistroName 'Debian QA' -KeepAlive $true
    Assert-Status (-not $result.Success -and $result.Error.Contains('could not be verified')) 'task configuration alone became successful residency'
}
Test-StatusCase 'idle exit releases only the managed keeper and preserves sign-in startup' {
    . Initialize-StatusLifecycleFixture
    $lifecycleFixture.Task=New-StatusLifecycleTask -Context $lifecycleFixture.Context -Autostart $true -KeepAlive $true -State Running
    $lifecycleFixture.Running=$true
    $result=Set-WslDistroResidency -DistroName 'Debian QA' -KeepAlive $false
    Assert-Status ($result.Success -and $result.State.Autostart -and -not $result.State.KeepAlive) 'idle exit discarded autostart'
    Assert-Status (($lifecycleFixture.Calls -join ',') -ceq 'Release,Stop,Policy:True:False') 'idle exit did not release only the owned keeper'
}
Test-StatusCase 'idle exit of a stopped instance never executes a guest cleanup command' {
    . Initialize-StatusLifecycleFixture
    $lifecycleFixture.Task=New-StatusLifecycleTask -Context $lifecycleFixture.Context -KeepAlive $true
    $result=Set-WslDistroResidency -DistroName 'Debian QA' -KeepAlive $false
    Assert-Status ($result.Success -and -not $result.State.KeepAlive -and -not $lifecycleFixture.Calls.Contains('Release')) 'stopped instance was entered for cleanup'
}
Test-StatusCase 'unknown running state updates idle policy but refuses to claim completed cleanup' {
    . Initialize-StatusLifecycleFixture
    $lifecycleFixture.Task=New-StatusLifecycleTask -Context $lifecycleFixture.Context -KeepAlive $true -State Running
    $lifecycleFixture.Known=$false
    $result=Set-WslDistroResidency -DistroName 'Debian QA' -KeepAlive $false
    Assert-Status (-not $result.Success -and $result.Error.Contains('unknown') -and -not $lifecycleFixture.Calls.Contains('Release')) 'unknown state triggered guest cleanup or claimed success'
    Assert-Status (-not (Get-WslLifecycleTaskPolicy -Task $lifecycleFixture.Task -Context $lifecycleFixture.Context).KeepAlive) 'idle policy remained resident after unknown cleanup'
}
Test-StatusCase 'keeper release builds an exact owner argv match and never a global stop' {
    $context=New-StatusLifecycleContext
    $tracking=[pscustomobject]@{Arguments=@()}
    function Invoke-WslCommand {param($Arguments,$TimeoutMilliseconds)$tracking.Arguments=$Arguments;New-StatusCommand}
    Stop-WslLifecycleKeeper -Context $context
    Assert-Status ($tracking.Arguments[0] -eq '--distribution' -and $tracking.Arguments[1] -ceq $context.DistroName) 'keeper cleanup targeted another distro'
    Assert-Status ($tracking.Arguments -notcontains '--terminate' -and $tracking.Arguments -notcontains '--shutdown') 'cleanup forced an instance/global stop'
    $script=$tracking.Arguments[-1]
    Assert-Status ($script.Contains('[ "$actual" = "$expected" ]') -and $script.Contains('kill -TERM') -and -not $script.Contains('pkill')) 'keeper cleanup used an unsafe broad match'
}
Test-StatusCase 'task registration uses current-user interactive sign-in without elevation or a timeout' {
    $context=New-StatusLifecycleContext
    $fixture=[pscustomobject]@{Task=$null;Definition=$null;Registered=0}
    function Get-WslLifecycleTask {param($Context)$fixture.Task}
    function New-ScheduledTaskAction {param($Execute,$Argument)[pscustomobject]@{Execute=$Execute;Arguments=$Argument}}
    function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel)[pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
    function New-ScheduledTaskSettingsSet {param($ExecutionTimeLimit,$MultipleInstances,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable)
        Assert-Status ($ExecutionTimeLimit -eq [TimeSpan]::Zero -and $AllowStartIfOnBatteries -and $DontStopIfGoingOnBatteries) 'managed task has a runtime/battery cutoff'
        [pscustomobject]@{Enabled=$true;ExecutionTimeLimit='PT0S';MultipleInstances=$MultipleInstances}}
    function New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User)
        Assert-Status $AtLogOn 'startup trigger was not sign-in'
        [pscustomobject]@{CimClass=[pscustomobject]@{CimClassName='MSFT_TaskLogonTrigger'};UserId=$User}}
    function New-ScheduledTask {param($Action,$Principal,$Settings,$Description,$Trigger=@())
        $fixture.Definition=[pscustomobject]@{TaskName=$context.TaskName;TaskPath=$context.TaskPath;Description=$Description;Actions=@($Action);Principal=$Principal;Settings=$Settings;Triggers=@($Trigger);State='Ready'}
        $fixture.Definition}
    function Register-ScheduledTask {param($TaskName,$TaskPath,$InputObject,[switch]$Force,$ErrorAction)$fixture.Registered++;$fixture.Task=$InputObject}
    Set-WslLifecycleTask -Context $context -Autostart $true -KeepAlive $true
    Assert-Status ($fixture.Registered -eq 1 -and $fixture.Task.Principal.UserId -ceq $context.Sid -and $fixture.Task.Principal.LogonType -eq 'Interactive' -and $fixture.Task.Principal.RunLevel -eq 'Limited') 'task was assigned another user or elevation'
    Assert-Status ($fixture.Task.Triggers[0].UserId -ceq $context.Sid -and $fixture.Task.Actions[0].Arguments -ceq $context.ResidentArguments) 'trigger/action mismatch'
}
Test-StatusCase 'task registration readback must match requested policy' {
    $context=New-StatusLifecycleContext
    $fixture=[pscustomobject]@{Task=$null}
    function Get-WslLifecycleTask {param($Context)$fixture.Task}
    function New-ScheduledTaskAction {param($Execute,$Argument)[pscustomobject]@{Execute=$Execute;Arguments=$Argument}}
    function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel)[pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
    function New-ScheduledTaskSettingsSet {param($ExecutionTimeLimit,$MultipleInstances,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable)[pscustomobject]@{Enabled=$true;ExecutionTimeLimit='PT1H';MultipleInstances=$MultipleInstances}}
    function New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User)[pscustomobject]@{CimClass=[pscustomobject]@{CimClassName='MSFT_TaskLogonTrigger'};UserId=$User}}
    function New-ScheduledTask {param($Action,$Principal,$Settings,$Description,$Trigger=@())[pscustomobject]@{TaskName=$context.TaskName;TaskPath=$context.TaskPath;Description=$Description;Actions=@($Action);Principal=$Principal;Settings=$Settings;Triggers=@($Trigger);State='Ready'}}
    function Register-ScheduledTask {param($TaskName,$TaskPath,$InputObject,[switch]$Force,$ErrorAction)$fixture.Task=$InputObject}
    $threw=$false
    try{Set-WslLifecycleTask -Context $context -Autostart $true -KeepAlive $true}catch{$threw=$true}
    Assert-Status $threw 'incorrect runtime limit passed task verification'
}
Test-StatusCase 'removing both policies unregisters only the exact managed task and verifies absence' {
    $context=New-StatusLifecycleContext
    $fixture=[pscustomobject]@{Task=(New-StatusLifecycleTask -Context $context -Autostart $true);Removed=''}
    function Get-WslLifecycleTask {param($Context)$fixture.Task}
    function Unregister-ScheduledTask {param($TaskName,$TaskPath,[bool]$Confirm,$ErrorAction)$fixture.Removed="$TaskPath$TaskName";$fixture.Task=$null}
    Set-WslLifecycleTask -Context $context -Autostart $false -KeepAlive $false
    Assert-Status ($fixture.Removed -ceq ($context.TaskPath+$context.TaskName) -and $null -eq $fixture.Task) 'removal affected an unrelated task or was not verified'
}

Test-StatusCase 'distribution selection preserves Unicode and space names as flat strings' {
    function Get-Command {param($Name,$ErrorAction)[pscustomobject]@{Name=$Name}}
    function Get-WslDistroVersions {[pscustomobject]@{Source='Registry';Known=$false;Distributions=@([pscustomobject]@{Name='中文 Debian';Version=$null},[pscustomobject]@{Name='Debian QA';Version=2})}}
    [string[]]$names=@(Get-WslDistros)
    Assert-Status ($names.Count -eq 2 -and $names[0] -ceq '中文 Debian' -and $names[1] -ceq 'Debian QA' -and $names[0] -is [string]) 'selection names were mangled or nested'
}
Test-StatusCase 'unverified distribution inventory cannot become a menu selection' {
    function Get-Command {param($Name,$ErrorAction)[pscustomobject]@{Name=$Name}}
    function Get-WslDistroVersions {[pscustomobject]@{Source='Unknown';Known=$false;Distributions=@([pscustomobject]@{Name='localized error text'})}}
    $threw=$false
    try{Get-WslDistros}catch{$threw=$true}
    Assert-Status $threw 'unverified output became a selectable distribution'
}
Test-StatusCase 'keep-running upgrades an already running one-shot startup into a new keeper' {
    . Initialize-StatusLifecycleFixture
    $lifecycleFixture.Task=New-StatusLifecycleTask -Context $lifecycleFixture.Context -Autostart $true -KeepAlive $false -State Running
    $result=Set-WslDistroResidency -DistroName 'Debian QA' -KeepAlive $true
    Assert-Status ($result.Success -and $lifecycleFixture.Calls.Contains('Stop') -and $lifecycleFixture.Calls.Contains('Start')) 'running one-shot task was mistaken for a resident keeper'
}
Test-StatusCase 'task and distro running without the exact keeper cannot verify residency' {
    . Initialize-StatusLifecycleFixture
    function Get-WslLifecycleKeeperState {param($Context)[pscustomobject]@{Known=$true;Running=$false}}
    $result=Set-WslDistroResidency -DistroName 'Debian QA' -KeepAlive $true
    Assert-Status (-not $result.Success) 'a transient running task was treated as a keeper'
}
Test-StatusCase 'residency needs two consecutive positive keeper observations' {
    . Initialize-StatusLifecycleFixture
    $observations=[pscustomobject]@{Count=0}
    function Get-WslLifecycleKeeperState {param($Context)$observations.Count++;[pscustomobject]@{Known=$true;Running=$true}}
    $result=Set-WslDistroResidency -DistroName 'Debian QA' -KeepAlive $true
    Assert-Status ($result.Success -and $observations.Count -ge 2) 'a single transient keeper sample passed verification'
}
Test-StatusCase 'unverified CLI inventory cannot generate a lifecycle task context' {
    function Get-WslDistroVersions {[pscustomobject]@{Source='Unknown';Known=$false;Distributions=@([pscustomobject]@{Name='Debian';Known=$false;Source='Command'})}}
    $threw=$false
    try{Get-WslLifecycleContext -DistroName Debian}catch{$threw=$true}
    Assert-Status $threw 'unverified distro row was accepted for task management'
}
Test-StatusCase 'task ownership accepts account-name principal and trigger after SID normalization' {
    $context=New-StatusLifecycleContext
    $task=New-StatusLifecycleTask -Context $context -Autostart $true -KeepAlive $true
    $task.Principal.UserId='FIXTURE\User'
    $task.Triggers[0].UserId='FIXTURE\User'
    function Resolve-WslLifecycleTaskSid {param($UserId)if($UserId -eq 'FIXTURE\User'){$context.Sid}else{$UserId}}
    Assert-Status (Test-WslLifecycleTaskOwnership -Task $task -Context $context) 'task scheduler account normalization made an owned task foreign'
}
Test-StatusCase 'trusted registry names permit running-state checks when unrelated WSL versions are unknown' {
    function Invoke-WslCommand {param($Arguments,$TimeoutMilliseconds)New-StatusCommand -Text "Debian QA`n"}
    function Get-WslDistroVersions {[pscustomobject]@{Source='Registry';Known=$false;Distributions=@([pscustomobject]@{Name='Debian QA';Version=$null;Source='Registry'})}}
    $state=Get-WslDistroRunningState -DistroName 'Debian QA'
    Assert-Status ($state.Known -and $state.Running) 'unknown version prevented a trusted registered-name running check'
}
Write-Host "WSL status regressions: $script:statusTestCount tests, $($script:statusTestFailures.Count) failures."
if ($script:statusTestFailures.Count -gt 0) { throw ($script:statusTestFailures -join "`n") }