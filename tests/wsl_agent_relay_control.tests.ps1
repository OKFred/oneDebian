# Offline controller checks. No WSL, guest services or global settings are changed.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. "$repo\components\wsl_common.ps1"
. "$repo\components\wsl_agent.ps1"
. "$repo\components\wsl_agent_relay.ps1"
$script:relayCount = 0
$script:relayFailures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Relay { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }
function Test-Relay { param([string]$Name, [scriptblock]$Body)
    $script:relayCount++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:relayFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function New-RelayResult { param([string]$Text = '', [int]$ExitCode = 0)
    [pscustomobject]@{ Text = $Text; ErrorText = ''; ExitCode = $ExitCode; IsDecoded = $true }
}

Test-Relay 'component sourcing never starts or compiles a relay' {
    function Invoke-WslCommand { throw 'unexpected native operation' }
    function Start-Process { throw 'unexpected startup' }
    . "$repo\components\wsl_agent_relay.ps1"
    Assert-Relay ([bool](Get-Command Start-WslAgentRelay)) 'entry missing'
}
Test-Relay 'foreign busy port fails before compile or process creation' {
    function Get-WslAgentRelayContext { [pscustomobject]@{ SourceHash = ('a' * 64) } }
    function Get-WslAgentRelayStatus { [pscustomobject]@{ running = $false } }
    function Get-WslAgentRelayGuestConfig { [pscustomobject]@{ viewer_port = 16080; mcp_port = 18931 } }
    function Test-WslAgentPorts { throw 'foreign busy port' }
    function Initialize-WslAgentRelayBuild { throw 'unexpected compile' }
    function Start-Process { throw 'unexpected startup' }
    $failed = $false
    try { Start-WslAgentRelay -Distro ai-dev } catch { $failed = $_.Exception.Message -eq 'foreign busy port' }
    Assert-Relay $failed 'port conflict was ignored'
}
Test-Relay 'already-owned matching relay is reused without guest mutation or restart' {
    function Get-WslAgentRelayContext { [pscustomobject]@{ SourceHash = ('a' * 64) } }
    function Get-WslAgentRelayStatus { [pscustomobject]@{ running = $true; ready = $true; source_sha = ('a' * 64) } }
    function Get-WslAgentRelayGuestConfig { throw 'unexpected guest query' }
    function Start-Process { throw 'unexpected startup' }
    Assert-Relay (Start-WslAgentRelay -Distro ai-dev).ready 'owned relay was not reused'
}
Test-Relay 'source update requires explicitly stopping the old owned worker' {
    function Get-WslAgentRelayContext { [pscustomobject]@{ SourceHash = ('b' * 64) } }
    function Get-WslAgentRelayStatus { [pscustomobject]@{ running = $true; ready = $true; source_sha = ('a' * 64) } }
    function Stop-WslAgentRelay { throw 'unexpected implicit stop' }
    $failed = $false
    try { Start-WslAgentRelay -Distro ai-dev } catch { $failed = $_.Exception.Message.Contains('RelayStop') }
    Assert-Relay $failed 'old worker was replaced implicitly'
}
Test-Relay 'stopped old-version metadata retires under its identity mutex before a new version starts' {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixture
    $id = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
    $ctx = [pscustomobject]@{ Root=$fixture; Id=$id; StatePath=(Join-Path $fixture ($id+'.json')); SourceHash=('b'*64); Distro='ai-dev'; Guid='11111111-1111-1111-1111-111111111111' }
    $old = [pscustomobject]@{ SourceHash=('a'*64); StatePath=$ctx.StatePath }
    $proof = [pscustomobject]@{ running=$false; source_sha=$old.SourceHash; distro=$ctx.Distro; registration_guid=$ctx.Guid }
    function Get-WslAgentRelayContext { $old }
    function Invoke-WslAgentRelayControl { param($Context,$Mode) Assert-Relay ($Mode -eq 'status' -and $Context.SourceHash -ceq ('a'*64)) 'old binary/version was not used to prove retirement'; $proof }
    try {
        [IO.File]::WriteAllText($ctx.StatePath, 'old-owned-metadata')
        Remove-StoppedWslAgentRelayMetadata -Context $ctx
        Assert-Relay (-not (Test-Path -LiteralPath $ctx.StatePath)) 'verified stopped metadata remained and would block the new worker'
        [IO.File]::WriteAllText($ctx.StatePath, 'retain-live-metadata')
        $proof.running=$true
        $failed=$false
        try { Remove-StoppedWslAgentRelayMetadata -Context $ctx } catch { $failed=$_.Exception.Message.Contains('stopped and owned') }
        Assert-Relay ($failed -and [IO.File]::ReadAllText($ctx.StatePath) -ceq 'retain-live-metadata') 'live metadata was removed'
        $proof.running=$false
        $created=$false
        $held=[Threading.Mutex]::new($true,('Local\oneDebian-Agent-Relay-'+$id),[ref]$created)
        try {
            $failed=$false
            try { Remove-StoppedWslAgentRelayMetadata -Context $ctx } catch { $failed=$_.Exception.Message.Contains('owns this relay identity') }
            Assert-Relay ($failed -and (Test-Path -LiteralPath $ctx.StatePath)) 'another owner/startup could race stale metadata removal'
        } finally { if($created){$held.ReleaseMutex()}; $held.Dispose() }
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Test-Relay 'status and stop do not enter or reboot WSL or compile anything' {
    $calls = New-Object 'System.Collections.Generic.List[string]'
    function Get-WslAgentRelayContext { [pscustomobject]@{} }
    function Invoke-WslAgentRelayControl { param($Context, $Mode) $calls.Add($Mode); [pscustomobject]@{ running = $false } }
    function Invoke-WslAgentShell { throw 'unexpected WSL entry' }
    function Initialize-WslAgentRelayBuild { throw 'unexpected compile' }
    $null = Get-WslAgentRelayStatus -Distro ai-dev
    $null = Stop-WslAgentRelay -Distro ai-dev
    Assert-Relay (($calls -join ',') -ceq 'status,stop') 'wrong control operations'
}
Test-Relay 'ownership cannot be proved by a listening port or changed process identity' {
    $process = Get-Process -Id $PID
    $ctx = [pscustomobject]@{ Guid = '11111111-1111-1111-1111-111111111111'; Distro = 'ai-dev'; SourceHash = ('a' * 64); StatePath = 'fixture'; Exe = $process.MainModule.FileName }
    $data = @{ running = $true; ready = $true; registration_guid = $ctx.Guid; distro = 'ai-dev'; source_sha = $ctx.SourceHash; pid = $PID; start_ticks = $process.StartTime.ToUniversalTime().Ticks }
    function Test-Path { $true }
    function Assert-WslAgentRelayBuild { }
    function Invoke-WslCommand { New-RelayResult ($data | ConvertTo-Json -Compress) }
    Assert-Relay (Invoke-WslAgentRelayControl -Context $ctx -Mode status).ready 'correct process rejected'
    $data.start_ticks--
    $failed = $false
    try { Invoke-WslAgentRelayControl -Context $ctx -Mode status } catch { $failed = $_.Exception.Message.Contains('process identity') }
    Assert-Relay $failed 'reused PID was accepted'
}
Test-Relay 'private build records reject binary tampering before execution' {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixture
    try {
        $exe = Join-Path $fixture 'fixture.exe'
        [IO.File]::WriteAllText($exe, 'not executed fixture')
        $ctx = [pscustomobject]@{ Exe = $exe; BuildRecord = ($exe + '.json'); SourceHash = ('a' * 64); Sid = 'fixture-owner' }
        $record = @{ source_sha = $ctx.SourceHash; owner_sid = $ctx.Sid; exe_sha = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant() }
        [IO.File]::WriteAllText($ctx.BuildRecord, ($record | ConvertTo-Json))
        Assert-WslAgentRelayBuild -Context $ctx
        [IO.File]::WriteAllText($exe, 'tampered')
        $failed = $false
        try { Assert-WslAgentRelayBuild -Context $ctx } catch { $failed = $_.Exception.Message.Contains('checksum/ownership') }
        Assert-Relay $failed 'changed binary accepted'
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Test-Relay 'relay cache directory is private and refuses an unowned existing directory' {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixture
    try {
        $ctx = [pscustomobject]@{ Root = (Join-Path $fixture 'relay'); Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
        Initialize-WslAgentRelayDirectory -Context $ctx
        Assert-Relay ((Get-Acl -LiteralPath $ctx.Root).AreAccessRulesProtected) 'cache inherited a broad ACL'
        Assert-Relay ([IO.File]::ReadAllText((Join-Path $ctx.Root '.owner')) -ceq ('oneDebian-agent-relay-v1|' + $ctx.Sid)) 'directory ownership marker missing'
        Initialize-WslAgentRelayDirectory -Context $ctx
        $ctx.Root = Join-Path $fixture 'foreign'
        $null = New-Item -ItemType Directory -Path $ctx.Root
        $failed = $false
        try { Initialize-WslAgentRelayDirectory -Context $ctx } catch { $failed = $_.Exception.Message.Contains('ownership marker') }
        Assert-Relay $failed 'unowned directory adopted silently'
    } finally { Remove-WslAgentBundle -Root $fixture }
}
Test-Relay 'verified direct viewer never starts a worker' {
    function Test-WslAgentViewerIdentity { $true }
    function Start-WslAgentRelay { throw 'unexpected startup' }
    $access = Ensure-WslAgentAccess -Distro ai-dev -Address ('http://127.0.0.1:16080/#token=' + ('C' * 43))
    Assert-Relay ($access.Mode -eq 'direct') 'direct identity proof ignored'
}
Test-Relay 'unverified viewer requires both owned worker and backend proof' {
    $checks = [pscustomobject]@{ Count = 0 }
    function Test-WslAgentViewerIdentity { $checks.Count++; $checks.Count -gt 1 }
    function Start-WslAgentRelay { [pscustomobject]@{ running = $true; ready = $true } }
    Assert-Relay ((Ensure-WslAgentAccess -Distro ai-dev -Address ('http://127.0.0.1:16080/#token=' + ('C' * 43))).Mode -eq 'relay') 'owned forwarding was not used'
    function Test-WslAgentViewerIdentity { $false }
    $failed = $false
    try { Ensure-WslAgentAccess -Distro ai-dev -Address ('http://127.0.0.1:16080/#token=' + ('C' * 43)) } catch { $failed = $_.Exception.Message.Contains('did not prove') }
    Assert-Relay $failed 'owned listener alone bypassed backend identity'
}
Test-Relay 'relay menu actions are scoped and uninstall stops forwarding first' {
    $calls = New-Object 'System.Collections.Generic.List[string]'
    function Get-WslDistros { @('ai-dev') }
    function Start-WslAgentRelay { param($Distro) $calls.Add("start:$Distro"); [pscustomobject]@{running=$false} }
    function Stop-WslAgentRelay { param($Distro) $calls.Add("stop:$Distro"); [pscustomobject]@{running=$false} }
    function Get-WslAgentRelayStatus { param($Distro) $calls.Add("status:$Distro"); [pscustomobject]@{running=$false} }
    function Write-WslAgentRelayStatus { }
    function Invoke-WslAgentCommand { param($Distro, $Command) $calls.Add("${Command}:$Distro"); New-RelayResult }
    Invoke-WslAgent -Action RelayStart -DistroName ai-dev
    Invoke-WslAgent -Action RelayStatus -DistroName ai-dev
    Invoke-WslAgent -Action RelayStop -DistroName ai-dev
    Invoke-WslAgent -Action Uninstall -DistroName ai-dev -Yes
    Assert-Relay (($calls -join ',') -ceq 'start:ai-dev,status:ai-dev,stop:ai-dev,stop:ai-dev,uninstall:ai-dev') 'wrong relay scope or uninstall ordering'
}
Test-Relay 'legacy Resume stages current Install and waits before access while NoWait defers forwarding' {
    $calls = New-Object 'System.Collections.Generic.List[string]'
    function Get-WslDistros { @('ai-dev') }
    function Get-WslDistroVersions { [pscustomobject]@{ Distributions = @([pscustomobject]@{Name='ai-dev';Version=2}) } }
    function Get-WslAgentPreparation { [pscustomobject]@{prepared=$true;agent_owned=$true;agent_exists=$true;completed=$true;config=[pscustomobject]@{viewer_port=16080;mcp_port=18931;cdp_port=19222};state=[pscustomobject]@{state='READY_SOFTWARE'}} }
    function Confirm-WslAgentPreparedSystemd { }
    function Send-WslAgentBundle { $calls.Add('stage'); '/fresh/agent.sh' }
    function Invoke-WslAgentCommand { param($Command,$Entry) Assert-Relay ($Command -ceq 'install' -and $Entry -ceq '/fresh/agent.sh') 'legacy alias used old deployed code'; $calls.Add('install'); New-RelayResult }
    function Wait-WslAgentInstall { $calls.Add('wait'); [pscustomobject]@{state='READY_SOFTWARE'} }
    function Complete-WslAgentAccess { $calls.Add('access') }
    Invoke-WslAgent -Action Resume -DistroName ai-dev -NoWait -Yes
    Assert-Relay (($calls -join ',') -ceq 'stage,install') 'NoWait started forwarding before readiness'
    $calls.Clear()
    Invoke-WslAgent -Action Resume -DistroName ai-dev -Yes
    Assert-Relay (($calls -join ',') -ceq 'stage,install,wait,access') 'viewer access setup ran before installation readiness'
}
Test-Relay 'Open verifies access before opening and does not print the fragment token' {
    $calls = New-Object 'System.Collections.Generic.List[string]'
    $token = 'C' * 43
    function Invoke-WslAgentShell { New-RelayResult "http://127.0.0.1:16080/#token=$token" }
    function Ensure-WslAgentAccess { param($Distro,$Address) $calls.Add('verify'); [pscustomobject]@{Address=$Address;Mode='direct'} }
    function Start-Process { param($FilePath) $calls.Add('open'); Assert-Relay ($FilePath.EndsWith($token)) 'token was not supplied privately to the browser' }
    $output = Open-WslAgentDesktop -Distro ai-dev | Out-String
    Assert-Relay (($calls -join ',') -ceq 'verify,open' -and -not $output.Contains($token)) 'Open skipped identity proof or exposed the token'
}

if (-not ('OneDebianRelayHealthFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Net; using System.Net.Sockets; using System.IO; using System.Text;
using System.Threading; using System.Security.Cryptography; using System.Text.RegularExpressions;
public sealed class OneDebianRelayHealthFixture : IDisposable {
    public readonly TcpListener Listener; public readonly Thread Worker; public readonly string Mode, Token;
    public string Request = ""; public int Port { get { return ((IPEndPoint)Listener.LocalEndpoint).Port; } }
    private TcpClient client;
    public OneDebianRelayHealthFixture(string mode, string token) {
        Mode=mode; Token=token; Listener=new TcpListener(IPAddress.Loopback,0); Listener.Start();
        Worker=new Thread(Run); Worker.IsBackground=true; Worker.Start();
    }
    private void Run() {
        try { client=Listener.AcceptTcpClient(); client.ReceiveTimeout=3000;
            using (var stream=client.GetStream()) {
                var reader=new StreamReader(stream,Encoding.ASCII,false,1024,true);
                string line; while((line=reader.ReadLine())!=null && line!="") Request+=line+"\n";
                var match=Regex.Match(Request,"nonce=([a-f0-9]{64})"); string nonce=match.Success?match.Groups[1].Value:"";
                string proof; using(var h=new HMACSHA256(Encoding.ASCII.GetBytes(Token))) {
                    proof=BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes("oneDebian-viewer-v1\n"+Port+"\n"+nonce))).Replace("-","").ToLowerInvariant();
                }
                string body="{\"nonce\":\""+nonce+"\",\"proof\":\""+(Mode=="wrong"?new string('f',64):proof)+"\"}";
                if(Mode=="oversize") body=new string('x',1025);
                string status=Mode=="redirect"?"302 Found":"200 OK";
                string headers="HTTP/1.1 "+status+"\r\nContent-Type: application/json\r\nContent-Length: "+Encoding.UTF8.GetByteCount(body)+"\r\nConnection: close\r\n";
                if(Mode=="redirect") headers+="Location: http://127.0.0.1:1/untrusted\r\n";
                byte[] bytes=Encoding.UTF8.GetBytes(headers+"\r\n"+body); stream.Write(bytes,0,bytes.Length);
            }
        } catch(Exception) { } finally { if(client!=null) client.Close(); }
    }
    public void Dispose() { Listener.Stop(); if(client!=null) client.Close(); Worker.Join(2000); }
}
'@
}
Test-Relay 'viewer proof succeeds without transmitting the fragment token' {
    $token = 'C' * 43
    $server = New-Object OneDebianRelayHealthFixture('correct', $token)
    try {
        Assert-Relay (Test-WslAgentViewerIdentity -Address "http://127.0.0.1:$($server.Port)/#token=$token") 'correct backend proof rejected'
        Assert-Relay ($server.Request.Contains('GET /health?nonce=') -and -not $server.Request.Contains($token)) 'token or fragment entered the HTTP request'
    } finally { $server.Dispose() }
}
Test-Relay 'wrong proof redirects oversized bodies and invalid destinations are rejected' {
    foreach ($mode in @('wrong','redirect','oversize')) {
        $server = New-Object OneDebianRelayHealthFixture($mode, ('C' * 43))
        try { Assert-Relay (-not (Test-WslAgentViewerIdentity -Address "http://127.0.0.1:$($server.Port)/#token=$('C' * 43)")) "unsafe response accepted: $mode" }
        finally { $server.Dispose() }
    }
    Assert-Relay (-not (Test-WslAgentViewerIdentity -Address 'http://evil.example/#token=not-a-token')) 'foreign host accepted'
}
Write-Host "WSL relay controller regressions: $script:relayCount tests, $($script:relayFailures.Count) failures."
if ($script:relayFailures.Count) { throw ($script:relayFailures -join "`n") }
