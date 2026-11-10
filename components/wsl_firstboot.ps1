# Prevent the image's interactive firstboot service from blocking WSL startup.
# Importing this file does not access or change an instance.

function Get-WslFirstBootProtectionScript {
    return @'
set -eu
export LC_ALL=C
unit=systemd-firstboot.service
mask=/etc/systemd/system/systemd-firstboot.service
if [ ! -e /usr/lib/systemd/system/systemd-firstboot.service ] && [ ! -e /lib/systemd/system/systemd-firstboot.service ] && [ ! -e "$mask" ] && [ ! -L "$mask" ]; then
  printf '__WSL_FIRSTBOOT_V1__\nPRESENT=no\nCHANGED=no\n__WSL_FIRSTBOOT_END__\n'
  exit 0
fi
changed=no
if [ -L "$mask" ]; then
  [ "$(readlink "$mask")" = /dev/null ] || { printf 'Custom firstboot unit link requires manual review: %s\n' "$mask" >&2; exit 1; }
elif [ -e "$mask" ]; then
  printf 'Custom firstboot unit requires manual review: %s\n' "$mask" >&2
  exit 1
else
  systemctl --root=/ mask "$unit" >&2
  changed=yes
fi
[ -L "$mask" ]
[ "$(readlink "$mask")" = /dev/null ]
pid1=$(cat /proc/1/comm)
if [ "$pid1" = systemd ]; then
  systemctl daemon-reload
  state=$(systemctl show "$unit" -p ActiveState --value)
  case "$state" in inactive|failed) ;; *) changed=yes;; esac
  systemctl stop "$unit"
  state=$(systemctl show "$unit" -p ActiveState --value)
  case "$state" in inactive|failed) ;; *) printf 'Firstboot service is still %s\n' "$state" >&2; exit 1;; esac
fi
printf '__WSL_FIRSTBOOT_V1__\nPRESENT=yes\nCHANGED=%s\n__WSL_FIRSTBOOT_END__\n' "$changed"
'@
}

function Set-WslFirstBootProtection {
    param([Parameter(Mandatory = $true)][string]$Distro)
    $result = Invoke-WslShellScript -Arguments @('--distribution', $Distro, '--user', 'root', '--exec', '/bin/sh', '-c', (Get-WslFirstBootProtectionScript)) -TimeoutMilliseconds 45000
    $valid = $result.ExitCode -eq 0 -and $result.IsDecoded -and $result.Text.Trim() -match '\A__WSL_FIRSTBOOT_V1__\r?\nPRESENT=(?<Present>yes|no)\r?\nCHANGED=(?<Changed>yes|no)\r?\n__WSL_FIRSTBOOT_END__\z'
    $present = $valid -and $Matches.Present -eq 'yes'
    $changed = $valid -and $Matches.Changed -eq 'yes'
    $errorText = if ($valid) { $null }
        elseif ($result.ErrorText.Trim()) { $result.ErrorText.Trim() }
        elseif ($result.Text.Trim()) { $result.Text.Trim() }
        else { "Firstboot protection could not be verified (exit $($result.ExitCode))." }
    return [pscustomobject]@{ Success = [bool]$valid; Present = [bool]$present; Changed = [bool]$changed; Error = $errorText }
}

function Test-WslFirstBootInteractive {
    try {
        return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and -not [Console]::IsErrorRedirected
    } catch { return $false }
}

function ConvertTo-WslLocaleName {
    param([Parameter(Mandatory = $true)][Globalization.CultureInfo]$Culture)
    # shortcut: only language-country cultures map directly, add explicit mappings when supporting script or variant cultures.
    if ($Culture.Name -cnotmatch '^[a-z]{2,3}-[A-Z]{2}$') { throw "No reliable Linux locale mapping for Windows culture '$($Culture.Name)'." }
    return $Culture.Name.Replace('-', '_') + '.UTF-8'
}

function Get-WslWindowsDefaults {
    return [pscustomobject]@{
        Locale = ConvertTo-WslLocaleName -Culture (Get-Culture)
        Messages = ConvertTo-WslLocaleName -Culture (Get-UICulture)
        TimeZone = (Get-TimeZone).Id
    }
}

