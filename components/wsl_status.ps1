# ==============================================================================
# components/wsl_status.ps1
# Description: Compact WSL inventory and per-instance lifecycle controls.
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl',
    [switch]$NoRun
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"
. "$PSScriptRoot\wsl_lifecycle.ps1"
. "$PSScriptRoot\wsl_status_data.ps1"

function Get-WslStatusTextWidth {
    param([AllowEmptyString()][string]$Text)
    $width = 0
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE10 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) { $width += 2 }
        else { $width++ }
    }
    return $width
}

function Format-WslStatusCell {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    if ((Get-WslStatusTextWidth $Text) -gt $Width) {
        $short = ''
        foreach ($character in $Text.ToCharArray()) {
            if ((Get-WslStatusTextWidth ($short + $character)) -gt ($Width - 1)) { break }
            $short += $character
        }
        $Text = $short + '…'
    }
    return $Text + (' ' * [Math]::Max(0, ($Width - (Get-WslStatusTextWidth $Text))))
}

function Format-WslStatusSize {
    param($Bytes)
    if ($null -eq $Bytes) { return '-' }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1TB) { return ([double]$Bytes / 1TB).ToString('0.##', $culture) + 'T' }
    if ($Bytes -ge 1GB) { return ([double]$Bytes / 1GB).ToString('0.##', $culture) + 'G' }
    if ($Bytes -ge 1MB) { return ([double]$Bytes / 1MB).ToString('0.#', $culture) + 'M' }
    if ($Bytes -ge 1KB) { return ([double]$Bytes / 1KB).ToString('0', $culture) + 'K' }
    return [string]$Bytes
}

function Format-WslStatusFlag {
    param($Value)
    if ($null -eq $Value) { return Get-I18nStr 'Status_Unknown' }
    if ($Value) { return Get-I18nStr 'Status_Yes' }
    return Get-I18nStr 'Status_No'
}

function Show-WslStatusTable {
    param([AllowEmptyCollection()][object[]]$Rows = @())
    $widths = @(2, 20, 4, 17, 7, 7, 4, 4)
    $headers = @((Get-I18nStr 'Status_Header') -split '\|' | ForEach-Object { $_.Trim() })
    $rule = ' ' + ('-' * 86)
    Write-Host $rule -ForegroundColor Gray
    $cells = for ($column = 0; $column -lt $widths.Count; $column++) {
        Format-WslStatusCell -Text $headers[$column] -Width $widths[$column]
    }
    Write-Host (' ' + ($cells -join ' | ')) -ForegroundColor Cyan
    Write-Host $rule -ForegroundColor Gray
    for ($index = 0; $index -lt $Rows.Count; $index++) {
        $row = $Rows[$index]
        $created = '-'
        if ($null -ne $row.Created) {
            try {
                $created = ([datetime]$row.Created).ToString('yyyy-MM-dd HH:mm')
                if ($row.CreatedSource -eq 'Storage') { $created = '~' + $created }
            } catch { $created = '-' }
        }
        $uptime = '-'
        if ($row.State -eq 'Running' -and $null -ne $row.UptimeSeconds) {
            $uptime = Format-WslStatusDuration -Seconds $row.UptimeSeconds
        }
        $stateKey = switch ($row.State) {
            'Running' { 'Status_StateRunning' }
            'Stopped' { 'Status_StateStopped' }
            default { 'Status_StateUnknown' }
        }
        $values = @(
            [string]($index + 1), [string]$row.Name, (Get-I18nStr $stateKey), $created,
            $uptime, (Format-WslStatusSize $row.SizeBytes),
            (Format-WslStatusFlag $row.Autostart), (Format-WslStatusFlag $row.KeepAlive)
        )
        $cells = for ($column = 0; $column -lt $widths.Count; $column++) {
            Format-WslStatusCell -Text $values[$column] -Width $widths[$column]
        }
        $colour = switch ($row.State) { 'Running' { 'Green' }; 'Stopped' { 'Gray' }; default { 'Yellow' } }
        Write-Host (' ' + ($cells -join ' | ')) -ForegroundColor $colour
    }
    Write-Host $rule -ForegroundColor Gray
    if (@($Rows | Where-Object { $_.CreatedSource -eq 'Storage' }).Count -gt 0) {
        Write-Host (' ' + (Get-I18nStr 'Status_CreatedApprox')) -ForegroundColor Gray
    }
}

