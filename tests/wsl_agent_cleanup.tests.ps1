# Mock-only cleanup boundaries; never enters or modifies a WSL instance.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. "$repo\components\wsl_common.ps1"
. "$repo\components\wsl_agent.ps1"
$script:cleanupCases = 0
$script:cleanupFailures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Cleanup { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Test-Cleanup { param([string]$Name, [scriptblock]$Body)
    $script:cleanupCases++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:cleanupFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function New-CleanupResult { param($Value, [int]$Code = 0)
    [pscustomobject]@{ Text = ($Value | ConvertTo-Json -Depth 12 -Compress); ErrorText = ''; ExitCode = $Code; IsDecoded = $true }
}
function New-CleanupPlan {
    [pscustomobject]@{
        state='CLEANUP_PLAN'; plan_id=('a'*64); active=$false; blockers=@(); warnings=@()
        remove_files=@('/opt/onedebian-agent/runtime.py'); remove_trees=@(); restore_files=@('/etc/wsl.conf'); settings=@()
        packages=[pscustomobject]@{remove=@('fixture-package');retained=@()}; retained=@('workspaces/profile/keyring/auth')
    }
}

Test-Cleanup 'cleanup actions are explicit and never fall through to instance creation' {
    $calls = New-Object 'System.Collections.Generic.List[string]'
    function Get-WslDistros { @('debian-wsl-main') }
    function Invoke-WslAgentCleanup { param($Distro,[switch]$PlanOnly) $calls.Add("${Distro}:$PlanOnly") }
    function Send-WslAgentBundle { throw 'unexpected bundle/create' }
    Invoke-WslAgent -Action CleanupPlan -DistroName debian-wsl-main
    Invoke-WslAgent -Action Cleanup -DistroName debian-wsl-main
    Assert-Cleanup (($calls -join ',') -ceq 'debian-wsl-main:True,debian-wsl-main:False') 'cleanup did not target the explicit instance'
    $failed=$false
    try { Invoke-WslAgent -Action Cleanup -DistroName missing } catch { $failed=$_.Exception.Message.Contains('not registered') }
    Assert-Cleanup ($failed -and $calls.Count -eq 2) 'unregistered target reached cleanup'
}
Test-Cleanup 'plan uses staged repository code and does not stop forwarding or alter live payload' {
    $events = New-Object 'System.Collections.Generic.List[string]'
    function Send-WslAgentBundle { param($Distro) $events.Add("stage:$Distro"); '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Invoke-WslAgentCommand {
        param($Distro,$Entry,$Command,$Options)
        Assert-Cleanup ($Distro -ceq 'debian-wsl-main' -and $Entry -ceq '/var/tmp/onedebian-agent.ABCDef1234/agent.sh') 'plan used old live components or another target'
        Assert-Cleanup ($Command -ceq 'cleanup-plan' -and ($Options -join ',') -ceq '--json') 'plan invoked mutation'
        $events.Add('plan'); New-CleanupResult (New-CleanupPlan)
    }
    function Write-Host { param($Object,$ForegroundColor) }
    function Read-Host { throw 'plan prompted for mutation' }
    function Stop-WslAgentRelay { throw 'plan stopped forwarding' }
    Invoke-WslAgentCleanup -Distro debian-wsl-main -PlanOnly
    Assert-Cleanup (($events -join ',') -ceq 'stage:debian-wsl-main,plan') 'plan did extra work'
}
Test-Cleanup 'active blocked malformed or failed plans cannot stop forwarding or apply changes' {
    foreach($case in @('active','blocker','invalid-id','wrong-state','bad-json','exit-failure')) {
        $plan=New-CleanupPlan
        switch($case) {
            active { $plan.active=$true }
            blocker { $plan.blockers=@('installation active') }
            invalid-id { $plan.plan_id='--unsafe' }
            wrong-state { $plan.state='READY_SOFTWARE' }
        }
        function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
        function Invoke-WslAgentCommand {
            param($Command)
            Assert-Cleanup ($Command -ceq 'cleanup-plan') 'invalid plan reached apply'
            if($case -eq 'bad-json'){return [pscustomobject]@{Text='not-json';ErrorText='fixture';ExitCode=0}}
            New-CleanupResult $plan $(if($case -eq 'exit-failure'){1}else{0})
        }
        function Write-Host { param($Object,$ForegroundColor) }
        function Stop-WslAgentRelay { throw 'invalid plan stopped forwarding' }
        function Read-Host { throw 'invalid plan requested confirmation' }
        $failure=''
        try { Invoke-WslAgentCleanup -Distro debian-wsl-main } catch { $failure=$_.Exception.Message }
        Assert-Cleanup ($failure -match 'Blocked|Invalid plan' -and $failure -notmatch 'stopped forwarding|requested confirmation|reached apply') "unsafe plan accepted: $case"
    }
}
Test-Cleanup 'Yes switch and a bare yes cannot replace exact target confirmation' {
    $events=New-Object 'System.Collections.Generic.List[string]'
    $answers=[pscustomobject]@{Index=0}
    function Get-WslDistros { @('debian-wsl-main') }
    function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Invoke-WslAgentCommand { param($Command) $events.Add($Command); New-CleanupResult (New-CleanupPlan) }
    function Write-Host { param($Object,$ForegroundColor) }
    function Read-Host { $answers.Index++; if($answers.Index -eq 1){'N'}else{'Y'} }
    function Stop-WslAgentRelay { throw 'bare yes stopped forwarding' }
    Invoke-WslAgent -Action Cleanup -DistroName debian-wsl-main -Yes
    Assert-Cleanup (($events -join ',') -ceq 'cleanup-plan' -and $answers.Index -eq 2) 'Yes bypassed target confirmation'
}
Test-Cleanup 'confirmed cleanup binds the same staged plan and stops only its relay before apply' {
    $events=New-Object 'System.Collections.Generic.List[string]'
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $answers=[pscustomobject]@{Index=0}
    function Send-WslAgentBundle { param($Distro) $events.Add("stage:$Distro"); '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Invoke-WslAgentCommand {
        param($Distro,$Entry,$Command,$Options)
        Assert-Cleanup ($Distro -ceq 'debian-wsl-main' -and $Entry -ceq '/var/tmp/onedebian-agent.ABCDef1234/agent.sh') 'apply changed target or stage'
        $events.Add($Command)
        if($Command -eq 'cleanup-plan'){return New-CleanupResult (New-CleanupPlan)}
        Assert-Cleanup (($Options -join '|') -ceq ('--yes|--plan-id|'+('a'*64)+'|--json')) 'apply lost approved plan identity'
        New-CleanupResult ([pscustomobject]@{state='CLEANED';retained=@('projects');warnings=@();log='/var/lib/onedebian-agent/cleanup.log'})
    }
    function Write-Host { param($Object,$ForegroundColor) $lines.Add([string]$Object) }
    function Read-Host { $answers.Index++; if($answers.Index -eq 1){'N'}else{'UNDO debian-wsl-main'} }
    function Stop-WslAgentRelay { param($Distro) Assert-Cleanup ($Distro -ceq 'debian-wsl-main') 'wrong relay stopped'; $events.Add('relay-stop') }
    Invoke-WslAgentCleanup -Distro debian-wsl-main
    Assert-Cleanup (($events -join ',') -ceq 'stage:debian-wsl-main,cleanup-plan,relay-stop,cleanup') 'apply ran before approval or stop'
    Assert-Cleanup (($lines -join ',').Contains('/var/lib/onedebian-agent/cleanup.log')) 'successful cleanup hid its log path'
}
Test-Cleanup 'partial results stay partial and apply failures preserve their diagnostics' {
    foreach($resultState in @('CLEANED_PARTIAL','ERROR')) {
        $capture=[pscustomobject]@{Read=0;Lines=(New-Object 'System.Collections.Generic.List[string]')}
        function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
        function Invoke-WslAgentCommand {
            param($Command)
            if($Command -eq 'cleanup-plan'){return New-CleanupResult (New-CleanupPlan)}
            New-CleanupResult ([pscustomobject]@{state=$resultState;retained=@('modified fnm');warnings=@();error='fixture stale plan';log='/var/lib/onedebian-agent/cleanup.log'}) $(if($resultState -eq 'ERROR'){1}else{0})
        }
        function Write-Host {param($Object,$ForegroundColor)$capture.Lines.Add([string]$Object)}
        function Read-Host {$capture.Read++;if($capture.Read-eq1){'N'}else{'UNDO debian-wsl-main'}}
        function Stop-WslAgentRelay { }
        $failure=''
        try {Invoke-WslAgentCleanup -Distro debian-wsl-main}catch{$failure=$_.Exception.Message}
        Assert-Cleanup (($capture.Lines -join ',').Contains('/var/lib/onedebian-agent/cleanup.log')) 'partial or failed cleanup hid its log path'
        if($resultState -eq 'ERROR'){Assert-Cleanup ($failure.Contains('fixture stale plan')) 'apply diagnostic was hidden'}
        else{Assert-Cleanup (-not$failure -and ($capture.Lines -join ',').Contains('Partial')) 'partial cleanup was reported as complete'}
    }
}
Test-Cleanup 'undo capture precedes firstboot and network mutation' {
    $events=New-Object 'System.Collections.Generic.List[string]'
    function Invoke-WslAgentCommand {param($Command)$events.Add($Command);New-CleanupResult @{} }
    function Invoke-WslAgentShell {New-CleanupResult 'init'}
    function Invoke-WslFirstBootSetup {$events.Add('firstboot')}
    function Get-WslNetworkState {$events.Add('network');[pscustomobject]@{Known=$false}}
    $failed=$false
    try{Initialize-WslAgentSystemd -Distro debian-wsl-main -Entry /source/agent.sh -RestartSelected}catch{$failed=$_.Exception.Message.Contains('Cannot verify WSL network')}
    Assert-Cleanup ($failed -and ($events -join ',') -ceq 'prepare-undo,firstboot,network') 'baseline happened after a mutation'
}
Test-Cleanup 'native menu binds the displayed plan and requires its explicit undo token' {
    $git = Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $bash = Join-Path (Split-Path -Parent $git.Source) '..\bin\bash.exe'
    Assert-Cleanup (Test-Path -LiteralPath $bash) 'Git Bash required for isolated native-menu check'
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixture
    try {
        $source = [IO.File]::ReadAllText("$repo\components\the_agent_environment.sh").Replace("`r`n","`n")
        [IO.File]::WriteAllText((Join-Path $fixture 'menu.sh'),$source,(New-Object Text.UTF8Encoding($false)))
        $script = @'
set -euo pipefail
source "$1"
trace=$2
scenario=$3
MENU_DIR=/fixture
expected_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bash() {
  printf '%s\n' "$*" >> "$trace"
  case "$2" in
    cleanup-plan)
      printf 'Retain projects\nplan_id: %s\n' "$expected_id"
      [[ $scenario != blocked ]]
      ;;
    cleanup)
      [[ "$*" == "/fixture/agent.sh cleanup --yes --plan-id $expected_id" ]]
      ;;
    *) return 9 ;;
  esac
}
answer=UNDO
[[ $scenario != cancelled ]] || answer=Y
set +e
printf '7\n%s\n' "$answer" | the_agent_environment
result=$?
set -e
if [[ $scenario == blocked ]]; then [[ $result == 1 ]]; else [[ $result == 0 ]]; fi
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'fixture.sh'),$script.Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        foreach($scenario in @('confirmed','cancelled','blocked')) {
            $trace=Join-Path $fixture ($scenario+'.txt')
            $result=Invoke-WslCommand -FilePath $bash -Arguments @('--noprofile','--norc',(Join-Path $fixture 'fixture.sh'),(Join-Path $fixture 'menu.sh'),$trace,$scenario) -TimeoutMilliseconds 15000
            Assert-Cleanup ($result.ExitCode -eq 0) "native menu fixture failed: $scenario $($result.ErrorText)"
            $lines=@([IO.File]::ReadAllLines($trace))
            Assert-Cleanup ($lines[0] -ceq '/fixture/agent.sh cleanup-plan') 'native menu did not inspect before mutation'
            Assert-Cleanup ($lines.Count -eq $(if($scenario -eq 'confirmed'){2}else{1})) 'native cancellation/blocking applied changes'
            if($scenario -eq 'confirmed'){Assert-Cleanup ($lines[1] -ceq ('/fixture/agent.sh cleanup --yes --plan-id '+('a'*64))) 'native apply changed the approved plan'}
        }
    } finally { Remove-WslAgentBundle -Root $fixture }
}

Write-Host "WSL Agent cleanup regressions: $script:cleanupCases tests, $($script:cleanupFailures.Count) failures."
if($script:cleanupFailures.Count){throw ($script:cleanupFailures -join "`n")}
