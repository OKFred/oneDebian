# oneDebian

**Agent 工作机**：Windows 菜单 **09** 可新建独立 `ai-dev` 或明确选择已有 WSL2 安装；原生 Debian 13 使用 Bash 菜单 **14**。包含 Node 26、Codex CLI、独立浏览器桌面、MCP、noVNC 与接管按钮。详见[安装、查看和恢复说明](docs/agent-workstation.md)。

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
- **01. Install (安装)**：根据 AMD64/ARM64 架构从 Linux Containers 镜像服务下载 Debian rootfs，强制验证匹配的 SHA-256 校验和后导入为 WSL 2，随后询问是否执行 Bash 菜单 01、02 的换源、软件包升级和基础工具安装，默认跳过。
- **02. Update (更新)**：更新指定 WSL Debian 的 `apt` 软件包或更新 Windows `wsl --update` 核心。
- **03. Backup (备份)**：将指定 WSL 发行版导出为便携的 `.tar` 或 WSL 2 `.vhdx` 快照。
- **04. Restore (还原)**：从 `.tar` 或 `.vhdx` 备份镜像还原/导入为新的 WSL 发行版。
- **05. Uninstall (卸载)**：支持单选或批量注销，要求 `Y` + `DELETE` 双重确认；只调用 `wsl --unregister`，不再猜测并递归删除发行版目录。
- **06. Config (配置向导)**：增量更新全局 `%UserProfile%\.wslconfig` 与单分发 `/etc/wsl.conf`，保留注释和未知配置键，校验输入并显示顺序敏感的 Git Diff。
- **07. Status (运维诊断)**：以短字段显示实例状态、创建时间近似值、运行时长、磁盘、自启和常驻，并管理登录后自启及空闲退出。
- **08. Purge (全量环境清理)**：注销选中的发行版，并按范围清理工具箱镜像缓存和导出备份；要求 `Y` + `PURGE` 双重确认。任一注销失败时保留恢复数据。
- **09. Agent 工作机**：一键创建独立 Debian 13 `ai-dev`，包含 fnm／Node 26、Codex CLI、Chromium、MCP、noVNC 和接管按钮；支持安装到明确选择的已有 WSL2。
- **L. Language (语言切换)**：支持界面在一键无缝切换 `简体中文` 与 `English`。
- **0. Exit (退出)**：退出工具箱（可直接按 Enter 回车或输入 0）。

