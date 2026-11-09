# Shared WSL network checks and confirmed eth0 protection. Importing is read-only.

function Get-WslConfiguredNetworkMode {
    $mode = 'nat'
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    try {
        if (Test-Path -LiteralPath $path) {
            $section = ''
            foreach ($line in (Get-Content -LiteralPath $path -ErrorAction Stop)) {
                if ($line -match '^\s*\[(.+)\]') { $section = $Matches[1].Trim(); continue }
                if ($section -in @('wsl2', 'experimental') -and $line -match '^\s*networkingMode\s*=\s*([^;#\s]+)') { $mode = $Matches[1].ToLowerInvariant() }
            }
        }
    } catch { return 'unknown' }
    return $mode
}

function Get-WslNetworkState {
    param([Parameter(Mandatory = $true)][string]$Distro, [switch]$PrepareSystemd)
    $script = @'
export LC_ALL=C
command -v ip >/dev/null 2>&1 || exit 1
printf '__WSL_NETWORK_V1__\n'
systemd=$(awk 'BEGIN{s=0} /^[[:space:]]*\[/{s=($0 ~ /^[[:space:]]*\[boot\]/)} s && /^[[:space:]]*systemd[[:space:]]*=/{v=$0;sub(/^[^=]*=[[:space:]]*/,"",v);sub(/[[:space:];#].*$/,"",v);value=tolower(v)} END{print value}' '/etc/wsl.conf' 2>/dev/null)
case "$systemd" in true|false) ;; '') systemd=false;; *) systemd=unknown;; esac
printf 'SYSTEMD=%s\n' "$systemd"
ipv4=$(ip -4 -o address show scope global 2>/dev/null | awk '$2!="lo" {print $2; exit}')
route=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1);exit}}')
if [ -n "$ipv4" ]; then echo IPV4=yes; else echo IPV4=no; fi
if [ -n "$route" ]; then echo ROUTE=yes; else echo ROUTE=no; fi
iface=${route:-${ipv4:-eth0}}; printf 'IFACE=%s\n' "$iface"
if ip link show dev eth0 >/dev/null 2>&1; then echo ETH0=yes; else echo ETH0=no; fi
nm=no; networkd=no; nm_active=no; nd_active=no
if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
  nm_active=yes; nm=$(nmcli -g GENERAL.NM-MANAGED device show eth0 2>/dev/null)
  case "$nm" in yes|no) ;; *) nm=unknown;; esac
fi
if systemctl is-active --quiet systemd-networkd.service 2>/dev/null; then
  nd_active=yes; status=$(networkctl status eth0 --no-pager 2>/dev/null)
  if printf '%s\n' "$status" | grep -Eq '^[[:space:]]*State:.*\(unmanaged\)'; then networkd=no
  elif printf '%s\n' "$status" | grep -Eq '^[[:space:]]*Network File:[[:space:]]+/'; then networkd=yes
  else networkd=unknown; fi
fi
printf 'NM=%s\nNETWORKD=%s\nNM_ACTIVE=%s\nNETWORKD_ACTIVE=%s\n' "$nm" "$networkd" "$nm_active" "$nd_active"
for unit in NetworkManager.service systemd-networkd.service; do
  enabled=$(systemctl is-enabled "$unit" 2>/dev/null)
  case "$unit" in NetworkManager.service) key=NM_ENABLED;; *) key=NETWORKD_ENABLED;; esac
  case "$enabled" in enabled|enabled-runtime) printf '%s=yes\n' "$key";; *) printf '%s=no\n' "$key";; esac
