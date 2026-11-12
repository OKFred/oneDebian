# Keyring command wiring only; no credential store or WSL instance is touched.
$ErrorActionPreference = 'Stop'
$repo=Split-Path -Parent $PSScriptRoot
. "$repo\components\wsl_common.ps1"
. "$repo\components\wsl_agent.ps1"
$script:keyringCases=0
$script:keyringFailures=New-Object 'System.Collections.Generic.List[string]'
function Assert-Keyring {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Test-Keyring {param([string]$Name,[scriptblock]$Body)
    $script:keyringCases++
    try{& $Body;Write-Host "PASS $Name"}catch{$script:keyringFailures.Add("${Name}: $($_.Exception.Message)");Write-Host "FAIL ${Name}: $($_.Exception.Message)"}
}
function New-KeyringResult {param([string]$State='INITIALIZED_EMPTY',[string]$Reason='fixture initialized new store',[int]$Code=0,[string]$Diagnostic='')
    [pscustomobject]@{Text=([pscustomobject]@{state=$State;reason=$Reason;error=$Diagnostic}|ConvertTo-Json -Compress);ErrorText='';ExitCode=$Code;IsDecoded=$true}
}
Test-Keyring 'keyring requires an explicit registered target even with Yes' {
    function Get-WslDistros {@('ai-dev')}
    function Send-WslAgentBundle {throw 'unexpected transfer'}
    foreach($name in @('','missing','-bad')){
        $failure='';try{Invoke-WslAgent -Action Keyring -DistroName $name -Yes}catch{$failure=$_.Exception.Message}
        Assert-Keyring ($failure -and -not $failure.Contains('unexpected')) 'invalid or implicit target reached transfer'
    }
}
Test-Keyring 'cancelled keyring action has no transfer or browser side effects' {
    function Get-WslDistros {@('ai-dev')}
    function Read-Host {''}
    function Send-WslAgentBundle {throw 'unexpected transfer'}
    function Stop-WslAgentRelay {throw 'unexpected relay stop'}
    function Invoke-WslAgentCommand {throw 'unexpected browser or keyring command'}
    Invoke-WslAgent -Action Keyring -DistroName ai-dev
}
Test-Keyring 'confirmation explains empty password and precedes the selected staged command' {
    $capture=[pscustomobject]@{Events=(New-Object 'System.Collections.Generic.List[string]');Lines=(New-Object 'System.Collections.Generic.List[string]')}
    function Get-WslDistros {@('ai-dev','other')}
    function Read-Host {$capture.Events.Add('confirm');'Y'}
    function Write-Host {param($Object,$ForegroundColor)$capture.Lines.Add([string]$Object)}
    function Send-WslAgentBundle {param($Distro) Assert-Keyring ($Distro -ceq 'ai-dev') 'wrong staged target';$capture.Events.Add('stage');'/var/tmp/onedebian-agent.ABCDef1234/agent.sh'}
    function Stop-WslAgentRelay {throw 'unexpected relay stop'}
    function Initialize-WslAgentSystemd {throw 'unexpected restart'}
    function Invoke-WslAgentCommand {
        param($Distro,$Entry,$Command,$Options,$Timeout,[switch]$AllowFailure)
        Assert-Keyring ($Distro -ceq 'ai-dev' -and $Entry -ceq '/var/tmp/onedebian-agent.ABCDef1234/agent.sh') 'target or new payload was lost'
        Assert-Keyring ($Command -ceq 'keyring' -and ($Options -join '|') -ceq '--yes|--json' -and $Timeout -eq 0 -and $AllowFailure) 'keyring protocol changed or added side effects'
        $capture.Events.Add('keyring');New-KeyringResult
    }
    Invoke-WslAgent -Action Keyring -DistroName ai-dev
    Assert-Keyring (($capture.Events -join ',') -ceq 'confirm,stage,keyring') 'keyring ran before confirmation or repeated'
    $text=$capture.Lines -join ','
    Assert-Keyring ($text.Contains('INITIALIZED_EMPTY') -and $text.Contains('fixture initialized new store')) 'state or reason was hidden'
    Assert-Keyring ($text.Contains('空密码') -and $text.Contains('保留已有库和旧凭据') -and $text.Contains('降低')) 'empty-password consent omitted its effect'
}
Test-Keyring 'explicit Yes preserves an existing-store result without claiming new initialization' {
    $lines=New-Object 'System.Collections.Generic.List[string]'
    function Get-WslDistros {@('ai-dev')}
    function Read-Host {throw 'unexpected prompt'}
    function Send-WslAgentBundle {'/var/tmp/onedebian-agent.ABCDef1234/agent.sh'}
    function Write-Host {param($Object,$ForegroundColor)$lines.Add([string]$Object)}
    function Invoke-WslAgentCommand {New-KeyringResult -State EXISTING_PRESERVED -Reason 'fixture existing store retained'}
    Invoke-WslAgent -Action Keyring -DistroName ai-dev -Yes
    $text=$lines -join ','
    Assert-Keyring ($text.Contains('EXISTING_PRESERVED') -and $text.Contains('fixture existing store retained') -and -not $text.Contains('INITIALIZED_EMPTY')) 'preserved store was reported as overwritten'
}
Test-Keyring 'failed or malformed keyring results retain diagnostics and fail' {
    function Get-WslDistros {@('ai-dev')}
    function Send-WslAgentBundle {'/var/tmp/onedebian-agent.ABCDef1234/agent.sh'}
    foreach($scenario in @('failed','malformed','empty')){
        function Invoke-WslAgentCommand {
            if($scenario -eq 'failed'){return New-KeyringResult -State ERROR -Reason 'fixture occupied keyring' -Code 1 -Diagnostic 'fixture refusal'}
            if($scenario -eq 'empty'){return New-KeyringResult -State ''}
            [pscustomobject]@{Text='not-json';ErrorText='fixture keyring protocol';ExitCode=1;IsDecoded=$true}
        }
        $failure='';try{Invoke-WslAgent -Action Keyring -DistroName ai-dev -Yes}catch{$failure=$_.Exception.Message}
        Assert-Keyring ([bool]$failure) 'invalid keyring result was accepted'
        if($scenario -eq 'failed'){Assert-Keyring ($failure.Contains('fixture refusal') -and $failure.Contains('fixture occupied keyring')) 'refusal diagnostic was hidden'}
        if($scenario -eq 'malformed'){Assert-Keyring ($failure.Contains('fixture keyring protocol')) 'malformed result hid stderr'}
    }
}
Test-Keyring 'native keyring menu requires consent and propagates helper failure' {
    $git=Get-Command git.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1
    $bash=Join-Path (Split-Path -Parent $git.Source) '..\bin\bash.exe'
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try{
        [IO.File]::WriteAllText((Join-Path $fixture 'menu.sh'),[IO.File]::ReadAllText("$repo\components\the_agent_environment.sh").Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        $source=@'
set -euo pipefail
source "$1"
trace=$2
scenario=$3
MENU_DIR=/fixture
bash() { printf '%s\n' "$*" >> "$trace"; [[ "$*" == '/fixture/agent.sh keyring --yes' && $scenario != failure ]]; }
answer=Y
[[ $scenario != cancelled ]] || answer=N
set +e
printf '9\n%s\n' "$answer" | the_agent_environment
result=$?
set -e
if [[ $scenario == failure ]]; then [[ $result != 0 ]]; else [[ $result == 0 ]]; fi
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'fixture.sh'),$source.Replace("`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
        foreach($scenario in @('confirmed','cancelled','failure')){
            $trace=Join-Path $fixture ($scenario+'.txt')
            $result=Invoke-WslCommand -FilePath $bash -Arguments @('--noprofile','--norc',(Join-Path $fixture 'fixture.sh'),(Join-Path $fixture 'menu.sh'),$trace,$scenario) -TimeoutMilliseconds 15000
            Assert-Keyring ($result.ExitCode -eq 0) "native keyring fixture failed: $scenario $($result.ErrorText)"
            if($scenario -eq 'cancelled'){Assert-Keyring (-not (Test-Path -LiteralPath $trace)) 'cancellation invoked keyring'}
            else{Assert-Keyring ([IO.File]::ReadAllText($trace).Trim() -ceq '/fixture/agent.sh keyring --yes') 'wrong native command or duplicate invocation'}
        }
    }finally{Remove-WslAgentBundle -Root $fixture}
}
Write-Host "WSL Agent keyring regressions: $script:keyringCases tests, $($script:keyringFailures.Count) failures."
if($script:keyringFailures.Count){throw ($script:keyringFailures -join "`n")}