另一台 Windows 电脑先用 **00 预检** 准备好 WSL2，再选 **09 → 1**；没有 D 盘时可选择当前用户目录下的 `wsl`。详见[新电脑部署步骤](docs/agent-workstation.md#在另一台-windows-上部署)。软件环境自动安装，首次凭据库选择与 Codex 授权仍需在该工作机完成，不迁移其他电脑的登录凭据。

#### WSL 配置行为

- 直接回车或输入 `--` 表示保留当前值；输入 `unset` 删除对应配置键。
- 资源项默认保持未设置，让 WSL 使用自适应默认值：宿主机内存的 50%、全部逻辑处理器，以及根据内存上限计算的 Swap。
- `.wslconfig` 对所有 WSL 2 发行版全局生效；`localhostForwarding=false` 会全局关闭 Windows localhost 转发，不是单发行版端口隔离。
- NAT 仍是默认网络模式。mirrored 会改善 VPN 与 IPv6 兼容性，但局域网入站访问仍可能需要配置 Hyper-V 防火墙。
- 启用 systemd 时会检查 Linux 网络管理器是否可能接管 `eth0`，不再仅凭两个服务已启用就判定冲突。由 WSL 管理名称解析时，建议保留 `generateHosts=true`、`generateResolvConf=true`；这两项与 systemd 独立，DNS 隧道要求不要关闭 `generateResolvConf`。详见微软的 [WSL 配置](https://learn.microsoft.com/windows/wsl/wsl-config#network-settings)和 [DNS 隧道说明](https://learn.microsoft.com/windows/wsl/troubleshooting#networking-considerations-with-dns-tunneling)。

#### 首次启动向导

`systemd-firstboot` 不只设置 root 密码，还可初始化语言、键盘、时区等。通用 Debian 镜像中的后台服务需要终端输入，可能挡住 systemd 启动，继而出现 `Failed to start the systemd user session`。

**01 安装**导入完成后会默认屏蔽 `systemd-firstboot.service`，显示 Windows 的默认区域语言、界面语言和时区，再询问是否立即初始化；回车或选择否会跳过，后台向导仍保持屏蔽。选择是时，用 Windows 当前区域格式设置 Linux 的 `LANG`，用 Windows 当前界面语言设置 `LC_MESSAGES`，准备对应的 UTF-8 locale 数据，再在终端安全询问 root 密码；密码不放入命令行。键盘和输入法继续使用 Windows 终端设置，不写 Linux 控制台键盘映射。时区使用 WSL 原生的 Windows 时区同步，`[time] useWindowsTimezone` 默认为 `true`；若此前显式关闭同步，应在配置中重新开启。无法可靠映射 Windows 语言时会显示手动设置入口，并继续后续安装选择；确认后若缺少语言数据工具或生成失败则明确报错，不自动安装语言包，也不会继续设置密码。没有交互终端时会显示带覆盖说明的手动设置命令。**06 配置**保存 systemd 设置前也会做后台服务防护；配置无变化时，需单独确认才处理现有实例。取消保存不会触发防护。

默认防护仅屏蔽首次启动服务，不禁用 systemd，也不删除已有用户、密码或配置；显式选择初始化才会重新配置所选项目。已配置好的系统可用 `passwd`、`localectl`、`timedatectl` 分别调整。需要恢复后台向导时，可在实例内执行 `systemctl unmask systemd-firstboot.service`。详见 [Debian firstboot 手册](https://manpages.debian.org/trixie/systemd/systemd-firstboot.1.en.html)和 [WSL 时区同步说明](https://learn.microsoft.com/windows/wsl/wsl-config#time-settings)。

#### 导入后出现 `set: Illegal option -`

这通常是 Windows 将 PowerShell 文件检出为 CRLF 后，多行 shell 脚本携带回车符进入 Linux。工具会在调用 Linux shell 前统一转换脚本换行，命令参数中的原始数据保持不变。

如果错误发生在“安装导入成功完成”之后，实例已经导入，无需注销或重新导入。更新仓库并重新打开 PowerShell，在仓库目录继续初始化已有实例：

```powershell
git pull --ff-only
. .\components\wsl_i18n.ps1
. .\components\wsl_common.ps1
. .\components\wsl_firstboot.ps1
Invoke-WslFirstBootSetup -Distro 'debian-wsl-main' -PromptInitialize
```

#### 换源与基础工具初始化

WSL 新建流程在首次启动防护和网络检查后，询问是否执行与 Bash 菜单 **01、02** 共用的初始化逻辑，只有输入 `Y` 或 `y` 才执行，回车或其他回答默认跳过；没有交互终端时也跳过。此选择与语言、时区和密码的首次启动初始化相互独立。确认后会备份并切换发行版官方软件源、保留安全更新和签名校验、更新索引并升级软件包，再安装 `nano net-tools htop wget curl git`。第三方源保留；传统 `.list` 和 DEB822 `.sources` 均受支持。初始化失败会显示错误，不会报告初始化成功，可修正原因后重试。

已有实例可显式补做，以下命令包含软件包升级，任一实例失败后停止批量执行：

```powershell
.\initialize-via-wsl.ps1 -DistroName 'debian-wsl-main', 'debian-wsl-01', 'debian-wsl-02', 'debian-wsl-03'
```

普通 Debian/Ubuntu 可在仓库目录运行 `sudo bash ./bootstrap.sh`。Bash 菜单 01、02 保留单独操作入口；02 仍询问是否安装。初始化只在安装时确认或显式调用独立入口时执行，不会随每次启动重复运行，不依赖 cloud-init、systemd 或 Windows 磁盘挂载。已有配置文件会在包升级时保留；初始化不负责重新启动实例以应用 `/etc/wsl.conf`。

#### 网络接管检查与修复

**06 配置**在启用 systemd 前检查接口接管风险；**01 安装**也会检查已启用 systemd 的新导入实例。**07 状态**检查运行中实例的 IPv4、默认路由及网络接管情况，发现异常时询问是否修复，不再仅因两个服务同时运行而报冲突。

对于 NAT／mirrored 模式下由 WSL 管理的 `eth0`，经确认后会先备份受影响的文件，再让 NetworkManager 和 networkd 忽略 `eth0`。已有连接配置和其他接口继续保留；修复不手写静态 IP／网关，也不修改 `hosts`／`resolv.conf`。无法确认的模式或其他接口需手动检查。

配置写入成功不代表联网已恢复。请先保存运行中的工作，按提示重启实例，再运行 **07** 验证地址和路由。如果共享 WSL 虚拟机仍保留损坏的网络状态，可能需要完整执行 `wsl --shutdown`；它会停止所有运行中的实例，自动修复不会自行执行此操作。

#### Precheck 版本检测与修复

- `wsl --set-default-version 2` 只设置**后续新安装**使用的 WSL 版本，不会转换已有 Debian。转换现有发行版需使用 `wsl --set-version <发行版名称> 2`；Precheck 会列出 WSL1 实例，并对每个实例单独询问是否转换。转换可能耗时，请提前备份重要文件。详见微软的 [WSL 命令说明](https://learn.microsoft.com/windows/wsl/basic-commands)。
- 默认版本与发行版注册信息按**当前 Windows 用户**保存。Precheck 会显示有效用户和 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss` 路径；如果使用其他管理员账号运行 PowerShell，查询和修改的就是该管理员账号的 WSL 设置与发行版清单。
- Precheck 优先读取当前用户注册表中的 `DefaultVersion` 和各发行版的 `Version`。注册表不能提供值时，才捕获并识别 WSL 命令输出的编码。空输出、乱码或无法识别的格式会显示为**无法验证**，不会直接判为 WSL1。工具通过 WSL 命令修改设置，不直接改写这些注册表值。
- 默认版本修复在当前用户上下文执行，不要求管理员身份；只有通过 DISM 修复 Windows 可选功能时才检查管理员权限。DISM 使用 `/norestart`，执行后会重新检查功能状态与重启要求。如果变更待重启或尚未生效，请重启 Windows 后重新运行 Precheck，再进行发行版转换。命令退出码为 0 本身不代表 WSL2 已就绪。
- 错误 `0x1bc` 表示 WSL2 内核需要更新。Precheck 会提示 `wsl --update`；如果无法通过商店更新，可尝试 `wsl --update --web-download`。详见微软的 [WSL 故障排查说明](https://learn.microsoft.com/windows/wsl/troubleshooting#error-0x1bc-when-wsl---set-default-version-2)。

#### 状态与实例操作

菜单 **07** 用短字段显示实例、状态、创建时间近似值、本次运行时长、磁盘大小、自启和常驻，不再显示实例的 WSL 版本列。创建日期前的 `~` 表示 Windows 存储目录的创建时间；复制、移动、还原或导入实例可能改变该值，因此它不保证是最初安装时间。无法读取的字段显示 `-` 或 `?`。

运行时长仅对确认正在运行的实例查询，按该实例的 init 进程启动时间计算，不把 WSL2 共享虚拟机的运行时长当作单个实例的运行时长。查看状态页不会启动已停止或状态未确认的实例。

- **A — 自启设置**：进入子菜单，**1** 开机自启，**2** 取消自启。管理当前 Windows 用户登录时执行的后台任务，不保留命令行窗口。WSL 实例按 Windows 用户注册，因此这里的“开机自启”是用户登录后启动，不以 SYSTEM 身份在登录前启动。
- **K — 运行方式**：进入子菜单，**1** 运行常驻，**2** 自动回收。运行常驻会按需启动选定实例，并在关闭工具箱后继续后台运行，无需保留额外 PowerShell 窗口；自动回收仅取消本工具的常驻，再由 WSL 按默认空闲规则退出，不强制停止正在运行的任务，也不修改全局内存回收设置。
- **T — 停止操作**：进入子菜单，**1** 立即停止一个实例，**2** 停止全部 WSL 实例。所有状态变更操作均需确认。选择 **0** 可返回上一级菜单，或退出操作菜单。
- 自启与常驻分别设置：同时选择 **A → 1** 和 **K → 1**，即可登录后启动并持续后台运行；自启但自动回收时，允许正常空闲退出。更新工具箱后，重新保存任一设置即可将已有的本工具任务迁移为后台启动；保留常驻时，正在运行的旧版常驻进程会重新启动，不强制停止实例或其中的其他任务。

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
14. **Agent 环境**：在现有 Debian 13 上安装独立浏览器工作环境，详见[工作机说明](docs/agent-workstation.md)。

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
.\tests\wsl_bootstrap.tests.ps1
```

无需实际安装软件或修改服务，即可验证 Cockpit 安装逻辑：

```bash
bash -n menu.sh && bash -n components/the_cockpit_extensions_installation.sh
bash tests/cockpit_extensions.tests.sh
bash tests/bootstrap.tests.sh
```

本工具的 WSL 行为以微软官方的[高级配置](https://learn.microsoft.com/windows/wsl/wsl-config)、[网络说明](https://learn.microsoft.com/windows/wsl/networking)和[命令行操作](https://learn.microsoft.com/windows/wsl/basic-commands)文档为准。
