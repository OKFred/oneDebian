# oneDebian

> 🇺🇸 Automated Tooling for Ubuntu/Debian Server Initialization & Windows WSL Management

**Author:** Fred  
**Updated:** 2026-08  
**Chinese Version / 中文文档:** [Simplified Chinese (readme_zhCN.md)](readme_zhCN.md)

---

## 🚀 Quick Start

### 1. Windows Environment (PowerShell WSL Management Toolbox)

Designed for Windows 10/11 PowerShell to easily check, install, and manage Debian 12 / Debian 13 WSL instances.

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
- **01. Install**: Automatically downloads official rootfs and imports requested Debian WSL (12 / 13).
- **02. Update**: Update `apt` packages inside WSL or update Windows `wsl --update` core.
- **03. Backup**: Export and backup specified WSL distro to `.tar` archive.
- **04. Restore**: Import and restore WSL distro from `.tar` or `.vhdx` backups.
- **05. Uninstall**: Single or batch unregister WSL distros with Double Confirm (`DELETE`) safety protection and residual folder cleanup.
- **06. Config**: Guided configuration for global `~/.wslconfig` and per-distro `/etc/wsl.conf`. Based on official default values with colored Git Diff preview, Feilian VPN compatibility, and port forwarding isolation (`localhostForwarding`) for multi-instance Node.js development.
- **07. Status**: Formatted dashboard showing running state, memory, and `.vhdx` disk paths/sizes for all WSL instances, with health check and process termination.
- **08. Purge**: Full WSL environment purge and reset. Unregisters all distros, cleans storage folders, rootfs caches, and backups with Double Confirm (`PURGE`) protection and WSL stack reset.
- **L. Language**: Toggle display language seamlessly between `简体中文` and `English`.
- **0. Exit**: Exit Toolbox (Direct Enter or type 0).

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
10. **Upgrade to Latest Linux Kernel Image**.
11. **Remove Unused Linux Kernel Images**.

---

## 📁 Component Architecture

- `menu.ps1` - Windows PowerShell Main Control Menu
- `menu.sh` - Linux Bash Main Control Menu
- `install-via-wsl.ps1` - WSL Quick Installer Forwarder Script
- `components/` - Core Feature Component Directory
  - `wsl_common.ps1` - Common Helper Functions
  - `wsl_i18n.ps1` - Multi-language Dictionary Module
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
