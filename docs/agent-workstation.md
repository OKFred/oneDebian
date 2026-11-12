# Agent 浏览器工作机

独立于 PVE，支持 WSL2 和已有的原生 Debian 13（amd64/arm64）。默认使用普通用户 `agent`，项目放在 `/home/agent/workspaces`。建议 4 核、8 GB 内存和 32 GB 可用磁盘；WSL 使用共享资源池，工具不修改全局 `.wslconfig`。

## Windows / WSL2

从仓库目录运行 `./menu.ps1`，选择 **09 Agent 工作机 → 1 新建独立 ai-dev**。可修改实例名、安装根目录、镜像源和端口；默认 `D:\wsl\ai-dev`、TUNA 源。

也可以直接运行：

```powershell
.\agent-via-wsl.ps1 -Action Create
.\agent-via-wsl.ps1 -Action Status -DistroName ai-dev
.\agent-via-wsl.ps1 -Action Open -DistroName ai-dev
.\agent-via-wsl.ps1 -Action RelayStatus -DistroName ai-dev
```

新实例的 rootfs 来自 Linux Containers 镜像服务，经上游 SHA256 校验后导入。它启用 systemd、默认登录 `agent`，关闭 Windows 磁盘自动挂载和程序互操作。只重启新实例，不改变 Windows 默认 WSL 或其他实例。默认启用现有的无窗口后台驻留；登录 Windows 自动启动默认关闭，需要时在原 **07 状态** 菜单开启。

### 在另一台 Windows 上部署

先运行 **00 预检**，确认 WSL2 可用并支持 systemd；尚未启用 Windows 虚拟化／WSL 功能时，需先完成该步骤，可能需要管理员权限和重启 Windows。工作机创建不会自动安装 WSL 本体或重启 Windows。建议所选 WSL 共享资源池有 4 CPU、8 GiB 内存，目标磁盘至少有 32 GiB 空闲空间；工具不会为此修改其他实例的全局限额。

克隆仓库，或下载 ZIP 后解压，再在仓库目录执行：

```powershell
git clone https://github.com/OKFred/oneDebian.git
cd oneDebian
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-via-wsl.ps1 -Action Create -DistroName ai-dev -WslRoot "$env:USERPROFILE\wsl" -Mirror tuna
```

确认一次后，脚本会下载并校验镜像、导入系统、安装软件、配置服务与后台驻留，并等待就绪。示例安装到当前用户目录的 `wsl\ai-dev`，没有 D 盘也能部署；可替换为其他有写权限的本地磁盘路径。实例名或安装目录已存在时会拒绝创建，保留已有资料。需要能访问镜像服务、Debian 软件源、GitHub、Node.js 和 npm；换用国内 APT 源不代表其他下载也已加速。

