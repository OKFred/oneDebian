# oneDebian

> 🇺🇸 Automated Tooling for Ubuntu/Debian Server Initialization & Windows WSL Management

**Author:** Fred  
**Updated:** 2026-08  
**Chinese Version / 中文文档:** [Simplified Chinese (readme_zhCN.md)](readme_zhCN.md)

---

## 🚀 Quick Start

### 1. Windows Environment (PowerShell WSL Management Toolbox)

Designed for Windows 10/11 PowerShell 5.1 or later to check, install, and manage Debian 12 / Debian 13 WSL instances. Current Store-delivered WSL is recommended.

```powershell
# 1. Clone the repository
git clone https://github.com/OKFred/oneDebian.git
cd oneDebian

# 2. Launch the PowerShell WSL management interactive menu
.\menu.ps1

# Or run quick installation script for specific Debian WSL
.\install-via-wsl.ps1 -Version 13 -WslRoot 'D:\wsl'
```

#### PowerShell Menu Features Overview (`menu.ps1`)

- **00. Precheck**: Checks CPU virtualization, Windows optional features, the default version for new WSL distributions, each installed distribution's actual WSL version, and disk space. Repairs are verified by querying the resulting state; existing WSL1 distributions require individual confirmation before conversion.
- **01. Install**: Downloads an AMD64/ARM64 Debian rootfs from the Linux Containers image service, requires a matching SHA-256 checksum, and imports it as WSL 2.
- **02. Update**: Update `apt` packages inside WSL or update Windows `wsl --update` core.
- **03. Backup**: Export a WSL distro as a portable `.tar` archive or a WSL 2 `.vhdx` snapshot.
- **04. Restore**: Import and restore WSL distro from `.tar` or `.vhdx` backups.
- **05. Uninstall**: Single or batch unregister WSL distros with `Y` + `DELETE` double confirmation. The tool relies on `wsl --unregister` and never guesses or recursively deletes a distro directory.
- **06. Config**: Incrementally updates global `%UserProfile%\.wslconfig` and per-distro `/etc/wsl.conf`, preserving comments and unknown keys. Input is validated and changes are shown with an order-sensitive Git diff.
- **07. Status**: Shows compact instance state, creation estimate, run duration, disk, autostart, and keep-alive fields; manages sign-in startup and idle exit.
- **08. Purge**: Unregisters selected distros and optionally removes the toolbox image cache and exported backups, protected by `Y` + `PURGE` confirmation. Recovery data is retained if unregistering any distro fails.
- **L. Language**: Toggle display language seamlessly between `简体中文` and `English`.
- **0. Exit**: Exit Toolbox (Direct Enter or type 0).

#### WSL configuration behavior

- Press Enter or enter `--` to keep the current value. Enter `unset` to remove a key.
- Resource settings are left unset by default so WSL can use its adaptive defaults (50% host memory, all logical processors, and swap based on the memory limit).
- `.wslconfig` is global to all WSL 2 distros. `localhostForwarding=false` disables host localhost forwarding globally; it is not per-distro port isolation.
- NAT remains the WSL default. Mirrored networking improves VPN and IPv6 compatibility, but inbound LAN access can still require Hyper-V firewall rules.
- Enabling systemd triggers a warning when both NetworkManager and systemd-networkd are enabled, because they can overwrite WSL's injected `eth0` configuration.

#### Precheck version detection and repair

