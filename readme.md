# oneDebian

> 用于 Ubuntu/Debian 服务器初始化 & Windows WSL 自动化运维工具箱

**Author:** Fred  
**Updated:** 2026-08

---

## 🚀 快速使用

### 1. Windows 环境 (PowerShell WSL 管理工具箱)

适合在 Windows 10/11 PowerShell 环境下快速管理 Debian 12 / Debian 13 WSL 实例。

```powershell
# 1. 克隆/拉取仓库
git clone https://github.com/OKFred/oneDebian.git
cd oneDebian

# 2. 启动 PowerShell WSL 管理交互菜单
.\menu.ps1

# 或者直接调用独立脚本快速安装指定 Debian 版本的 WSL
.\install-via-wsl.ps1 -Version 13 -WslRoot 'D:\wsl'
```

#### PowerShell 菜单预览 (`menu.ps1`)

- **01. Install (安装)**：下载官方最新 rootfs，导入安装指定版本 (Debian 12/13) 的 WSL 发行版。
- **02. Update (更新)**：快速更新指定 WSL Debian 的 `apt` 软件包或更新 Windows `wsl --update` 核心。
- **03. Backup (备份)**：将指定 WSL 发行版导出备份为 `.tar` 镜像文件。
- **04. Restore (还原)**：从 `.tar` 或 `.vhdx` 备份镜像还原/导入为新的 WSL 发行版。
- **05. Uninstall (卸载)**：支持单选或批量全选 (All) 卸载注销 WSL 发行版，带有双重确认 (输入 `DELETE`) 防误删保护，并提示清理本地残留目录。
- **06. Config (配置向导)**：引导配置全局 `~/.wslconfig` 与单发行版 `/etc/wsl.conf`。基于微软官方标准默认值，提供彩色 Git Diff 对比预览，并针对多分发 Node.js 开发 (如 7001 端口) 提供 `localhostForwarding` 端口隔离专项配置。

---

### 2. Linux 环境 (Bash 服务器初始化工具箱)


适合在原生 Linux / Debian 服务器终端下执行初始化配置与常用工具安装。

```bash
cd $HOME && git clone https://github.com/OKFred/oneDebian
cd $HOME/oneDebian && chmod +x menu.sh && ./menu.sh
```

#### Bash 菜单预览 (`menu.sh`)

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

## 📁 目录架构说明

- `menu.ps1` - Windows PowerShell 控制主菜单
- `menu.sh` - Linux Bash 控制主菜单
- `install-via-wsl.ps1` - WSL 快捷安装代理脚本
- `components/` - 工具箱核心功能组件目录
  - `wsl_common.ps1` - WSL 通用辅助函数库
  - `wsl_install.ps1` - WSL 自动化安装脚本
  - `wsl_update.ps1` - WSL 系统与核心更新脚本
  - `wsl_backup.ps1` - WSL 发行版导出备份脚本
  - `wsl_restore.ps1` - WSL 发行版导入还原脚本
  - `wsl_uninstall.ps1` - WSL 发行版注销卸载脚本
  - `wsl_config.ps1` - WSL 全局与单分发配置向导脚本
  - `*.sh` - Linux Bash 下的各项运维安装子组件

