# Offline Install/retry controller checks. Never enters an actual WSL instance.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. "$repo\components\wsl_common.ps1"
. "$repo\components\wsl_agent.ps1"
$script:installCount=0
$script:installFailures=New-Object 'System.Collections.Generic.List[string]'
function Assert-Install { param([bool]$Value,[string]$Message) if(-not $Value){throw $Message} }
function Test-Install { param([string]$Name,[scriptblock]$Body)
    $script:installCount++
    try { & $Body; Write-Host "PASS $Name" } catch { $script:installFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function New-InstallResult { param([string]$Text='') [pscustomobject]@{Text=$Text;ErrorText='';ExitCode=0;IsDecoded=$true} }
function Invoke-InstallFixture {
    param($Preparation,[hashtable]$Extra=@{},[string[]]$Answers=@())
    $capture=[pscustomobject]@{Events=(New-Object 'System.Collections.Generic.List[string]');Options=@();Access=@{};Lines=(New-Object 'System.Collections.Generic.List[string]');Answers=(New-Object 'System.Collections.Generic.Queue[string]')}
    foreach($answer in $Answers){$capture.Answers.Enqueue($answer)}
    function Get-WslDistros { @('ai-dev','original-a','original-b','original-c','original-d') }
    function Get-WslDistroVersions { [pscustomobject]@{Distributions=@([pscustomobject]@{Name='ai-dev';Version=2})} }
    function Get-WslAgentPreparation { $Preparation }
    function Write-Host { param($Object,$ForegroundColor) $capture.Lines.Add([string]$Object) }
    function Read-Host { param($Prompt) $capture.Events.Add('confirm'); if(-not $capture.Answers.Count){throw "unexpected prompt: $Prompt"}; $capture.Answers.Dequeue() }
    function Send-WslAgentBundle { param($Distro) Assert-Install ($Distro -ceq 'ai-dev') 'wrong stage target'; $capture.Events.Add('stage'); '/fresh/agent.sh' }
    function Confirm-WslAgentResources { $capture.Events.Add('resources'); $false }
    function Confirm-WslAgentPreparedSystemd { param($Distro) Assert-Install ($Distro -ceq 'ai-dev') 'wrong systemd target'; $capture.Events.Add('systemd') }
    function Initialize-WslAgentSystemd { $capture.Events.Add('prepare') }
    function Invoke-WslCommand { throw 'unexpected native WSL change' }
    function Invoke-WslAgentShell { throw 'unexpected direct WSL mutation' }
    function Invoke-WslAgentCommand { param($Distro,$Entry,$Command,$Options)
        Assert-Install ($Distro -ceq 'ai-dev' -and $Entry -ceq '/fresh/agent.sh' -and $Command -ceq 'install') 'did not use current Install payload'
        $capture.Events.Add('install'); $capture.Options=@($Options); New-InstallResult
    }
    function Wait-WslAgentInstall { $capture.Events.Add('wait'); [pscustomobject]@{state='READY_GPU'} }
    function Complete-WslAgentAccess { param($Distro,$SshPort) $capture.Events.Add('access'); $capture.Access=@{}; foreach($key in $PSBoundParameters.Keys){$capture.Access[$key]=$PSBoundParameters[$key]} }
    $invoke=@{Action='Install';DistroName='ai-dev';Yes=$true}
    foreach($key in $Extra.Keys){$invoke[$key]=$Extra[$key]}
    Invoke-WslAgent @invoke
    return $capture
}
function New-PreparedInstall {
    param([string]$State='READY_GPU',[bool]$Completed=$true)
    [pscustomobject]@{prepared=$true;agent_owned=$true;agent_exists=$true;completed=$Completed;config=[pscustomobject]@{viewer_port=26080;mcp_port=28931;cdp_port=29222;gpu_backend='d3d12'};state=[pscustomobject]@{state=$State;mirror='ustc';precheck_passed=$true;allow_low_resources=$false}}
}
Test-Install 'READY refreshes current payload but preserves ports mirror and healthy access defaults' {
    $capture=Invoke-InstallFixture (New-PreparedInstall)
    Assert-Install (($capture.Events -join ',') -ceq 'stage,systemd,install,wait,access') 'READY repeated preparation or skipped readiness'
    Assert-Install (($capture.Options -join ',') -ceq '--yes,--json') 'READY overrode saved ports or current source'
    Assert-Install (-not $capture.Access.ContainsKey('SshPort')) 'default SSH port overrode a custom registered port'
    Assert-Install (($capture.Lines -join ',').Contains('APT: keep | noVNC 26080 / MCP 28931 / CDP 29222')) 'summary hid preserved config'
}
Test-Install 'interrupted initial job inherits confirmed source low-resource consent and skips firstboot' {
    $preparation=New-PreparedInstall -State INTERRUPTED -Completed $false
    $preparation.state.allow_low_resources=$true
    $capture=Invoke-InstallFixture $preparation
    Assert-Install (($capture.Events -join ',') -ceq 'stage,systemd,install,wait,access') 'interrupted job repeated setup'
    Assert-Install ($capture.Options -contains '--allow-low-resources' -and $capture.Options -notcontains '--mirror') 'prior consent or source inheritance lost'
    Assert-Install (($capture.Lines -join ',').Contains('APT: ustc')) 'interrupted confirmed source was hidden'
}
Test-Install 'active prepared install stages but does not reconfigure or terminate other distros' {
    $capture=Invoke-InstallFixture (New-PreparedInstall -State PACKAGES -Completed $false) @{NoWait=$true}
    Assert-Install (($capture.Events -join ',') -ceq 'stage,systemd,install') 'active task ran extra setup/access'
    Assert-Install (-not ($capture.Lines -join ',').Contains('Resume')) 'NoWait still directed to the removed flow'
}
Test-Install 'explicit source and SSH override remain available without overwriting browser ports' {
    $capture=Invoke-InstallFixture (New-PreparedInstall) @{Mirror='tuna';SshPort=2223;ViewerPort=16080}
    Assert-Install (($capture.Options -join ',') -ceq '--yes,--json,--mirror,tuna') 'explicit mirror lost or configured port overwritten'
    Assert-Install ($capture.Access.SshPort -eq 2223) 'explicit SSH override was ignored'
}
Test-Install 'legacy Resume is the current Install workflow including a fresh bundle' {
    $capture=Invoke-InstallFixture (New-PreparedInstall) @{Action='Resume'}
    Assert-Install (($capture.Events -join ',') -ceq 'stage,systemd,install,wait,access') 'legacy alias retained a separate code path'
}
Test-Install 'an unowned existing account requires separate consent before bundle changes' {
    $preparation=[pscustomobject]@{prepared=$false;agent_owned=$false;agent_exists=$true;completed=$false;config=$null;state=$null}
    $failed=$false
    try { Invoke-InstallFixture $preparation } catch { $failed=$_.Exception.Message.Contains('-AdoptUser') }
    Assert-Install $failed '-Yes implicitly adopted an unrelated user'
    $capture=Invoke-InstallFixture $preparation @{AdoptUser=$true}
    Assert-Install (($capture.Events -join ',') -ceq 'stage,resources,prepare,install,wait,access') 'first install skipped normal preparation'
    Assert-Install ($capture.Options -contains '--adopt-user' -and $capture.Options -notcontains '--mirror') 'adoption or default keep-source behavior was lost'
}
Test-Install 'existing installation asks once before staging current code and owned user is not readopted' {
    $capture=Invoke-InstallFixture (New-PreparedInstall) @{Yes=$false} @('Y')
    Assert-Install (($capture.Events -join ',') -ceq 'confirm,stage,systemd,install,wait,access') 'confirmation did not precede changes or owned user repeated adoption'
    Assert-Install ($capture.Options -notcontains '--adopt-user') 'owned account was unnecessarily adopted'
}
Test-Install 'read-only preflight rejects malformed metadata and invalid saved ports' {
    foreach($json in @('not-json','{"prepared":true}', '{"prepared":true,"agent_owned":true,"agent_exists":true,"completed":true,"state":{},"config":{"viewer_port":22,"mcp_port":18931,"cdp_port":19222}}')){
        function Invoke-WslAgentShell { param($Distro,$Script) Assert-Install ($Script -notmatch 'mkdir|useradd|systemctl|tee|>>') 'preflight contains mutation'; New-InstallResult $json }
        $failed=$false;try { Get-WslAgentPreparation -Distro ai-dev } catch { $failed=$_.Exception.Message.Contains('metadata is invalid') }
        Assert-Install $failed 'untrusted metadata was accepted as fresh install'
    }
}
Test-Install 'prepared systemd checks never repeat firstboot network or global shutdown' {
    $capture=[pscustomobject]@{Reads=0;Stops=0;Runtime='systemd'}
    function Invoke-WslAgentShell {
        param($Distro,$Script)
        Assert-Install ($Distro -ceq 'ai-dev' -and $Script -ceq 'cat /proc/1/comm') 'systemd check changed settings or queried another instance'
        $capture.Reads++; New-InstallResult $capture.Runtime
    }
    function Invoke-WslCommand {
        param($Arguments,$TimeoutMilliseconds)
        Assert-Install (($Arguments -join ',') -ceq '--terminate,ai-dev') 'restart touched other instances or used global shutdown'
        $capture.Stops++; $capture.Runtime='systemd'; New-InstallResult
    }
    function Invoke-WslFirstBootSetup { throw 'unexpected firstboot' }
    function Get-WslNetworkState { throw 'unexpected network preparation' }
    function Invoke-WslAgentCommand { throw 'unexpected prepare-wsl' }
    function Read-Host { 'N' }
    Confirm-WslAgentPreparedSystemd -Distro ai-dev
    Assert-Install ($capture.Reads -eq 1 -and $capture.Stops -eq 0) 'healthy systemd restarted'
    $capture.Runtime='init'
    $failed=$false; try { Confirm-WslAgentPreparedSystemd -Distro ai-dev } catch { $failed=$_.Exception.Message.Contains('Restart deferred') }
    Assert-Install ($failed -and $capture.Stops -eq 0) 'declined restart made changes'
    Confirm-WslAgentPreparedSystemd -Distro ai-dev -RestartSelected
    Assert-Install ($capture.Stops -eq 1 -and $capture.Runtime -ceq 'systemd') 'explicit targeted restart did not verify PID1'
}
Test-Install 'preflight shell reads fresh prepared interrupted and cleaned metadata without altering files' {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    $native=(Get-Command Invoke-WslCommand).ScriptBlock
    try {
        $state=Join-Path $fixture 'state'; $config=Join-Path $fixture 'etc'
        $null=New-Item -ItemType Directory -Path $state,$config
        function Invoke-WslAgentShell {
            param($Distro,$Script)
            $guestState=$state.Replace('\','/'); $guestConfig=$config.Replace('\','/')
            $query="id() { return 0; }`n"+$Script.Replace('/var/lib/onedebian-agent',$guestState).Replace('/etc/onedebian-agent',$guestConfig)
            $result=& $native -FilePath 'C:\Program Files\Git\bin\bash.exe' -Arguments @('--noprofile','--norc','-c',$query) -TimeoutMilliseconds 15000
            if($result.ExitCode -ne 0){throw $result.ErrorText}
            $result
        }
        $fresh=Get-WslAgentPreparation -Distro ai-dev
        Assert-Install (-not $fresh.prepared -and -not $fresh.agent_owned -and $fresh.agent_exists) 'fresh metadata classification failed'
        [IO.File]::WriteAllText((Join-Path $state '.owner'),'oneDebian-agent-v1')
        [IO.File]::WriteAllText((Join-Path $state 'user-owned'),"agent`n")
        [IO.File]::WriteAllText((Join-Path $config 'config.json'),'{"viewer_port":26080,"mcp_port":28931,"cdp_port":29222}')
        [IO.File]::WriteAllText((Join-Path $state 'state.json'),'{"state":"INTERRUPTED","mirror":"ustc","precheck_passed":true}')
        $interrupted=Get-WslAgentPreparation -Distro ai-dev
        Assert-Install ($interrupted.prepared -and -not $interrupted.completed -and $interrupted.config.viewer_port -eq 26080 -and $interrupted.state.mirror -ceq 'ustc') 'interrupted configuration lost'
        [IO.File]::WriteAllText((Join-Path $state 'installed.json'),'{}')
        $before=Get-ChildItem -LiteralPath $fixture -Recurse -File|Get-FileHash|ForEach-Object { $_.Hash+':'+$_.Path }
        $ready=Get-WslAgentPreparation -Distro ai-dev
        $after=Get-ChildItem -LiteralPath $fixture -Recurse -File|Get-FileHash|ForEach-Object { $_.Hash+':'+$_.Path }
        Assert-Install ($ready.prepared -and $ready.completed -and ($before -join ',') -ceq ($after -join ',')) 'preflight wrote installation metadata'
        [IO.File]::WriteAllText((Join-Path $state 'cleanup-completed.json'),'{}')
        $cleaned=Get-WslAgentPreparation -Distro ai-dev
        Assert-Install (-not $cleaned.prepared -and $cleaned.agent_owned -and $null -eq $cleaned.config) 'full cleanup incorrectly skipped preparation or repeated adoption'
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Test-Install 'native original install and old retry numbers both use Install with current entry' {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try {
        $source=[IO.File]::ReadAllText("$repo\components\the_agent_environment.sh").Replace('/var/lib/onedebian-agent', './state').Replace("`r`n","`n")
        [IO.File]::WriteAllText((Join-Path $fixture 'menu.sh'),$source,(New-Object Text.UTF8Encoding($false)))
        $driver=@'
set -euo pipefail
cd "$1"
source menu.sh
MENU_DIR=/current
choice=$2
mode=$3
command() { if [[ $* == '-v python3' ]]; then return 0; fi; builtin command "$@"; }
mkdir -p state
if [[ $mode == prepared ]]; then printf oneDebian-agent-v1 > state/.owner; printf 'agent\n' > state/user-owned; fi
the_agent_resources_prechecked() { [[ $mode == prepared ]]; }
id() { return 1; }
bash() { printf '%s\n' "$*" >> trace; [[ $2 != plan ]] || printf 'warnings: fixture disk has less than 32GiB free\n'; }
if [[ $mode == prepared ]]; then printf '%s\nY\n' "$choice" | the_agent_environment
else printf '%s\nkeep\n\n\n\nY\nY\n' "$choice" | the_agent_environment; fi
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'fixture.sh'),$driver.Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        foreach($choice in @('1','2')){ foreach($mode in @('fresh','prepared')){
            $run=Join-Path $fixture ($choice+$mode); $null=New-Item -ItemType Directory -Path $run
            Copy-Item -LiteralPath (Join-Path $fixture 'menu.sh') -Destination $run
            $result=Invoke-WslCommand -FilePath 'C:\Program Files\Git\bin\bash.exe' -Arguments @('--noprofile','--norc',(Join-Path $fixture 'fixture.sh'),$run,$choice,$mode) -TimeoutMilliseconds 15000
            Assert-Install ($result.ExitCode -eq 0) "native fixture failed: $choice $mode $($result.ErrorText)"
            $trace=[IO.File]::ReadAllText((Join-Path $run 'trace'))
            Assert-Install ($trace.Contains('/current/agent.sh install --wait') -and -not $trace.Contains(' resume ')) 'native choice kept separate Resume'
            if($mode -eq 'prepared'){Assert-Install ($trace.Trim() -ceq "/current/agent.sh plan`n/current/agent.sh install --wait") 'native prepared environment overrode config or repeated low-space consent'}
        } }
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Test-Install 'native prepare-wsl without initial PRECHECK still offers lower-resource consent' {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try {
        $source=[IO.File]::ReadAllText("$repo\components\the_agent_environment.sh").Replace('/var/lib/onedebian-agent','./state').Replace("`r`n","`n")
        [IO.File]::WriteAllText((Join-Path $fixture 'menu.sh'),$source,(New-Object Text.UTF8Encoding($false)))
        $driver=@'
set -euo pipefail
cd "$1"
source menu.sh
MENU_DIR=/current
command() { if [[ $* == '-v python3' ]]; then return 0; fi; builtin command "$@"; }
mkdir state
printf oneDebian-agent-v1 > state/.owner
printf 'agent\n' > state/user-owned
the_agent_resources_prechecked() { return 1; }
id() { return 1; }
bash() { printf '%s\n' "$*" >> trace; [[ $2 != plan ]] || printf 'warnings: fixture low free space\n'; }
printf '1\nY\nY\n' | the_agent_environment
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'fixture.sh'),$driver.Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        $result=Invoke-WslCommand -FilePath 'C:\Program Files\Git\bin\bash.exe' -Arguments @('--noprofile','--norc',(Join-Path $fixture 'fixture.sh'),$fixture) -TimeoutMilliseconds 15000
        Assert-Install ($result.ExitCode -eq 0) "native prepare-only fixture failed: $($result.ErrorText)"
        $trace=[IO.File]::ReadAllText((Join-Path $fixture 'trace')).Trim()
        Assert-Install ($trace -ceq "/current/agent.sh plan`n/current/agent.sh install --wait --allow-low-resources") 'prepared user skipped first resource consent or reset saved configuration'
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Test-Install 'native completed resource PRECHECK avoids another free-space consent' {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try {
        $source=[IO.File]::ReadAllText("$repo\components\the_agent_environment.sh").Replace('/var/lib/onedebian-agent','./state').Replace("`r`n","`n")
        [IO.File]::WriteAllText((Join-Path $fixture 'menu.sh'),$source,(New-Object Text.UTF8Encoding($false)))
        $driver=@'
set -euo pipefail
cd "$1"
source menu.sh
MENU_DIR=/current
command() { if [[ $* == '-v python3' ]]; then return 0; fi; builtin command "$@"; }
mkdir state
printf oneDebian-agent-v1 > state/.owner
printf 'agent\n' > state/user-owned
the_agent_resources_prechecked() { return 0; }
id() { return 1; }
bash() { printf '%s\n' "$*" >> trace; [[ $2 != plan ]] || printf 'warnings: fixture low free space after installation\n'; }
printf '1\nY\n' | the_agent_environment
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'fixture.sh'),$driver.Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        $result=Invoke-WslCommand -FilePath 'C:\Program Files\Git\bin\bash.exe' -Arguments @('--noprofile','--norc',(Join-Path $fixture 'fixture.sh'),$fixture) -TimeoutMilliseconds 15000
        Assert-Install ($result.ExitCode -eq 0) "native completed fixture failed: $($result.ErrorText)"
        $trace=[IO.File]::ReadAllText((Join-Path $fixture 'trace')).Trim()
        Assert-Install ($trace -ceq "/current/agent.sh plan`n/current/agent.sh install --wait") 'READY environment repeated free-space consent or added an override'
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Test-Install 'native missing Python confirms bootstrap without invoking Python helper or read-only plan' {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try {
        $source=[IO.File]::ReadAllText("$repo\components\the_agent_environment.sh").Replace('/var/lib/onedebian-agent','./state').Replace("`r`n","`n")
        [IO.File]::WriteAllText((Join-Path $fixture 'menu.sh'),$source,(New-Object Text.UTF8Encoding($false)))
        $driver=@'
set -euo pipefail
cd "$1"
source menu.sh
MENU_DIR=/current
mode=$2
mkdir state
if [[ $mode == prepared* ]]; then printf oneDebian-agent-v1 > state/.owner; printf 'agent\n' > state/user-owned; fi
command() { if [[ $* == '-v python3' ]]; then return 1; fi; builtin command "$@"; }
python3() { printf 'unexpected Python execution\n' >&2; return 97; }
the_agent_resources_prechecked() { printf 'unexpected Python helper\n' >&2; return 98; }
id() { return 1; }
getconf() { printf '4\n'; }
awk() { if [[ $* == *MemTotal* ]]; then printf '8388608\n'; else printf '1048576\n'; fi; }
df() { printf 'fixture input to mocked awk\n'; }
bash() { [[ $2 != plan ]] || { printf 'unexpected read-only plan\n' >&2; return 99; }; printf '%s\n' "$*" >> trace; }
if [[ $mode == fresh ]]; then printf '1\nkeep\n\n\n\nY\nY\n' | the_agent_environment
elif [[ $mode == prepared-decline ]]; then printf '1\nN\n' | the_agent_environment
else printf '1\nY\nY\n' | the_agent_environment; fi
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'fixture.sh'),$driver.Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        foreach($mode in @('fresh','prepared','prepared-decline')){
            $run=Join-Path $fixture $mode; $null=New-Item -ItemType Directory -Path $run
            Copy-Item -LiteralPath (Join-Path $fixture 'menu.sh') -Destination $run
            $result=Invoke-WslCommand -FilePath 'C:\Program Files\Git\bin\bash.exe' -Arguments @('--noprofile','--norc',(Join-Path $fixture 'fixture.sh'),$run,$mode) -TimeoutMilliseconds 15000
            Assert-Install ($result.ExitCode -eq 0 -and $result.Text.Contains('Python bootstrap after confirmation')) "native missing-Python fixture failed: $mode $($result.ErrorText)"
            $tracePath=Join-Path $run 'trace'
            if($mode -eq 'prepared-decline'){Assert-Install (-not (Test-Path -LiteralPath $tracePath)) 'declined resource consent still started bootstrap'}
            else {
                $trace=[IO.File]::ReadAllText($tracePath).Trim()
                Assert-Install ($trace.StartsWith('/current/agent.sh install --wait') -and $trace.EndsWith('--allow-low-resources') -and -not $trace.Contains(' plan')) 'missing Python blocked install or bypassed low-resource consent'
                if($mode -eq 'prepared'){Assert-Install (-not $trace.Contains('--mirror') -and -not $trace.Contains('--viewer-port')) 'prepared bootstrap replaced existing config'}
            }
        }
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Write-Host "WSL Agent Install regressions: $script:installCount tests, $($script:installFailures.Count) failures."
if($script:installFailures.Count){throw ($script:installFailures -join "`n")}
