# ==============================================================================
# components/wsl_common.ps1
# Description: WSL 管理脚本公共辅助函数 (修复 -f 格式化输出 System.String[] 的 Bug)
# Author: Fred
# ==============================================================================

function Get-WslDistros {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe not found. Install or enable Windows Subsystem for Linux first.'
    }
    # Reuse the verified registry/byte-decoded inventory for selection too, so
    # localized names are identical to those displayed in the status table.
    $inventory = Get-WslDistroVersions
    if ($inventory.Source -eq 'Unknown') {
        throw 'Unable to query registered WSL distributions.'
    }
    return [string[]]@($inventory.Distributions | ForEach-Object { [string]$_.Name })
}

function Select-WslDistro {
    param(
        [string]$Title = $(Get-I18nStr 'Select_Distro_Title')
    )

    [string[]]$distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Host "`n[!] $(Get-I18nStr 'No_Distro_Found')" -ForegroundColor Red
        return $null
    }

    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $distros.Count; $i++) {
        $name = [string]$distros[$i]
        Write-Host " [$($i + 1)] $name"
    }

    while ($true) {
        $inputVal = Read-Host "`n$(Get-I18nStr 'Select_Index_Prompt') [1-$($distros.Count)] (输入 0 取消)"
        if ($inputVal -eq '0') {
            Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
            return $null
        }

        if ($inputVal -match '^\d+$') {
            $index = [int]$inputVal - 1
            if ($index -ge 0 -and $index -lt $distros.Count) {
                return [string]$distros[$index]
            }
        }

        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
    }
}

# Decode redirected native output before PowerShell applies its console encoding.
function ConvertFrom-WslCommandBytes {
    param([AllowEmptyCollection()][byte[]]$Bytes = @())
    $encodingName = 'UTF-8'
    $offset = 0
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
            $encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true)
            $encodingName = 'UTF-16LE'; $offset = 2
        } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
            $encoding = New-Object System.Text.UnicodeEncoding($true, $true, $true)
            $encodingName = 'UTF-16BE'; $offset = 2
        } elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
            $offset = 3
        } elseif ($Bytes.Length -ge 2 -and $Bytes.Length % 2 -eq 0) {
            $evenZeros = 0; $oddZeros = 0
            for ($i = 0; $i -lt $Bytes.Length; $i += 2) {
                if ($Bytes[$i] -eq 0) { $evenZeros++ }
                if ($Bytes[$i + 1] -eq 0) { $oddZeros++ }
            }
            # WSL tables/status contain ASCII labels or padding even in Chinese.
            if ($oddZeros -gt 0 -and $oddZeros -gt $evenZeros * 2) {
                $encoding = New-Object System.Text.UnicodeEncoding($false, $false, $true)
                $encodingName = 'UTF-16LE'
            } elseif ($evenZeros -gt 0 -and $evenZeros -gt $oddZeros * 2) {
                $encoding = New-Object System.Text.UnicodeEncoding($true, $false, $true)
                $encodingName = 'UTF-16BE'
            }
        }
        $text = $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
        if ($text.IndexOf([char]0) -ge 0) { throw 'Unexpected NUL in native output.' }
        return [pscustomobject]@{ Text = $text; IsDecoded = $true; Encoding = $encodingName }
    } catch {
        return [pscustomobject]@{ Text = ''; IsDecoded = $false; Encoding = 'Unknown' }
    }
}

function ConvertTo-WslCommandArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($Argument.IndexOf([char]0) -ge 0) { throw 'NUL is not a valid command argument.' }
    # WSL parses its switches before CRT-style argument decoding; leave simple
    # flags unquoted ("--status" can otherwise be treated as a Linux command).
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    # Windows CommandLineToArgvW/CRT quoting, including quotes and trailing slashes.
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-WslCommand {
    param([string[]]$Arguments = @(), [string]$FilePath = 'wsl.exe', [int]$TimeoutMilliseconds = 0)
    $process = New-Object System.Diagnostics.Process
    $output = New-Object System.IO.MemoryStream
    $errors = New-Object System.IO.MemoryStream
    try {
        $application = Get-Command $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $process.StartInfo.FileName = $application.Source
        $process.StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WslCommandArgument $_ }) -join ' ')
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($output)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($errors)
        if ($TimeoutMilliseconds -gt 0 -and -not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Native query timed out.'
        }
        $process.WaitForExit()
        [void]$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        $decodedOutput = ConvertFrom-WslCommandBytes -Bytes $output.ToArray()
        $decodedErrors = ConvertFrom-WslCommandBytes -Bytes $errors.ToArray()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode; Text = $decodedOutput.Text; ErrorText = $decodedErrors.Text
            IsDecoded = ($decodedOutput.IsDecoded -and $decodedErrors.IsDecoded); Encoding = $decodedOutput.Encoding
        }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Text = ''; ErrorText = $_.Exception.Message; IsDecoded = $false; Encoding = 'Unknown' }
    } finally {
        $process.Dispose(); $output.Dispose(); $errors.Dispose()
    }
}

