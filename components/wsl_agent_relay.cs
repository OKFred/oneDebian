using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("oneDebian Agent loopback relay v1")]

internal sealed class RelayConfig
{
    internal string Guid, Distro, StatePath, SourceSha;
    internal int ViewerPort, McpPort;
    internal bool McpReady;
    internal readonly string Sid = WindowsIdentity.GetCurrent().User.Value;
    internal readonly int Session = Process.GetCurrentProcess().SessionId;
    internal string Id
    {
        get
        {
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Sid + "|" + Session + "|" + Guid))).Replace("-", "").ToLowerInvariant();
        }
    }
    internal string MutexName { get { return "Local\\oneDebian-Agent-Relay-" + Id; } }
    internal string StopName { get { return MutexName + "-stop"; } }
    internal string ReadyName { get { return MutexName + "-ready"; } }

    internal static RelayConfig Parse(string[] args)
    {
        bool run = args.Length > 0 && args[0] == "run";
        if ((!run && (args.Length != 4 || (args[0] != "status" && args[0] != "stop"))) || (run && args.Length != 7))
            throw new ArgumentException("Expected run GUID distro viewerPort mcpPort statePath sourceSha, or status|stop GUID statePath sourceSha");
        var c = new RelayConfig();
        c.Guid = new Guid(args[1]).ToString("D").ToLowerInvariant();
        c.StatePath = Path.GetFullPath(args[run ? 5 : 2]);
        c.SourceSha = args[run ? 6 : 3];
        if (!Regex.IsMatch(c.SourceSha, "\\A[a-f0-9]{64}\\z")) throw new ArgumentException("Invalid source SHA256");
        c.Distro = c.ReadRegistration();
        if (run)
        {
            if (!String.Equals(c.Distro, args[2], StringComparison.Ordinal)) throw new InvalidOperationException("Distro does not match its registration");
            c.ViewerPort = Port(args[3]); c.McpPort = Port(args[4]);
            if (c.ViewerPort == c.McpPort) throw new ArgumentException("Relay ports must differ");
        }
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".oneDebian") + Path.DirectorySeparatorChar;
        if (!c.StatePath.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("State must be inside the current user's .oneDebian directory");
        RelayState.CheckPath(c.StatePath);
        return c;
    }
    private static int Port(string text)
    {
        int port;
        if (!Int32.TryParse(text, out port) || port < 1024 || port > 65535) throw new ArgumentException("Invalid relay port");
        return port;
    }

    internal ProcessStartInfo Backend(string kind)
    {
        // Names can be reused after unregistering; never forward to a replacement registration.
        ReadRegistration();
        string wsl = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wsl.exe");
        string[] values = { "--distribution", Distro, "--user", "agent", "--exec", "/usr/bin/python3", "/opt/onedebian-agent/relay.py", kind };
        var quoted = new List<string>();
        foreach (string value in values) quoted.Add(Quote(value));
        return new ProcessStartInfo(wsl, String.Join(" ", quoted));
    }
    private string ReadRegistration()
    {
        using (var key = Registry.CurrentUser.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss\\{" + Guid + "}"))
        {
            if (key == null) throw new InvalidOperationException("The WSL registration no longer exists");
            return CheckRegistration(key.GetValue("DistributionName") as string, Convert.ToInt32(key.GetValue("Version", 0)));
        }
    }
    internal string CheckRegistration(string name, int version)
    {
        if (version != 2) throw new InvalidOperationException("The relay requires a verified WSL2 registration");
        if (String.IsNullOrWhiteSpace(name)) throw new InvalidOperationException("Invalid WSL registration");
        if (Distro != null && !String.Equals(Distro, name, StringComparison.Ordinal)) throw new InvalidOperationException("The WSL registration name changed");
        return name;
    }
    internal static string Quote(string value)
    {
        if (value.IndexOf('\0') >= 0) throw new ArgumentException("NUL argument");
        if (value.Length > 0 && !Regex.IsMatch(value, "[\\s\"]")) return value;
        value = Regex.Replace(value, "(\\\\*)\"", "$1$1\\\"");
        value = Regex.Replace(value, "(\\\\+)$", "$1$1");
        return "\"" + value + "\"";
    }
}

