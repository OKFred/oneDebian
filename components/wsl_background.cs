using System;
using System.Diagnostics;

[assembly: System.Reflection.AssemblyTitle("oneDebian WSL background launcher v1")]

internal static class WslBackground
{
    private static int Main(string[] args)
    {
        if (args.Length != 2) return 2;
        try
        {
            var start = new ProcessStartInfo(args[0], args[1]);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            using (var process = Process.Start(start))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch
        {
            return 1;
        }
    }
}
