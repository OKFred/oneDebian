# Offline firstboot protection checks. Native WSL and systemd mutations are stubbed.
$ErrorActionPreference = 'Stop'
$firstBootRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $firstBootRepoRoot 'components\wsl_common.ps1')
. (Join-Path $firstBootRepoRoot 'components\wsl_i18n.ps1')
. (Join-Path $firstBootRepoRoot 'components\wsl_firstboot.ps1')
$script:firstBootTestCount = 0
$script:firstBootFailures = New-Object System.Collections.Generic.List[string]

function Assert-FirstBoot {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Test-FirstBootCase {
    param([string]$Name, [scriptblock]$Body)
    $script:firstBootTestCount++
    try { & $Body; Write-Host "  PASS $Name" -ForegroundColor Green }
    catch { $script:firstBootFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "  FAIL ${Name}: $($_.Exception.Message)" -ForegroundColor Red }
}
function New-FirstBootCommand {
    param([string]$Text = '', [int]$ExitCode = 0, [bool]$IsDecoded = $true, [string]$ErrorText = '')
    [pscustomobject]@{ Text = $Text; ErrorText = $ErrorText; ExitCode = $ExitCode; IsDecoded = $IsDecoded }
}
function New-FirstBootResult {
    param([bool]$Success = $true, [bool]$Present = $true, [bool]$Changed = $true)
    [pscustomobject]@{ Success = $Success; Present = $Present; Changed = $Changed; Error = $(if ($Success) { '' } else { 'fixture mask failure' }) }
}
function New-FirstBootMarker {
    param([string]$Present = 'yes', [string]$Changed = 'yes')
    "__WSL_FIRSTBOOT_V1__`nPRESENT=$Present`nCHANGED=$Changed`n__WSL_FIRSTBOOT_END__`n"
}

function New-WindowsDefaultsFixture { [pscustomobject]@{ Locale = 'en_SG.UTF-8'; Messages = 'en_GB.UTF-8'; TimeZone = 'China Standard Time' } }

Test-FirstBootCase 'Windows locale mapping preserves regional and display choices and rejects ambiguous variants' {
    Assert-FirstBoot ((ConvertTo-WslLocaleName -Culture ([Globalization.CultureInfo]'en-SG')) -ceq 'en_SG.UTF-8') 'regional culture was mapped incorrectly'
    Assert-FirstBoot ((ConvertTo-WslLocaleName -Culture ([Globalization.CultureInfo]'en-GB')) -ceq 'en_GB.UTF-8') 'display culture was mapped incorrectly'
    foreach ($name in @('en', 'sr-Latn-RS')) {
        $failed = $false
        try { ConvertTo-WslLocaleName -Culture ([Globalization.CultureInfo]$name) | Out-Null } catch { $failed = $true }
        Assert-FirstBoot $failed 'an ambiguous Windows culture was silently mapped'
    }
}
Test-FirstBootCase 'Windows defaults read regional and UI cultures without using the legacy system locale' {
    function Get-Culture { [Globalization.CultureInfo]'en-SG' }
    function Get-UICulture { [Globalization.CultureInfo]'en-GB' }
    function Get-TimeZone { [pscustomobject]@{ Id = 'China Standard Time' } }
    function Get-WinSystemLocale { throw 'legacy non-Unicode system locale must not determine the user language' }
    $defaults = Get-WslWindowsDefaults
    Assert-FirstBoot ($defaults.Locale -ceq 'en_SG.UTF-8' -and $defaults.Messages -ceq 'en_GB.UTF-8' -and $defaults.TimeZone -ceq 'China Standard Time') 'Windows defaults mixed the user language settings'
}
Test-FirstBootCase 'locale preparation preserves positional arguments and rejects unverified completion' {
    $tracking = [pscustomobject]@{ Arguments = @() }
    function Invoke-WslCommand { param($Arguments) $tracking.Arguments = $Arguments; New-FirstBootCommand "__WSL_LOCALE_READY_V1__`n" }
    $name = 'Debian QA''s 中文'
    Initialize-WslLocaleData -Distro $name -Locale 'en_SG.UTF-8' -Messages 'en_GB.UTF-8'
    Assert-FirstBoot ($tracking.Arguments[1] -ceq $name -and ($tracking.Arguments[-3..-1] -join ',') -ceq '--,en_SG.UTF-8,en_GB.UTF-8') 'locale data was interpolated into shell text'
    foreach ($command in @((New-FirstBootCommand -ExitCode 1), (New-FirstBootCommand -Text '__WSL_LOCALE_READY_V1__' -IsDecoded $false), (New-FirstBootCommand -Text 'incomplete'))) {
        function Invoke-WslCommand { param($Arguments) $command }
        $failed = $false
        try { Initialize-WslLocaleData -Distro $name -Locale 'en_SG.UTF-8' -Messages 'en_GB.UTF-8' } catch { $failed = $true }
        Assert-FirstBoot $failed 'locale preparation accepted unverified execution'
    }
}

Test-FirstBootCase 'verified protection preserves the exact selected distribution argument' {
    $tracking = [pscustomobject]@{ Arguments = @() }
    function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) $tracking.Arguments = $Arguments; New-FirstBootCommand (New-FirstBootMarker) }
    $name = 'Debian QA''s 中文'
    $result = Set-WslFirstBootProtection -Distro $name
    Assert-FirstBoot ($result.Success -and $result.Present -and $result.Changed) 'verified protection was not accepted'
    Assert-FirstBoot ($tracking.Arguments[1] -ceq $name -and $tracking.Arguments -contains 'root') 'the distribution was interpolated into shell text or not run as root'
}
Test-FirstBootCase 'missing service and an unchanged mask are verified without claiming a change' {
    foreach ($present in @('yes', 'no')) {
        $text = New-FirstBootMarker -Present $present -Changed 'no'
        function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) New-FirstBootCommand $text }
        $result = Set-WslFirstBootProtection -Distro 'Debian QA'
        Assert-FirstBoot ($result.Success -and -not $result.Changed -and $result.Present -eq ($present -eq 'yes')) 'absent and already protected states were conflated'
    }
}
Test-FirstBootCase 'a native failure or invalid readback cannot report successful protection' {
    foreach ($command in @(
        (New-FirstBootCommand -Text (New-FirstBootMarker) -ExitCode 1),
        (New-FirstBootCommand -Text (New-FirstBootMarker) -IsDecoded $false),
        (New-FirstBootCommand -Text '__WSL_FIRSTBOOT_V1__'),
        (New-FirstBootCommand -Text (New-FirstBootMarker -Present 'unknown'))
    )) {
        function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) $command }
        Assert-FirstBoot (-not (Set-WslFirstBootProtection -Distro 'Debian QA').Success) 'unverified protection was reported as successful'
    }
}
Test-FirstBootCase 'WSL failures written to stdout remain visible' {
    function Invoke-WslCommand { param($Arguments, $TimeoutMilliseconds) New-FirstBootCommand -Text 'Wsl/Service/E_UNEXPECTED' -ExitCode -1 }
    $result = Set-WslFirstBootProtection -Distro 'Debian QA'
    Assert-FirstBoot (-not $result.Success -and $result.Error.Contains('Wsl/Service/E_UNEXPECTED')) 'stdout startup error was swallowed'
}
Test-FirstBootCase 'protection failure stops setup before any interactive initialization' {
    function Set-WslFirstBootProtection { param($Distro) New-FirstBootResult -Success $false }
    function Read-Host { throw 'failed protection must not prompt' }
    function wsl.exe { throw 'failed protection must not initialize' }
    function Write-Host { param($Object, $ForegroundColor) }
    $failed = $false
    try { Invoke-WslFirstBootSetup -Distro 'Debian QA' -PromptInitialize } catch { $failed = $_.Exception.Message.Contains('fixture mask failure') }
    Assert-FirstBoot $failed 'a failed mask allowed setup to continue'
}
Test-FirstBootCase 'systemd configuration protects firstboot without asking to initialize' {
    $tracking = [pscustomobject]@{ Protections = 0 }
    function Set-WslFirstBootProtection { param($Distro) $tracking.Protections++; New-FirstBootResult }
    function Read-Host { throw 'configuration protection must not open an initialization prompt' }
    function wsl.exe { throw 'configuration protection must not initialize' }
    function Get-WslWindowsDefaults { throw 'configuration protection must not read Windows defaults' }
    function Write-Host { param($Object, $ForegroundColor) }
    Invoke-WslFirstBootSetup -Distro 'Debian QA'
    Assert-FirstBoot ($tracking.Protections -eq 1) 'configuration did not protect firstboot exactly once'
}
Test-FirstBootCase 'the default installation choice keeps the background wizard masked' {
    function Set-WslFirstBootProtection { param($Distro) New-FirstBootResult }
    function Test-WslFirstBootInteractive { $true }
    function Read-Host { param($Prompt) '' }
    function wsl.exe { throw 'the default choice must not initialize interactively' }
    function Get-WslWindowsDefaults { New-WindowsDefaultsFixture }
    function Initialize-WslLocaleData { throw 'declining initialization must not generate locale data' }
    function Write-Host { param($Object, $ForegroundColor) }
    Invoke-WslFirstBootSetup -Distro 'Debian QA' -PromptInitialize
}
Test-FirstBootCase 'confirmed initialization inherits Windows defaults and prompts only for the root password' {
    $tracking = [pscustomobject]@{ Arguments = @(); Calls = 0; LocaleArguments = @() }
    function Set-WslFirstBootProtection { param($Distro) New-FirstBootResult }
    function Test-WslFirstBootInteractive { $true }
    function Read-Host { param($Prompt) 'Y' }
    function Write-Host { param($Object, $ForegroundColor) }
    function Get-WslWindowsDefaults { New-WindowsDefaultsFixture }
    function Invoke-WslCommand { param($Arguments) $tracking.LocaleArguments = $Arguments; New-FirstBootCommand "__WSL_LOCALE_READY_V1__`n" }
    function wsl.exe { $tracking.Arguments = @($args); $tracking.Calls++; $global:LASTEXITCODE = 0 }
    Invoke-WslFirstBootSetup -Distro 'Debian QA' -PromptInitialize
    Assert-FirstBoot ($tracking.Calls -eq 1 -and $tracking.Arguments -contains 'Debian QA') 'confirmed initialization did not directly execute the selected distribution'
    foreach ($option in @('--locale=en_SG.UTF-8', '--locale-messages=en_GB.UTF-8', '--prompt-root-password')) {
        Assert-FirstBoot ($tracking.Arguments -contains $option) "missing interactive option $option"
    }
    Assert-FirstBoot (($tracking.Arguments -join ' ') -notmatch '--(?:prompt-locale|prompt-keymap|prompt-timezone|timezone=|keymap=)') 'Windows timezone or terminal input was overridden'
    Assert-FirstBoot ($tracking.LocaleArguments -contains 'en_SG.UTF-8' -and $tracking.LocaleArguments -contains 'en_GB.UTF-8' -and $tracking.LocaleArguments -notcontains 'systemd-firstboot') 'locale data preparation captured password input or used the wrong languages'
    Assert-FirstBoot ($tracking.Arguments -contains '--force') 'the confirmed initialization could silently skip all preconfigured image values'
    Assert-FirstBoot (($tracking.Arguments -join ' ') -notmatch '--(?:reset|root-password=|root-password-hashed=)') 'initialization reset the image or passed a password value on the command line'
}
Test-FirstBootCase 'noninteractive installation does not run the password wizard' {
    function Set-WslFirstBootProtection { param($Distro) New-FirstBootResult }
    function Test-WslFirstBootInteractive { $false }
    function Read-Host { param($Prompt) 'Y' }
    function Write-Host { param($Object, $ForegroundColor) }
    function wsl.exe { throw 'noninteractive initialization must not execute or hang' }
    function Get-WslWindowsDefaults { throw 'noninteractive installation must not read Windows defaults' }
    Invoke-WslFirstBootSetup -Distro 'Debian QA' -PromptInitialize
}
Test-FirstBootCase 'a failed interactive initialization cannot be reported as complete' {
    function Set-WslFirstBootProtection { param($Distro) New-FirstBootResult }
    function Test-WslFirstBootInteractive { $true }
    function Read-Host { param($Prompt) 'Y' }
    function Write-Host { param($Object, $ForegroundColor) }
    function wsl.exe { $global:LASTEXITCODE = 17 }
    function Get-WslWindowsDefaults { New-WindowsDefaultsFixture }
    function Initialize-WslLocaleData { }
    $failed = $false
    try { Invoke-WslFirstBootSetup -Distro 'Debian QA' -PromptInitialize } catch { $failed = $_.Exception.Message.Contains('17') }
    Assert-FirstBoot $failed 'failed interactive initialization was reported as complete'
}
Test-FirstBootCase 'failed locale preparation stops before the password prompt' {
    function Set-WslFirstBootProtection { param($Distro) New-FirstBootResult }
    function Test-WslFirstBootInteractive { $true }
    function Read-Host { param($Prompt) 'Y' }
    function Write-Host { param($Object, $ForegroundColor) }
    function Get-WslWindowsDefaults { New-WindowsDefaultsFixture }
    function Invoke-WslCommand { param($Arguments) New-FirstBootCommand -ExitCode 17 -ErrorText 'fixture locale generation failure' }
    function wsl.exe { throw 'locale preparation failure must not reach password initialization' }
    $failed = $false
    try { Invoke-WslFirstBootSetup -Distro 'Debian QA' -PromptInitialize } catch { $failed = $_.Exception.Message.Contains('fixture locale generation failure') }
    Assert-FirstBoot $failed 'locale preparation failed without its diagnostic or still prompted for a password'
}
Test-FirstBootCase 'unavailable Windows defaults show manual guidance without initializing or failing setup' {
    function Set-WslFirstBootProtection { param($Distro) New-FirstBootResult }
    function Test-WslFirstBootInteractive { $true }
    function Get-WslWindowsDefaults { throw 'fixture unsupported Windows culture' }
    function Read-Host { throw 'unsupported defaults must not show a misleading confirmation' }
    $messages = New-Object System.Collections.Generic.List[string]
    function Write-Host { param($Object, $ForegroundColor) $messages.Add([string]$Object) }
    function wsl.exe { throw 'unsupported defaults must not initialize' }
    Invoke-WslFirstBootSetup -Distro 'Debian QA' -PromptInitialize
    Assert-FirstBoot (@($messages | Where-Object { $_.Contains('fixture unsupported Windows culture') }).Count -eq 1) 'unsupported Windows defaults were silently ignored'
    Assert-FirstBoot (@($messages | Where-Object { $_.Contains('systemd-firstboot') }).Count -eq 1) 'manual initialization guidance was not provided'
}
Test-FirstBootCase 'a distribution without firstboot does not prompt for initialization' {
    function Set-WslFirstBootProtection { param($Distro) New-FirstBootResult -Present $false -Changed $false }
    function Read-Host { throw 'a missing firstboot binary/service must not prompt' }
    function wsl.exe { throw 'a missing firstboot service must not initialize' }
    function Write-Host { param($Object, $ForegroundColor) }
    Invoke-WslFirstBootSetup -Distro 'Debian QA' -PromptInitialize
}

