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

- **00. Precheck (安装前预检)**：检查 CPU 虚拟化、Windows 可选功能、新发行版的默认 WSL 版本、各已安装发行版的实际 WSL 版本及磁盘空间。修复后重新查询状态验证；现有 WSL1 发行版须逐个确认后才会转换。
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

#### Precheck 版本检测与修复

- `wsl --set-default-version 2` 只设置**后续新安装**使用的 WSL 版本，不会转换已有 Debian。转换现有发行版需使用 `wsl --set-version <发行版名称> 2`；Precheck 会列出 WSL1 实例，并对每个实例单独询问是否转换。转换可能耗时，请提前备份重要文件。详见微软的 [WSL 命令说明](https://learn.microsoft.com/windows/wsl/basic-commands)。
- 默认版本与发行版注册信息按**当前 Windows 用户**保存。Precheck 会显示有效用户和 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss` 路径；如果使用其他管理员账号运行 PowerShell，查询和修改的就是该管理员账号的 WSL 设置与发行版清单。
- Precheck 优先读取当前用户注册表中的 `DefaultVersion` 和各发行版的 `Version`。注册表不能提供值时，才捕获并识别 WSL 命令输出的编码。空输出、乱码或无法识别的格式会显示为**无法验证**，不会直接判为 WSL1。工具通过 WSL 命令修改设置，不直接改写这些注册表值。
- 默认版本修复在当前用户上下文执行，不要求管理员身份；只有通过 DISM 修复 Windows 可选功能时才检查管理员权限。DISM 使用 `/norestart`，执行后会重新检查功能状态与重启要求。如果变更待重启或尚未生效，请重启 Windows 后重新运行 Precheck，再进行发行版转换。命令退出码为 0 本身不代表 WSL2 已就绪。
- 错误 `0x1bc` 表示 WSL2 内核需要更新。Precheck 会提示 `wsl --update`；如果无法通过商店更新，可尝试 `wsl --update --web-download`。详见微软的 [WSL 故障排查说明](https://learn.microsoft.com/windows/wsl/troubleshooting#error-0x1bc-when-wsl---set-default-version-2)。

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
12. **Cockpit 文件浏览器**：在 Cockpit 内安装文件管理组件（Files 或 Navigator）。
13. **Cockpit SMB 文件共享**：安装 Samba 和 Cockpit File Sharing，在 Cockpit 内管理 SMB 共享。

#### Cockpit 文件管理与 SMB

在仓库目录运行 `sudo bash menu.sh`，选择 **12** 或 **13** 并确认安装。两项都会按需安装 Cockpit、启用 `cockpit.socket`。访问 `https://服务器IP:9090`，使用已有 Linux 账号登录，刷新页面即可看到新侧栏入口；需要管理权限时在 Cockpit 中启用管理访问。

- **12 — 文件浏览器**：当前 APT 软件源中的 `cockpit-files` 候选版本不低于 45 时优先安装；否则校验 SHA256 后安装固定的 [45Drives Navigator v0.5.14-1](https://github.com/45Drives/cockpit-navigator/releases/tag/v0.5.14-1) 源码发行包，无需 Node.js 构建。已有 Navigator 文件会保留。此回退方式属于手动安装，不通过 APT 自动更新。
- **13 — File Sharing / 文件共享 → Samba**：安装与系统匹配且经过 SHA256 校验的 [45Drives File Sharing v4.6.3](https://github.com/45Drives/cockpit-file-sharing/releases/tag/v4.6.3) 软件包，支持 **Debian 12/13、Ubuntu 20.04/22.04**。其他版本会明确停止，不混用其他发行版的软件包。插件还依赖 NFS 软件包。脚本不添加第三方 APT 源，因此下载的插件不会自动获得上游更新；已安装的更新版本会保留。
- SMB 安装前备份已有 `/etc/samba/smb.conf` 并保留原配置。安装会启用 `smbd`，共享目录和密码由用户在界面中设置。在 Samba 页面如提示配置问题，点击 **Fix now** 启用 registry，然后添加共享，并通过 **Manage Samba Passwords** 为已有 Linux 用户设置 SMB 密码。原配置文件中的共享继续有效；需要在界面中管理时，再选择 Import 并确认导入。详见[上游使用说明](https://github.com/45Drives/cockpit-file-sharing#usage)。
- 这两项要求 root 权限、APT 和运行中的 systemd，保留 Cockpit 登录限制及防火墙规则。请按需要的网络范围放行 Cockpit TCP **9090**、SMB TCP **445**；Windows 访问路径为 `\\服务器IP\共享名`。

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

无需实际安装软件或修改服务，即可验证 Cockpit 安装逻辑：

```bash
bash -n menu.sh && bash -n components/the_cockpit_extensions_installation.sh
bash tests/cockpit_extensions.tests.sh
```

本工具的 WSL 行为以微软官方的[高级配置](https://learn.microsoft.com/windows/wsl/wsl-config)、[网络说明](https://learn.microsoft.com/windows/wsl/networking)和[命令行操作](https://learn.microsoft.com/windows/wsl/basic-commands)文档为准。