done
if printf '[device-wsl-eth0]\nmatch-device=interface-name:eth0\nmanaged=0\n' | cmp -s - '/etc/NetworkManager/conf.d/99-wsl-eth0-unmanaged.conf'; then echo NM_PROTECTED=yes; else echo NM_PROTECTED=no; fi
nd_order_ok=yes
for path in '/etc/systemd/network/'*.network '/run/systemd/network/'*.network '/usr/lib/systemd/network/'*.network '/lib/systemd/network/'*.network; do
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then continue; fi
  name=${path##*/}
  if [ "$name" \< '00-wsl-eth0-unmanaged.network' ]; then nd_order_ok=no; break; fi
done
if [ "$nd_order_ok" = yes ] && printf '[Match]\nName=eth0\n\n[Link]\nUnmanaged=yes\n' | cmp -s - '/etc/systemd/network/00-wsl-eth0-unmanaged.network'; then echo NETWORKD_PROTECTED=yes; else echo NETWORKD_PROTECTED=no; fi
mode=$(wslinfo --networking-mode 2>/dev/null | tr '[:upper:]' '[:lower:]'); printf 'MODE=%s\n' "${mode:-unknown}"
printf '__WSL_NETWORK_END__\n'
'@
    $result = Invoke-WslCommand -Arguments @('--distribution', $Distro, '--user', 'root', '--exec', '/bin/sh', '-c', $script) -TimeoutMilliseconds 30000
    $fields = @{}
    $valid = $result.ExitCode -eq 0 -and $result.IsDecoded -and $result.Text.Trim().StartsWith('__WSL_NETWORK_V1__') -and $result.Text.Trim().EndsWith('__WSL_NETWORK_END__')
    foreach ($line in ($result.Text -split '\r?\n')) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') {
            if ($fields.ContainsKey($Matches[1])) { $valid = $false }
            $fields[$Matches[1]] = $Matches[2].Trim()
        }
    }
    foreach ($key in @('IPV4', 'ROUTE', 'ETH0', 'NM_ACTIVE', 'NETWORKD_ACTIVE', 'NM_ENABLED', 'NETWORKD_ENABLED', 'NM_PROTECTED', 'NETWORKD_PROTECTED')) {
        if ($fields[$key] -notin @('yes', 'no')) { $valid = $false }
    }
    if ($fields.SYSTEMD -notin @('true', 'false') -or $fields.NM -notin @('yes', 'no') -or $fields.NETWORKD -notin @('yes', 'no') -or
        -not $fields.IFACE -or $fields.IFACE -notmatch '^[A-Za-z0-9_.:@-]+$' -or -not $fields.MODE) { $valid = $false }
    $mode = if ($fields.MODE -and $fields.MODE -ne 'unknown') { $fields.MODE } else { Get-WslConfiguredNetworkMode }
    $risk = $valid -and ($fields.NM -eq 'yes' -or $fields.NETWORKD -eq 'yes')
    if ($PrepareSystemd -and $valid) {
        $risk = $risk -or ($fields.NM_ENABLED -eq 'yes' -and $fields.NM_ACTIVE -eq 'no' -and $fields.NM_PROTECTED -ne 'yes') -or
            ($fields.NETWORKD_ENABLED -eq 'yes' -and $fields.NETWORKD_ACTIVE -eq 'no' -and $fields.NETWORKD_PROTECTED -ne 'yes')
    }
    $errorText = if ($result.ExitCode -ne 0) {
        if ($result.ErrorText.Trim()) { $result.ErrorText.Trim() }
        elseif ($result.Text.Trim()) { $result.Text.Trim() }
        else { "Network query failed (exit $($result.ExitCode))." }
    } elseif (-not $valid) { 'Network state could not be verified.' } else { $null }
    return [pscustomobject]@{
        Known = [bool]$valid; SystemdEnabled = ($fields.SYSTEMD -eq 'true')
        HasIPv4 = ($fields.IPV4 -eq 'yes'); HasDefaultRoute = ($fields.ROUTE -eq 'yes'); Interface = $fields.IFACE
        NetworkManagerManaged = $(if ($fields.NM -in @('yes', 'no')) { $fields.NM -eq 'yes' } else { $null })
        NetworkdManaged = $(if ($fields.NETWORKD -in @('yes', 'no')) { $fields.NETWORKD -eq 'yes' } else { $null })
        NetworkManagerProtected = ($fields.NM_PROTECTED -eq 'yes'); NetworkdProtected = ($fields.NETWORKD_PROTECTED -eq 'yes')
        Risk = [bool]$risk; RepairSupported = ($valid -and $mode -in @('nat', 'mirrored') -and $fields.IFACE -eq 'eth0' -and $fields.ETH0 -eq 'yes')
        Mode = $mode; Error = $errorText
    }
}