# Run the service-file checks against a private tree, never the guest or host /etc.
function Invoke-FirstBootFixture {
    param([scriptblock]$Body)
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('oneDebian firstboot tests ' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    try {
        $bash = 'C:\Program Files\Git\bin\bash.exe'
        $converted = Invoke-WslCommand -FilePath $bash -Arguments @('--noprofile', '--norc', '-c', 'cygpath -u "$1"', '--', $fixtureRoot) -TimeoutMilliseconds 10000
        Assert-FirstBoot ($converted.ExitCode -eq 0) 'could not resolve the private fixture path'
        $unixRoot = $converted.Text.Trim()
        foreach ($directory in @('etc\systemd\system', 'usr\lib\systemd\system', 'proc\1')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $directory) -Force
        }
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'proc\1\comm'), "init`n")
        $escapedRoot = $unixRoot.Replace(' ', '\ ')
        $script = [regex]::Replace((Get-WslFirstBootProtectionScript), '/(?:etc|usr/lib|lib|proc)/', { param($match) "$escapedRoot$($match.Value)" })
        $scriptPath = Join-Path $fixtureRoot 'firstboot fixture.sh'
        [IO.File]::WriteAllText($scriptPath, ($script -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        & $Body ([pscustomobject]@{ Root = $fixtureRoot; UnixRoot = $unixRoot; Bash = $bash; Script = $scriptPath.Replace('\', '/') })
    } finally {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot -ErrorAction Stop).ProviderPath
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -cne [IO.Path]::GetFileName($fixtureRoot)) { throw 'Unsafe firstboot fixture cleanup target.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Test-FirstBootCase 'the actual shell skips an absent service without creating a mask' {
    Invoke-FirstBootFixture {
        param($fixture)
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script) -TimeoutMilliseconds 10000
        Assert-FirstBoot ($result.ExitCode -eq 0 -and $result.Text.Contains('PRESENT=no')) 'a system without firstboot was treated as a failure'
        Assert-FirstBoot (@(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'etc\systemd\system')).Count -eq 0) 'the missing service still received a mask'
    }
}
Test-FirstBootCase 'the actual shell refuses to overwrite a custom local service' {
    Invoke-FirstBootFixture {
        param($fixture)
        $path = Join-Path $fixture.Root 'etc\systemd\system\systemd-firstboot.service'
        $original = "[Service]`nExecStart=/custom/firstboot`n"
        [IO.File]::WriteAllText($path, $original)
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script) -TimeoutMilliseconds 10000
        Assert-FirstBoot ($result.ExitCode -ne 0 -and [IO.File]::ReadAllText($path) -ceq $original) 'the existing custom unit was modified'
    }
}

