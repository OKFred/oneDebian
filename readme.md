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

- **00. Precheck**: Pre-install environment check & diagnostic. Checks CPU hardware virtualization (VT-x/AMD-V), Windows `VirtualMachinePlatform` features, WSL2 default version, and disk free space with one-click DISM auto-fix or skip.
- **01. Install**: Downloads an AMD64/ARM64 Debian rootfs from the Linux Containers image service, requires a matching SHA-256 checksum, and imports it as WSL 2.
- **02. Update**: Update `apt` packages inside WSL or update Windows `wsl --update` core.
- **03. Backup**: Export a WSL distro as a portable `.tar` archive or a WSL 2 `.vhdx` snapshot.
- **04. Restore**: Import and restore WSL distro from `.tar` or `.vhdx` backups.
- **05. Uninstall**: Single or batch unregister WSL distros with `Y` + `DELETE` double confirmation. The tool relies on `wsl --unregister` and never guesses or recursively deletes a distro directory.
- **06. Config**: Incrementally updates global `%UserProfile%\.wslconfig` and per-distro `/etc/wsl.conf`, preserving comments and unknown keys. Input is validated and changes are shown with an order-sensitive Git diff.
- **07. Status**: Shows registered VHD paths/sizes and checks running distros for an IPv4 address, default route, and conflicting NetworkManager/systemd-networkd services.
- **08. Purge**: Unregisters selected distros and optionally removes the toolbox image cache and exported backups, protected by `Y` + `PURGE` confirmation. Recovery data is retained if unregistering any distro fails.
- **L. Language**: Toggle display language seamlessly between `简体中文` and `English`.
- **0. Exit**: Exit Toolbox (Direct Enter or type 0).

#### WSL configuration behavior

- Press Enter or enter `--` to keep the current value. Enter `unset` to remove a key.
- Resource settings are left unset by default so WSL can use its adaptive defaults (50% host memory, all logical processors, and swap based on the memory limit).
- `.wslconfig` is global to all WSL 2 distros. `localhostForwarding=false` disables host localhost forwarding globally; it is not per-distro port isolation.
- NAT remains the WSL default. Mirrored networking improves VPN and IPv6 compatibility, but inbound LAN access can still require Hyper-V firewall rules.
- Enabling systemd triggers a warning when both NetworkManager and systemd-networkd are enabled, because they can overwrite WSL's injected `eth0` configuration.

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

WSL behavior in this toolbox follows Microsoft's documentation for [advanced configuration](https://learn.microsoft.com/windows/wsl/wsl-config), [networking](https://learn.microsoft.com/windows/wsl/networking), and [command-line operations](https://learn.microsoft.com/windows/wsl/basic-commands).