- `wsl --set-default-version 2` sets the version for **future installations**. It does not convert an existing Debian distribution. To convert one, use `wsl --set-version <DistributionName> 2`; Precheck lists installed WSL1 distributions and asks separately before converting each one. Conversion can take time, so keep a backup of important files. See Microsoft's [WSL command reference](https://learn.microsoft.com/windows/wsl/basic-commands).
- The default version and distribution registrations belong to the **current Windows user**. Precheck shows the effective user and `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss` path. Running PowerShell as another administrator account uses that account's WSL settings and distribution list.
- Precheck reads `DefaultVersion` and each distribution's `Version` from that user's registry first. When the registry cannot supply a value, it captures WSL command output with encoding detection. Empty, garbled, or unrecognized output is reported as **unable to verify**, rather than assumed to mean WSL1. The toolbox uses WSL commands to make changes and does not edit these registry values directly.
- Default-version repair runs as the current user and does not require an administrator check. Only Windows optional-feature repairs through DISM require elevation. DISM uses `/norestart`; feature state and restart requirements are queried again afterward. If changes are pending or not yet effective, restart Windows and rerun Precheck before attempting a distribution conversion. A successful command exit code alone does not prove that WSL2 is ready.
- Error `0x1bc` means the WSL2 kernel needs an update. Precheck displays `wsl --update` and, if the Store update path is unavailable, `wsl --update --web-download`. See Microsoft's [WSL troubleshooting guide](https://learn.microsoft.com/windows/wsl/troubleshooting#error-0x1bc-when-wsl---set-default-version-2).

#### Status and instance actions

Menu **07** shows short columns for name, state, creation estimate, current run duration, disk size, autostart, and keep-alive. The per-instance WSL version column is removed. A leading `~` on a creation date means the storage folder's Windows creation time: copying, moving, restoring, or importing a distribution may change that value, so it is not a guaranteed original installation date. Unavailable fields show `-` or `?`.

Run duration is queried only for a confirmed running instance and is based on that instance's init process start time. It does not use the shared WSL2 virtual machine uptime as the distribution's uptime. Viewing the dashboard does not start stopped or unverified instances.

- **A / N — Autostart / Cancel autostart** manages a task for the current Windows user at sign-in. It does not run distributions as SYSTEM before a user signs in, because WSL distributions are registered per Windows user.
- **K / R — Keep running / Allow idle exit** controls this toolbox's keep-alive for the selected instance. Keep running starts the instance if needed; allowing idle exit releases only the toolbox's keep-alive and lets WSL apply its default idle rules. It does not force-stop running work or change global memory-reclaim settings.
- Autostart and keep-alive are independent: autostart with idle exit starts at sign-in then permits normal idle shutdown; autostart with keep-alive remains running. **T** stops one instance immediately; **S** stops all WSL instances. Each state-changing action asks for confirmation.

---

### 2. Linux Environment (Bash Server Initialization Toolbox)

Designed for native Linux / Debian server shell to perform initialization and software installation.

```bash
cd $HOME && git clone https://github.com/OKFred/oneDebian
cd $HOME/oneDebian && chmod +x menu.sh && ./menu.sh
```

#### Bash Menu Preview (`menu.sh`)

1. **Mirror Repository Switch**: Easily switch to local APT mirror sources.
2. **Basic Setup**: Install `nano`, `wget`, `curl`, `git`, and basic tools.
3. **Configure SSH**: Harden SSH configuration and key bindings.
4. **Install Node.js Environment**: Install Node.js, `npm`, `pnpm`, and `yarn` via `nvm`.
5. **Install Cockpit Management Panel**: Web UI for monitoring server status.
6. **Install Docker Environment**: Deploy Docker Engine, Compose, and Portainer UI.
7. **Project Deployment**: Pull and deploy Node.js / Web projects.
8. **Disk Partition, Format & Mount**: Automated disk formatting & mounting.
9. **Install a Desktop Environment**: Choose XFCE, LXQt, MATE, GNOME, or KDE Plasma, with optional xrdp remote desktop setup.
10. **Upgrade to Latest Linux Kernel Image**.
11. **Remove Unused Linux Kernel Images**.
12. **Cockpit File Browser**: Install file management inside Cockpit (Files or Navigator).
13. **Cockpit SMB File Sharing**: Install Samba and Cockpit File Sharing to manage SMB shares in Cockpit.

#### Cockpit file management and SMB