function Invoke-LocaleShellFixture {
    param([scriptblock]$LocaleBody)
    Invoke-FirstBootFixture {
        param($fixture)
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Root 'definitions')
        foreach ($name in @('en_SG', 'en_GB')) { [IO.File]::WriteAllText((Join-Path $fixture.Root "definitions\$name"), 'fixture definition') }
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'generated'), "C.utf8`nen_US.utf8`n")
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'calls'), '')
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'locale.gen'), "# keep existing locale definitions`nen_US.UTF-8 UTF-8`n")
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'archive'), 'existing locale archive')
        $prelude = @'
locale() {
  case "$1" in -a) cat "$fixture_root/generated" ;; charmap) printf 'UTF-8\n' ;; *) return 91 ;; esac
}
localedef() {
  printf '%s\n' "$*" >>"$fixture_root/calls"
  [ ! -f "$fixture_root/fail" ] || return 42
  if [ ! -f "$fixture_root/no-generate" ]; then printf '%s\n' "${!#}" >>"$fixture_root/generated"; fi
}
rm() { printf 'Unexpected removal.\n' >&2; return 99; }
'@
        $escapedRoot = $fixture.UnixRoot.Replace(' ', '\ ')
        $script = (Get-WslLocalePreparationScript).Replace('/usr/share/i18n/locales/', ($fixture.UnixRoot + '/definitions/')).Replace('/etc/locale.gen', ($escapedRoot + '/locale.gen'))
        $quotedRoot = $fixture.UnixRoot.Replace("'", "'\''")
        $scriptPath = Join-Path $fixture.Root 'locale fixture.sh'
        [IO.File]::WriteAllText($scriptPath, (("fixture_root='$quotedRoot'`n" + $prelude + "`n" + $script) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        & $LocaleBody ([pscustomobject]@{ Root = $fixture.Root; Bash = $fixture.Bash; Script = $scriptPath.Replace('\', '/') })
    }
}
Test-FirstBootCase 'locale data generation preserves existing locales and persists choices exactly once' {
    Invoke-LocaleShellFixture {
        param($fixture)
        $arguments = @('--noprofile', '--norc', $fixture.Script, 'en_SG.UTF-8', 'en_GB.UTF-8')
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments $arguments -TimeoutMilliseconds 10000
        Assert-FirstBoot ($result.ExitCode -eq 0 -and $result.Text.Trim() -ceq '__WSL_LOCALE_READY_V1__') 'locale data was not generated and verified'
        $original = "# keep existing locale definitions`nen_US.UTF-8 UTF-8`n"
        Assert-FirstBoot ([IO.File]::ReadAllText((Join-Path $fixture.Root 'locale.gen.onedebian.bak')) -ceq $original) 'the original locale configuration was not backed up'
        $configured = [IO.File]::ReadAllText((Join-Path $fixture.Root 'locale.gen'))
        Assert-FirstBoot ($configured.StartsWith($original) -and $configured.Contains('en_SG.UTF-8 UTF-8') -and $configured.Contains('en_GB.UTF-8 UTF-8')) 'locale configuration replaced existing choices or omitted Windows defaults'
        Assert-FirstBoot ([IO.File]::ReadAllText((Join-Path $fixture.Root 'archive')) -ceq 'existing locale archive') 'locale preparation removed the existing archive'
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments $arguments -TimeoutMilliseconds 10000
        Assert-FirstBoot ($result.ExitCode -eq 0 -and [IO.File]::ReadAllText((Join-Path $fixture.Root 'locale.gen')) -ceq $configured) 'repeated preparation duplicated locale definitions'
        Assert-FirstBoot (@(Get-Content -LiteralPath (Join-Path $fixture.Root 'calls')).Count -eq 2) 'existing generated locales were regenerated'
        Assert-FirstBoot ([IO.File]::ReadAllText((Join-Path $fixture.Root 'locale.gen.onedebian.bak')) -ceq $original) 'repeated preparation replaced the original backup'
    }
}
Test-FirstBootCase 'missing locale definitions fail before generating either locale' {
    Invoke-LocaleShellFixture {
        param($fixture)
        Remove-Item -LiteralPath (Join-Path $fixture.Root 'definitions\en_GB')
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script, 'en_SG.UTF-8', 'en_GB.UTF-8') -TimeoutMilliseconds 10000
        Assert-FirstBoot ($result.ExitCode -ne 0 -and (Get-Item -LiteralPath (Join-Path $fixture.Root 'calls')).Length -eq 0) 'an unsupported second locale partially generated the first'
        Assert-FirstBoot (-not (Test-Path -LiteralPath (Join-Path $fixture.Root 'locale.gen.onedebian.bak'))) 'failed validation changed locale configuration'
    }
}
Test-FirstBootCase 'locale generator errors cannot report completion or persist incomplete choices' {
    Invoke-LocaleShellFixture {
        param($fixture)
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'fail'), '')
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script, 'en_SG.UTF-8', 'en_GB.UTF-8') -TimeoutMilliseconds 10000
        Assert-FirstBoot ($result.ExitCode -eq 42 -and -not $result.Text.Contains('__WSL_LOCALE_READY_V1__')) 'localedef failure was ignored'
        Assert-FirstBoot (-not (Test-Path -LiteralPath (Join-Path $fixture.Root 'locale.gen.onedebian.bak'))) 'failed generation persisted incomplete choices'
    }
}
Test-FirstBootCase 'UTF-8 fallback cannot substitute for an actually generated locale' {
    Invoke-LocaleShellFixture {
        param($fixture)
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'no-generate'), '')
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script, 'en_SG.UTF-8', 'en_GB.UTF-8') -TimeoutMilliseconds 10000
        Assert-FirstBoot ($result.ExitCode -ne 0 -and -not $result.Text.Contains('__WSL_LOCALE_READY_V1__')) 'the ambient UTF-8 locale hid missing generated data'
    }
}
Test-FirstBootCase 'unsafe locale backup paths fail before any generation' {
    Invoke-LocaleShellFixture {
        param($fixture)
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Root 'locale.gen.onedebian.bak')
        $result = Invoke-WslCommand -FilePath $fixture.Bash -Arguments @('--noprofile', '--norc', $fixture.Script, 'en_SG.UTF-8', 'en_GB.UTF-8') -TimeoutMilliseconds 10000
        Assert-FirstBoot ($result.ExitCode -ne 0 -and (Get-Item -LiteralPath (Join-Path $fixture.Root 'calls')).Length -eq 0) 'an unsafe backup path was ignored'
    }
}