function Get-WslLocalePreparationScript {
    return @'
set -eu
export LC_ALL=C
[ "$#" -eq 2 ] || { printf 'Expected regional and display locales.\n' >&2; exit 1; }
command -v locale >/dev/null
command -v localedef >/dev/null
for config in /etc/locale.gen /etc/locale.gen.onedebian.bak; do
  if [ -L "$config" ] || { [ -e "$config" ] && [ ! -f "$config" ]; }; then printf 'Unsafe locale configuration path: %s\n' "$config" >&2; exit 1; fi
done
[ -f /etc/locale.gen ] || { printf 'Missing /etc/locale.gen; install the locales package before retrying.\n' >&2; exit 1; }
locale_exists() {
  locale -a | tr '[:upper:]' '[:lower:]' | tr -d '-' | grep -Fxq "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
}
for target in "$@"; do
  printf '%s\n' "$target" | grep -Eq '^[a-z]{2,3}_[A-Z]{2}\.UTF-8$' || { printf 'Unsupported locale: %s\n' "$target" >&2; exit 1; }
  if ! locale_exists "$target"; then
    [ -r "/usr/share/i18n/locales/${target%.UTF-8}" ] || { printf 'Missing locale definition: %s; install the locales package before retrying.\n' "$target" >&2; exit 1; }
  fi
done
for target in "$@"; do
  if ! locale_exists "$target"; then localedef -i "${target%.UTF-8}" -f UTF-8 "$target"; fi
  locale_exists "$target" && [ "$(LC_ALL="$target" locale charmap)" = UTF-8 ] || { printf 'Locale is not available as UTF-8: %s\n' "$target" >&2; exit 1; }
done
for target in "$@"; do
  if ! awk -v target="$target" 'BEGIN { target=tolower(target); gsub(/-/,"",target) } { name=tolower($1); gsub(/-/,"",name); if(name==target && $2=="UTF-8") found=1 } END { exit !found }' /etc/locale.gen; then
    [ -e /etc/locale.gen.onedebian.bak ] || cp -p /etc/locale.gen /etc/locale.gen.onedebian.bak
    printf '\n%s UTF-8\n' "$target" >>/etc/locale.gen
  fi
done
printf '__WSL_LOCALE_READY_V1__\n'
'@
}

function Initialize-WslLocaleData {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z]{2,3}_[A-Z]{2}\.UTF-8$')][string]$Locale,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z]{2,3}_[A-Z]{2}\.UTF-8$')][string]$Messages
    )
    $result = Invoke-WslShellScript -Arguments @('--distribution', $Distro, '--user', 'root', '--exec', '/bin/sh', '-c', (Get-WslLocalePreparationScript), '--', $Locale, $Messages)
    if ($result.ExitCode -eq 0 -and $result.IsDecoded -and $result.Text.Trim() -ceq '__WSL_LOCALE_READY_V1__') { return }
    $details = if ($result.ErrorText.Trim()) { $result.ErrorText.Trim() } elseif ($result.Text.Trim()) { $result.Text.Trim() } else { "Locale preparation failed (exit $($result.ExitCode))." }
    throw (Get-I18nStr 'FirstBoot_LocaleFailed' -Args @($Distro, $details))
}

function Invoke-WslFirstBootSetup {
    param([Parameter(Mandatory = $true)][string]$Distro, [switch]$PromptInitialize)
    $protection = Set-WslFirstBootProtection -Distro $Distro
    if (-not $protection.Success) { throw (Get-I18nStr 'FirstBoot_ProtectionFailed' -Args @($Distro, $protection.Error)) }
    if (-not $protection.Present) { return }
    if ($protection.Changed -or $PromptInitialize) { Write-Host (Get-I18nStr 'FirstBoot_Protected' -Args @($Distro)) -ForegroundColor Green }

    $manualCommand = "wsl.exe --distribution '$($Distro.Replace("'", "''"))' --user root --exec systemd-firstboot --prompt-locale --prompt-keymap --prompt-timezone --prompt-root-password --force"
    if ($PromptInitialize -and (Test-WslFirstBootInteractive)) {
        try { $defaults = Get-WslWindowsDefaults } catch {
            Write-Host (Get-I18nStr 'FirstBoot_DefaultsFailed' -Args @($Distro, $_.Exception.Message)) -ForegroundColor Yellow
            Write-Host (Get-I18nStr 'FirstBoot_ManualCommand' -Args @($manualCommand)) -ForegroundColor Yellow
            return
        }
        Write-Host (Get-I18nStr 'FirstBoot_WindowsDefaults' -Args @($defaults.Locale, $defaults.Messages, $defaults.TimeZone)) -ForegroundColor Cyan
        if ((Read-Host (Get-I18nStr 'FirstBoot_InitializePrompt' -Args @($Distro))) -ne 'Y') {
            Write-Host (Get-I18nStr 'FirstBoot_ManualCommand' -Args @($manualCommand)) -ForegroundColor Yellow
            return
        }
        Initialize-WslLocaleData -Distro $Distro -Locale $defaults.Locale -Messages $defaults.Messages
        # Timezone and terminal input remain managed by WSL/Windows; passwords stay in the interactive terminal.
        & wsl.exe --distribution $Distro --user root --exec systemd-firstboot "--locale=$($defaults.Locale)" "--locale-messages=$($defaults.Messages)" --prompt-root-password --force
        $initializeExit = $LASTEXITCODE
        if ($initializeExit -ne 0) { throw (Get-I18nStr 'FirstBoot_InitializeFailed' -Args @($Distro, $initializeExit)) }
        Write-Host (Get-I18nStr 'FirstBoot_Initialized' -Args @($Distro)) -ForegroundColor Green
    } elseif ($PromptInitialize) {
        Write-Host (Get-I18nStr 'FirstBoot_ManualCommand' -Args @($manualCommand)) -ForegroundColor Yellow
    }
}