安装后打开桌面：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agent-via-wsl.ps1 -Action Open -DistroName ai-dev
```

新电脑仍有两项首次设置：在桌面选择凭据库密码策略，以及用以下命令为这台工作机授权 Codex。空密码需在桌面明确确认未加密存储；本仓库不会复制其他电脑的凭据库设置、网站登录或 Codex 凭据。

```powershell
wsl.exe --distribution ai-dev --user agent --exec /home/agent/.local/bin/codex login --device-auth
wsl.exe --distribution ai-dev --user agent --exec /home/agent/.local/bin/codex
```

因此“一键部署”指软件环境自动安装，首次账号授权和凭据库选择仍由使用者完成。本次 `ai-dev` 的空密码设置是该实例的选择，不会成为其他电脑的默认设置。

基本检查使用 **09 → 5 验收**。完成首次凭据库设置、交还 Codex 后，可再运行完整浏览器验收；它只使用合成页面和 Cookie：

```powershell
wsl.exe --distribution ai-dev --user root --exec /bin/bash /opt/onedebian-agent/agent.sh verify --browser
```

若后台驻留或可选的 Windows 登录自启无法验证，创建流程会保留实例和安装器并报告原错误，不会继续提交安装任务。先在 **07 状态** 修复该实例对应策略，再使用 **09 → 3 继续安装**；命令行创建时自定义过镜像源或端口的，继续时也应传入原参数。

实机验收已覆盖 Windows x64 + WSL2 的新 Debian 13 实例：MCP 输入／点击／截图、noVNC 原生键鼠、接管与交还、实例冷启动、页面与合成 Cookie 保留，以及 Codex 登录保留。ARM64 和原生 Debian 共用安装逻辑，但尚未完成各自硬件上的全链路实测；GPU 加速由目标机器验收决定，失败使用软件渲染。

已有系统须显式指定：

```powershell
.\agent-via-wsl.ps1 -Action Install -DistroName <指定的WSL2实例>
```

默认保留已有镜像源、挂载和互操作设置。如 PID 1 不是 systemd，会提示只重启该实例；可以推迟。已有 `agent` 账号须明确使用 `-AdoptUser`，工具不改变其密码，也不导入任何旧凭据。

`agent` 应为专用账号，不与其他正在使用的图形桌面共用用户 D-Bus 会话。

## 原生 Debian 13

进入 **menu.sh → 14 Agent 环境**，或在仓库中运行：

```bash
sudo bash ./agent.sh plan
sudo bash ./agent.sh install --wait
sudo bash ./agent.sh status
sudo bash ./agent.sh resume --wait
sudo bash ./agent.sh verify --browser
```

只安装必要依赖，不执行 `apt upgrade`，不调用原桌面／nvm 菜单，不安装显示管理器或改变物理桌面。`--mirror tuna|ustc|official` 是显式换源；默认 `keep`。不足建议资源时默认停止，了解影响后可明确加 `--allow-low-resources`。端口可用 `--viewer-port`、`--mcp-port`、`--cdp-port` 修改。

## Codex、查看与接管

| 功能 | 默认入口 | 进程所在位置 |
|---|---|---|
| noVNC | `http://127.0.0.1:16080/`，从菜单授权打开 | Debian |
| 浏览器 MCP | `http://127.0.0.1:18931/mcp` | Debian |
| Chromium CDP | `127.0.0.1:19222` | Debian |
| VNC | `/run/user/<uid>/onedebian-agent/vnc.sock` | Debian 私有 Unix socket |

Chromium 在 TigerVNC/XFCE 的独立桌面中运行，不通过 WSLg 弹出 Windows 窗口。桌面与浏览器进程共享 systemd 私有临时目录，不替换 WSLg 的 `/tmp/.X11-unix`。它们使用正常用户 D-Bus/keyring，保留 Chromium 沙箱。

安装器为新 `agent` 账号生成 Codex MCP 配置；已有配置保留，需要合并以下内容（端口以 `status` 为准）：

```toml
[mcp_servers.vm_browser]
url = "http://127.0.0.1:18931/mcp"
startup_timeout_sec = 30
tool_timeout_sec = 120
disabled_tools = ["browser_close"]
```

Codex CLI 位于 `~/.local/bin/codex`。在目标系统中，以 `agent` 用户执行 `codex login --device-auth`，按输出在本机浏览器完成授权；工具不会复制其他实例或 Windows 的登录信息。在 Codex 中使用 `/mcp` 检查连接。浏览器任务明确指定 `vm_browser`，连接失败时先检查状态，不改用本机浏览器。

Git 与 OpenSSH 客户端一并安装。SSH 非交互命令和自己创建的服务可以直接使用 `/home/agent/.local/bin/node`、`npm`、`npx` 或 `codex`；这些入口显式读取记录的 fnm 版本，不依赖 `.bashrc`。真实项目可用用户级 systemd 服务运行，接管浏览器不会停止这些服务。

Windows 通过 **09 → 打开桌面** 或 `-Action Open` 自动携带本地令牌。初始只读；需要手动操作时先停止 Codex 当前任务，再切换 noVNC 输入模式，点击桌面“接管浏览器”。完成后点击“交还 Codex”，切回只读并要求 Codex重新读取标签页继续。