Test-FirstBootCase 'installation applies firstboot protection before the first version query' {
    $source = [IO.File]::ReadAllText((Join-Path $firstBootRepoRoot 'components\wsl_install.ps1'))
    $import = $source.IndexOf('& wsl.exe --import ')
    $protect = $source.IndexOf('Invoke-WslFirstBootSetup -Distro $DistroName -PromptInitialize')
    $query = $source.IndexOf('-- cat /etc/debian_version')
    Assert-FirstBoot ($import -ge 0 -and $protect -gt $import -and $query -gt $protect) 'the imported instance was queried before firstboot protection/setup'
}

. (Join-Path $firstBootRepoRoot 'components\wsl_config.ps1')
function Initialize-FirstBootConfigFixture {
    $tracking = [pscustomobject]@{ Events = (New-Object System.Collections.Generic.List[string]); Answer = 'Y'; FailProtection = $false; ExistingSystemd = 'false' }
    function Write-Host { param($Object, $ForegroundColor) }
    function Select-WslDistro { param($Title) 'Debian QA' }
    function Read-ConfigPrompt {
        param($Message, $CurrentValue, $AllowedValues, $Normalizer, $Validator, $HintText)
        if ($Message -like '启用 systemd*') { return [pscustomobject]@{ Action = 'Set'; Value = 'true' } }
        [pscustomobject]@{ Action = 'Keep'; Value = $CurrentValue }
    }
    function Show-ConfigDiff { param($OldContent, $NewContent, $TargetTitle) }
    function Read-Host { param($Prompt) $tracking.Answer }
    function Invoke-WslFirstBootSetup {
        param($Distro, [switch]$PromptInitialize)
        $tracking.Events.Add('firstboot')
        Assert-FirstBoot (-not $PromptInitialize) 'systemd config unexpectedly requested a password wizard'
        if ($tracking.FailProtection) { throw 'fixture mask failure' }
    }
    function Invoke-WslNetworkRepairPrompt { param($Distro, [switch]$PrepareSystemd) $tracking.Events.Add('network'); $true }
    function wsl.exe {
        $global:LASTEXITCODE = 0
        if (($args -join ' ') -match 'if \[ -f /etc/wsl.conf \]; then cat') { "[boot]`nsystemd=$($tracking.ExistingSystemd)`n" }
        else { $tracking.Events.Add('write') }
    }
}
Test-FirstBootCase 'cancelling the final systemd save never modifies firstboot or configuration' {
    . Initialize-FirstBootConfigFixture
    $tracking.Answer = 'N'
    Configure-SingleDistroConf
    Assert-FirstBoot ($tracking.Events.Count -eq 0) 'cancelled systemd save still changed firstboot or configuration'
}
Test-FirstBootCase 'confirmed systemd save protects firstboot before network checks and config writes' {
    . Initialize-FirstBootConfigFixture
    Configure-SingleDistroConf
    Assert-FirstBoot (($tracking.Events -join ',') -eq 'firstboot,network,write,write') 'protection did not precede the systemd configuration write'
}
Test-FirstBootCase 'failed firstboot protection leaves systemd configuration unchanged' {
    . Initialize-FirstBootConfigFixture
    $tracking.FailProtection = $true
    Configure-SingleDistroConf
    Assert-FirstBoot (($tracking.Events -join ',') -eq 'firstboot') 'a failed mask still saved systemd or ran network repair'
}
Test-FirstBootCase 'keeping systemd disabled never changes firstboot' {
    . Initialize-FirstBootConfigFixture
    function Read-ConfigPrompt {
        param($Message, $CurrentValue, $AllowedValues, $Normalizer, $Validator, $HintText)
        [pscustomobject]@{ Action = 'Keep'; Value = $CurrentValue }
    }
    Configure-SingleDistroConf
    Assert-FirstBoot ($tracking.Events.Count -eq 0) 'a systemd-off configuration still modified firstboot'
}
Test-FirstBootCase 'an unchanged systemd configuration needs separate confirmation before masking' {
    . Initialize-FirstBootConfigFixture
    $tracking.ExistingSystemd = 'true'
    $tracking.Answer = 'N'
    Configure-SingleDistroConf
    Assert-FirstBoot (($tracking.Events -join ',') -eq 'network') 'unchanged settings caused unconfirmed firstboot/configuration mutation'
}

