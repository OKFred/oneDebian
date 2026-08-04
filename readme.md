# oneDebian

> 🇨🇳 用于 Ubuntu/Debian 服务器初始化 & Windows WSL 自动化运维工具箱  
> 🇺🇸 Automated Tooling for Ubuntu/Debian Server Initialization & Windows WSL Management

**Author:** Fred  
**Updated:** 2026-08

---

## 🌐 Language / 语言目录
- [🇨🇳 简体中文说明](#-简体中文说明)
- [🇺🇸 English Documentation](#-english-documentation)

---

## 🇨🇳 简体中文说明

### 🚀 快速使用

#### 1. Windows 环境 (PowerShell WSL 管理工具箱)

适合在 Windows 10/11 PowerShell 环境下管理 Debian 12 / Debian 13 等 WSL 实例。

```powershell
# 1. 克隆/拉取仓库
git clone https://github.com/OKFred/oneDebian.git
cd oneDebian

# 2. 启动 PowerShell WSL 管理交互菜单
.\menu.ps1

# 或者直接调用快捷脚本安装指定 Debian 版本的 WSL
.\install-via-wsl.ps1 -Version 13 -WslRoot 'D:\wsl'
```

##### PowerShell 菜单功能预览 (`menu.ps1`)

- **01. Install (安装)**：自动下载官方 rootfs，导入安装指定版本 (Debian 12/13) 的 WSL 发行版。
- **02. Update (更新)**：更新指定 WSL Debian 的 `apt` 软件包或更新 Windows `wsl --update` 核心。
- **03. Backup (备份)**：将指定 WSL 发行版导出备份为 `.tar` 镜像文件。
- **04. Restore (还原)**：从 `.tar` 或 `.vhdx` 备份镜像还原/导入为新的 WSL 发行版。
- **05. Uninstall (卸载)**：支持单选或批量全选 (All) 卸载注销 WSL 发行版，带有双重确认 (输入 `DELETE`) 防误删保护，并提示清理本地残留目录。
- **06. Config (配置向导)**：引导配置全局 `~/.wslconfig` 与单分发 `/etc/wsl.conf`。基于微软官方标准默认值，提供彩色 Git Diff 对比预览，并针对多分发 Node.js 开发 (如 7001 端口) 提供 `localhostForwarding` 端口隔离专项配置。
- **07. Status (运维诊断)**：格式化仪表盘实时查看所有 WSL 实例状态、内存与 `.vhdx` 物理磁盘路径与大小，支持健康度诊断与进程杀死。
- **08. Purge (全量环境清理)**：全量扫描并彻底注销所有 WSL 实例、删除数据文件夹、清理镜像缓存与导出备份。包含双重高危确认 (输入 `PURGE`) 保护，并重置 WSL 堆栈。

- **L. Language (语言切换)**：支持界面在一键无缝切换 `简体中文` 与 `English`。

---

#### 2. Linux 环境 (Bash 服务器初始化工具箱)

适合在原生 Linux / Debian 服务器终端下执行初始化配置与常用工具安装。

```bash
cd $HOME && git clone https://github.com/OKFred/oneDebian
cd $HOME/oneDebian && chmod +x menu.sh && ./menu.sh
```

##### Bash 菜单预览 (`menu.sh`)

1. **更换国内源**
2. **安装基础工具** (`nano`, `wget`, `git` 等)
3. **配置 SSH**
4. **安装 Node.js 环境** (`nvm`, `node`, `npm`)
5. **安装 Cockpit 运维面板**
6. **安装 Docker 容器环境** (`docker`, `dockerd`, `portainer`)
7. **项目部署**
8. **磁盘分区、格式化与挂载**
10. **更新到新版 Linux 镜像**
11. **清理未使用的 Linux 镜像**

---

## 🇺🇸 English Documentation

### 🚀 Quick Start

#### 1. Windows Environment (PowerShell WSL Management Toolbox)

Designed for Windows 10/11 PowerShell to easily manage Debian 12 / Debian 13 WSL instances.

```powershell
# 1. Clone the repository
git clone https://github.com/OKFred/oneDebian.git
cd oneDebian

# 2. Launch the PowerShell WSL management interactive menu
.\menu.ps1

# Or run quick installation script for specific Debian WSL
.\install-via-wsl.ps1 -Version 13 -WslRoot 'D:\wsl'
```

##### PowerShell Menu Features Overview (`menu.ps1`)

- **01. Install**: Automatically downloads official rootfs and imports requested Debian WSL (12 / 13).
- **02. Update**: Update `apt` packages inside WSL or update Windows `wsl --update` core.
- **03. Backup**: Export and backup specified WSL distro to `.tar` archive.
- **04. Restore**: Import and restore WSL distro from `.tar` or `.vhdx` backups.
- **05. Uninstall**: Single or batch unregister WSL distros with Double Confirm (`DELETE`) safety protection and residual folder cleanup.
- **06. Config**: Guided configuration for global `~/.wslconfig` and per-distro `/etc/wsl.conf`. Based on official default values with colored Git Diff preview and port forwarding isolation (`localhostForwarding`) for multi-instance Node.js development.
- **07. Status**: Formatted dashboard showing running state, memory, and `.vhdx` disk paths/sizes for all WSL instances, with health check and process termination.
- **08. Purge**: Full WSL environment purge and reset. Unregisters all distros, cleans storage folders, rootfs caches, and backups with Double Confirm (`PURGE`) protection and WSL stack reset.
- **L. Language**: Toggle display language seamlessly between `简体中文` and `English`.


---

#### 2. Linux Environment (Bash Server Initialization Toolbox)

Designed for native Linux / Debian server shell to perform initialization and software installation.

```bash
cd $HOME && git clone https://github.com/OKFred/oneDebian
cd $HOME/oneDebian && chmod +x menu.sh && ./menu.sh
```

##### Bash Menu Preview (`menu.sh`)

1. **Mirror Repository Switch**
2. **Basic Setup** (Install `nano`, `wget`, `git`, etc.)
3. **Configure SSH**
4. **Install Node.js Environment** (`nvm`, `node`, `npm`)
5. **Install Cockpit Management Panel**
6. **Install Docker Environment** (`docker`, `dockerd`, `portainer`)
7. **Project Deployment**
8. **Disk Partition, Format & Mount**
10. **Upgrade to Latest Linux Kernel Image**
11. **Remove Unused Linux Images**

---

## 📁 目录架构说明 / Component Architecture

- `menu.ps1` - Windows PowerShell 控制主菜单 / Windows PS Main Menu
- `menu.sh` - Linux Bash 控制主菜单 / Linux Bash Main Menu
- `install-via-wsl.ps1` - WSL 快捷安装代理脚本 / WSL Quick Installer Script
- `components/` - 工具箱核心功能组件目录 / Toolbox Core Components
  - `wsl_common.ps1` - WSL 通用辅助函数库 / Common Helper Functions
  - `wsl_i18n.ps1` - 多语言 (i18n) 字典与切换库 / Multi-language Dictionary Module
  - `wsl_install.ps1` - WSL 自动化安装脚本 / WSL Automated Installer
  - `wsl_update.ps1` - WSL 系统与核心更新脚本 / WSL & System Updater
  - `wsl_backup.ps1` - WSL 发行版导出备份脚本 / WSL Distro Backup Script
  - `wsl_restore.ps1` - WSL 发行版导入还原脚本 / WSL Distro Restore Script
  - `wsl_uninstall.ps1` - WSL 发行版注销卸载脚本 / WSL Distro Uninstaller
  - `wsl_config.ps1` - WSL 全局与单分发配置向导脚本 / WSL Config Helper
  - `wsl_status.ps1` - WSL 运维诊断与实例管理脚本 / WSL Status & Health Checker
  - `wsl_purge.ps1` - 全量 WSL 环境彻底清理与重置脚本 / Full WSL Environment Purge & Reset
  - `*.sh` - Linux Bash 下的各项运维安装子组件 / Linux Bash Installer Components