function Get-WslRegistryState {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    try {
        $properties = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        $distros = @(); $distrosAvailable = $true
        try {
            foreach ($child in @(Get-ChildItem -LiteralPath $path -ErrorAction Stop)) {
                $item = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction Stop
                if ($item.DistributionName) {
                    $distros += [pscustomobject]@{ Name = [string]$item.DistributionName; Version = $item.Version }
                } else { $distrosAvailable = $false }
            }
        } catch { $distrosAvailable = $false }
        return [pscustomobject]@{
            Available = $true; DefaultVersion = $properties.DefaultVersion; Distributions = @($distros)
            DistrosAvailable = $distrosAvailable; Error = $null
        }
    } catch {
        return [pscustomobject]@{ Available = $false; DefaultVersion = $null; Distributions = @(); DistrosAvailable = $false; Error = $_.Exception.Message }
    }
}

function ConvertFrom-WslDefaultVersionText {
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '(?im)^\s*(?:Default\s*Version|默认版本)\s*[:：]\s*([12])\s*$') {
        return [int]$Matches[1]
    }
    return $null
}

function ConvertFrom-WslDistroListText {
    param([AllowEmptyString()][string]$Text)
    $distros = @(); $header = $false; $valid = $true
    foreach ($line in ($Text.TrimStart([char]0xFEFF) -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        if (-not $header) {
            if ($line -match '^\s*(?:NAME|名称)\s+(?:STATE|状态)\s+(?:VERSION|版本)\s*$') { $header = $true }
            else { $valid = $false }
            continue
        }
        if ($line -match '^\s*\*?\s*(?<Name>.+?)\s{2,}(?<State>.+?)\s{2,}(?<Version>[12])\s*$') {
            $distros += [pscustomobject]@{ Name = $Matches.Name.Trim(); Version = [int]$Matches.Version; Known = $true; Source = 'Command' }
        } else { $valid = $false }
    }
    $known = $header -and $valid
    if (-not $known) {
        foreach ($distro in $distros) { $distro.Known = $false }
    }
    return [pscustomobject]@{ Known = $known; Distributions = @($distros) }
}

function Get-WslDefaultVersion {
    param([scriptblock]$ReadRegistry = { Get-WslRegistryState }, [scriptblock]$RunCommand = { param($NativeArguments) Invoke-WslCommand -Arguments $NativeArguments -TimeoutMilliseconds 30000 })
    $registry = $null
    try { $registry = & $ReadRegistry } catch { }
    if ($registry -and $registry.Available -and [string]$registry.DefaultVersion -match '^[12]$') {
        return [pscustomobject]@{ Known = $true; Version = [int]$registry.DefaultVersion; Source = 'Registry'; Command = $null; Error = $null }
    }
    try { $command = & $RunCommand @('--status') } catch { $command = [pscustomobject]@{ ExitCode = -1; IsDecoded = $false; Text = ''; ErrorText = $_.Exception.Message } }
    $version = $null
    if ($command.ExitCode -eq 0 -and $command.IsDecoded) { $version = ConvertFrom-WslDefaultVersionText -Text $command.Text }
    return [pscustomobject]@{ Known = ($null -ne $version); Version = $version; Source = $(if ($null -ne $version) { 'Command' } else { 'Unknown' }); Command = $command; Error = $command.ErrorText }
}

function Get-WslDistroVersions {
    param([scriptblock]$ReadRegistry = { Get-WslRegistryState }, [scriptblock]$RunCommand = { param($NativeArguments) Invoke-WslCommand -Arguments $NativeArguments -TimeoutMilliseconds 30000 })
    $registry = $null
    try { $registry = & $ReadRegistry } catch { }
    if ($registry -and $registry.Available -and ($null -eq $registry.PSObject.Properties['DistrosAvailable'] -or $registry.DistrosAvailable)) {
        $distros = @($registry.Distributions | ForEach-Object {
            $known = ([string]$_.Version -match '^[12]$')
            [pscustomobject]@{ Name = $_.Name; Version = $(if ($known) { [int]$_.Version } else { $null }); Known = $known; Source = 'Registry' }
        })
        return [pscustomobject]@{ Known = (@($distros | Where-Object { -not $_.Known }).Count -eq 0); Distributions = $distros; Source = 'Registry'; Command = $null; Error = $null }
    }
    try { $command = & $RunCommand @('--list', '--verbose') } catch { $command = [pscustomobject]@{ ExitCode = -1; IsDecoded = $false; Text = ''; ErrorText = $_.Exception.Message } }
    $parsed = [pscustomobject]@{ Known = $false; Distributions = @() }
    if ($command.ExitCode -eq 0 -and $command.IsDecoded) { $parsed = ConvertFrom-WslDistroListText -Text $command.Text }
    return [pscustomobject]@{ Known = $parsed.Known; Distributions = @($parsed.Distributions); Source = $(if ($parsed.Known) { 'Command' } else { 'Unknown' }); Command = $command; Error = $command.ErrorText }
}

function Set-WslDefaultVersion {
    param([ValidateSet(2)][int]$Version = 2, [scriptblock]$Query = { Get-WslDefaultVersion }, [scriptblock]$RunCommand = { param($NativeArguments) Invoke-WslCommand -Arguments $NativeArguments })
    try { $before = & $Query } catch { $before = [pscustomobject]@{ Known = $false; Version = $null; Error = $_.Exception.Message } }
    if (-not $before.Known) { return [pscustomobject]@{ Success = $false; Status = 'Unknown'; Command = $null; State = $before } }
    if ($before.Version -eq $Version) { return [pscustomobject]@{ Success = $true; Status = 'Verified'; Command = $null; State = $before } }
    try { $command = & $RunCommand @('--set-default-version', [string]$Version) } catch { $command = [pscustomobject]@{ ExitCode = -1; Text = ''; ErrorText = $_.Exception.Message; IsDecoded = $false } }
    try { $after = & $Query } catch { $after = [pscustomobject]@{ Known = $false; Version = $null; Error = $_.Exception.Message } }
    $status = if ($command.ExitCode -ne 0) { 'Failed' } elseif (-not $after.Known) { 'Unknown' } elseif ($after.Version -eq $Version) { 'Verified' } else { 'Failed' }
    return [pscustomobject]@{ Success = ($status -eq 'Verified'); Status = $status; Command = $command; State = $after }
}

function Set-WslDistroVersion {
    param([Parameter(Mandatory)][string]$Name, [ValidateSet(2)][int]$Version = 2, [scriptblock]$Query = { Get-WslDistroVersions }, [scriptblock]$RunCommand = { param($NativeArguments) Invoke-WslCommand -Arguments $NativeArguments })
    try { $before = & $Query } catch { $before = [pscustomobject]@{ Known = $false; Distributions = @(); Error = $_.Exception.Message } }
    $matchesByName = @($before.Distributions | Where-Object { $_.Name -eq $Name })
    if ($matchesByName.Count -ne 1 -or -not $matchesByName[0].Known) { return [pscustomobject]@{ Success = $false; Status = 'Unknown'; Command = $null; State = $before } }
    if ($matchesByName[0].Version -eq $Version) { return [pscustomobject]@{ Success = $true; Status = 'Verified'; Command = $null; State = $before } }
    try { $command = & $RunCommand @('--set-version', $Name, [string]$Version) } catch { $command = [pscustomobject]@{ ExitCode = -1; Text = ''; ErrorText = $_.Exception.Message; IsDecoded = $false } }
    try { $after = & $Query } catch { $after = [pscustomobject]@{ Known = $false; Distributions = @(); Error = $_.Exception.Message } }
    $matchesByName = @($after.Distributions | Where-Object { $_.Name -eq $Name })
    $status = if ($command.ExitCode -ne 0) { 'Failed' } elseif ($matchesByName.Count -ne 1 -or -not $matchesByName[0].Known) { 'Unknown' } elseif ($matchesByName[0].Version -eq $Version) { 'Verified' } else { 'Failed' }
    return [pscustomobject]@{ Success = ($status -eq 'Verified'); Status = $status; Command = $command; State = $after }
}

function Test-WslAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WslFeatureState {
    param([string]$Name)
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        $state = [string]$feature.State
        $known = $state -in @('Enabled', 'Disabled', 'DisabledWithPayloadRemoved', 'EnablePending', 'DisablePending', 'Removed')
        return [pscustomobject]@{ Known = $known; State = $state; Enabled = ($state -eq 'Enabled'); Pending = ($state -in @('EnablePending', 'DisablePending')) }
    } catch { return [pscustomobject]@{ Known = $false; State = 'Unknown'; Enabled = $false; Pending = $false } }
}

function Get-WslRebootState {
    try {
        $pending = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction Stop) -or
            (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction Stop)
        $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if ($session.PendingFileRenameOperations) { $pending = $true }
        return [pscustomobject]@{ Known = $true; Pending = [bool]$pending }
    } catch { return [pscustomobject]@{ Known = $false; Pending = $false } }
}

function Test-WslKernelUpdateRequired {
    param($CommandResult)
    if ($null -eq $CommandResult) { return $false }
    $text = "$($CommandResult.Text)`n$($CommandResult.ErrorText)"
    return (($CommandResult.ExitCode -band 0xFFFF) -eq 444 -or
        $text -match '(?i)0x(?:80070)?0*1bc\b|WSL_E_WSL2_KERNEL|WSL\s*2.*(?:kernel.*(?:update|missing)|update.*kernel|(?:更新|缺少|缺失).*内核|内核.*(?:更新|缺少|缺失))')
}