function Invoke-FirstBootInstallFlowFixture {
    param([bool]$Interactive = $true, [bool]$Present = $true, [string]$InitializeAnswer = 'Y', [int]$BootstrapExitCode = 0, [string]$BootstrapAnswer = 'Y', [int]$LocaleExitCode = 0, [bool]$DefaultsAvailable = $true)
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('oneDebian install flow ' + [guid]::NewGuid().ToString('N'))
    $tracking = [pscustomobject]@{
        Interactive = $Interactive; Present = $Present; Imports = 0; Protections = 0; Initializations = 0
        Bootstraps = 0; BootstrapExitCode = $BootstrapExitCode; Failure = ''
        LocalePreparations = 0; LocaleExitCode = $LocaleExitCode; DefaultsReads = 0; DefaultsAvailable = $DefaultsAvailable
        Prompts = (New-Object System.Collections.Generic.List[string]); Messages = (New-Object System.Collections.Generic.List[string])
        Events = (New-Object System.Collections.Generic.List[string]); NativeArguments = @()
        Answers = (New-Object System.Collections.Generic.Queue[string]); Hash = ''
    }
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'components\locales') -Force
    try {
        foreach ($file in @('wsl_install.ps1', 'wsl_firstboot.ps1', 'wsl_i18n.ps1', 'wsl_network.ps1', 'wsl_bootstrap.ps1', 'the_os_release.sh', 'the_repo_localization.sh', 'the_basic_setup.sh')) {
            Copy-Item -LiteralPath (Join-Path $firstBootRepoRoot "components\$file") -Destination (Join-Path $fixtureRoot "components\$file")
        }
        Copy-Item -LiteralPath (Join-Path $firstBootRepoRoot 'bootstrap.sh') -Destination (Join-Path $fixtureRoot 'bootstrap.sh')
        foreach ($language in @('zh-CN', 'en-US')) {
            Copy-Item -LiteralPath (Join-Path $firstBootRepoRoot "components\locales\$language.json") -Destination (Join-Path $fixtureRoot "components\locales\$language.json")
        }
        # Keep the real installer/helper and replace only external execution and host capabilities.
        $common = @'
function Get-WslDistros { @() }
function Invoke-WslCommand {
    param($Arguments, $TimeoutMilliseconds)
    if (($Arguments -join "`n").Contains('__WSL_LOCALE_READY_V1__')) {
        $tracking.LocalePreparations++; $tracking.Events.Add('locale')
        $text = if ($tracking.LocaleExitCode -eq 0) { "__WSL_LOCALE_READY_V1__`n" } else { 'fixture locale failure' }
        return New-FirstBootCommand -Text $text -ExitCode $tracking.LocaleExitCode
    }
    if ($Arguments[-1].Contains('__WSL_FIRSTBOOT_V1__')) {
        $tracking.Protections++; $tracking.Events.Add('protect')
        $present = if ($tracking.Present) { 'yes' } else { 'no' }
        return New-FirstBootCommand (New-FirstBootMarker -Present $present -Changed $present)
    }
    if ($Arguments[-1].Contains('__WSL_NETWORK_V1__')) {
        $tracking.Events.Add('network')
        return New-FirstBootCommand "__WSL_NETWORK_V1__`nSYSTEMD=false`nIPV4=yes`nROUTE=yes`nIFACE=eth0`nETH0=yes`nNM=no`nNETWORKD=no`nNM_ACTIVE=no`nNETWORKD_ACTIVE=no`nNM_ENABLED=no`nNETWORKD_ENABLED=no`nNM_PROTECTED=yes`nNETWORKD_PROTECTED=yes`nMODE=nat`n__WSL_NETWORK_END__"
    }
    if ($Arguments[-1].Contains('ONEDEBIAN_BOOTSTRAP_OK')) {
        $tracking.Bootstraps++; $tracking.Events.Add('bootstrap')
        $text = if ($tracking.BootstrapExitCode -eq 0) { "ONEDEBIAN_BOOTSTRAP_OK`n" } else { 'fixture package failure' }
        return New-FirstBootCommand -Text $text -ExitCode $tracking.BootstrapExitCode
    }
    throw 'Unexpected guest query escaped the installation fixture boundary.'
}
'@
        $common = [IO.File]::ReadAllText((Join-Path $firstBootRepoRoot 'components\wsl_common.ps1'), [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) + "`n" + $common
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'components\wsl_common.ps1'), $common, (New-Object Text.UTF8Encoding($true)))
        Add-Content -LiteralPath (Join-Path $fixtureRoot 'components\wsl_firstboot.ps1') -Value "`nfunction Test-WslFirstBootInteractive { return `$tracking.Interactive }" -Encoding UTF8
        Add-Content -LiteralPath (Join-Path $fixtureRoot 'components\wsl_firstboot.ps1') -Value "`nfunction Get-WslWindowsDefaults { `$tracking.DefaultsReads++; if (-not `$tracking.DefaultsAvailable) { throw 'fixture unsupported Windows culture' }; New-WindowsDefaultsFixture }" -Encoding UTF8
        $tokens = $null; $errors = $null
        $menuAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $firstBootRepoRoot 'menu.ps1'), [ref]$tokens, [ref]$errors)
        $wrapper = $menuAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Install-Wrapper' }, $true)
        Assert-FirstBoot ($errors.Count -eq 0 -and $null -ne $wrapper) 'could not load the actual menu 01 wrapper'
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'menu.ps1'), ($wrapper.Extent.Text + "`nInvoke-Install-Wrapper`n"), (New-Object Text.UTF8Encoding($true)))
        $installRoot = Join-Path $fixtureRoot 'instances'
        $null = New-Item -ItemType Directory -Path (Join-Path $installRoot 'images') -Force
        $archive = Join-Path $installRoot 'images\debian-13-rootfs.tar.xz'
        [IO.File]::WriteAllText($archive, 'private verified cache fixture, not a real rootfs')
        $tracking.Hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        foreach ($answer in @('13', 'oneDebian-install-fixture', $installRoot, 'Y')) { $tracking.Answers.Enqueue($answer) }
        if ($Interactive -and $Present -and $DefaultsAvailable) { $tracking.Answers.Enqueue($InitializeAnswer) }
        if ($Interactive) { $tracking.Answers.Enqueue($BootstrapAnswer) }
        function Read-Host {
            param($Prompt)
            $tracking.Prompts.Add([string]$Prompt)
            if ($tracking.Answers.Count -eq 0) { throw 'Unexpected additional installation prompt.' }
            $tracking.Answers.Dequeue()
        }
        function Write-Host { param($Object, $ForegroundColor) $tracking.Messages.Add([string]$Object) }
        function curl.exe {
            $global:LASTEXITCODE = 0
            if ($args -contains '-o') { throw 'A download escaped the private verified cache fixture.' }
            if ([string]$args[-1] -like '*/SHA256SUMS') { return "$($tracking.Hash)  rootfs.tar.xz" }
            '<a href="20261109_0000/">fixture build</a>'
        }
        function wsl.exe {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq '--import') { $tracking.Imports++; $tracking.Events.Add('import'); return }
            if ($args -contains 'systemd-firstboot') {
                $tracking.Initializations++; $tracking.Events.Add('initialize'); $tracking.NativeArguments = @($args); return
            }
            if ($args -contains '/etc/debian_version') { $tracking.Events.Add('version'); return '13.0' }
            if ($args[0] -eq '--list') { return }
            throw 'A native WSL call escaped the installation fixture boundary.'
        }
        try { & (Join-Path $fixtureRoot 'menu.ps1') | Out-Null }
        catch { $tracking.Failure = $_.Exception.Message }
        return $tracking
    } finally {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot -ErrorAction Stop).ProviderPath
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -cne [IO.Path]::GetFileName($fixtureRoot)) { throw 'Unsafe install fixture cleanup target.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Test-FirstBootCase 'menu 01 reaches the visible initialization choice and its native action' {
    $flow = Invoke-FirstBootInstallFlowFixture
    Assert-FirstBoot ($flow.Imports -eq 1 -and $flow.Protections -eq 1 -and $flow.Initializations -eq 1) 'the actual menu/install flow did not reach native firstboot initialization'
    Assert-FirstBoot ($flow.Prompts.Count -eq 6 -and $flow.Answers.Count -eq 0) 'the installation initialization questions were not visible or an answer was unused'
    $initializePrompt = Get-I18nStr 'FirstBoot_InitializePrompt' -Args @('oneDebian-install-fixture')
    Assert-FirstBoot ($flow.Prompts[4] -ceq $initializePrompt -and $initializePrompt -ne 'FirstBoot_InitializePrompt') 'the actual installation did not show the translated initialization choice'
    Assert-FirstBoot ($flow.Prompts[-1].Contains('Bash 01') -and $flow.Prompts[-1].Contains('[y/N]') -and $flow.Bootstraps -eq 1) 'package initialization did not require its own default-no choice'
    Assert-FirstBoot (($flow.Events -join ',') -eq 'import,protect,locale,initialize,version,network,bootstrap' -and -not $flow.Failure) 'the actual installation steps ran in an unexpected order or failed'
    Assert-FirstBoot ($flow.NativeArguments -contains '--prompt-root-password' -and $flow.NativeArguments -contains '--force') 'the initialization action can skip the preconfigured root-password field'
    Assert-FirstBoot ($flow.NativeArguments -contains '--locale=en_SG.UTF-8' -and $flow.NativeArguments -contains '--locale-messages=en_GB.UTF-8') 'the installer did not inherit distinct Windows region and display languages'
    Assert-FirstBoot (@($flow.Messages | Where-Object { $_.Contains('en_SG.UTF-8') -and $_.Contains('en_GB.UTF-8') -and $_.Contains('China Standard Time') }).Count -eq 1) 'the Windows defaults were not visible before confirmation'
}
Test-FirstBootCase 'menu 01 declining initialization never re-prompts or changes the image values' {
    $flow = Invoke-FirstBootInstallFlowFixture -InitializeAnswer 'N'
    Assert-FirstBoot ($flow.Imports -eq 1 -and $flow.Protections -eq 1 -and $flow.Initializations -eq 0) 'declining initialization still executed the interactive native action'
    Assert-FirstBoot ($flow.Prompts.Count -eq 6 -and $flow.Answers.Count -eq 0 -and $flow.Bootstraps -eq 1) 'the firstboot and package initialization choices were not independent'
    Assert-FirstBoot (($flow.Events -join ',') -eq 'import,protect,version,network,bootstrap' -and -not $flow.Failure) 'declining firstboot initialization interrupted package initialization'
}
Test-FirstBootCase 'failed package initialization stops installation and propagates its failure' {
    $flow = Invoke-FirstBootInstallFlowFixture -BootstrapExitCode 17
    Assert-FirstBoot ($flow.Bootstraps -eq 1 -and $flow.Failure.Contains('17')) 'package failure was swallowed by the installer'
    Assert-FirstBoot (@($flow.Messages | Where-Object { $_ -match 'To start distro run:|启动该发行版命令:' }).Count -eq 0) 'failed initialization still reached the final installation message'
}
Test-FirstBootCase 'declining or leaving the package choice empty skips it and completes installation' {
    foreach ($answer in @('N', '', 'unexpected')) {
        $flow = Invoke-FirstBootInstallFlowFixture -BootstrapAnswer $answer
        Assert-FirstBoot ($flow.Bootstraps -eq 0 -and -not $flow.Failure -and $flow.Answers.Count -eq 0) 'package initialization ran without an explicit yes'
        Assert-FirstBoot (($flow.Events -join ',') -eq 'import,protect,locale,initialize,version,network') 'declining package initialization changed unrelated installation steps'
        Assert-FirstBoot (@($flow.Messages | Where-Object { $_ -match 'To start distro run:|启动该发行版命令:' }).Count -eq 1) 'declining package initialization prevented installation completion'
    }
}
Test-FirstBootCase 'a lowercase yes confirms package initialization' {
    $flow = Invoke-FirstBootInstallFlowFixture -BootstrapAnswer 'y'
    Assert-FirstBoot ($flow.Bootstraps -eq 1 -and -not $flow.Failure) 'lowercase yes did not confirm package initialization'
}
Test-FirstBootCase 'noninteractive installation skips optional initialization without asking' {
    $flow = Invoke-FirstBootInstallFlowFixture -Interactive $false
    Assert-FirstBoot ($flow.Prompts.Count -eq 4 -and $flow.Answers.Count -eq 0 -and $flow.Initializations -eq 0 -and $flow.Bootstraps -eq 0 -and $flow.DefaultsReads -eq 0 -and $flow.LocalePreparations -eq 0 -and -not $flow.Failure) 'noninteractive installation prompted or initialized packages'
    Assert-FirstBoot (($flow.Events -join ',') -eq 'import,protect,version,network') 'noninteractive installation changed unrelated steps'
}
Test-FirstBootCase 'package initialization can be selected when the firstboot service is absent' {
    $flow = Invoke-FirstBootInstallFlowFixture -Present $false
    Assert-FirstBoot ($flow.Prompts.Count -eq 5 -and $flow.Answers.Count -eq 0 -and $flow.Initializations -eq 0 -and $flow.Bootstraps -eq 1 -and -not $flow.Failure) 'package initialization depended on the firstboot service'
}
Test-FirstBootCase 'unavailable Windows defaults preserve the independent package initialization choice' {
    $flow = Invoke-FirstBootInstallFlowFixture -DefaultsAvailable $false
    Assert-FirstBoot ($flow.Prompts.Count -eq 5 -and $flow.Answers.Count -eq 0 -and $flow.Initializations -eq 0 -and $flow.LocalePreparations -eq 0 -and $flow.Bootstraps -eq 1 -and -not $flow.Failure) 'unsupported defaults prevented the separate package choice or changed the system'
    Assert-FirstBoot (($flow.Events -join ',') -eq 'import,protect,version,network,bootstrap') 'unsupported defaults changed unrelated installation steps'
}
Test-FirstBootCase 'confirmed locale preparation failure stops the install before passwords or packages' {
    $flow = Invoke-FirstBootInstallFlowFixture -LocaleExitCode 17
    Assert-FirstBoot ($flow.LocalePreparations -eq 1 -and $flow.Initializations -eq 0 -and $flow.Bootstraps -eq 0 -and $flow.Failure.Contains('fixture locale failure')) 'locale preparation failure was swallowed or still initialized credentials/packages'
}

Write-Host "WSL firstboot regressions: $script:firstBootTestCount tests, $($script:firstBootFailures.Count) failures."
if ($script:firstBootFailures.Count -gt 0) { throw ($script:firstBootFailures -join "`n") }
