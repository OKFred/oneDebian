# ==============================================================================
# components/wsl_check.ps1
# Description: WSL precheck with independently verified user defaults and instances.
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl',
    [switch]$NoRun
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Get-WslPrecheckVersionState {
    $default = Get-WslDefaultVersion
    $inventory = Get-WslDistroVersions
    $wsl1 = @($inventory.Distributions | Where-Object { $_.Known -and $_.Version -eq 1 })
    $unknown = -not $default.Known -or -not $inventory.Known -or
        @($inventory.Distributions | Where-Object { -not $_.Known }).Count -gt 0
    return [pscustomobject]@{
        Default = $default
        Inventory = $inventory
        NeedDefaultFix = ($default.Known -and $default.Version -eq 1)
        Wsl1Distros = $wsl1
        HasUnknown = $unknown
        HasIssue = ($unknown -or ($default.Known -and $default.Version -ne 2) -or $wsl1.Count -gt 0)
    }
}

function Show-WslKernelGuidance {
    param($CommandResult)
    if ($null -ne $CommandResult -and (Test-WslKernelUpdateRequired -CommandResult $CommandResult)) {
        Write-Host "  [!] $(Get-I18nStr 'Check_KernelUpdate')" -ForegroundColor Yellow
    }
}

function Show-WslVersionRepairResult {
    param($Result, [string]$Name = '')
    $key = if ($Name) { 'Check_Convert' } else { 'Check_DefaultFix' }
    $suffix = switch ($Result.Status) {
        'Verified' { 'Success' }
        'Failed' { 'Failed' }
        default { 'Unknown' }
    }
    $colour = if ($Result.Success) { 'Green' } else { 'Yellow' }
    Write-Host "  $(Get-I18nStr ($key + $suffix) -Args @($Name))" -ForegroundColor $colour
    if (-not $Result.Success -and $null -ne $Result.Command) {
        if ($Result.Command.Text) { Write-Host $Result.Command.Text -ForegroundColor Yellow }
        if ($Result.Command.ErrorText) { Write-Host $Result.Command.ErrorText -ForegroundColor Yellow }
    }
    Show-WslKernelGuidance -CommandResult $Result.Command
}

function Invoke-WslVersionRepairs {
    param(
        [Parameter(Mandatory = $true)]$VersionState,
        [bool]$AllowConversion = $true,
        [switch]$DefaultOnly,
        [switch]$SkipDefault
    )
    $defaultResult = $null
    $distributionResults = New-Object System.Collections.Generic.List[object]
    # The current user's default is independent of elevation and existing distros.
    if (-not $SkipDefault -and $VersionState.NeedDefaultFix) {
        $defaultResult = Set-WslDefaultVersion -Version 2
        Show-WslVersionRepairResult -Result $defaultResult
    }
    if (-not $DefaultOnly) {
        if (-not $AllowConversion -and @($VersionState.Wsl1Distros).Count -gt 0) {
            Write-Host "  [!] $(Get-I18nStr 'Check_SkippedConversionPending')" -ForegroundColor Yellow
        }
        foreach ($distro in $VersionState.Wsl1Distros) {
            $confirmed = $false
            if ($AllowConversion) {
                $answer = Read-Host (Get-I18nStr 'Check_ConvertPrompt' -Args @($distro.Name))
                $confirmed = $answer -eq 'Y'
            }
            if (-not $confirmed) {
                Write-Host "  $(Get-I18nStr 'Check_ConvertSkipped' -Args @($distro.Name))" -ForegroundColor Gray
                $distributionResults.Add([pscustomobject]@{ Name = $distro.Name; Status = 'Skipped'; Success = $false; State = $distro })
                continue
            }
            # A failed instance conversion must not discard results for others.
            try {
                $result = Set-WslDistroVersion -Name $distro.Name -Version 2
            } catch {
                $result = [pscustomobject]@{
                    Success = $false; Status = 'Failed'; State = $null
                    Command = [pscustomobject]@{ Text = ''; ErrorText = $_.Exception.Message }
                }
            }
            Show-WslVersionRepairResult -Result $result -Name $distro.Name
            $distributionResults.Add([pscustomobject]@{
                Name = $distro.Name; Status = $result.Status; Success = $result.Success; State = $result.State
            })
        }
    }
    return [pscustomobject]@{ DefaultResult = $defaultResult; DistributionResults = @($distributionResults.ToArray()) }
}