如果全局 `.wslconfig` 已设置 `localhostForwarding=false`，工作机就绪后会自动启动当前用户的专用回环转发，无须修改该设置或重启其他 WSL。`Open` 也会先验证入口身份，再按需启动转发；已有可验证的 WSL 原生转发可继续使用。未确认身份的占用端口会报错，不会停止其他程序，也不会把桌面令牌发给它。

**09 → 8／9／10** 分别启动、停止、查看专用转发，也可使用 `-Action RelayStart|RelayStop|RelayStatus`。转发只在 Windows 当前用户会话中运行；只绑定 `127.0.0.1` 的 noVNC／MCP 同号端口，经 `wsl.exe` 把字节送入明确选定的发行版，不转发 CDP，不在 Windows 部署 MCP。端口仍以工作机 `status` 为准。

转发器通过本机 .NET Framework 编译，无须管理员或 Windows Python。旧版工作机需要先单独升级受管组件；对已 READY 的环境执行 `Install`／`Resume` 不会自动升级这些组件。新建工作机已包含所需组件。转发器代码升级时如检测到旧版转发仍运行，请先 `RelayStop` 再 `RelayStart`。停止转发只断开查看／MCP 连接，保留 Debian、浏览器页面和构建任务；人工接管时 MCP 暂停不妨碍桌面查看。卸载工作机前会先停止它自己的本机转发。

接管会停止 MCP，保留浏览器、页面及独立构建任务；人工标记跨重启保留。断开 MCP、查看页或 SSH 隧道不退出桌面。令牌文件权限为 0600，状态与日志不输出令牌。查看入口校验 Host/Origin 并禁止 iframe 嵌入。

远程原生 Debian 使用已有的 SSH 密钥入口，不复制私钥、不放宽 sshd。先建立隧道：

```bash
ssh -N -L 127.0.0.1:16080:127.0.0.1:16080 -L 127.0.0.1:18931:127.0.0.1:18931 <已有SSH用户>@<Debian地址>
```

在服务器上以 `agent` 运行 `python3 /opt/onedebian-agent/runtime.py open-url`，将输出的带片段令牌地址放到自己本机浏览器。自定义端口时隧道两端保持一致；工具不将监听地址改为 `0.0.0.0`。

首次使用 keyring 可能需要在桌面设置或解锁密码；自动登录不能解锁有密码的 keyring，状态会保留这一待办。工具不自动设置空密码，也不改成明文凭据存储。真实网站账号由用户首次授权。

## GPU、状态与恢复

首次安装仅尝试已有 `/dev/dri/renderD*`，在独立临时 profile 中检查原生 EGL 绘制、WebGL1/2 绘制与 Chromium GPU 进程对应设备文件句柄。失败回到软件桌面，不安装宿主 GPU 驱动、不换内核。仅有 `/dev/dxg` 不能证明该独立桌面支持硬件加速。GPU 验收可再运行 `sudo bash ./agent.sh verify --gpu`；软件模式下该硬件验收应失败，普通浏览器验收仍应通过。

安装任务由 `onedebian-agent-install.service` 执行，退出终端不会取消。日志在 `/var/lib/onedebian-agent/install.log`，阶段／版本／GPU 证据保存在 `/var/lib/onedebian-agent/` 和 `/etc/onedebian-agent/`。重新运行不会启动第二个并发任务；中断后使用 Resume，保留已下载文件。

```bash
sudo tail -n 40 /var/lib/onedebian-agent/install.log
sudo bash /opt/onedebian-agent/agent.sh resume --wait
sudo bash /opt/onedebian-agent/agent.sh verify --browser
sudo bash /opt/onedebian-agent/agent.sh uninstall --yes
```

卸载只移除校验一致的自有服务与文件，修改过的服务须人工检查；保留账号、项目、profile、keyring、安装记录和已安装依赖。APT 源、WSL 设置与后台驻留也保留，按原菜单或备份另行恢复。不会自动注销或删除 WSL。浏览器资料位于 `~/.local/share/onedebian-agent/profile`，接管标记为同目录上一级的 `manual`。

此环境没有 PVE 宿主级内网隔离，WSL 也不是用于运行不可信代码的强隔离边界。首版不移植 PVE 防火墙、显卡直通或 SLS。