function Get-WslEth0RepairScript {
    return @'
set -eu
export LC_ALL=C
umask 077
nm_file='/etc/NetworkManager/conf.d/99-wsl-eth0-unmanaged.conf'
nd_file='/etc/systemd/network/00-wsl-eth0-unmanaged.network'
# shortcut: earlier custom network rules need manual review; parse Match rules only if those layouts must be supported.
for path in '/etc/systemd/network/'*.network '/run/systemd/network/'*.network '/usr/lib/systemd/network/'*.network '/lib/systemd/network/'*.network; do
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then continue; fi
  name=${path##*/}
  if [ "$name" \< '00-wsl-eth0-unmanaged.network' ]; then printf 'Earlier network rule requires manual review: %s\n' "$path" >&2; exit 1; fi
done
for path in "$nm_file" "$nd_file"; do
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then printf 'Unsafe configuration path: %s\n' "$path" >&2; exit 1; fi
done
nm_ok=no; nd_ok=no
if printf '[device-wsl-eth0]\nmatch-device=interface-name:eth0\nmanaged=0\n' | cmp -s - "$nm_file"; then nm_ok=yes; fi
if printf '[Match]\nName=eth0\n\n[Link]\nUnmanaged=yes\n' | cmp -s - "$nd_file"; then nd_ok=yes; fi
backup=
if [ "$nm_ok" != yes ] || [ "$nd_ok" != yes ]; then
  backup=$(mktemp -d '/root/onedebian-network-backup.XXXXXXXX')
  if [ -f "$nm_file" ]; then cp -p "$nm_file" "$backup/NetworkManager.original.conf"; fi
  if [ -f "$nd_file" ]; then cp -p "$nd_file" "$backup/networkd.original.network"; fi
  printf '[device-wsl-eth0]\nmatch-device=interface-name:eth0\nmanaged=0\n' >"$backup/NetworkManager.new.conf"
  printf '[Match]\nName=eth0\n\n[Link]\nUnmanaged=yes\n' >"$backup/networkd.new.network"
  printf 'BACKUP=%s\n' "$backup"
  install -d -m 0755 '/etc/NetworkManager/conf.d' '/etc/systemd/network'
  if [ "$nm_ok" != yes ]; then install -m 0644 "$backup/NetworkManager.new.conf" "$nm_file"; fi
  if [ "$nd_ok" != yes ]; then install -m 0644 "$backup/networkd.new.network" "$nd_file"; fi
fi
printf '[device-wsl-eth0]\nmatch-device=interface-name:eth0\nmanaged=0\n' | cmp -s - "$nm_file"
printf '[Match]\nName=eth0\n\n[Link]\nUnmanaged=yes\n' | cmp -s - "$nd_file"
printf '__WSL_NETWORK_REPAIRED__\nBACKUP=%s\n__WSL_NETWORK_END__\n' "$backup"
'@
}

function Repair-WslEth0Management {
    param([Parameter(Mandatory = $true)][string]$Distro)
    $before = Get-WslNetworkState -Distro $Distro
    if (-not $before.Known -or -not $before.RepairSupported) {
        return [pscustomobject]@{ Success = $false; BackupPath = ''; Error = 'The standard WSL eth0 network could not be verified.'; RestartRequired = $false }
    }
    $result = Invoke-WslCommand -Arguments @('--distribution', $Distro, '--user', 'root', '--exec', '/bin/sh', '-c', (Get-WslEth0RepairScript)) -TimeoutMilliseconds 30000
    $backup = ''
    if ($result.Text -match '(?m)^BACKUP=([^\r\n]*)$') { $backup = $Matches[1] }
    if ($result.ExitCode -ne 0 -or -not $result.IsDecoded -or $result.Text -notmatch '(?m)^__WSL_NETWORK_REPAIRED__$') {
        return [pscustomobject]@{ Success = $false; BackupPath = $backup; Error = $(if ($result.ErrorText) { $result.ErrorText } else { 'Network protection write could not be verified.' }); RestartRequired = $false }
    }
    $after = Get-WslNetworkState -Distro $Distro
    $success = $after.Known -and $after.NetworkManagerProtected -and $after.NetworkdProtected
    return [pscustomobject]@{ Success = [bool]$success; BackupPath = $backup; Error = $(if ($success) { $null } else { 'Network protection readback did not match.' }); RestartRequired = [bool]$success }
}

function Invoke-WslNetworkRepairPrompt {
    param([Parameter(Mandatory = $true)][string]$Distro, [switch]$PrepareSystemd, [switch]$OnlyIfSystemd, $State)
    if ($null -eq $State) { $State = Get-WslNetworkState -Distro $Distro -PrepareSystemd:$PrepareSystemd }
    if (-not $State.Known) {
        Write-Host (Get-I18nStr 'Network_CheckUnknown' -Args @($Distro)) -ForegroundColor Yellow
        if ($State.Error) { Write-Host ('    ' + $State.Error.Trim()) -ForegroundColor Yellow }
        return $false
    }
    if ($OnlyIfSystemd -and -not $State.SystemdEnabled) { return $true }
    if (-not $State.Risk -and $State.HasIPv4 -and $State.HasDefaultRoute) { return $true }
    Write-Host (Get-I18nStr 'Network_Risk' -Args @($Distro)) -ForegroundColor Yellow
    if (-not $State.RepairSupported) {
        Write-Host (Get-I18nStr 'Network_RepairUnsupported' -Args @($Distro)) -ForegroundColor Yellow
        return $false
    }
    if ((Read-Host (Get-I18nStr 'Network_RepairPrompt' -Args @($Distro))) -ne 'Y') {
        Write-Host (Get-I18nStr 'Network_RepairSkipped' -Args @($Distro)) -ForegroundColor Gray
        return $false
    }
    $repair = Repair-WslEth0Management -Distro $Distro
    if (-not $repair.Success) {
        Write-Host (Get-I18nStr 'Network_RepairFailed' -Args @($Distro, $repair.Error)) -ForegroundColor Red
        return $false
    }
    $backup = if ($repair.BackupPath) { $repair.BackupPath } else { '-' }
    Write-Host (Get-I18nStr 'Network_RepairWritten' -Args @($Distro, $backup)) -ForegroundColor Green
    Write-Host (Get-I18nStr 'Network_RestartRequired' -Args @($Distro)) -ForegroundColor Yellow
    return $true
}
