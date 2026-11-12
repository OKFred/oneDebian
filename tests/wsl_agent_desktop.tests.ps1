# Desktop-update boundaries only; no live WSL, browser or desktop changes.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. "$repo\components\wsl_common.ps1"
. "$repo\components\wsl_agent.ps1"
$script:desktopCases = 0
$script:desktopFailures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Desktop { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Test-Desktop { param([string]$Name, [scriptblock]$Body)
    $script:desktopCases++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:desktopFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function New-DesktopResult { param([string]$State='DESKTOP_UPDATED', [bool]$Restarted=$true, [int]$Code=0, [string]$Diagnostic='')
    [pscustomobject]@{ Text=(@{state=$State;controls_restarted=$Restarted;reason='fixture owned desktop files updated';error=$Diagnostic}|ConvertTo-Json -Compress);ErrorText='';ExitCode=$Code;IsDecoded=$true }
}
Test-Desktop 'desktop update requires an explicit registered target even with Yes' {
    function Get-WslDistros { @('ai-dev') }
    function Send-WslAgentBundle { throw 'unexpected transfer' }
    foreach ($target in @('', 'missing', '-bad')) {
        $failure=''; try { Invoke-WslAgent -Action DesktopUpdate -DistroName $target -Yes } catch { $failure=$_.Exception.Message }
        Assert-Desktop ($failure -and -not $failure.Contains('unexpected')) 'implicit or unknown target reached transfer'
    }
}
Test-Desktop 'cancellation performs no transfer or service changes' {
    function Get-WslDistros { @('ai-dev') }
    function Read-Host { '' }
    function Send-WslAgentBundle { throw 'unexpected transfer' }
    function Invoke-WslAgentCommand { throw 'unexpected desktop command' }
    function Stop-WslAgentRelay { throw 'unexpected relay stop' }
    function Initialize-WslAgentSystemd { throw 'unexpected restart' }
    Invoke-WslAgent -Action DesktopUpdate -DistroName ai-dev
}
Test-Desktop 'confirmation precedes the selected staged desktop command and preserves diagnostics' {
    $capture=[pscustomobject]@{Events=(New-Object 'System.Collections.Generic.List[string]');Lines=(New-Object 'System.Collections.Generic.List[string]')}
    function Get-WslDistros { @('ai-dev','other') }
    function Read-Host { $capture.Events.Add('confirm'); 'Y' }
    function Write-Host { param($Object,$ForegroundColor) $capture.Lines.Add([string]$Object) }
    function Send-WslAgentBundle { param($Distro) Assert-Desktop ($Distro -ceq 'ai-dev') 'wrong staged target';$capture.Events.Add('stage');'/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Stop-WslAgentRelay { throw 'unexpected relay stop' }
    function Start-WslAgentRelay { throw 'unexpected relay start' }
    function Initialize-WslAgentSystemd { throw 'unexpected desktop/WSL restart' }
    function Initialize-WslAgentSsh { throw 'unexpected SSH setup' }
    function Invoke-WslAgentCommand {
        param($Distro,$Entry,$Command,$Options,$Timeout,[switch]$AllowFailure)
        Assert-Desktop ($Distro -ceq 'ai-dev' -and $Entry -ceq '/var/tmp/onedebian-agent.ABCDef1234/agent.sh') 'target or new payload was lost'
        Assert-Desktop ($Command -ceq 'desktop' -and ($Options -join '|') -ceq '--yes|--json' -and $Timeout -eq 0 -and $AllowFailure) 'desktop protocol was replaced by another operation'
        $capture.Events.Add('desktop'); New-DesktopResult
    }
    Invoke-WslAgent -Action DesktopUpdate -DistroName ai-dev
    Assert-Desktop (($capture.Events -join ',') -ceq 'confirm,stage,desktop') 'desktop update ran before confirmation or repeated'
    $text=$capture.Lines -join ','
    Assert-Desktop ($text.Contains('fixture owned desktop files updated') -and $text.Contains('True')) 'result reason or control restart was hidden'
    Assert-Desktop ($text.Contains('Agent 工作浏览器') -and $text.Contains('保留浏览器页面和构建任务')) 'consent did not explain the intended effect'
}
Test-Desktop 'Yes preserves a successful update without pretending controls restarted' {
    $lines=New-Object 'System.Collections.Generic.List[string]'
    function Get-WslDistros { @('ai-dev') }
    function Read-Host { throw 'unexpected prompt' }
    function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Write-Host { param($Object,$ForegroundColor) $lines.Add([string]$Object) }
    function Invoke-WslAgentCommand { New-DesktopResult -Restarted $false }
    Invoke-WslAgent -Action DesktopUpdate -DistroName ai-dev -Yes
    Assert-Desktop (($lines -join ',').Contains('False')) 'non-restarted controls were reported as restarted'
}
Test-Desktop 'errors malformed output and unverified completion never report success' {
    function Get-WslDistros { @('ai-dev') }
    function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    foreach ($scenario in @('failed','malformed','wrong-state','missing-restart','bad-restart')) {
        function Invoke-WslAgentCommand {
            if ($scenario -eq 'failed') { return New-DesktopResult -State ERROR -Code 1 -Diagnostic 'fixture modified controls' }
            if ($scenario -eq 'wrong-state') { return New-DesktopResult -State READY_GPU }
            if ($scenario -eq 'missing-restart') { return [pscustomobject]@{Text='{"state":"DESKTOP_UPDATED"}';ErrorText='';ExitCode=0;IsDecoded=$true} }
            if ($scenario -eq 'bad-restart') { return [pscustomobject]@{Text='{"state":"DESKTOP_UPDATED","controls_restarted":1}';ErrorText='';ExitCode=0;IsDecoded=$true} }
            return [pscustomobject]@{Text='not-json';ErrorText='fixture desktop protocol';ExitCode=1;IsDecoded=$true}
        }
        $failure='';try { Invoke-WslAgent -Action DesktopUpdate -DistroName ai-dev -Yes } catch { $failure=$_.Exception.Message }
        Assert-Desktop ([bool]$failure) "invalid result was accepted: $scenario"
        if ($scenario -eq 'failed') { Assert-Desktop ($failure.Contains('fixture modified controls')) 'backend diagnostic was hidden' }
        if ($scenario -eq 'malformed') { Assert-Desktop ($failure.Contains('fixture desktop protocol')) 'malformed result hid stderr' }
    }
}
Test-Desktop 'menu fifteen maps to the explicit desktop update action' {
    $capture=[pscustomobject]@{Answers=(New-Object 'System.Collections.Generic.Queue[string]');Commands=0}
    $capture.Answers.Enqueue('15'); $capture.Answers.Enqueue('Y')
    function Read-Host { $capture.Answers.Dequeue() }
    function Get-WslDistros { @('ai-dev') }
    function Select-WslDistro { 'ai-dev' }
    function Write-Host { param($Object,$ForegroundColor) }
    function Send-WslAgentBundle { '/fixture/agent.sh' }
    function Invoke-WslAgentCommand { param($Distro,$Entry,$Command,$Options,$Timeout,[switch]$AllowFailure)
        Assert-Desktop ($Command -ceq 'desktop' -and $Distro -ceq 'ai-dev') 'menu selected the wrong command'
        $capture.Commands++; New-DesktopResult
    }
    Invoke-WslAgent -Action Menu
    Assert-Desktop ($capture.Commands -eq 1 -and $capture.Answers.Count -eq 0) 'menu did not confirm the selected desktop update exactly once'
}
Test-Desktop 'native desktop menu requires consent and propagates helper failure' {
    $git=Get-Command git.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1
    $bash=Join-Path (Split-Path -Parent $git.Source) '..\bin\bash.exe'
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try {
        [IO.File]::WriteAllText((Join-Path $fixture 'menu.sh'),[IO.File]::ReadAllText("$repo\components\the_agent_environment.sh").Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        $source=@'
set -euo pipefail
source "$1"
trace=$2
scenario=$3
MENU_DIR=/fixture
bash() { printf '%s\n' "$*" >> "$trace"; [[ "$*" == '/fixture/agent.sh desktop --yes' && $scenario != failure ]]; }
answer=Y
[[ $scenario != cancelled ]] || answer=N
set +e
printf '11\n%s\n' "$answer" | the_agent_environment
result=$?
set -e
if [[ $scenario == failure ]]; then [[ $result != 0 ]]; else [[ $result == 0 ]]; fi
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'fixture.sh'),$source.Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        foreach ($scenario in @('confirmed','cancelled','failure')) {
            $trace=Join-Path $fixture ($scenario+'.txt')
            $result=Invoke-WslCommand -FilePath $bash -Arguments @('--noprofile','--norc',(Join-Path $fixture 'fixture.sh'),(Join-Path $fixture 'menu.sh'),$trace,$scenario) -TimeoutMilliseconds 15000
            Assert-Desktop ($result.ExitCode -eq 0) "native desktop fixture failed: $scenario $($result.ErrorText)"
            if ($scenario -eq 'cancelled') { Assert-Desktop (-not (Test-Path -LiteralPath $trace)) 'cancellation invoked desktop update' }
            else { Assert-Desktop ([IO.File]::ReadAllText($trace).Trim() -ceq '/fixture/agent.sh desktop --yes') 'wrong native command or duplicate invocation' }
        }
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Write-Host "WSL Agent desktop regressions: $script:desktopCases tests, $($script:desktopFailures.Count) failures."
if ($script:desktopFailures.Count) { throw ($script:desktopFailures -join "`n") }