Run `sudo bash menu.sh` in the repository and select **12** or **13**, then confirm installation. Both entries install Cockpit if needed and enable `cockpit.socket`. Open `https://SERVER-IP:9090`, sign in with an existing Linux account, and refresh the page to see the new sidebar entry. Enable administrative access in Cockpit when needed.

- **12 — File browser** uses `cockpit-files` from the configured APT repositories when its candidate version is at least 45. Otherwise it installs the fixed [45Drives Navigator v0.5.14-1](https://github.com/45Drives/cockpit-navigator/releases/tag/v0.5.14-1) source distribution after SHA256 verification; this needs no Node.js build. Existing Navigator files are preserved. This fallback is a manual installation, so it does not receive APT updates.
- **13 — File Sharing → Samba** uses the matching, SHA256-verified [45Drives File Sharing v4.6.3](https://github.com/45Drives/cockpit-file-sharing/releases/tag/v4.6.3) package for **Debian 12/13 or Ubuntu 20.04/22.04**. Other releases stop with an explanation instead of using another distribution's package. The plugin also requires NFS packages. No third-party APT repository is added, so the downloaded plugin does not receive automatic upstream updates; newer installed plugin versions are retained.
- SMB installation backs up an existing `/etc/samba/smb.conf` and preserves its configuration. It enables `smbd`, but does not create shares or set passwords. On the Samba page, click **Fix now** if prompted to enable registry configuration, add a share, and use **Manage Samba Passwords** for an existing Linux user. Existing file-based shares remain available; importing them into the UI is a separate, confirmed operation. See the [upstream usage guide](https://github.com/45Drives/cockpit-file-sharing#usage).
- These entries require root, APT, and running systemd. They preserve Cockpit login restrictions and firewall rules. Allow TCP **9090** for Cockpit and **445** for SMB within the intended network; Windows clients connect to `\\SERVER-IP\SHARE`.

---

## 📁 Component Architecture

- `menu.ps1` - Windows PowerShell Main Control Menu
- `menu.sh` - Linux Bash Main Control Menu
- `install-via-wsl.ps1` - WSL Quick Installer Forwarder Script
- `components/` - Core Feature Component Directory
  - `wsl_common.ps1` - Common Helper Functions
  - `wsl_i18n.ps1` - Multi-language (i18n) Dynamic JSON Loader
  - `locales/` - Locale JSON Dictionaries (`zh-CN.json`, `en-US.json`)
  - `wsl_check.ps1` - Pre-install Check & Virtualization Diagnostic Script

  - `wsl_install.ps1` - WSL Automated Installer
  - `wsl_update.ps1` - WSL & System Packages Updater
  - `wsl_backup.ps1` - WSL Distro Backup & Export Script
  - `wsl_restore.ps1` - WSL Distro Restore & Import Script
  - `wsl_uninstall.ps1` - WSL Distro Uninstaller with Double Confirm
  - `wsl_config.ps1` - WSL Global & Per-Distro Guided Config Helper
  - `wsl_status.ps1` - WSL Dashboard, Health Diagnostics & Process Manager
  - `wsl_purge.ps1` - Full WSL Environment Purge & Reset Script
  - `*.sh` - Linux Bash Installer Subcomponents

## Development checks

Run the dependency-free PowerShell 5.1 compatibility and configuration merge tests with:

```powershell
.\tests\wsl_logic.tests.ps1
```

Check the Cockpit installers without installing packages or changing services:

```bash
bash -n menu.sh && bash -n components/the_cockpit_extensions_installation.sh
bash tests/cockpit_extensions.tests.sh
```

WSL behavior in this toolbox follows Microsoft's documentation for [advanced configuration](https://learn.microsoft.com/windows/wsl/wsl-config), [networking](https://learn.microsoft.com/windows/wsl/networking), and [command-line operations](https://learn.microsoft.com/windows/wsl/basic-commands).