function Test-WslStatusRunning {
    param([string]$DistroName)
    $result = Invoke-WslCommand -Arguments @('--list', '--running', '--quiet') -TimeoutMilliseconds 15000
    if ($result.ExitCode -ne 0 -or -not $result.IsDecoded) { return $false }
    $names = @($result.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return $names -ccontains $DistroName
}

function Show-WslNetworkHealth {
    param([string]$DistroName)
    # Recheck before entering a distribution; a stopped/unknown distro is not probed.
    if (-not (Test-WslStatusRunning -DistroName $DistroName)) { return }
    $probeScript = 'echo __IPV4__; ip -4 -brief address show dev eth0 scope global 2>/dev/null; echo __ROUTE__; ip route show default 2>/dev/null; echo __NM__; systemctl is-active NetworkManager.service 2>/dev/null; echo __NETWORKD__; systemctl is-active systemd-networkd.service 2>/dev/null; true'
    $result = Invoke-WslCommand -Arguments @('--distribution', $DistroName, '--user', 'root', '--exec', 'sh', '-c', $probeScript) -TimeoutMilliseconds 15000
    if ($result.ExitCode -ne 0 -or -not $result.IsDecoded) {
        Write-Host ('  ' + (Get-I18nStr 'Status_NetworkProbeFailed' -Args @($DistroName, $result.ExitCode))) -ForegroundColor Yellow
        return
    }
    $values = @{ IPV4 = ''; ROUTE = ''; NM = ''; NETWORKD = '' }
    $currentKey = $null
    foreach ($line in ($result.Text -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^__(IPV4|ROUTE|NM|NETWORKD)__$') { $currentKey = $Matches[1]; continue }
        if ($currentKey -and -not $values[$currentKey]) { $values[$currentKey] = $trimmed }
    }
    if (-not $values.IPV4 -or -not $values.ROUTE) {
        $key = 'Status_NetworkUnhealthy'; $colour = 'Red'
    } elseif ($values.NM -eq 'active' -and $values.NETWORKD -eq 'active') {
        $key = 'Status_NetworkConflict'; $colour = 'Red'
    } else { $key = 'Status_NetworkHealthy'; $colour = 'Green' }
    Write-Host ('  ' + (Get-I18nStr $key -Args @($DistroName))) -ForegroundColor $colour
}

function Invoke-WslStatusAction {
    param([AllowEmptyString()][string]$Choice)
    $choiceCode = $Choice.ToUpperInvariant()
    if ($choiceCode -eq '0' -or -not $choiceCode) { return }
    if ($choiceCode -notin @('A', 'N', 'K', 'R', 'T', 'S')) {
        Write-Host (Get-I18nStr 'Err_InvalidChoice') -ForegroundColor Yellow
        return
    }
    $target = ''
    if ($choiceCode -eq 'S') { $target = 'WSL'; $confirmKey = 'Status_ConfirmShutdown' }
    else {
        $target = Select-WslDistro -Title (Get-I18nStr 'Select_Distro_Title')
        if (-not $target) { return }
        $confirmKey = switch ($choiceCode) {
            'A' { 'Status_ConfirmAutoOn' }; 'N' { 'Status_ConfirmAutoOff' }
            'K' { 'Status_ConfirmKeepOn' }; 'R' { 'Status_ConfirmKeepOff' }
            'T' { 'Status_ConfirmTerm' }
        }
    }
    if ((Read-Host (Get-I18nStr $confirmKey -Args @($target))) -ne 'Y') {
        Write-Host (Get-I18nStr 'Operation_Cancelled') -ForegroundColor Gray
        return
    }
    try {
        $result = switch ($choiceCode) {
            'A' { Set-WslDistroAutostart -DistroName $target -Enabled $true }
            'N' { Set-WslDistroAutostart -DistroName $target -Enabled $false }
            'K' { Set-WslDistroResidency -DistroName $target -KeepAlive $true }
            'R' { Set-WslDistroResidency -DistroName $target -KeepAlive $false }
            'T' {
                $command = Invoke-WslCommand -Arguments @('--terminate', $target)
                [pscustomobject]@{ Success = ($command.ExitCode -eq 0); Error = $command.ErrorText }
            }
            'S' {
                $command = Invoke-WslCommand -Arguments @('--shutdown')
                [pscustomobject]@{ Success = ($command.ExitCode -eq 0); Error = $command.ErrorText }
            }
        }
        if ($result.Success) {
            Write-Host ('[OK] ' + (Get-I18nStr 'Status_ActionSuccess' -Args @($target))) -ForegroundColor Green
        } else {
            Write-Host ('[!] ' + (Get-I18nStr 'Status_ActionFailed' -Args @($target, $result.Error))) -ForegroundColor Red
        }
    } catch {
        Write-Host ('[!] ' + (Get-I18nStr 'Status_ActionFailed' -Args @($target, $_.Exception.Message))) -ForegroundColor Red
    }
}

function Show-WslStatusSubmenu {
    param([ValidateSet('A', 'K', 'T')][string]$Group)
    $menu = switch ($Group) {
        'A' { @{ Title = 'Status_SubmenuAutostart'; Items = @('Status_SubAutostartOn', 'Status_SubAutostartOff'); Actions = @('A', 'N'); Hint = 'Status_AutoHint' } }
        'K' { @{ Title = 'Status_SubmenuRunMode'; Items = @('Status_SubResident', 'Status_SubReclaim'); Actions = @('K', 'R'); Hint = 'Status_KeepHint' } }
        'T' { @{ Title = 'Status_SubmenuStop'; Items = @('Status_SubStopOne', 'Status_SubStopAll'); Actions = @('T', 'S'); Hint = '' } }
    }
    while ($true) {
        Write-Host ("`n" + (Get-I18nStr $menu.Title)) -ForegroundColor Yellow
        foreach ($key in $menu.Items) { Write-Host (' ' + (Get-I18nStr $key)) }
        if ($menu.Hint) { Write-Host (' ' + (Get-I18nStr $menu.Hint)) -ForegroundColor Gray }
        Write-Host (' ' + (Get-I18nStr 'Status_Back'))
        $choice = ([string](Read-Host ((Get-I18nStr 'Prompt_Select') + ' [1/2/0]'))).Trim()
        if (-not $choice -or $choice -eq '0') { return }
        if ($choice -in @('1', '2')) {
            Invoke-WslStatusAction -Choice $menu.Actions[([int]$choice - 1)]
        } else {
            Write-Host (Get-I18nStr 'Err_InvalidChoice') -ForegroundColor Yellow
        }
    }
}

function Show-WslStatusActions {
    while ($true) {
        Write-Host ("`n" + (Get-I18nStr 'Status_Step3')) -ForegroundColor Yellow
        foreach ($key in @('Status_GroupAutostart', 'Status_GroupRunMode', 'Status_GroupStop')) {
            Write-Host (' ' + (Get-I18nStr $key))
        }
        Write-Host (' ' + (Get-I18nStr 'Status_Back'))
        $choice = ([string](Read-Host ((Get-I18nStr 'Prompt_Select') + ' [A/K/T/0]'))).Trim().ToUpperInvariant()
        if (-not $choice -or $choice -eq '0') { return }
        if ($choice -in @('A', 'K', 'T')) {
            Show-WslStatusSubmenu -Group $choice
        } else {
            Write-Host (Get-I18nStr 'Err_InvalidChoice') -ForegroundColor Yellow
        }
    }
}

function Show-WslDashboard {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host ('     ' + (Get-I18nStr 'Status_Title')) -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host ("`n" + (Get-I18nStr 'Status_Step1')) -ForegroundColor Yellow
    if ($null -eq (Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host ('  ' + (Get-I18nStr 'Status_CliMissing')) -ForegroundColor Yellow
        return
    }
    Write-Host ('  ' + (Get-I18nStr 'Status_CliReady')) -ForegroundColor Gray
    Write-Host ("`n" + (Get-I18nStr 'Status_Step2')) -ForegroundColor Yellow
    try { $rows = @(Get-WslStatusRows) }
    catch {
        Write-Host ('[!] ' + (Get-I18nStr 'Status_QueryFailed' -Args @($_.Exception.Message))) -ForegroundColor Yellow
        return
    }
    if ($rows.Count -eq 0) {
        Write-Host ('  ' + (Get-I18nStr 'No_Distro_Found')) -ForegroundColor Gray
        return
    }
    Show-WslStatusTable -Rows $rows
    Write-Host ("`n" + (Get-I18nStr 'Status_NetworkTitle')) -ForegroundColor Yellow
    $running = @($rows | Where-Object { $_.State -eq 'Running' })
    if ($running.Count -eq 0) {
        Write-Host ('  ' + (Get-I18nStr 'Status_NetworkSkipped')) -ForegroundColor Gray
    } else {
        foreach ($row in $running) { Show-WslNetworkHealth -DistroName $row.Name }
    }
    Show-WslStatusActions
}

if (-not $NoRun -and $MyInvocation.InvocationName -ne '.') { Show-WslDashboard }