function Invoke-WslFeatureRepairs {
    param(
        [Parameter(Mandatory = $true)][object[]]$FeatureStates,
        [bool]$IsAdmin = $false
    )
    $failed = $false
    $restartRequested = $false
    $dismExecuted = $false
    $disabled = @($FeatureStates | Where-Object {
        $_.Result.Known -and $_.Result.State -in 'Disabled', 'DisabledWithPayloadRemoved'
    })
    if ($disabled.Count -gt 0 -and -not $IsAdmin) {
        Write-Host "  [!] $(Get-I18nStr 'Check_AdminFeaturesOnly')" -ForegroundColor Yellow
        $failed = $true
    } elseif ($disabled.Count -gt 0) {
        foreach ($feature in $disabled) {
            $dismExecuted = $true
            $command = Invoke-WslCommand -FilePath 'dism.exe' -Arguments @(
                '/online', '/enable-feature', "/featurename:$($feature.Name)", '/all', '/norestart'
            )
            if ($command.Text) { Write-Host $command.Text }
            if ($command.ErrorText) { Write-Host $command.ErrorText -ForegroundColor Yellow }
            if ($command.ExitCode -eq 3010) { $restartRequested = $true }
            elseif ($command.ExitCode -ne 0) { $failed = $true }
        }
    }
    # DISM exit 0 alone does not mean a feature has taken effect.
    $fresh = @(
        foreach ($feature in $FeatureStates) {
            [pscustomobject]@{ Name = $feature.Name; Result = (Get-WslFeatureState -Name $feature.Name) }
        }
    )
    $reboot = Get-WslRebootState
    $pending = $restartRequested -or $reboot.Pending -or
        @($fresh | Where-Object { $_.Result.Pending }).Count -gt 0
    $featuresReady = @($fresh | Where-Object { -not $_.Result.Known -or -not $_.Result.Enabled }).Count -eq 0
    $ready = $featuresReady -and $reboot.Known -and -not $pending -and -not $failed
    $knownOff = @($fresh | Where-Object { $_.Result.Known -and -not $_.Result.Enabled }).Count -gt 0
    $blockedWithoutDism = -not $dismExecuted -and @($FeatureStates | Where-Object { $_.Result.Known -and -not $_.Result.Enabled }).Count -gt 0
    # Reading optional features may require elevation; that alone must not require
    # elevation for a separately confirmed, known WSL1 instance conversion.
    $canConvert = -not $failed -and -not $pending -and -not $knownOff -and -not $blockedWithoutDism -and
        (-not $dismExecuted -or $ready)
    if ($pending) {
        Write-Host "  [!] $(Get-I18nStr 'Check_RebootPending')" -ForegroundColor Yellow
    } elseif (-not $ready) {
        Write-Host "  [?] $(Get-I18nStr 'Check_FeaturesNotReady')" -ForegroundColor Yellow
    }
    return [pscustomobject]@{
        Ready = $ready; CanConvert = $canConvert; Failed = $failed; Pending = $pending; FeatureStates = $fresh; Reboot = $reboot
    }
}