internal static class RelayState
{
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    internal static void CheckPath(string path)
    {
        for (string part = path; !String.IsNullOrEmpty(part); part = Path.GetDirectoryName(part))
            if ((File.Exists(part) || Directory.Exists(part)) && (File.GetAttributes(part) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Relay state path must not contain reparse points");
    }
    internal static string Text(object value) { return Json.Serialize(value); }
    internal static Dictionary<string, object> Snapshot(RelayConfig c, bool ready, string error)
    {
        using (var p = Process.GetCurrentProcess())
            return new Dictionary<string, object> {
                {"running", true}, {"ready", ready}, {"registration_guid", c.Guid}, {"distro", c.Distro},
                {"viewer_port", c.ViewerPort}, {"mcp_port", c.McpPort}, {"pid", p.Id},
                {"start_ticks", p.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture)},
                {"source_sha", c.SourceSha}, {"exe", p.MainModule.FileName}, {"owner_sid", c.Sid},
                {"session_id", c.Session}, {"mcp_backend_ready", c.McpReady}, {"error", error}
            };
    }
    internal static void Write(RelayConfig c, bool ready, string error)
    {
        CheckPath(c.StatePath);
        Directory.CreateDirectory(Path.GetDirectoryName(c.StatePath));
        string temporary = c.StatePath + "." + System.Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, Text(Snapshot(c, ready, error)), new UTF8Encoding(false));
            var acl = new FileSecurity();
            acl.SetOwner(new SecurityIdentifier(c.Sid)); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(c.Sid), FileSystemRights.FullControl, AccessControlType.Allow));
            File.SetAccessControl(temporary, acl);
            if (File.Exists(c.StatePath)) { Read(c); File.Replace(temporary, c.StatePath, null); }
            else File.Move(temporary, c.StatePath);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    internal static Dictionary<string, object> Read(RelayConfig c)
    {
        try { return ReadExisting(c); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
    private static Dictionary<string, object> ReadExisting(RelayConfig c)
    {
        CheckPath(c.StatePath);
        if (!File.Exists(c.StatePath)) return null;
        var acl = File.GetAccessControl(c.StatePath);
        if (!String.Equals(acl.GetOwner(typeof(SecurityIdentifier)).Value, c.Sid, StringComparison.Ordinal))
            throw new InvalidOperationException("Foreign relay state owner");
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow && rule.IdentityReference.Value != c.Sid)
                throw new InvalidOperationException("Relay state is not private to the current user");
        var info = new FileInfo(c.StatePath);
        if (info.Length > 16384) throw new InvalidOperationException("Oversized relay state");
        Dictionary<string, object> data;
        using (var file = new FileStream(c.StatePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(file, Encoding.UTF8)) data = Json.Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
        if ((string)data["owner_sid"] != c.Sid || Convert.ToInt32(data["session_id"]) != c.Session || (string)data["registration_guid"] != c.Guid
            || (string)data["distro"] != c.Distro || (string)data["source_sha"] != c.SourceSha
            || !String.Equals((string)data["exe"], Process.GetCurrentProcess().MainModule.FileName, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Relay state identity or version mismatch");
        return data;
    }
    internal static Dictionary<string, object> Status(RelayConfig c)
    {
        var data = Read(c);
        if (data == null) return new Dictionary<string, object> {{"running", false}, {"ready", false}};
        bool running = false, signalled = false;
        try
        {
            using (var process = Process.GetProcessById(Convert.ToInt32(data["pid"])))
            using (var mutex = Mutex.OpenExisting(c.MutexName))
            using (var stop = EventWaitHandle.OpenExisting(c.StopName, EventWaitHandleRights.Synchronize))
            using (var ready = EventWaitHandle.OpenExisting(c.ReadyName, EventWaitHandleRights.Synchronize))
            {
                running = !process.HasExited && process.SessionId == c.Session && process.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture) == (string)data["start_ticks"]
                    && String.Equals(process.MainModule.FileName, (string)data["exe"], StringComparison.OrdinalIgnoreCase) && !stop.WaitOne(0);
                signalled = ready.WaitOne(0);
            }
        }
        catch (ArgumentException) { }
        catch (WaitHandleCannotBeOpenedException) { }
        data["running"] = running;
        data["ready"] = running && signalled && Convert.ToBoolean(data["ready"]);
        return data;
    }
}

internal sealed class RelayJob : IDisposable
{
    private IntPtr handle;
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimit { public long PerProcess, PerJob; public uint Flags; public UIntPtr Minimum, Maximum; public uint ActiveProcesses; public UIntPtr Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong ReadOp, WriteOp, OtherOp, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimit { public BasicLimit Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int type, IntPtr data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    internal RelayJob()
    {
        handle = CreateJobObject(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        var limit = new ExtendedLimit(); limit.Basic.Flags = 0x2000; // Kill only our child launchers when this worker exits.
        int size = Marshal.SizeOf(limit); IntPtr data = Marshal.AllocHGlobal(size);
        try { Marshal.StructureToPtr(limit, data, false); if (!SetInformationJobObject(handle, 9, data, (uint)size)) throw new System.ComponentModel.Win32Exception(); }
        catch { Dispose(); throw; }
        finally { Marshal.FreeHGlobal(data); }
    }
    internal void Add(Process process) { if (!AssignProcessToJobObject(handle, process.Handle)) throw new System.ComponentModel.Win32Exception(); }
    public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
}

internal sealed class RelayServer : IDisposable
{
    private readonly RelayConfig config;
    private readonly Func<string, ProcessStartInfo> backend;
    private readonly RelayJob job = new RelayJob();
    private readonly List<TcpClient> clients = new List<TcpClient>();
    private readonly List<Process> children = new List<Process>();
    private readonly SemaphoreSlim slots = new SemaphoreSlim(16);
    private TcpListener viewer, mcp;
    private volatile bool stopped;
    internal Action<bool> McpAvailability;
    internal bool Stopped { get { return stopped; } }
    internal readonly ManualResetEvent Failed = new ManualResetEvent(false);
    internal RelayServer(RelayConfig c, Func<string, ProcessStartInfo> factory) { config = c; backend = factory; }
    internal void Bind()
    {
        try
        {
            viewer = new TcpListener(IPAddress.Loopback, config.ViewerPort); viewer.Start(16);
            mcp = new TcpListener(IPAddress.Loopback, config.McpPort); mcp.Start(16);
        }
        catch { Dispose(); throw; }
    }
    private Process Start(string kind)
    {
        var start = backend(kind);
        start.UseShellExecute = false; start.CreateNoWindow = true;
        start.RedirectStandardInput = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
        var process = new Process {StartInfo = start};
        try
        {
            if (!process.Start()) throw new IOException("Backend launcher did not start");
            lock (children) { if (stopped) throw new IOException("Relay stopped"); children.Add(process); }
            job.Add(process);
            return process;
        }
        catch { lock (children) children.Remove(process); Kill(process); throw; }
    }
    private static async Task Drain(Stream stream)
    {
        try
        {
            byte[] buffer = new byte[1024];
            while (await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false) != 0) { }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }
    private static async Task Handshake(Process process)
    {
        // Only stderr carries the bounded startup acknowledgement; stdout is untouched binary data.
        var stream = process.StandardError.BaseStream;
        byte[] line = new byte[80]; int length = 0;
        while (length < line.Length)
        {
            byte[] next = new byte[1];
            if (await stream.ReadAsync(next, 0, 1).ConfigureAwait(false) == 0) throw new IOException("Backend exited before readiness");
            if (next[0] == 10) break;
            line[length++] = next[0];
        }
        if (Encoding.ASCII.GetString(line, 0, length).TrimEnd('\r') != "ONEDEBIAN_RELAY_READY") throw new IOException("Unexpected backend acknowledgement");
    }
    private static async Task Ready(Process process)
    {
        Task ack = Handshake(process);
        if (await Task.WhenAny(ack, Task.Delay(15000)).ConfigureAwait(false) != ack) throw new TimeoutException("Backend readiness timed out");
        await ack.ConfigureAwait(false);
    }
    internal async Task Preflight()
    {
        foreach (string kind in new[] {"viewer", "mcp"})
        {
            Process process = null;
            try { process = Start(kind); await Ready(process).ConfigureAwait(false); if (kind == "mcp") config.McpReady = true; }
            catch (Exception) { if (kind != "mcp") throw; config.McpReady = false; }
            finally { if (process != null) { Kill(process); lock (children) children.Remove(process); } }
        }
    }
    internal void Accept()
    {
        AcceptLoop(viewer, "viewer"); AcceptLoop(mcp, "mcp");
    }
    private async void AcceptLoop(TcpListener listener, string kind)
    {
        try
        {
            while (!stopped)
            {
                TcpClient client = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
                if (!slots.Wait(0)) { client.Close(); continue; }
                lock (clients) { if (stopped) { client.Close(); slots.Release(); break; } clients.Add(client); }
                Handle(client, kind);
            }
        }
        catch (ObjectDisposedException) { }
        catch (SocketException) { if (!stopped) { Failed.Set(); Dispose(); } }
    }
    private static async Task Copy(Stream source, Stream target)
    {
        byte[] buffer = new byte[16384]; int size;
        while ((size = await source.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) != 0)
        {
            await target.WriteAsync(buffer, 0, size).ConfigureAwait(false);
            // Process stdin is buffered; short HTTP/WebSocket frames must not wait for EOF.
            await target.FlushAsync().ConfigureAwait(false);
        }
    }
    private async void Handle(TcpClient client, string kind)
    {
        Process process = null;
        bool connected = false;
        try
        {
            client.NoDelay = true;
            process = Start(kind); await Ready(process).ConfigureAwait(false);
            connected = true;
            if (kind == "mcp" && McpAvailability != null) McpAvailability(true);
            Task stderr = Drain(process.StandardError.BaseStream);
            var network = client.GetStream();
            Task upload = Upload(network, process);
            Task download = Copy(process.StandardOutput.BaseStream, network);
            Task first = await Task.WhenAny(upload, download).ConfigureAwait(false);
            await first.ConfigureAwait(false);
            if (first == download) client.Close();
            // A client may close only its write side and still be waiting for the response.
            await download.ConfigureAwait(false);
            try { client.Client.Shutdown(SocketShutdown.Send); } catch (SocketException) { } catch (ObjectDisposedException) { }
            client.Close();
            try { await upload.ConfigureAwait(false); } catch (IOException) { } catch (ObjectDisposedException) { }
            GC.KeepAlive(stderr);
        }
        catch (Exception)
        {
            if (!connected && kind == "mcp" && McpAvailability != null) McpAvailability(false);
            // Connection failures affect only this byte stream; never log its contents.
        }
        finally
        {
            client.Close(); lock (clients) clients.Remove(client);
            if (process != null) { Kill(process); lock (children) children.Remove(process); }
            slots.Release();
        }
    }
    private static async Task Upload(Stream stream, Process process)
    {
        try { await Copy(stream, process.StandardInput.BaseStream).ConfigureAwait(false); }
        finally { process.StandardInput.Close(); }
    }
    private static void Kill(Process process)
    {
        try { process.StandardInput.Close(); } catch (Exception) { }
        try { if (!process.WaitForExit(500)) { process.Kill(); process.WaitForExit(2000); } } catch (InvalidOperationException) { }
        process.Dispose();
    }
    public void Dispose()
    {
        if (stopped) return; stopped = true;
        if (viewer != null) viewer.Stop(); if (mcp != null) mcp.Stop();
        lock (clients) foreach (var client in clients.ToArray()) client.Close();
        lock (children) foreach (var child in children.ToArray()) { try { child.Kill(); } catch (InvalidOperationException) { } }
        job.Dispose();
    }
}

internal static class WslAgentRelay
{
    private static int Main(string[] args)
    {
        try
        {
            var config = RelayConfig.Parse(args);
            if (args[0] != "run")
            {
                var status = RelayState.Status(config);
                if (args[0] == "stop" && Convert.ToBoolean(status["running"]))
                {
                    using (var stop = EventWaitHandle.OpenExisting(config.StopName, EventWaitHandleRights.Modify)) stop.Set();
                    using (var process = Process.GetProcessById(Convert.ToInt32(status["pid"]))) process.WaitForExit(10000);
                    status = RelayState.Status(config);
                }
                Console.WriteLine(RelayState.Text(status));
                return args[0] == "stop" && Convert.ToBoolean(status["running"]) ? 1 : 0;
            }
            return Run(config, config.Backend);
        }
        catch (Exception error) { Console.Error.WriteLine("oneDebian relay: " + error.Message); return 1; }
    }
    internal static int Run(RelayConfig c, Func<string, ProcessStartInfo> factory)
    {
        var sid = new SecurityIdentifier(c.Sid);
        var mutexAcl = new MutexSecurity(); mutexAcl.AddAccessRule(new MutexAccessRule(sid, MutexRights.FullControl, AccessControlType.Allow));
        var eventAcl = new EventWaitHandleSecurity(); eventAcl.AddAccessRule(new EventWaitHandleAccessRule(sid, EventWaitHandleRights.FullControl, AccessControlType.Allow));
        bool created;
        using (var mutex = new Mutex(true, c.MutexName, out created, mutexAcl))
        {
            if (!created) throw new InvalidOperationException("An instance already owns this relay identity");
            try
            {
                using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, c.StopName, out created, eventAcl))
                {
                    if (!created) throw new InvalidOperationException("A foreign stop event already exists");
                    using (var ready = new EventWaitHandle(false, EventResetMode.ManualReset, c.ReadyName, out created, eventAcl))
                    using (var server = new RelayServer(c, factory))
                    {
                        if (!created) throw new InvalidOperationException("A foreign readiness event already exists");
                        RelayState.Write(c, false, null);
                        server.McpAvailability = delegate(bool available) { lock (c) { if (!server.Stopped && c.McpReady != available) { c.McpReady = available; RelayState.Write(c, true, null); } } };
                        string error = null;
                        try
                        {
                            server.Bind(); server.Preflight().GetAwaiter().GetResult();
                            RelayState.Write(c, true, null); ready.Set(); server.Accept();
                            if (WaitHandle.WaitAny(new WaitHandle[] {stop, server.Failed}) == 1) throw new IOException("Relay listener failed");
                        }
                        catch (Exception failure) { error = failure.Message; throw; }
                        finally { lock (c) { ready.Reset(); server.Dispose(); RelayState.Write(c, false, error); } }
                    }
                }
                return 0;
            }
            finally { mutex.ReleaseMutex(); }
        }
    }
}
