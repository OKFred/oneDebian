# Current-user byte forwarding only; importing this component changes no state.

function Get-WslAgentRelayRegistration {
    param([string]$Distro)
    $entries = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop | ForEach-Object {
        $item = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
        if ($item.DistributionName -ceq $Distro) {
            [pscustomobject]@{ Guid = ([guid]$_.PSChildName).ToString('D'); Distro = [string]$item.DistributionName; Version = [int]$item.Version }
        }
    })
    if ($entries.Count -ne 1 -or $entries[0].Version -ne 2) { throw 'Select one verified WSL2 registration for forwarding.' }
    return $entries[0]
}

function Get-WslAgentRelayIdentity {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return [pscustomobject]@{ Sid = $sid; Session = [Diagnostics.Process]::GetCurrentProcess().SessionId }
}

function Get-WslAgentRelayContext {
    param([string]$Distro, [switch]$RecordedBuild)
    $registration = Get-WslAgentRelayRegistration -Distro $Distro
    $identity = Get-WslAgentRelayIdentity
    $source = Join-Path $PSScriptRoot 'wsl_agent_relay.cs'
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity.Sid + '|' + $identity.Session + '|' + $registration.Guid))
        $id = ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $root = Join-Path $env:USERPROFILE '.oneDebian\agent-relay'
    $state = Join-Path $root ($id + '.json')
    if (Test-Path -LiteralPath $root) {
        Assert-WslAgentRelayPath -Path $root
        $marker = Join-Path $root '.owner'
        Assert-WslAgentRelayPath -Path $marker
        if (-not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker) -cne ('oneDebian-agent-relay-v1|' + $identity.Sid)) { throw 'Existing relay directory has no matching ownership marker.' }
    }
    if ($RecordedBuild -and (Test-Path -LiteralPath $state)) {
        if ((Get-Item -LiteralPath $state).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Relay metadata symlink rejected.' }
        $metadata = [IO.File]::ReadAllText($state) | ConvertFrom-Json -ErrorAction Stop
        if ([string]$metadata.source_sha -notmatch '^[a-f0-9]{64}$' -or ([guid]$metadata.registration_guid).ToString('D') -cne $registration.Guid -or $metadata.distro -cne $Distro) {
            throw 'Unrecognized relay metadata; no process was stopped or replaced.'
        }
        $sourceHash = [string]$metadata.source_sha
    }
    $exe = Join-Path $root ('bin\agent-relay-' + $sourceHash + '.exe')
    return [pscustomobject]@{ Distro = $Distro; Guid = $registration.Guid; Sid = $identity.Sid; Session = $identity.Session; Id = $id;
        Root = $root; StatePath = $state; Source = $source; SourceHash = $sourceHash; Exe = $exe; BuildRecord = ($exe + '.json') }
}

