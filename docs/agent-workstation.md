# Agent 浏览器工作机

独立于 PVE，支持 WSL2 和已有的原生 Debian 13（amd64/arm64）。默认使用普通用户 `agent`，项目放在 `/home/agent/workspaces`。建议 4 核、8 GB 内存和 32 GB 可用磁盘；WSL 使用共享资源池，工具不修改全局 `.wslconfig`。

## Windows / WSL2

从仓库目录运行 `./menu.ps1`，选择 **09 Agent 工作机 → 1 新建独立 ai-dev**。可修改实例名、安装根目录、镜像源和端口；默认 `D:\wsl\ai-dev`、TUNA 源。

也可以直接运行：

```powershell
.\agent-via-wsl.ps1 -Action Create
.\agent-via-wsl.ps1 -Action Status -DistroName ai-dev
.\agent-via-wsl.ps1 -Action Open -DistroName ai-dev
```

新实例的 rootfs 来自 Linux Containers 镜像服务，经上游 SHA256 校验后导入。它启用 systemd、默认登录 `agent`，关闭 Windows 磁盘自动挂载和程序互操作。只重启新实例，不改变 Windows 默认 WSL 或其他实例。默认启用现有的无窗口后台驻留；登录 Windows 自动启动默认关闭，需要时在原 **07 状态** 菜单开启。

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

如果全局 `.wslconfig` 已设置 `localhostForwarding=false`，创建前会高亮提醒，Windows 不能直接打开上述 WSL 回环入口。工具不修改该全局设置、不自动执行影响其他实例的重启；须另行安排转发或调整网络设置。Linux 侧的桌面和 MCP 仍可正常运行。

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
