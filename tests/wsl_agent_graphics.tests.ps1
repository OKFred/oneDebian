# Graphics menu boundaries only; never modifies or starts a WSL instance.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. "$repo\components\wsl_common.ps1"
. "$repo\components\wsl_agent.ps1"
$script:graphicsCases = 0
$script:graphicsFailures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Graphics { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Test-Graphics { param([string]$Name,[scriptblock]$Body)
    $script:graphicsCases++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:graphicsFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function New-GraphicsResult { param([string]$State='READY_GPU',[string]$Backend='d3d12',[int]$Code=0,[string]$Reason='native EGL and WebGL draw passed',[string]$Diagnostic='')
    [pscustomobject]@{Text=([pscustomobject]@{state=$State;backend=$Backend;reason=$Reason;error=$Diagnostic;log='/var/lib/onedebian-agent/gpu.log'}|ConvertTo-Json -Compress);ErrorText='';ExitCode=$Code;IsDecoded=$true}
}

Test-Graphics 'graphics requires an explicit registered target even with Yes' {
    function Get-WslDistros { @('ai-dev') }
    function Send-WslAgentBundle { throw 'unexpected transfer' }
    foreach($name in @('','missing','-bad')) {
        $failure=''
        try { Invoke-WslAgent -Action Graphics -DistroName $name -Yes } catch { $failure=$_.Exception.Message }
        Assert-Graphics ($failure -and -not $failure.Contains('unexpected')) 'invalid or implicit target reached transfer'
    }
}
Test-Graphics 'cancelled graphics never stages code or stops existing access' {
    function Get-WslDistros { @('ai-dev') }
    function Read-Host { '' }
    function Send-WslAgentBundle { throw 'unexpected transfer' }
    function Stop-WslAgentRelay { throw 'unexpected relay stop' }
    Invoke-WslAgent -Action Graphics -DistroName ai-dev
}
Test-Graphics 'graphics confirmation precedes staging and uses synchronous selected command only' {
    $capture=[pscustomobject]@{Events=(New-Object 'System.Collections.Generic.List[string]');Lines=(New-Object 'System.Collections.Generic.List[string]')}
    function Get-WslDistros { @('ai-dev','other') }
    function Read-Host { $capture.Events.Add('confirm'); 'Y' }
    function Write-Host { param($Object,$ForegroundColor) $capture.Lines.Add([string]$Object) }
    function Send-WslAgentBundle { param($Distro) Assert-Graphics ($Distro -ceq 'ai-dev') 'wrong staged target'; $capture.Events.Add('stage'); '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Stop-WslAgentRelay { throw 'unexpected relay stop' }
    function Initialize-WslAgentSystemd { throw 'unexpected restart' }
    function Invoke-WslAgentCommand {
        param($Distro,$Entry,$Command,$Options,$Timeout,[switch]$AllowFailure)
        Assert-Graphics ($Distro -ceq 'ai-dev' -and $Entry -ceq '/var/tmp/onedebian-agent.ABCDef1234/agent.sh') 'command lost selected target or new payload'
        Assert-Graphics ($Command -ceq 'gpu' -and ($Options -join '|') -ceq '--yes|--json' -and $Timeout -eq 0 -and $AllowFailure) 'graphics action changed protocol or bounded execution'
        $capture.Events.Add('gpu'); New-GraphicsResult
    }
    Invoke-WslAgent -Action Graphics -DistroName ai-dev
    Assert-Graphics (($capture.Events -join ',') -ceq 'confirm,stage,gpu') 'command ran before confirmation or repeated'
    $text=$capture.Lines -join ','
    Assert-Graphics ($text.Contains('d3d12') -and $text.Contains('Accelerated') -and $text.Contains('gpu.log')) 'result summary lost backend, status or log'
    Assert-Graphics ($text.Contains('保留资料和页面') -and $text.Contains('不重装 WSL')) 'confirmation omitted scope'
}
Test-Graphics 'explicit Yes skips only confirmation and still stages the selected target' {
    $capture=[pscustomobject]@{Calls=0}
    function Get-WslDistros { @('ai-dev') }
    function Read-Host { throw 'unexpected prompt' }
    function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Invoke-WslAgentCommand { $capture.Calls++; New-GraphicsResult }
    Invoke-WslAgent -Action Graphics -DistroName ai-dev -Yes
    Assert-Graphics ($capture.Calls -eq 1) 'explicit action was not executed once'
}
Test-Graphics 'software fallback remains distinct from accelerated success' {
    $lines=New-Object 'System.Collections.Generic.List[string]'
    function Get-WslDistros { @('ai-dev') }
    function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Write-Host { param($Object,$ForegroundColor) $lines.Add([string]$Object) }
    function Invoke-WslAgentCommand { New-GraphicsResult -State READY_SOFTWARE -Backend software -Reason 'fixture unsupported hardware' }
    Invoke-WslAgent -Action Graphics -DistroName ai-dev -Yes
    $text=$lines -join ','
    Assert-Graphics ($text.Contains('Software') -and $text.Contains('fixture unsupported hardware') -and -not $text.Contains('Accelerated')) 'fallback reported acceleration or hid original reason'
}
Test-Graphics 'manual rejection and malformed results never report accelerated success' {
    function Get-WslDistros { @('ai-dev') }
    function Send-WslAgentBundle { '/var/tmp/onedebian-agent.ABCDef1234/agent.sh' }
    function Stop-WslAgentRelay { throw 'unexpected relay stop' }
    foreach($scenario in @('manual','malformed','inconsistent')) {
        $lines=New-Object 'System.Collections.Generic.List[string]'
        function Write-Host { param($Object,$ForegroundColor) $lines.Add([string]$Object) }
        function Invoke-WslAgentCommand {
            if($scenario -eq 'manual'){return New-GraphicsResult -State ERROR -Backend software -Code 1 -Reason '' -Diagnostic 'manual takeover is active'}
            if($scenario -eq 'inconsistent'){return New-GraphicsResult -State READY_GPU -Backend software}
            [pscustomobject]@{Text='not-json';ErrorText='fixture protocol failure';ExitCode=1;IsDecoded=$true}
        }
        $failure=''; try {Invoke-WslAgent -Action Graphics -DistroName ai-dev -Yes}catch{$failure=$_.Exception.Message}
        Assert-Graphics ($failure -and -not ($lines -join ',').Contains('Accelerated')) 'failed or inconsistent result reported success'
        if($scenario -eq 'manual'){Assert-Graphics ($failure.Contains('manual takeover') -and ($lines -join ',').Contains('gpu.log') -and ($lines -join ',').Contains('Manual')) 'manual refusal lost diagnostics or log'}
        if($scenario -eq 'malformed'){Assert-Graphics ($failure.Contains('fixture protocol failure')) 'parse failure hid stderr'}
    }
}
Test-Graphics 'native graphics menu requires confirmation and propagates command failure' {
    $git=Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $bash=Join-Path (Split-Path -Parent $git.Source) '..\bin\bash.exe'
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try {
        [IO.File]::WriteAllText((Join-Path $fixture 'menu.sh'),[IO.File]::ReadAllText("$repo\components\the_agent_environment.sh").Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        $script=@'
set -euo pipefail
source "$1"
trace=$2
scenario=$3
MENU_DIR=/fixture
bash() { printf '%s\n' "$*" >> "$trace"; [[ "$*" == '/fixture/agent.sh gpu --yes' && $scenario != failure ]]; }
answer=Y
[[ $scenario != cancelled ]] || answer=N
set +e
printf '8\n%s\n' "$answer" | the_agent_environment
result=$?
set -e
if [[ $scenario == failure ]]; then [[ $result != 0 ]]; else [[ $result == 0 ]]; fi
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'fixture.sh'),$script.Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        foreach($scenario in @('confirmed','cancelled','failure')) {
            $trace=Join-Path $fixture ($scenario+'.txt')
            $result=Invoke-WslCommand -FilePath $bash -Arguments @('--noprofile','--norc',(Join-Path $fixture 'fixture.sh'),(Join-Path $fixture 'menu.sh'),$trace,$scenario) -TimeoutMilliseconds 15000
            Assert-Graphics ($result.ExitCode -eq 0) "native graphics fixture failed: $scenario $($result.ErrorText)"
            if($scenario -eq 'cancelled'){Assert-Graphics (-not (Test-Path -LiteralPath $trace)) 'native cancellation called gpu'}
            else {Assert-Graphics ([IO.File]::ReadAllText($trace).Trim() -ceq '/fixture/agent.sh gpu --yes') 'native action changed command or ran more than once'}
        }
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Write-Host "WSL Agent graphics regressions: $script:graphicsCases tests, $($script:graphicsFailures.Count) failures."
if($script:graphicsFailures.Count){throw ($script:graphicsFailures -join "`n")}
