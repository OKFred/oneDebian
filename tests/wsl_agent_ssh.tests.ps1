# SSH setup uses mocks; one disposable real key verifies Windows DACL persistence.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. "$repo\components\wsl_common.ps1"
. "$repo\components\wsl_agent.ps1"
. "$repo\components\wsl_agent_ssh.ps1"
$script:sshCount = 0
$script:sshFailures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Ssh { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Test-Ssh { param([string]$Name, [scriptblock]$Body)
    $script:sshCount++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:sshFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function New-SshResult { param([string]$Text = '', [int]$Code = 0)
    [pscustomobject]@{Text=$Text;ErrorText='fixture diagnostic';ExitCode=$Code;IsDecoded=$true}
}
function Use-SshFixture { param([scriptblock]$Body)
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    $before=$env:USERPROFILE
    try {
        $env:USERPROFILE=$fixture
        $capture=[pscustomobject]@{Calls=(New-Object 'System.Collections.Generic.List[object]');Backend=0;Public='ssh-ed25519 AAAAFixturePublic';Host='ssh-ed25519 AAAAFixtureHost';AliasConflict=$false;FailLogin=$false;PartialKey=$false}
        function Set-WslAgentSshPrivateAcl {param($Path,$Sid,[switch]$Directory)}
        function Get-Command {param($Name,$CommandType,$ErrorAction) [pscustomobject]@{Source='C:\Windows\System32\wsl.exe'}}
        function Invoke-WslCommand {
            param($FilePath,$Arguments,$TimeoutMilliseconds)
            $capture.Calls.Add([pscustomobject]@{File=$FilePath;Args=@($Arguments)})
            if($FilePath -eq 'ssh-keygen.exe') {
                if($Arguments -contains '-t') {
                    $p=$Arguments[[array]::IndexOf($Arguments,'-f')+1]
                    [IO.File]::WriteAllText($p,'fixture-private-key')
                    if($capture.PartialKey){throw 'fixture interrupted after private key creation'}
                    [IO.File]::WriteAllText(($p+'.pub'),$capture.Public+" fixture`n")
                }
                if($Arguments -contains '-y'){return New-SshResult ($capture.Public+"`n")}
                return New-SshResult '256 fixture fingerprint'
            }
            if($FilePath -eq 'ssh.exe' -and $Arguments[0] -eq '-G') {
                $hostName=if($capture.AliasConflict){'foreign.example.invalid'}else{$Arguments[1]}
                return New-SshResult "hostname $hostName`n"
            }
            if($FilePath -eq 'ssh.exe') {
                if($capture.FailLogin){return New-SshResult '' 255}
                return New-SshResult "agent`nfixture-host`n"
            }
            throw 'Unexpected native operation'
        }
        function Invoke-WslAgentCommand {
            param($Distro,$Entry,$Command,$Options,$Timeout,[switch]$AllowFailure)
            Assert-Ssh ($Distro -ceq 'ai-dev' -and $Entry -ceq '/fixture/agent.sh') 'target or staged entry was changed'
            Assert-Ssh ($Command -ceq 'ssh' -and $Timeout -eq 0 -and $AllowFailure) 'wrong backend protocol'
            Assert-Ssh (($Options -join '|') -ceq ('--yes|--ssh-public-key|'+$capture.Public+'|--ssh-port|2222|--json')) 'private data or wrong public key was sent'
            $capture.Backend++
            return New-SshResult (@{state='SSH_READY';port=2222;host_public_key=$capture.Host} | ConvertTo-Json -Compress)
        }
        & $Body $fixture $capture
    } finally {
        $env:USERPROFILE=$before
        Remove-WslAgentBundle -Root $fixture
    }
}

Test-Ssh 'sourcing SSH component is read-only' {
    function Invoke-WslCommand {throw 'unexpected native command'}
    function New-Item {throw 'unexpected write'}
    . "$repo\components\wsl_agent_ssh.ps1"
}
Test-Ssh 'private ACL changes only the DACL on an ordinary user temp directory and key' {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try {
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $private=Join-Path $fixture 'private'
        $null=New-Item -ItemType Directory -Path $private
        $key=Join-Path $private 'fixture-key'
        [IO.File]::WriteAllText($key,'fixture-only-not-a-real-key')
        foreach($item in @(@($private,$true),@($key,$false))) {
            $before=(Get-Acl -LiteralPath $item[0]).Owner
            Set-WslAgentSshPrivateAcl -Path $item[0] -Sid $sid -Directory:$item[1]
            $acl=Get-Acl -LiteralPath $item[0]
            Assert-Ssh ($acl.Owner -ceq $before -and $acl.AreAccessRulesProtected) 'owner changed or DACL still inherited'
            $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            Assert-Ssh ($rules.Count -eq 2 -and @($rules | Where-Object {$_.IdentityReference.Value -notin @($sid,'S-1-5-18') -or $_.AccessControlType -ne 'Allow'}).Count -eq 0) 'private path grants another identity'
        }
    } finally {Remove-WslAgentBundle -Root $fixture}
}
Test-Ssh 'a real temporary ssh-keygen key stays readable after private ACL persistence' {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $fixture
    try {
        $key=Join-Path $fixture 'disposable-ed25519'
        $generated=Invoke-WslCommand -FilePath ssh-keygen.exe -Arguments @('-q','-t','ed25519','-N','','-f',$key,'-C','oneDebian disposable ACL test') -TimeoutMilliseconds 30000
        Assert-Ssh ($generated.ExitCode -eq 0) 'temporary key generation failed'
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $owner=(Get-Acl -LiteralPath $key).Owner
        Set-WslAgentSshPrivateAcl -Path $key -Sid $sid
        $acl=Get-Acl -LiteralPath $key
        $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        Assert-Ssh ($acl.Owner -ceq $owner -and $acl.AreAccessRulesProtected -and $rules.Count -eq 2) 'key owner or protected DACL changed incorrectly'
        Assert-Ssh (@($rules | Where-Object {$_.IdentityReference.Value -notin @($sid,'S-1-5-18') -or $_.AccessControlType -ne 'Allow'}).Count -eq 0) 'private key grants another identity'
        $derived=Invoke-WslCommand -FilePath ssh-keygen.exe -Arguments @('-y','-P','','-f',$key) -TimeoutMilliseconds 10000
        Assert-Ssh ($derived.ExitCode -eq 0 -and $derived.Text -match '^ssh-ed25519 ') 'OpenSSH cannot read the key after setting its DACL'
    } finally {Remove-WslAgentBundle -Root $fixture}
}
Test-Ssh 'setup generates only a local key and pins an IP-independent SSH alias' {
    Use-SshFixture {
        param($fixture,$capture)
        $null=New-Item -ItemType Directory -Path (Join-Path $fixture '.ssh')
        $old="Host keep`n  HostName example.invalid`n"
        [IO.File]::WriteAllText((Join-Path $fixture '.ssh\config'),$old)
        $result=Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh
        Assert-Ssh ($result.state -eq 'SSH_READY' -and $result.alias -ceq 'oneDebian-ai-dev') 'ready alias missing'
        $body=[IO.File]::ReadAllText($result.config)
        Assert-Ssh ($body.Contains('ProxyCommand C:\Windows\System32\wsl.exe --distribution ai-dev --user agent --exec /usr/bin/nc 127.0.0.1 2222')) 'proxy depends on IP or shell interpolation'
        Assert-Ssh ($body.Contains('StrictHostKeyChecking yes') -and $body.Contains('HostKeyAlias oneDebian-ai-dev') -and $body.Contains('IdentitiesOnly yes')) 'SSH authentication was weakened'
        $config=[IO.File]::ReadAllText((Join-Path $fixture '.ssh\config'))
        Assert-Ssh ($config.EndsWith($old) -and $config.StartsWith('Include ')) 'existing config was not retained or Include was placed inside an old Host'
        Assert-Ssh ([IO.File]::ReadAllText((Join-Path $fixture '.ssh\onedebian_agent_ed25519')) -ceq 'fixture-private-key') 'private identity unexpectedly copied or changed'
        $generated=@($capture.Calls | Where-Object {$_.File -ceq 'ssh-keygen.exe' -and $_.Args -ccontains '-t'})
        Assert-Ssh ($generated.Count -eq 1 -and $generated[0].Args[[array]::IndexOf($generated[0].Args,'-N')+1] -ceq '') 'empty key passphrase argument was lost'
        Assert-Ssh ($capture.Backend -eq 1) 'backend was repeated'
    }
}
Test-Ssh 'repeat setup reuses the key and only updates a trusted host-key record' {
    Use-SshFixture {
        param($fixture,$capture)
        $first=Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh
        $capture.Host='ssh-ed25519 AAAAFixtureRotated'
        $second=Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh
        Assert-Ssh (@($capture.Calls | Where-Object {$_.File -ceq 'ssh-keygen.exe' -and $_.Args -ccontains '-t'}).Count -eq 1) 'rerun replaced the key'
        $global=[IO.File]::ReadAllText((Join-Path $fixture '.ssh\config'))
        Assert-Ssh ([regex]::Matches($global,'(?m)^Include ').Count -eq 1) 'rerun duplicated Include'
        $known=[IO.File]::ReadAllText((Join-Path $fixture '.ssh\onedebian-agent\oneDebian-ai-dev.known_hosts'))
        Assert-Ssh ($known.Contains('AAAAFixtureRotated') -and -not $known.Contains('AAAAFixtureHost')) 'trusted root host key was not updated precisely'
    }
}
Test-Ssh 'a preexisting SSH alias is rejected before key or guest writes' {
    Use-SshFixture {
        param($fixture,$capture)
        $capture.AliasConflict=$true
        $failure='';try{Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('another configuration')) 'foreign SSH alias was overwritten'
        Assert-Ssh ($capture.Backend -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $fixture '.ssh\onedebian_agent_ed25519'))) 'conflict created key or changed guest'
    }
    Use-SshFixture {
        param($fixture,$capture)
        $null=New-Item -ItemType Directory -Path (Join-Path $fixture '.ssh')
        [IO.File]::WriteAllText((Join-Path $fixture '.ssh\config'),"Host oneDebian-ai-dev`n  User existing`n")
        $failure='';try{Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('existing Host entry') -and $capture.Backend -eq 0) 'alias with only User was silently overridden'
    }
}
Test-Ssh 'an unrecorded dedicated private key is retained' {
    Use-SshFixture {
        param($fixture,$capture)
        $null=New-Item -ItemType Directory -Path (Join-Path $fixture '.ssh')
        $p=Join-Path $fixture '.ssh\onedebian_agent_ed25519'
        [IO.File]::WriteAllText($p,'preexisting-user-private')
        $failure='';try{Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('unrecorded')) 'foreign private key was adopted'
        Assert-Ssh ([IO.File]::ReadAllText($p) -ceq 'preexisting-user-private') 'foreign key was changed'
        Assert-Ssh ($capture.Backend -eq 0) 'guest changed before identity validation'
    }
}
Test-Ssh 'an owned pending key pair resumes after ACL failure without regenerating identity' {
    Use-SshFixture {
        param($fixture,$capture)
        $capture | Add-Member -NotePropertyName FailAcl -NotePropertyValue $true
        function Set-WslAgentSshPrivateAcl {
            param($Path,$Sid,[switch]$Directory)
            if($Path.EndsWith('onedebian_agent_ed25519') -and $capture.FailAcl){throw 'fixture ACL interruption'}
        }
        $failure='';try{Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('ACL interruption')) 'fixture did not stop between generation and completion'
        $recordPath=Join-Path $fixture '.ssh\onedebian-agent\key.json'
        $pending=[IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
        Assert-Ssh ($pending.state -ceq 'CREATING') 'pending key journal was not written before generation'
        $capture.FailAcl=$false
        $null=Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh
        $complete=[IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
        Assert-Ssh ($complete.state -ceq 'READY' -and $complete.private_sha256 -match '^[a-f0-9]{64}$' -and $complete.public_sha256 -match '^[a-f0-9]{64}$') 'completed key evidence missing'
        Assert-Ssh (@($capture.Calls | Where-Object {$_.File -ceq 'ssh-keygen.exe' -and $_.Args -ccontains '-t'}).Count -eq 1) 'resuming replaced the private key'
    }
}
Test-Ssh 'an owned private-only pending key resumes but a changed completed key is retained' {
    Use-SshFixture {
        param($fixture,$capture)
        $capture.PartialKey=$true
        $failure='';try{Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('interrupted after private')) 'fixture did not interrupt key generation'
        $capture.PartialKey=$false
        $null=Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh
        Assert-Ssh (@($capture.Calls | Where-Object {$_.File -ceq 'ssh-keygen.exe' -and $_.Args -ccontains '-t'}).Count -eq 1) 'private-only recovery generated another identity'
        $key=Join-Path $fixture '.ssh\onedebian_agent_ed25519'
        [IO.File]::AppendAllText($key,'changed')
        $failure='';try{Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('recorded identity') -and $capture.Backend -eq 1) 'changed completed key was silently accepted'
        Assert-Ssh ([IO.File]::ReadAllText($key).EndsWith('changed')) 'changed key was overwritten'
    }
}
Test-Ssh 'changed alias files block rerun and failed login never reports ready' {
    Use-SshFixture {
        param($fixture,$capture)
        $first=Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh
        [IO.File]::AppendAllText($first.config,"# user change`n")
        $failure='';try{Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('was changed') -and $capture.Backend -eq 1) 'user edit was overwritten'
    }
    Use-SshFixture {
        param($fixture,$capture)
        $capture.FailLogin=$true
        $failure='';try{Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('login test failed') -and $failure.Contains('fixture diagnostic')) 'failed login was reported ready'
    }
}
Test-Ssh 'public key and target validation reject private material and command syntax' {
    foreach($bad in @('-----BEGIN OPENSSH PRIVATE KEY-----',"ssh-ed25519 AAAA`ncommand=bad",'ssh-rsa AAAA')) {
        $failed=$false;try{Get-WslAgentSshPublicKey -Text $bad}catch{$failed=$true}
        Assert-Ssh $failed 'non-public or multi-line key accepted'
    }
    function Invoke-WslCommand {throw 'native command ran before target validation'}
    foreach($bad in @('ai-dev&whoami','ai-dev%PATH%',"ai-dev`nother")) {
        $failure='';try{Initialize-WslAgentSsh -Distro $bad -Entry /fixture/agent.sh}catch{$failure=$_.Exception.Message}
        Assert-Ssh ($failure.Contains('simple registered')) 'target command syntax was accepted'
    }
}
Test-Ssh 'cleanup removes only the unchanged owned alias and retains the private key' {
    Use-SshFixture {
        param($fixture,$capture)
        $first=Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh
        $config=Join-Path $fixture '.ssh\config'
        [IO.File]::AppendAllText($config,"Host keep`n  HostName preserved.invalid`n")
        $result=Remove-WslAgentSshRegistration -Distro ai-dev
        Assert-Ssh ($result.state -eq 'SSH_REMOVED') 'owned alias was not removed'
        Assert-Ssh (-not (Test-Path -LiteralPath $first.config)) 'owned config remained'
        Assert-Ssh (Test-Path -LiteralPath (Join-Path $fixture '.ssh\onedebian_agent_ed25519')) 'private key was removed'
        Assert-Ssh ([IO.File]::ReadAllText($config) -ceq "Host keep`n  HostName preserved.invalid`n") 'global user config was overwritten'
        Assert-Ssh ((Remove-WslAgentSshRegistration -Distro ai-dev).state -eq 'SSH_ABSENT') 'cleanup was not idempotent'
    }
}
Test-Ssh 'cleanup retains modified aliases without partial deletion' {
    Use-SshFixture {
        param($fixture,$capture)
        $first=Initialize-WslAgentSsh -Distro ai-dev -Entry /fixture/agent.sh
        $known=Join-Path $fixture '.ssh\onedebian-agent\oneDebian-ai-dev.known_hosts'
        [IO.File]::AppendAllText($known,"# user edit`n")
        $result=Remove-WslAgentSshRegistration -Distro ai-dev
        Assert-Ssh ($result.state -eq 'SSH_RETAINED') 'modified host-key registration was deleted'
        Assert-Ssh ((Test-Path -LiteralPath $first.config) -and (Test-Path -LiteralPath $known)) 'modified registration was partially removed'
    }
}
Test-Ssh 'normal installation completion configures SSH after viewer readiness' {
    . "$repo\components\wsl_agent_relay.ps1"
    $events=New-Object 'System.Collections.Generic.List[string]'
    function Ensure-WslAgentAccess {param($Distro) $events.Add("viewer:$Distro"); [pscustomobject]@{Mode='fixture'}}
    function Send-WslAgentBundle {param($Distro) $events.Add("bundle:$Distro"); '/fixture/agent.sh'}
    function Initialize-WslAgentSsh {param($Distro,$Entry,$SshPort) $events.Add("ssh:${Distro}:${SshPort}:${Entry}")}
    Complete-WslAgentAccess -Distro ai-dev -SshPort 2223
    Assert-Ssh (($events -join ',') -ceq 'viewer:ai-dev,bundle:ai-dev,ssh:ai-dev:2223:/fixture/agent.sh') 'installation did not configure the selected SSH target after readiness'
}
Write-Host "WSL Agent SSH regressions: $script:sshCount tests, $($script:sshFailures.Count) failures."
if($script:sshFailures.Count){throw ($script:sshFailures -join "`n")}
