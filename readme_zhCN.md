# oneDebian

> 🇨🇳 用于 Ubuntu/Debian 服务器初始化 & Windows WSL 自动化运维工具箱

**作者：** Fred  
**更新时间：** 2026-08  
**英文文档：** [English Documentation](readme.md)

---

## 🚀 快速使用

### 1. Windows 环境 (PowerShell WSL 管理工具箱)

适合在 Windows 10/11 PowerShell 5.1 或更高版本下检测环境、安装与管理 Debian 12 / Debian 13 WSL 实例，建议使用 Microsoft Store 分发的新版 WSL。

```powershell
# 1. 克隆/拉取仓库
git clone https://github.com/OKFred/oneDebian.git
cd oneDebian

# 2. 启动 PowerShell WSL 管理交互菜单
.\menu.ps1

# 或者直接调用快捷脚本安装指定 Debian 版本的 WSL
.\install-via-wsl.ps1 -Version 13 -WslRoot 'D:\wsl'
```

#### PowerShell 菜单功能清单 (`menu.ps1`)

- **00. Precheck (安装前预检)**：自动化排查 CPU 硬件虚拟化 (VT-x/AMD-V) 开启状态、Windows 虚拟机平台功能、WSL2 命令行连通性与磁盘可用空间，支持一键 DISM 自动修复或跳过。
- **01. Install (安装)**：根据 AMD64/ARM64 架构从 Linux Containers 镜像服务下载 Debian rootfs，强制验证匹配的 SHA-256 校验和后导入为 WSL 2。
- **02. Update (更新)**：更新指定 WSL Debian 的 `apt` 软件包或更新 Windows `wsl --update` 核心。
- **03. Backup (备份)**：将指定 WSL 发行版导出为便携的 `.tar` 或 WSL 2 `.vhdx` 快照。
- **04. Restore (还原)**：从 `.tar` 或 `.vhdx` 备份镜像还原/导入为新的 WSL 发行版。
- **05. Uninstall (卸载)**：支持单选或批量注销，要求 `Y` + `DELETE` 双重确认；只调用 `wsl --unregister`，不再猜测并递归删除发行版目录。
- **06. Config (配置向导)**：增量更新全局 `%UserProfile%\.wslconfig` 与单分发 `/etc/wsl.conf`，保留注释和未知配置键，校验输入并显示顺序敏感的 Git Diff。
- **07. Status (运维诊断)**：从注册信息读取真实 VHD 路径和大小，并检查运行中发行版的 IPv4、默认路由及 NetworkManager/systemd-networkd 冲突。
- **08. Purge (全量环境清理)**：注销选中的发行版，并按范围清理工具箱镜像缓存和导出备份；要求 `Y` + `PURGE` 双重确认。任一注销失败时保留恢复数据。
- **L. Language (语言切换)**：支持界面在一键无缝切换 `简体中文` 与 `English`。
- **0. Exit (退出)**：退出工具箱（可直接按 Enter 回车或输入 0）。

#### WSL 配置行为

- 直接回车或输入 `--` 表示保留当前值；输入 `unset` 删除对应配置键。
- 资源项默认保持未设置，让 WSL 使用自适应默认值：宿主机内存的 50%、全部逻辑处理器，以及根据内存上限计算的 Swap。
- `.wslconfig` 对所有 WSL 2 发行版全局生效；`localhostForwarding=false` 会全局关闭 Windows localhost 转发，不是单发行版端口隔离。
- NAT 仍是默认网络模式。mirrored 会改善 VPN 与 IPv6 兼容性，但局域网入站访问仍可能需要配置 Hyper-V 防火墙。
- 启用 systemd 时，如果同时检测到 NetworkManager 与 systemd-networkd，向导会提示它们可能覆盖 WSL 注入的 `eth0` 地址和路由。

---

### 2. Linux 环境 (Bash 服务器初始化工具箱)

适合在原生 Linux / Debian 服务器终端下执行初始化配置与常用工具安装。

```bash
cd $HOME && git clone https://github.com/OKFred/oneDebian
cd $HOME/oneDebian && chmod +x menu.sh && ./menu.sh
```

#### Bash 菜单功能清单 (`menu.sh`)

1. **更换国内源**：一键切换 Debian/Ubuntu 官方与镜像源。
2. **安装基础工具**：安装 `nano`, `wget`, `curl`, `git` 等基础运维依赖。
3. **配置 SSH**：优化安全配置与密钥绑定。
4. **安装 Node.js 环境**：通过 `nvm` 安装 Node.js 与 `npm`/`pnpm`/`yarn`。
5. **安装 Cockpit 运维面板**：可视化监控服务器状态。
6. **安装 Docker 容器环境**：快速部署 Docker, Docker Compose 与 Portainer 管理面板。
7. **项目部署**：快速拉取与构建 Node.js/Web 项目。
8. **磁盘分区与格式化**：自动化磁盘挂载。
9. **安装桌面环境**：可选 XFCE、LXQt、MATE、GNOME 或 KDE Plasma，并可选择安装 xrdp 远程桌面。
10. **更新到新版 Linux 内核**。
11. **清理未使用的 Linux 镜像缓存**。

---

## 📁 目录架构说明

- `menu.ps1` - Windows PowerShell 控制主菜单
- `menu.sh` - Linux Bash 控制主菜单
- `install-via-wsl.ps1` - WSL 快捷安装代理脚本
- `components/` - 工具箱核心功能组件目录
  - `wsl_common.ps1` - WSL 通用辅助函数库
  - `wsl_i18n.ps1` - 多语言 (i18n) 动态 JSON 语言包加载器
  - `locales/` - 多语言 JSON 字典目录 (`zh-CN.json`, `en-US.json`)
  - `wsl_check.ps1` - WSL 安装前环境预检与虚拟化诊断脚本

  - `wsl_install.ps1` - WSL 自动化安装脚本
  - `wsl_update.ps1` - WSL 系统与核心更新脚本
  - `wsl_backup.ps1` - WSL 发行版导出备份脚本
  - `wsl_restore.ps1` - WSL 发行版导入还原脚本
  - `wsl_uninstall.ps1` - WSL 发行版注销卸载脚本
  - `wsl_config.ps1` - WSL 全局与单分发配置向导脚本
  - `wsl_status.ps1` - WSL 运维诊断与实例管理脚本
  - `wsl_purge.ps1` - 全量 WSL 环境彻底清理与重置脚本
  - `*.sh` - Linux Bash 下的各项运维安装子组件

## 开发验证

使用以下命令运行不依赖 Pester 的 PowerShell 5.1 兼容性及配置合并测试：

```powershell
.\tests\wsl_logic.tests.ps1
```

本工具的 WSL 行为以微软官方的[高级配置](https://learn.microsoft.com/windows/wsl/wsl-config)、[网络说明](https://learn.microsoft.com/windows/wsl/networking)和[命令行操作](https://learn.microsoft.com/windows/wsl/basic-commands)文档为准。
