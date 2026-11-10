# Current-user WSL startup and residency. Dot-sourcing never changes task/WSL state.
# Requires wsl_common.ps1 for native command capture and Windows argument quoting.

function Get-WslLifecycleKeeperScript {
    # TERM releases only this shell's own sleep child; no global WSL shutdown.
    return 'child=; finish() { if [ -n "$child" ]; then kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi; exit 0; }; trap finish TERM INT HUP; while :; do /bin/sleep 86400 & child=$!; wait "$child"; child=; done'
}

function Get-WslLifecycleBackgroundArguments {
    param([string]$Executable, [string]$Arguments)
    # Wait for WSL so Task Scheduler tracks residency and receives its exit code.
    $script = @(
        '$ErrorActionPreference = ''Stop'''
        'try {'
        '    $start = New-Object System.Diagnostics.ProcessStartInfo'
        "    `$start.FileName = '$($Executable.Replace("'", "''"))'"
        "    `$start.Arguments = '$($Arguments.Replace("'", "''"))'"
        '    $start.UseShellExecute = $false'
        '    $start.CreateNoWindow = $true'
        '    $process = [System.Diagnostics.Process]::Start($start)'
        '    $process.WaitForExit()'
        '    exit $process.ExitCode'
        '} catch { exit 1 }'
    ) -join "`n"
    return '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
}

function Initialize-WslLifecycleLauncher {
    param($Context)
    if (-not (Test-Path -LiteralPath $Context.LauncherExe)) {
        $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Context.LauncherExe) -Force -ErrorAction Stop
        $build = Invoke-WslCommand -FilePath $compiler -Arguments @('/nologo', '/target:winexe', '/platform:anycpu', "/out:$($Context.LauncherExe)", (Join-Path $PSScriptRoot 'wsl_background.cs')) -TimeoutMilliseconds 30000
        if ($build.ExitCode -ne 0) { throw "The background launcher build failed: $($build.Text) $($build.ErrorText)" }
    }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Context.LauncherExe)
    if ($info.FileDescription -cne 'oneDebian WSL background launcher v1') { throw 'An unrecognized background launcher exists; it was not replaced.' }
}

function Get-WslLifecycleContext {
    param([Parameter(Mandatory = $true)][string]$DistroName)
    $inventory = Get-WslDistroVersions
    $registered = @($inventory.Distributions | Where-Object { $_.Name -eq $DistroName -and ($_.Known -or $_.Source -eq 'Registry') })
    if ($registered.Count -ne 1) { throw 'The selected distribution registration could not be verified.' }
    $name = [string]$registered[0].Name
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid + '|' + $name.ToUpperInvariant()))
        $token = ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $wslExe = (Get-Command wsl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $start = @('--distribution', $name, '--exec', '/bin/true')
    $resident = @('--distribution', $name, '--exec', '/bin/sh', '-c', (Get-WslLifecycleKeeperScript), "onedebian-$token")
    $startArguments = (($start | ForEach-Object { ConvertTo-WslCommandArgument $_ }) -join ' ')
    $residentArguments = (($resident | ForEach-Object { ConvertTo-WslCommandArgument $_ }) -join ' ')
    return [pscustomobject]@{
        DistroName = $name; Sid = $sid; Token = $token; WslExe = $wslExe
        TaskName = "oneDebian-WSL-$token"; TaskPath = '\'
        Description = "oneDebian WSL lifecycle v1; owner=$sid; instance=$token"
        StartArguments = $startArguments; ResidentArguments = $residentArguments
        BackgroundExe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        BackgroundStartArguments = (Get-WslLifecycleBackgroundArguments -Executable $wslExe -Arguments $startArguments)
        BackgroundResidentArguments = (Get-WslLifecycleBackgroundArguments -Executable $wslExe -Arguments $residentArguments)
        # MSIX apps redirect LocalAppData writes away from the Task Scheduler.
        LauncherExe = (Join-Path $env:USERPROFILE '.oneDebian\bin\wsl-background-v1.exe')
        LauncherStartArguments = ((ConvertTo-WslCommandArgument $wslExe) + ' ' + (ConvertTo-WslCommandArgument $startArguments))
        LauncherResidentArguments = ((ConvertTo-WslCommandArgument $wslExe) + ' ' + (ConvertTo-WslCommandArgument $residentArguments))
    }
}