function Invoke-WslPrecheck {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     $(Get-I18nStr 'Check_Title')     " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    $hasIssue = $false
    $unknownChecks = New-Object System.Collections.Generic.List[string]
    $featureNames = @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')

    Write-Host "`n$(Get-I18nStr 'Check_Step1')" -ForegroundColor Yellow
    try {
        $csInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($csInfo.HypervisorPresent -or $cpuInfo.VirtualizationFirmwareEnabled) {
            Write-Host "  [✓] $(if ($global:CurrentLang -eq 'zh-CN') { 'CPU 硬件虚拟化已启用。' } else { 'CPU hardware virtualization is enabled.' })" -ForegroundColor Green
        } else {
            Write-Host "  [!] $(if ($global:CurrentLang -eq 'zh-CN') { '请确认 BIOS/UEFI 中已开启 VT-x/AMD-V。' } else { 'Enable VT-x/AMD-V in BIOS/UEFI.' })" -ForegroundColor Red
            $hasIssue = $true
        }
    } catch {
        Write-Host "  [?] $($_.Exception.Message)" -ForegroundColor Yellow
        $unknownChecks.Add('CPU virtualization')
        $hasIssue = $true
    }

    Write-Host "`n$(Get-I18nStr 'Check_Step2')" -ForegroundColor Yellow
    $features = @(
        foreach ($name in $featureNames) {
            $state = Get-WslFeatureState -Name $name
            if (-not $state.Known) {
                Write-Host "  [?] $(Get-I18nStr 'Check_FeatureUnknown' -Args @($name))" -ForegroundColor Yellow
                $unknownChecks.Add($name)
                $hasIssue = $true
            } else {
                $colour = if ($state.Enabled) { 'Green' } else { 'Yellow' }
                Write-Host "  $(Get-I18nStr 'Check_FeatureValue' -Args @($name, $state.State))" -ForegroundColor $colour
                if (-not $state.Enabled -or $state.Pending) { $hasIssue = $true }
            }
            [pscustomobject]@{ Name = $name; Result = $state }
        }
    )
    $reboot = Get-WslRebootState
    if ($reboot.Pending -or @($features | Where-Object { $_.Result.Pending }).Count -gt 0) {
        Write-Host "  [!] $(Get-I18nStr 'Check_RebootPending')" -ForegroundColor Yellow
        $hasIssue = $true
    } elseif (-not $reboot.Known) {
        $unknownChecks.Add('Windows restart state')
        $hasIssue = $true
    }

    Write-Host "`n$(Get-I18nStr 'Check_Step3')" -ForegroundColor Yellow
    try { $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { $currentUser = [Environment]::UserName }
    Write-Host "  $(Get-I18nStr 'Check_CurrentUser' -Args @($currentUser))" -ForegroundColor Gray
    Write-Host "  $(Get-I18nStr 'Check_RegistryScope' -Args @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'))" -ForegroundColor Gray
    Write-Host "  $(Get-I18nStr 'Check_DefaultScope')" -ForegroundColor Gray
    $wslAvailable = $null -ne (Get-Command wsl.exe -ErrorAction SilentlyContinue)
    if (-not $wslAvailable) {
        Write-Host "  [!] $(Get-I18nStr 'Check_WslMissing')" -ForegroundColor Red
        $hasIssue = $true
    }
    $versionState = Get-WslPrecheckVersionState
    Write-Host "  $(Get-I18nStr 'Check_DefaultVersionTitle')" -ForegroundColor Cyan
    if ($versionState.Default.Known) {
        $colour = if ($versionState.Default.Version -eq 2) { 'Green' } else { 'Yellow' }
        Write-Host "  $(Get-I18nStr 'Check_DefaultVersion' -Args @($versionState.Default.Version, $versionState.Default.Source))" -ForegroundColor $colour
    } else {
        Write-Host "  [?] $(Get-I18nStr 'Check_DefaultUnknown')" -ForegroundColor Yellow
        $unknownChecks.Add('New distribution default version')
    }
    Show-WslKernelGuidance -CommandResult $versionState.Default.Command
    Write-Host "  $(Get-I18nStr 'Check_DistrosTitle')" -ForegroundColor Cyan
    if (-not $versionState.Inventory.Known) {
        Write-Host "  [?] $(Get-I18nStr 'Check_DistrosUnknown')" -ForegroundColor Yellow
        $unknownChecks.Add('Installed distribution versions')
    }
    foreach ($distro in $versionState.Inventory.Distributions) {
        if ($distro.Known) {
            $colour = if ($distro.Version -eq 2) { 'Green' } else { 'Yellow' }
            Write-Host "  $(Get-I18nStr 'Check_DistroVersion' -Args @($distro.Name, $distro.Version))" -ForegroundColor $colour
        } else {
            Write-Host "  [?] $(Get-I18nStr 'Check_DistroVersionUnknown' -Args @($distro.Name))" -ForegroundColor Yellow
        }
    }
    if ($versionState.Inventory.Known -and @($versionState.Inventory.Distributions).Count -eq 0) {
        Write-Host "  $(Get-I18nStr 'Check_NoDistros')" -ForegroundColor Gray
    }
    Show-WslKernelGuidance -CommandResult $versionState.Inventory.Command
    if ($versionState.HasIssue) { $hasIssue = $true }

    Write-Host "`n$(Get-I18nStr 'Check_Step4')" -ForegroundColor Yellow
    $isAdmin = Test-WslAdministrator
    Write-Host "  $(if ($isAdmin) { 'Administrator' } else { 'Normal user' })" -ForegroundColor Gray
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Write-Host '  [!] curl.exe missing!' -ForegroundColor Red
        $hasIssue = $true
    } else { Write-Host '  [✓] curl.exe' -ForegroundColor Green }

    Write-Host "`n$(Get-I18nStr 'Check_Step5')" -ForegroundColor Yellow
    $qualifier = Split-Path -Qualifier $DefaultWslRoot
    $driveLetter = if ($qualifier) { $qualifier.TrimEnd(':') } else { 'C' }
    $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        Write-Host "  Disk ${driveLetter}:\ Free Space: $freeGB GB" -ForegroundColor $(if ($freeGB -ge 10) { 'Green' } else { 'Yellow' })
        if ($freeGB -lt 10) { $hasIssue = $true }
    } else {
        $unknownChecks.Add("Drive ${driveLetter}: free space")
        $hasIssue = $true
    }

    Write-Host "`n==========================================" -ForegroundColor Cyan
    if (-not $hasIssue) {
        Write-Host "  [✓] $(Get-I18nStr 'Check_AllReady')" -ForegroundColor Green
        return
    }
    Write-Host "  [!] $(Get-I18nStr 'Check_IssuesFound')" -ForegroundColor Yellow
    if ($unknownChecks.Count -gt 0) {
        Write-Host "  $(Get-I18nStr 'Check_UnableVerify' -Args @(($unknownChecks -join ', ')))" -ForegroundColor Yellow
    }
    $disabled = @($features | Where-Object { $_.Result.Known -and $_.Result.State -in 'Disabled', 'DisabledWithPayloadRemoved' })
    foreach ($feature in $disabled) {
        Write-Host "  dism.exe /online /enable-feature /featurename:$($feature.Name) /all /norestart" -ForegroundColor Yellow
    }
    if ($versionState.NeedDefaultFix) { Write-Host '  wsl --set-default-version 2' -ForegroundColor Yellow }
    $hasVersionFix = $wslAvailable -and ($versionState.NeedDefaultFix -or @($versionState.Wsl1Distros).Count -gt 0)
    if (-not $hasVersionFix -and $disabled.Count -eq 0) {
        Write-Host "  $(Get-I18nStr 'Check_NoSafeFix')" -ForegroundColor Gray
        return
    }
    Write-Host "`n[Y] $(Get-I18nStr 'Check_AutoFixOption')" -ForegroundColor Green
    Write-Host " [N] $(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
    if ((Read-Host (Get-I18nStr 'Check_Fix_Prompt')) -ne 'Y') {
        Write-Host (Get-I18nStr 'Operation_Cancelled') -ForegroundColor Gray
        return
    }
    if ($wslAvailable) { $null = Invoke-WslVersionRepairs -VersionState $versionState -DefaultOnly }
    $featureRepair = Invoke-WslFeatureRepairs -FeatureStates $features -IsAdmin $isAdmin
    if ($wslAvailable) {
        $null = Invoke-WslVersionRepairs -VersionState $versionState -SkipDefault -AllowConversion $featureRepair.CanConvert
    }
    Write-Host "`n$(Get-I18nStr 'Check_FixSummary')" -ForegroundColor Cyan
}

if (-not $NoRun) { Invoke-WslPrecheck }