function Assert-WslAgentRelayPath {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Relay path symlink rejected: $current" }
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Initialize-WslAgentRelayDirectory {
    param($Context)
    Assert-WslAgentRelayPath -Path $Context.Root
    $marker = Join-Path $Context.Root '.owner'
    Assert-WslAgentRelayPath -Path $marker
    if (Test-Path -LiteralPath $Context.Root) {
        if (-not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker) -cne ('oneDebian-agent-relay-v1|' + $Context.Sid)) {
            throw 'Existing relay directory has no matching ownership marker.'
        }
        return
    }
    $null = New-Item -ItemType Directory -Path $Context.Root -Force
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $sid = New-Object Security.Principal.SecurityIdentifier($Context.Sid)
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($owner in @($Context.Sid, 'S-1-5-18')) {
        $principal = New-Object Security.Principal.SecurityIdentifier($owner)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($principal, 'FullControl', $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Context.Root -AclObject $acl
    [IO.File]::WriteAllText($marker, ('oneDebian-agent-relay-v1|' + $Context.Sid), (New-Object Text.UTF8Encoding($false)))
}

function Assert-WslAgentRelayBuild {
    param($Context)
    Assert-WslAgentRelayPath -Path $Context.Exe
    Assert-WslAgentRelayPath -Path $Context.BuildRecord
    if (-not (Test-Path -LiteralPath $Context.Exe -PathType Leaf) -or -not (Test-Path -LiteralPath $Context.BuildRecord -PathType Leaf)) { throw 'The owned relay executable or build record is missing.' }
    $record = [IO.File]::ReadAllText($Context.BuildRecord) | ConvertFrom-Json -ErrorAction Stop
    $actual = (Get-FileHash -LiteralPath $Context.Exe -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($record.source_sha -cne $Context.SourceHash -or $record.exe_sha -cne $actual -or $record.owner_sid -cne $Context.Sid) { throw 'Relay executable checksum/ownership changed; it was not executed.' }
}

function Initialize-WslAgentRelayBuild {
    param($Context)
    Initialize-WslAgentRelayDirectory -Context $Context
    Assert-WslAgentRelayPath -Path $Context.BuildRecord
    if (Test-Path -LiteralPath $Context.Exe) { Assert-WslAgentRelayBuild -Context $Context; return }
    $compiler = @('Framework64', 'Framework') | ForEach-Object { Join-Path $env:SystemRoot "Microsoft.NET\$_\v4.0.30319\csc.exe" } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $compiler) { throw 'The Windows .NET Framework C# compiler is unavailable.' }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Context.Exe) -Force
    $result = Invoke-WslCommand -FilePath $compiler -Arguments @('/nologo', '/target:winexe', '/platform:anycpu', '/r:System.Web.Extensions.dll', "/out:$($Context.Exe)", $Context.Source) -TimeoutMilliseconds 30000
    if ($result.ExitCode -ne 0) { throw "Relay build failed: $($result.Text) $($result.ErrorText)" }
    if ((Get-FileHash -LiteralPath $Context.Source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Context.SourceHash) { throw 'Relay source changed during compilation; the executable was not started.' }
    $record = @{ source_sha = $Context.SourceHash; exe_sha = (Get-FileHash -LiteralPath $Context.Exe -Algorithm SHA256).Hash.ToLowerInvariant(); owner_sid = $Context.Sid }
    [IO.File]::WriteAllText($Context.BuildRecord, ($record | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Assert-WslAgentRelayBuild -Context $Context
}

function Invoke-WslAgentRelayControl {
    param($Context, [ValidateSet('status', 'stop')][string]$Mode)
    if (-not (Test-Path -LiteralPath $Context.StatePath)) {
        return [pscustomobject]@{ running = $false; ready = $false; distro = $Context.Distro }
    }
    Assert-WslAgentRelayBuild -Context $Context
    $result = Invoke-WslCommand -FilePath $Context.Exe -Arguments @($Mode, $Context.Guid, $Context.StatePath, $Context.SourceHash) -TimeoutMilliseconds 10000
    if ($result.ExitCode -ne 0 -or -not $result.IsDecoded) { throw "Relay ownership/control could not be verified: $($result.Text) $($result.ErrorText)" }
    try { $status = $result.Text | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Relay control returned invalid status.' }
    if ($status.running) {
        if (([guid]$status.registration_guid).ToString('D') -cne $Context.Guid -or $status.distro -cne $Context.Distro -or $status.source_sha -cne $Context.SourceHash) {
            throw 'The running relay did not prove its selected-instance identity.'
        }
        $process = Get-Process -Id ([int]$status.pid) -ErrorAction Stop
        if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$status.start_ticks -or [IO.Path]::GetFullPath($process.MainModule.FileName) -ine [IO.Path]::GetFullPath($Context.Exe)) { throw 'Relay process identity changed.' }
    }
    return $status
}

function Get-WslAgentRelayStatus {
    param([string]$Distro)
    $context = Get-WslAgentRelayContext -Distro $Distro -RecordedBuild
    return Invoke-WslAgentRelayControl -Context $context -Mode status
}

function Stop-WslAgentRelay {
    param([string]$Distro)
    $context = Get-WslAgentRelayContext -Distro $Distro -RecordedBuild
    $status = Invoke-WslAgentRelayControl -Context $context -Mode stop
    if ($status.running) { throw 'Owned relay did not finish stopping; no other process was killed.' }
    return $status
}

function Get-WslAgentRelayGuestConfig {
    param([string]$Distro)
    $code = @'
import hashlib,json,pathlib,pwd,stat
root=pathlib.Path('/opt/onedebian-agent'); etc=pathlib.Path('/etc/onedebian-agent'); state=pathlib.Path('/var/lib/onedebian-agent')
for directory in (root,etc,state):
    assert not directory.is_symlink() and (directory/'.owner').read_text()=='oneDebian-agent-v1', 'Unowned Agent directory'
def trusted(path):
    s=path.lstat(); assert stat.S_ISREG(s.st_mode) and s.st_uid==0 and not s.st_mode&0o022, 'Untrusted Agent file'
    return path.read_bytes()
c=json.loads(trusted(etc/'config.json')); helper=root/'relay.py'
digest=hashlib.sha256(trusted(helper)).hexdigest(); manifest=json.loads(trusted(state/'files.json'))
assert manifest.get(str(helper))==digest, 'Relay helper ownership/checksum differs'
assert c['user']=='agent' and pwd.getpwnam(c['user']).pw_uid!=0, 'Ordinary Agent user required'
assert all(type(c[k]) is int and 1024<=c[k]<=65535 for k in ('viewer_port','mcp_port')) and c['viewer_port']!=c['mcp_port'], 'Invalid service ports'
print(json.dumps({k:c[k] for k in ('user','viewer_port','mcp_port')}))
'@
    try {
        $result = Invoke-WslAgentShell -Distro $Distro -Script 'exec /usr/bin/python3 -c "$1"' -Data @($code)
        return $result.Text | ConvertFrom-Json -ErrorAction Stop
    } catch { throw "The selected Agent workstation needs its owned relay.py component installed/updated first. $($_.Exception.Message)" }
}

function Remove-StoppedWslAgentRelayMetadata {
    param($Context)
    $old = Get-WslAgentRelayContext -Distro $Context.Distro -RecordedBuild
    if ($old.SourceHash -ceq $Context.SourceHash -or -not (Test-Path -LiteralPath $Context.StatePath)) { return }
    $expected = Join-Path $Context.Root ($Context.Id + '.json')
    if ([IO.Path]::GetFullPath($Context.StatePath) -ine [IO.Path]::GetFullPath($expected) -or $old.StatePath -ine $Context.StatePath) { throw 'Relay state cleanup target differs from its verified identity.' }
    $created = $false
    $mutex = [Threading.Mutex]::new($false, ('Local\oneDebian-Agent-Relay-' + $Context.Id), [ref]$created)
    $locked = $false
    try {
        if (-not $created -or -not $mutex.WaitOne(0)) { throw 'Another process owns this relay identity; stale metadata was retained.' }
        $locked = $true
        Assert-WslAgentRelayPath -Path $Context.StatePath
        $before = (Get-FileHash -LiteralPath $Context.StatePath -Algorithm SHA256).Hash
        # The old executable still enforces its exact SID/session/GUID/version before retirement.
        $status = Invoke-WslAgentRelayControl -Context $old -Mode status
        if ($status.running -or $status.source_sha -cne $old.SourceHash -or $status.distro -cne $Context.Distro -or ([guid]$status.registration_guid).ToString('D') -cne $Context.Guid) { throw 'Old relay metadata was not proved stopped and owned.' }
        if ((Get-FileHash -LiteralPath $Context.StatePath -Algorithm SHA256).Hash -cne $before) { throw 'Relay metadata changed during validation; it was retained.' }
        Remove-Item -LiteralPath $Context.StatePath -Force
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Start-WslAgentRelay {
    param([string]$Distro)
    $context = Get-WslAgentRelayContext -Distro $Distro
    $status = Get-WslAgentRelayStatus -Distro $Distro
    if ($status.running) {
        if ($status.source_sha -cne $context.SourceHash) { throw 'Relay code was updated. Run RelayStop, then RelayStart; browser and desktop are retained.' }
        return $status
    }
    if ($status.source_sha -and $status.source_sha -cne $context.SourceHash) { Remove-StoppedWslAgentRelayMetadata -Context $context }
    $config = Get-WslAgentRelayGuestConfig -Distro $Distro
    Test-WslAgentPorts -Ports @([int]$config.viewer_port, [int]$config.mcp_port)
    Initialize-WslAgentRelayBuild -Context $context
    $arguments = @('run', $context.Guid, $context.Distro, [string]$config.viewer_port, [string]$config.mcp_port, $context.StatePath, $context.SourceHash)
    $commandLine = ($arguments | ForEach-Object { ConvertTo-WslCommandArgument $_ }) -join ' '
    $process = Start-Process -FilePath $context.Exe -ArgumentList $commandLine -WindowStyle Hidden -PassThru
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $process.Refresh()
        if ($process.HasExited) { throw 'Relay exited during startup; check port conflicts and the selected workstation.' }
        $status = Invoke-WslAgentRelayControl -Context $context -Mode status
        if ($status.running -and $status.ready) { return $status }
        Start-Sleep -Milliseconds 250
    } while ($watch.Elapsed.TotalSeconds -lt 45)
    $null = Invoke-WslAgentRelayControl -Context $context -Mode stop
    throw 'Owned relay startup timed out; its startup was stopped.'
}

function Write-WslAgentRelayStatus {
    param($Status)
    if (-not $Status.running) { Write-Host '本机专用转发：已停止 / Agent relay stopped'; return }
    $label = if ($Status.ready) { '运行中 / Owned relay ready' } else { '启动中 / Starting' }
    Write-Host "本机专用转发：$label | $($Status.distro) | PID $($Status.pid)" -ForegroundColor Green
    Write-Host "noVNC: http://127.0.0.1:$($Status.viewer_port)/ | MCP: http://127.0.0.1:$($Status.mcp_port)/mcp"
    Write-Host '仅转发回环字节；MCP 与浏览器仍运行在 Debian。'
    if ($Status.PSObject.Properties['mcp_backend_ready'] -and -not $Status.mcp_backend_ready) { Write-Host '启动时 MCP 后端未就绪；当前状态以工作机为准。' -ForegroundColor Yellow }
}

function Get-WslAgentViewerAddress {
    param([string]$Distro)
    $result = Invoke-WslAgentShell -Distro $Distro -Script 'set -eu; exec runuser -u agent -- /usr/bin/python3 /opt/onedebian-agent/runtime.py open-url'
    $address = $result.Text.Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.UserInfo -or $uri.Fragment -notmatch '^#token=[A-Za-z0-9_-]{43}$') {
        throw 'Viewer returned an invalid localhost URL.'
    }
    return $address
}

function Test-WslAgentViewerIdentity {
    param([string]$Address)
    $uri = $null
    if (-not [Uri]::TryCreate($Address, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.UserInfo -or $uri.Fragment -notmatch '^#token=([A-Za-z0-9_-]{43})$') { return $false }
    $token = $Matches[1]
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $bytes = New-Object byte[] 32; $random.GetBytes($bytes) } finally { $random.Dispose() }
    $nonce = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    $hmac = New-Object Security.Cryptography.HMACSHA256
    $hmac.Key = [Text.Encoding]::ASCII.GetBytes($token)
    try {
        $message = "oneDebian-viewer-v1`n$($uri.Port)`n$nonce"
        $expected = ([BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($message)))).Replace('-', '').ToLowerInvariant()
    } finally { $hmac.Dispose() }
    $response = $null
    try {
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$($uri.Port)/health?nonce=$nonce")
        $request.Proxy = $null
        $request.AllowAutoRedirect = $false
        $request.Timeout = 3000
        $request.ReadWriteTimeout = 3000
        $request.KeepAlive = $false
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt 1024) { return $false }
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 1025
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt 1024) { return $false }
        $body = [Text.Encoding]::UTF8.GetString($buffer, 0, $count) | ConvertFrom-Json -ErrorAction Stop
        if ($body.nonce -cne $nonce -or [string]$body.proof -notmatch '^[a-f0-9]{64}$') { return $false }
        $difference = 0
        for ($i = 0; $i -lt 64; $i++) { $difference = $difference -bor ([int][char]$expected[$i] -bxor [int][char]$body.proof[$i]) }
        return $difference -eq 0
    } catch { return $false }
    finally { if ($null -ne $response) { $response.Dispose() } }
}

function Ensure-WslAgentAccess {
    param([string]$Distro, [string]$Address = '')
    if (-not $Address) { $Address = Get-WslAgentViewerAddress -Distro $Distro }
    $uri = $null
    if (-not [Uri]::TryCreate($Address, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.UserInfo -or $uri.Fragment -notmatch '^#token=[A-Za-z0-9_-]{43}$') { throw 'Viewer returned an invalid localhost URL.' }
    if (Test-WslAgentViewerIdentity -Address $Address) { return [pscustomobject]@{ Address = $Address; Mode = 'direct' } }
    $relay = Start-WslAgentRelay -Distro $Distro
    if (-not $relay.running -or -not $relay.ready -or -not (Test-WslAgentViewerIdentity -Address $Address)) {
        throw 'The selected workstation did not prove its viewer identity; no browser was opened.'
    }
    return [pscustomobject]@{ Address = $Address; Mode = 'relay' }
}

function Complete-WslAgentAccess {
    param([string]$Distro, [int]$SshPort = 2222)
    try {
        $access = Ensure-WslAgentAccess -Distro $Distro
        Write-Host "本机查看入口已验证 / Viewer verified: $Distro ($($access.Mode))" -ForegroundColor Green
    } catch { throw "工作机已就绪，但本机查看入口尚未接通 / Workstation ready; viewer unavailable. $($_.Exception.Message)" }
    try {
        $entry = Send-WslAgentBundle -Distro $Distro
        Initialize-WslAgentSsh -Distro $Distro -Entry $entry -SshPort $SshPort
    } catch { throw "工作机和查看入口已就绪，SSH 配置尚未完成，请用 09 → 14 重试。 / SSH incomplete: $($_.Exception.Message)" }
}
