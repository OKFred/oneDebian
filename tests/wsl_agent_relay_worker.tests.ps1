# Native binary tests use only disposable loopback sockets and C# fixture children.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'components\wsl_common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-relay-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$workers = New-Object System.Collections.Generic.List[Diagnostics.Process]
$clients = New-Object System.Collections.Generic.List[Net.Sockets.TcpClient]
$cases = 0
function Assert-RelayWorker([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Free-RelayPort {
    $socket = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $socket.Start(); try { return $socket.LocalEndpoint.Port } finally { $socket.Stop() }
}
function Fixture-Call([string[]]$Values) {
    $result = Invoke-WslCommand -FilePath $fixture -Arguments $Values -TimeoutMilliseconds 20000
    if ($result.ExitCode -ne 0) { throw "Fixture failed: $($result.ErrorText) $($result.Text)" }
    return $result.Text | ConvertFrom-Json
}
function Start-Fixture([string]$Kind = 'echo', [int]$Viewer = 0, [int]$Mcp = 0) {
    if (-not $Viewer) { $Viewer = Free-RelayPort }
    if (-not $Mcp) { do { $Mcp = Free-RelayPort } while ($Mcp -eq $Viewer) }
    $identity = [guid]::NewGuid().ToString('D'); $state = Join-Path $testRoot "$identity.json"
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $fixture
    $start.Arguments = (@('serve', $identity, $state, [string]$Viewer, [string]$Mcp, $Kind) | ForEach-Object { ConvertTo-WslCommandArgument $_ }) -join ' '
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start); $workers.Add($process)
    $context = [pscustomobject]@{ Guid=$identity; State=$state; Viewer=$Viewer; Mcp=$Mcp; Process=$process }
    $limit = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ($process.HasExited) { throw "Worker exited: $($process.StandardError.ReadToEnd())" }
        if (Test-Path -LiteralPath $state) {
            $status = Fixture-Call @('status',$identity,$state)
            if ($status.running -and $status.ready) { return $context }
        }
        Start-Sleep -Milliseconds 80
    } while ([DateTime]::UtcNow -lt $limit)
    throw 'Worker readiness timed out'
}
function Stop-Fixture($Context) {
    $status = Fixture-Call @('stop',$Context.Guid,$Context.State)
    Assert-RelayWorker (-not $status.running -and -not $status.ready) 'Worker did not stop'
}
function Connect-Fixture([int]$Port) {
    $socket = New-Object Net.Sockets.TcpClient
    $socket.Connect('127.0.0.1',$Port); $socket.ReceiveTimeout=15000; $socket.SendTimeout=15000
    $clients.Add($socket); return $socket
}
function Read-RelayBytes($Stream,[int]$Length) {
    $output = New-Object byte[] $Length; $offset=0
    while ($offset -lt $Length) { $count=$Stream.Read($output,$offset,$Length-$offset); if (-not $count) { throw "Early EOF at $offset/$Length" }; $offset += $count }
    return ,$output
}
function Same-RelayBytes([byte[]]$A,[byte[]]$B) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($hash.ComputeHash($A)) -ceq [Convert]::ToBase64String($hash.ComputeHash($B)) } finally { $hash.Dispose() }
}
try {
    $fixtureSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Threading;
internal static class RelayFixture {
    static RelayConfig Config(string guid,string state) { return new RelayConfig {Guid=guid,Distro="fixture",StatePath=state,SourceSha=new String('a',64)}; }
    static int Main(string[] a) {
        try {
            if(a[0]=="registration") {
                var selected=Config(System.Guid.NewGuid().ToString("D"),"unused");
                selected.CheckRegistration("fixture",2);
                int refused=0;
                try { selected.CheckRegistration("replacement",2); } catch(InvalidOperationException) { refused++; }
                try { selected.CheckRegistration("fixture",1); } catch(InvalidOperationException) { refused++; }
                try { selected.Backend("viewer"); } catch(InvalidOperationException) { refused++; }
                if(refused!=3) throw new Exception("Changed or missing registration was accepted");
                Console.WriteLine("{\"verified\":true}"); return 0;
            }
            if(a[0]=="child") {
                if(a[1]=="fail") return 9;
                Console.Error.WriteLine("ONEDEBIAN_RELAY_READY"); Console.Error.Flush();
                var input=Console.OpenStandardInput(); var output=Console.OpenStandardOutput();
                if(a[1]=="duplex") { byte[] initial=new byte[2*1024*1024]; for(int i=0;i<initial.Length;i++)initial[i]=(byte)(i%251); output.Write(initial,0,initial.Length); output.Flush(); }
                if(a[1]=="hold") { byte[] one=new byte[1]; if(input.Read(one,0,1)>0){output.Write(one,0,1);output.Flush();} while(input.Read(one,0,1)>0){} return 0; }
                if(a[1]=="eof") { using(var all=new MemoryStream()) { input.CopyTo(all); byte[] data=all.ToArray(); output.Write(data,0,data.Length); output.Flush(); } return 0; }
                byte[] buffer=new byte[16384]; int count; while((count=input.Read(buffer,0,buffer.Length))!=0){output.Write(buffer,0,count);output.Flush();} return 0;
            }
            var c=Config(a[1],a[2]);
            if(a[0]=="status" || a[0]=="stop") {
                var state=RelayState.Status(c);
                if(a[0]=="stop" && Convert.ToBoolean(state["running"])) {
                    using(var e=EventWaitHandle.OpenExisting(c.StopName,EventWaitHandleRights.Modify))e.Set();
                    using(var p=Process.GetProcessById(Convert.ToInt32(state["pid"])))p.WaitForExit(10000);
                    state=RelayState.Status(c);
                }
                Console.WriteLine(RelayState.Text(state));return 0;
            }
            c.ViewerPort=Int32.Parse(a[3]); c.McpPort=Int32.Parse(a[4]); string kind=a[5];
            return WslAgentRelay.Run(c, delegate(string service) { return new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName,"child "+(kind=="manual" && service=="mcp" ? "fail" : kind=="manual" ? "echo" : kind)); });
        } catch(Exception e) {Console.Error.WriteLine(e.GetType().Name+": "+e.Message);return 1;}
    }
}
'@
    $source = Join-Path $testRoot 'fixture.cs'; $fixture = Join-Path $testRoot 'relay fixture.exe'
    [IO.File]::WriteAllText($source,$fixtureSource,(New-Object Text.UTF8Encoding($false)))
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $compiler)) { $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    $compiled = & $compiler /nologo /target:exe /main:RelayFixture /reference:System.Web.Extensions.dll "/out:$fixture" (Join-Path $repo 'components\wsl_agent_relay.cs') $source 2>&1 | Out-String
    Assert-RelayWorker ($LASTEXITCODE -eq 0) "Fixture compilation failed: $compiled"
    $production = Join-Path $testRoot 'relay.exe'
    $compiled = & $compiler /nologo /target:winexe /reference:System.Web.Extensions.dll "/out:$production" (Join-Path $repo 'components\wsl_agent_relay.cs') 2>&1 | Out-String
    Assert-RelayWorker ($LASTEXITCODE -eq 0) "Worker compilation failed: $compiled"
    $bytes=[IO.File]::ReadAllBytes($production); $pe=[BitConverter]::ToInt32($bytes,0x3c)
    Assert-RelayWorker ([BitConverter]::ToUInt16($bytes,$pe+92) -eq 2) 'Production worker is not a hidden GUI executable'
    $cases++; Write-Host 'PASS hidden GUI executable compiles with the platform compiler'
    $registration=Fixture-Call @('registration')
    Assert-RelayWorker $registration.verified 'Backend did not recheck its original WSL2 registration'
    $cases++; Write-Host 'PASS backend rechecks missing, renamed and non-WSL2 registrations without registry writes'

    $context=Start-Fixture
    $client=Connect-Fixture $context.Viewer; $stream=$client.GetStream()
    $payload=New-Object byte[] (2MB); (New-Object Random(73)).NextBytes($payload)
    $send=$stream.WriteAsync($payload,0,$payload.Length); $received=Read-RelayBytes $stream $payload.Length; $null=$send.GetAwaiter().GetResult()
    Assert-RelayWorker (Same-RelayBytes $payload $received) 'Binary echo changed bytes'; $client.Close()
    $cases++; Write-Host 'PASS 2 MiB binary data and backpressure'
    $listener=[Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object {$_.Port -in $context.Viewer,$context.Mcp}
    Assert-RelayWorker (@($listener).Count -eq 2 -and @($listener | Where-Object {$_.Address.ToString() -ne '127.0.0.1'}).Count -eq 0) 'Listener escaped IPv4 loopback'
    $cases++; Write-Host 'PASS only the two IPv4 loopback ports are bound'
    Stop-Fixture $context

    $context=Start-Fixture 'eof'; $client=Connect-Fixture $context.Viewer; $stream=$client.GetStream()
    $stream.Write($payload,0,$payload.Length); $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
    $received=Read-RelayBytes $stream $payload.Length
    Assert-RelayWorker (Same-RelayBytes $payload $received) 'Client half-close truncated the backend response'
    Assert-RelayWorker ($stream.ReadByte() -eq -1) 'Backend EOF was not propagated'; $client.Close(); Stop-Fixture $context
    $cases++; Write-Host 'PASS write-half-close preserves the complete response and EOF'

    $context=Start-Fixture 'duplex'; $client=Connect-Fixture $context.Mcp; $stream=$client.GetStream()
    $send=$stream.WriteAsync($payload,0,$payload.Length); $initial=Read-RelayBytes $stream $payload.Length; $received=Read-RelayBytes $stream $payload.Length; $null=$send.GetAwaiter().GetResult()
    Assert-RelayWorker ($initial[0] -eq 0 -and $initial[250] -eq 250 -and (Same-RelayBytes $payload $received)) 'Full duplex stream stalled or changed bytes'
    $client.Close(); Stop-Fixture $context; $cases++; Write-Host 'PASS simultaneous large streams in both directions'

    $context=Start-Fixture 'manual'; $status=Fixture-Call @('status',$context.Guid,$context.State)
    Assert-RelayWorker ($status.ready -and -not $status.mcp_backend_ready) 'Manual mode blocked the viewer worker'
    $client=Connect-Fixture $context.Viewer; $stream=$client.GetStream(); $stream.WriteByte(42); Assert-RelayWorker ($stream.ReadByte() -eq 42) 'Manual mode viewer is unavailable'; $client.Close(); Stop-Fixture $context
    $cases++; Write-Host 'PASS viewer remains available when manual mode stops MCP'

    $busy=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $busy.Start(); $busyPort=$busy.LocalEndpoint.Port; $free=Free-RelayPort
    try {
        $failed=$false; try { $null=Start-Fixture 'echo' $free $busyPort } catch {$failed=$true}
        Assert-RelayWorker $failed 'Occupied second port was accepted'
        $reuse=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$free); $reuse.Start(); $reuse.Stop()
    } finally {$busy.Stop()}
    $cases++; Write-Host 'PASS an occupied port rolls back the other bind'

    $context=Start-Fixture 'hold'; $held=New-Object System.Collections.Generic.List[Net.Sockets.TcpClient]
    for($i=0;$i -lt 16;$i++){ $c=Connect-Fixture $context.Viewer; $held.Add($c); $c.GetStream().WriteByte(1); Assert-RelayWorker ($c.GetStream().ReadByte() -eq 1) 'Backend did not confirm its active job assignment' }
    $limit=[DateTime]::UtcNow.AddSeconds(10)
    do { $childCount=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($context.Process.Id)" | Where-Object {$_.ExecutablePath -eq $fixture}).Count; if($childCount -eq 16){break}; Start-Sleep -Milliseconds 100 } while([DateTime]::UtcNow -lt $limit)
    Assert-RelayWorker ($childCount -eq 16) "Expected 16 bounded backends, found $childCount"
    $excess=Connect-Fixture $context.Viewer
    Assert-RelayWorker ($excess.GetStream().ReadByte() -eq -1) 'Excess connection was not refused'; $excess.Close()
    $children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($context.Process.Id)" | Where-Object {$_.ExecutablePath -eq $fixture} | Select-Object -ExpandProperty ProcessId)
    Stop-Fixture $context
    Start-Sleep -Milliseconds 250
    Assert-RelayWorker (@($children | Where-Object {Get-Process -Id $_ -ErrorAction SilentlyContinue}).Count -eq 0) 'Owned backend children survived stop'
    $cases++; Write-Host 'PASS 16-connection bound and scoped child cleanup'

    $context=Start-Fixture 'hold'; $client=Connect-Fixture $context.Viewer; $client.GetStream().WriteByte(1); Assert-RelayWorker ($client.GetStream().ReadByte() -eq 1) 'Crash fixture backend did not start'
    $children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($context.Process.Id)" | Where-Object {$_.ExecutablePath -eq $fixture} | Select-Object -ExpandProperty ProcessId)
    Assert-RelayWorker ($children.Count -eq 1) "Crash cleanup test requires one confirmed owned child, found $($children.Count)"
    $context.Process.Kill(); $context.Process.WaitForExit(); Start-Sleep -Milliseconds 300
    Assert-RelayWorker (@($children | Where-Object {Get-Process -Id $_ -ErrorAction SilentlyContinue}).Count -eq 0) 'Job object failed to clean children after a worker crash'
    $status=Fixture-Call @('status',$context.Guid,$context.State)
    Assert-RelayWorker (-not $status.running -and -not $status.ready) 'Stale metadata was reported ready'
    $cases++; Write-Host 'PASS crash cleanup and stale readiness rejection'

    $context=Start-Fixture; $data=Get-Content -Raw -LiteralPath $context.State | ConvertFrom-Json; $saved=$data.source_sha; $data.source_sha=('b'*64); [IO.File]::WriteAllText($context.State,($data|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    $refused=$false; try { $null=Fixture-Call @('stop',$context.Guid,$context.State) } catch {$refused=$true}
    Assert-RelayWorker ($refused -and -not $context.Process.HasExited) 'Foreign source identity was allowed to stop a worker'
    $data.source_sha=$saved; [IO.File]::WriteAllText($context.State,($data|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    Stop-Fixture $context; $cases++; Write-Host 'PASS source identity mismatch refuses control without stopping the worker'

    $context=Start-Fixture; $data=Get-Content -Raw -LiteralPath $context.State | ConvertFrom-Json; $data.start_ticks='1'; [IO.File]::WriteAllText($context.State,($data|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    $status=Fixture-Call @('status',$context.Guid,$context.State)
    Assert-RelayWorker (-not $status.running) 'Reused PID metadata was accepted'
    # Restore only this test's own known identity so its ordinary scoped stop is exercised.
    $data.start_ticks=$context.Process.StartTime.ToUniversalTime().Ticks.ToString(); [IO.File]::WriteAllText($context.State,($data|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    Stop-Fixture $context; $cases++; Write-Host 'PASS PID/start-time ownership must match'

    Write-Host "WSL relay worker regressions: $cases tests, 0 failures."
}
finally {
    foreach($client in $clients){$client.Close()}
    foreach($worker in $workers){try{if(-not $worker.HasExited){$worker.Kill();$worker.WaitForExit()}}catch{};$worker.Dispose()}
    $resolved=[IO.Path]::GetFullPath($testRoot); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^onedebian-relay-tests-[a-f0-9]{32}$'){throw 'Unsafe test cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
