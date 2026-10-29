# Read-only metadata for the WSL status page. Importing this file does not start WSL.

function Get-WslDistroStorageInfo {
    param([string]$DistroName)
    try {
        $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if ($properties.DistributionName -ne $DistroName) { continue }
            $basePath = [Environment]::ExpandEnvironmentVariables([string]$properties.BasePath)
            if (-not $basePath) { return $null }
            $created = $null
            $directory = Get-Item -LiteralPath $basePath -ErrorAction SilentlyContinue
            if ($directory) { $created = $directory.CreationTime }
            $vhdName = if ($properties.VhdFileName) { [string]$properties.VhdFileName } else { 'ext4.vhdx' }
            $vhdPath = Join-Path $basePath $vhdName
            $vhd = Get-Item -LiteralPath $vhdPath -ErrorAction SilentlyContinue
            if (-not $vhd) {
                $vhd = Get-ChildItem -LiteralPath $basePath -Filter '*.vhdx' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            # WSL does not expose the original registration timestamp. A storage
            # directory's creation time is only a labelled approximation.
            return [pscustomobject]@{
                Path = $(if ($vhd) { $vhd.FullName } else { $null })
                Length = $(if ($vhd) { $vhd.Length } else { $null })
                Created = $created
                CreatedSource = $(if ($null -ne $created) { 'Storage' } else { 'Unknown' })
            }
        }
    } catch { }
    return $null
}

function Get-WslRunningDistroNames {
    param([AllowEmptyCollection()][string[]]$DistroNames = @())
    $command = Invoke-WslCommand -Arguments @('--list', '--running', '--quiet') -TimeoutMilliseconds 15000
    $names = @(); $known = $command.ExitCode -eq 0 -and $command.IsDecoded
    if ($known) {
        foreach ($line in ($command.Text -split '\r?\n')) {
            $name = $line.Trim()
            if (-not $name) { continue }
            # Do not turn an error/warning/localized sentence into a distro name.
            if ($DistroNames -notcontains $name -or $names -contains $name) { $known = $false; break }
            $names += $name
        }
    }
    return [pscustomobject]@{ Known = $known; Names = $(if ($known) { @($names) } else { @() }); Command = $command }
}

function ConvertFrom-WslInstanceUptime {
    param([AllowEmptyString()][string]$Text)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $numberStyle = [Globalization.NumberStyles]::Float
    if ($Text -notmatch '(?m)^__UPTIME__\r?\n(?<Seconds>\d+(?:\.\d+)?)\s') { return $null }
    $vmUptime = 0.0
    if (-not [double]::TryParse($Matches.Seconds, $numberStyle, $culture, [ref]$vmUptime)) { return $null }
    if ($Text -notmatch '(?m)^__HZ__\r?\n(?<Hz>\d+)\s*$') { return $null }
    $hz = 0.0
    if (-not [double]::TryParse($Matches.Hz, $numberStyle, $culture, [ref]$hz) -or $hz -le 0) { return $null }
    # comm can contain spaces and parentheses. Greedily skip it, then index
    # starttime (field 22) from the state field (field 3), not by splitting comm.
    if ($Text -notmatch '(?m)^1\s+\(.*\)\s+(?<Fields>[^\r\n]+)') { return $null }
    $fields = $Matches.Fields.Trim() -split '\s+'
    if ($fields.Count -lt 20 -or $fields[19] -notmatch '^\d+$') { return $null }
    $startTicks = 0.0
    if (-not [double]::TryParse($fields[19], $numberStyle, $culture, [ref]$startTicks)) { return $null }
    $elapsed = $vmUptime - $startTicks / $hz
    if ($elapsed -lt 0) { return $null }
    return [math]::Floor($elapsed)
}

function Get-WslInstanceUptime {
    param([string]$DistroName)
    # Refresh immediately before entering the distro; an earlier dashboard
    # snapshot may already be stale after an idle shutdown.
    $running = Invoke-WslCommand -Arguments @('--list', '--running', '--quiet') -TimeoutMilliseconds 15000
    if ($running.ExitCode -ne 0 -or -not $running.IsDecoded) { return $null }
    $names = @($running.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names -cnotcontains $DistroName) { return $null }
    $script = 'printf "__UPTIME__\n"; cat /proc/uptime; printf "__INIT__\n"; cat /proc/1/stat; printf "__HZ__\n"; getconf CLK_TCK'
    $command = Invoke-WslCommand -Arguments @('--distribution', $DistroName, '--exec', '/bin/sh', '-c', $script) -TimeoutMilliseconds 15000
    if ($command.ExitCode -ne 0 -or -not $command.IsDecoded) { return $null }
    return ConvertFrom-WslInstanceUptime -Text $command.Text
}

function Format-WslStatusDuration {
    param([AllowNull()]$Seconds)
    if ($null -eq $Seconds -or $Seconds -lt 0) { return '-' }
    $duration = [TimeSpan]::FromSeconds([math]::Floor([double]$Seconds))
    if ($duration.TotalDays -ge 1) { return ('{0}d{1:00}h' -f [math]::Floor($duration.TotalDays), $duration.Hours) }
    if ($duration.TotalHours -ge 1) { return ('{0}h{1:00}m' -f [math]::Floor($duration.TotalHours), $duration.Minutes) }
    if ($duration.TotalMinutes -ge 1) { return ('{0}m{1:00}s' -f [math]::Floor($duration.TotalMinutes), $duration.Seconds) }
    return ('{0}s' -f $duration.Seconds)
}

function Get-WslStatusRows {
    $inventory = Get-WslDistroVersions
    if ($inventory.Source -eq 'Unknown') { throw 'Unable to query registered WSL distributions.' }
    $distros = @($inventory.Distributions)
    $running = Get-WslRunningDistroNames -DistroNames @($distros | ForEach-Object { $_.Name })
    foreach ($distro in $distros) {
        $name = [string]$distro.Name
        $state = if (-not $running.Known) { 'Unknown' } elseif ($running.Names -contains $name) { 'Running' } else { 'Stopped' }
        $storage = Get-WslDistroStorageInfo -DistroName $name
        $uptime = $null
        # Never probe a stopped/unknown distribution: wsl -d would start it.
        if ($state -eq 'Running') { $uptime = Get-WslInstanceUptime -DistroName $name }
        $lifecycle = Get-WslDistroLifecycle -DistroName $name
        [pscustomobject]@{
            Name = $name; State = $state
            Created = $(if ($storage) { $storage.Created } else { $null })
            CreatedSource = $(if ($storage) { $storage.CreatedSource } else { 'Unknown' })
            UptimeSeconds = $uptime
            SizeBytes = $(if ($storage) { $storage.Length } else { $null })
            Autostart = $(if ($lifecycle.Known) { $lifecycle.Autostart } else { $null })
            KeepAlive = $(if ($lifecycle.Known) { $lifecycle.KeepAlive } else { $null })
        }
    }
}