function Resolve-WslLifecycleTaskSid {
    param([string]$UserId)
    if ($UserId -match '^S-1-\d+(?:-\d+)+$') { return $UserId }
    try {
        $account = New-Object Security.Principal.NTAccount($UserId)
        return $account.Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

function Test-WslLifecycleTaskOwnership {
    param($Task, $Context)
    if ($null -eq $Task) { return $false }
    $actions = @($Task.Actions | Where-Object { $null -ne $_ })
    $triggers = @($Task.Triggers | Where-Object { $null -ne $_ })
    $direct = $actions.Count -eq 1 -and $actions[0].Execute -ieq $Context.WslExe -and
        $actions[0].Arguments -cin @($Context.StartArguments, $Context.ResidentArguments)
    $background = $actions.Count -eq 1 -and $actions[0].Execute -ieq $Context.BackgroundExe -and
        $actions[0].Arguments -cin @($Context.BackgroundStartArguments, $Context.BackgroundResidentArguments)
    $native = $actions.Count -eq 1 -and $actions[0].Execute -ieq $Context.LauncherExe -and
        $actions[0].Arguments -cin @($Context.LauncherStartArguments, $Context.LauncherResidentArguments)
    if ($Task.TaskName -cne $Context.TaskName -or $Task.TaskPath -cne $Context.TaskPath -or
        $Task.Description -cne $Context.Description -or -not ($direct -or $background -or $native) -or
        (Resolve-WslLifecycleTaskSid -UserId $Task.Principal.UserId) -ine $Context.Sid -or
        [string]$Task.Principal.LogonType -notin @('Interactive', '3') -or
        [string]$Task.Principal.RunLevel -notin @('Limited', '0') -or $triggers.Count -gt 1) { return $false }
    if ($triggers.Count -eq 1 -and
        ($triggers[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger' -or
            (Resolve-WslLifecycleTaskSid -UserId $triggers[0].UserId) -ine $Context.Sid)) { return $false }
    return $true
}

function Get-WslLifecycleTask {
    param($Context)
    # Listing the folder distinguishes an absent task from access/query failure.
    $tasks = @(Get-ScheduledTask -TaskPath $Context.TaskPath -ErrorAction Stop | Where-Object { $_.TaskName -ceq $Context.TaskName })
    if ($tasks.Count -eq 0) { return $null }
    if ($tasks.Count -ne 1 -or -not (Test-WslLifecycleTaskOwnership -Task $tasks[0] -Context $Context)) {
        throw 'A task with this name exists but is not the verified oneDebian task. No changes were made to it.'
    }
    return $tasks[0]
}

function Get-WslLifecycleTaskPolicy {
    param($Task, $Context)
    $resident = $null -ne $Task -and $Task.Actions[0].Arguments -cin @($Context.ResidentArguments, $Context.BackgroundResidentArguments, $Context.LauncherResidentArguments)
    return [pscustomobject]@{
        Known = $true
        Autostart = ($null -ne $Task -and @($Task.Triggers | Where-Object { $null -ne $_ }).Count -eq 1 -and $Task.Settings.Enabled)
        KeepAlive = $resident
        ResidentRunning = ($resident -and [string]$Task.State -eq 'Running')
        Error = $null
    }
}

function Get-WslDistroLifecycle {
    param([Parameter(Mandatory = $true)][string]$DistroName)
    try {
        $context = Get-WslLifecycleContext -DistroName $DistroName
        $task = Get-WslLifecycleTask -Context $context
        return Get-WslLifecycleTaskPolicy -Task $task -Context $context
    } catch {
        return [pscustomobject]@{ Known = $false; Autostart = $false; KeepAlive = $false; ResidentRunning = $false; Error = $_.Exception.Message }
    }
}

function Set-WslLifecycleTask {
    param($Context, [bool]$Autostart, [bool]$KeepAlive)
    $existing = Get-WslLifecycleTask -Context $Context
    if (-not $Autostart -and -not $KeepAlive) {
        if ($null -ne $existing) {
            Unregister-ScheduledTask -TaskName $Context.TaskName -TaskPath $Context.TaskPath -Confirm:$false -ErrorAction Stop
        }
        if ($null -ne (Get-WslLifecycleTask -Context $Context)) { throw 'The startup task removal could not be verified.' }
        return
    }
    Initialize-WslLifecycleLauncher -Context $Context
    $arguments = if ($KeepAlive) { $Context.LauncherResidentArguments } else { $Context.LauncherStartArguments }
    $action = New-ScheduledTaskAction -Execute $Context.LauncherExe -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId $Context.Sid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $definition = @{ Action = $action; Principal = $principal; Settings = $settings; Description = $Context.Description }
    if ($Autostart) { $definition.Trigger = New-ScheduledTaskTrigger -AtLogOn -User $Context.Sid }
    $task = New-ScheduledTask @definition
    $null = Register-ScheduledTask -TaskName $Context.TaskName -TaskPath $Context.TaskPath -InputObject $task -Force -ErrorAction Stop
    $verified = Get-WslLifecycleTask -Context $Context
    if ($null -eq $verified) { throw 'The task registration could not be verified.' }
    $policy = Get-WslLifecycleTaskPolicy -Task $verified -Context $Context
    if ($policy.Autostart -ne $Autostart -or $policy.KeepAlive -ne $KeepAlive -or -not $verified.Settings.Enabled -or
        $verified.Actions[0].Execute -ine $Context.LauncherExe -or $verified.Actions[0].Arguments -cne $arguments -or
        [string]$verified.Settings.ExecutionTimeLimit -notin @('PT0S', 'PT0H0M0S') -or
        [string]$verified.Settings.MultipleInstances -notin @('IgnoreNew', '2')) { throw 'The registered task settings do not match the requested policy.' }
}

function Get-WslDistroRunningState {
    param([Parameter(Mandatory = $true)][string]$DistroName)
    $command = Invoke-WslCommand -Arguments @('--list', '--running', '--quiet') -TimeoutMilliseconds 15000
    if ($command.ExitCode -ne 0 -or -not $command.IsDecoded) { return [pscustomobject]@{ Known = $false; Running = $false } }
    $names = @($command.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # Quiet output is trusted only when every line matches a registered name.
    $inventory = Get-WslDistroVersions
    $registeredNames = @($inventory.Distributions | ForEach-Object { $_.Name })
    $namesVerified = $inventory.Known -or $inventory.Source -eq 'Registry'
    if (-not $namesVerified -or $DistroName -notin $registeredNames -or @($names | Where-Object { $_ -notin $registeredNames }).Count -gt 0) {
        return [pscustomobject]@{ Known = $false; Running = $false }
    }
    return [pscustomobject]@{ Known = $true; Running = ($DistroName -in $names) }
}

function Get-WslLifecycleKeeperSignature {
    param($Context)
    # Match the entire /proc argv byte sequence, not a substring or PID file.
    $argv = "/bin/sh`0-c`0$(Get-WslLifecycleKeeperScript)`0onedebian-$($Context.Token)`0"
    return ([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($argv))).Replace('-', '').ToLowerInvariant()
}

function Get-WslLifecycleKeeperState {
    param($Context)
    $probe = 'expected=EXPECTED; for path in /proc/[0-9]*/cmdline; do [ -r "$path" ] || continue; actual=$(od -An -v -tx1 "$path" 2>/dev/null | tr -d " \n"); [ "$actual" != "$expected" ] || { printf __ONEDEBIAN_KEEPER_RUNNING__; exit 0; }; done; printf __ONEDEBIAN_KEEPER_ABSENT__'
    $probe = $probe.Replace('EXPECTED', (Get-WslLifecycleKeeperSignature -Context $Context))
    $command = Invoke-WslShellScript -Arguments @('--distribution', $Context.DistroName, '--exec', '/bin/sh', '-c', $probe) -TimeoutMilliseconds 15000
    $marker = $command.Text.Trim()
    $known = $command.ExitCode -eq 0 -and $command.IsDecoded -and $marker -in @('__ONEDEBIAN_KEEPER_RUNNING__', '__ONEDEBIAN_KEEPER_ABSENT__')
    $errorText = $null
    if (-not $known) {
        $detail = (@($command.ErrorText, $command.Text) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join "`n"
        if (-not $command.IsDecoded) { $detail = 'WSL returned undecodable output.' }
        $errorText = "WSL keeper probe failed (exit $($command.ExitCode)): $detail"
    }
    return [pscustomobject]@{ Known = $known; Running = ($known -and $marker -eq '__ONEDEBIAN_KEEPER_RUNNING__'); ExitCode = $command.ExitCode; Error = $errorText }
}

function Stop-WslLifecycleKeeper {
    param($Context)
    $expected = Get-WslLifecycleKeeperSignature -Context $Context
    $release = 'expected=EXPECTED; failed=0; for path in /proc/[0-9]*/cmdline; do [ -r "$path" ] || continue; actual=$(od -An -v -tx1 "$path" 2>/dev/null | tr -d " \n"); [ "$actual" = "$expected" ] || continue; pid=${path%/cmdline}; pid=${pid#/proc/}; kill -TERM "$pid" 2>/dev/null || { failed=1; continue; }; count=0; while [ -r "$path" ]; do actual=$(od -An -v -tx1 "$path" 2>/dev/null | tr -d " \n"); [ "$actual" = "$expected" ] || break; count=$((count+1)); [ "$count" -lt 30 ] || { failed=1; break; }; sleep 0.1; done; done; exit "$failed"'
    $release = $release.Replace('EXPECTED', $expected)
    $command = Invoke-WslShellScript -Arguments @('--distribution', $Context.DistroName, '--exec', '/bin/sh', '-c', $release) -TimeoutMilliseconds 15000
    if ($command.ExitCode -ne 0) { throw 'The managed Linux keep-alive process release could not be verified.' }
}

function Set-WslDistroAutostart {
    param([Parameter(Mandatory = $true)][string]$DistroName, [bool]$Enabled)
    try {
        $context = Get-WslLifecycleContext -DistroName $DistroName
        $task = Get-WslLifecycleTask -Context $context
        $before = Get-WslLifecycleTaskPolicy -Task $task -Context $context
        if ($before.KeepAlive -and $task.Actions[0].Execute -ine $context.LauncherExe) {
            $running = Get-WslDistroRunningState -DistroName $context.DistroName
            if (-not $running.Known) { throw 'The existing keep-alive state could not be verified; background migration was not attempted.' }
            $keeper = if ($running.Known -and $running.Running) { Get-WslLifecycleKeeperState -Context $context } else { $null }
            if ($null -ne $keeper -and -not $keeper.Known) { throw 'The existing keep-alive process could not be verified; background migration was not attempted.' }
            if ([string]$task.State -in @('Running', 'Queued') -or ($null -ne $keeper -and $keeper.Known -and $keeper.Running)) {
                $migration = Set-WslDistroResidency -DistroName $DistroName -KeepAlive $true
                if (-not $migration.Success) { throw $migration.Error }
            }
        }
        Set-WslLifecycleTask -Context $context -Autostart $Enabled -KeepAlive $before.KeepAlive
        $state = Get-WslLifecycleTaskPolicy -Task (Get-WslLifecycleTask -Context $context) -Context $context
        return [pscustomobject]@{ Success = $true; State = $state; Error = $null }
    } catch { return [pscustomobject]@{ Success = $false; State = $null; Error = $_.Exception.Message } }
}

function Set-WslDistroResidency {
    param([Parameter(Mandatory = $true)][string]$DistroName, [bool]$KeepAlive)
    try {
        $context = Get-WslLifecycleContext -DistroName $DistroName
        $task = Get-WslLifecycleTask -Context $context
        $before = Get-WslLifecycleTaskPolicy -Task $task -Context $context
        if ($KeepAlive) {
            Initialize-WslLifecycleLauncher -Context $context
            $restartKeeper = $before.KeepAlive -and ($task.Actions[0].Execute -ine $context.LauncherExe -or [string]$task.State -ne 'Running')
            if ($restartKeeper) {
                $running = Get-WslDistroRunningState -DistroName $context.DistroName
                if (-not $running.Known) { throw 'The existing keep-alive state could not be verified; background migration was not attempted.' }
                if ($running.Running) { Stop-WslLifecycleKeeper -Context $context }
            }
            # A running one-shot startup action cannot become a keeper merely
            # because its task definition is updated underneath it.
            if (($restartKeeper -or -not $before.KeepAlive) -and $null -ne $task -and [string]$task.State -in @('Running', 'Queued')) {
                Stop-ScheduledTask -TaskName $context.TaskName -TaskPath $context.TaskPath -ErrorAction Stop
            }
            Set-WslLifecycleTask -Context $context -Autostart $before.Autostart -KeepAlive $true
            $task = Get-WslLifecycleTask -Context $context
            if ($restartKeeper -or -not $before.KeepAlive -or [string]$task.State -ne 'Running') {
                Start-ScheduledTask -TaskName $context.TaskName -TaskPath $context.TaskPath -ErrorAction Stop
            }
            $residentRunning = $false
            $verifiedSamples = 0
            $keeperError = $null
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                $task = Get-WslLifecycleTask -Context $context
                $running = Get-WslDistroRunningState -DistroName $context.DistroName
                if ([string]$task.State -eq 'Running' -and $running.Known -and $running.Running) {
                    $keeper = Get-WslLifecycleKeeperState -Context $context
                    $keeperError = $keeper.Error
                    if ($keeper.Known -and $keeper.Running) { $verifiedSamples++ } else { $verifiedSamples = 0 }
                } else { $verifiedSamples = 0 }
                if ($verifiedSamples -ge 2) { $residentRunning = $true; break }
                Start-Sleep -Milliseconds 250
            }
            if (-not $residentRunning) { throw ('The keep-alive task was configured, but its running state could not be verified.' + $(if ($keeperError) { "`n$keeperError" })) }
        } else {
            # Changing the policy never terminates the instance or other workloads.
            $running = Get-WslDistroRunningState -DistroName $context.DistroName
            if ($before.KeepAlive -and $running.Known -and $running.Running) { Stop-WslLifecycleKeeper -Context $context }
            if ($null -ne $task -and [string]$task.State -in @('Running', 'Queued')) {
                Stop-ScheduledTask -TaskName $context.TaskName -TaskPath $context.TaskPath -ErrorAction Stop
            }
            Set-WslLifecycleTask -Context $context -Autostart $before.Autostart -KeepAlive $false
            if (-not $running.Known) { throw 'Automatic reclaim was configured; current instance state was unknown, so Linux cleanup was not attempted.' }
        }
        $state = Get-WslLifecycleTaskPolicy -Task (Get-WslLifecycleTask -Context $context) -Context $context
        return [pscustomobject]@{ Success = $true; State = $state; Error = $null }
    } catch { return [pscustomobject]@{ Success = $false; State = $null; Error = $_.Exception.Message } }
}
