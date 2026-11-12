# Agent 浏览器工作机

独立于 PVE，支持 WSL2 和已有的原生 Debian 13（amd64/arm64）。默认使用普通用户 `agent`，项目放在 `/home/agent/workspaces`。建议 4 核、8 GB 内存和 32 GB 可用磁盘；WSL 使用共享资源池，工具不修改全局 `.wslconfig`。

安装入口同时负责首装、中断重试和已有环境检查补齐。一次执行会准备开发工具、桌面、浏览器和连接入口；第二次执行会使用仓库最新组件，缺什么补什么，保留已有端口、项目、浏览器资料和正常服务。Windows 已有实例始终选择 **09 → 2 安装／检查补齐**，原生 Debian 始终选择 **14 → 1**。旧菜单编号和 `Resume` 命令仅作隐藏兼容别名，不再有独立恢复流程；其他编号不变。显卡重测、SSH、凭据库和桌面更新等专项入口保留，供高级运维使用。

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

安装确认中会说明：新凭据库自动初始化为空密码，已有库和旧密码保留；真实网站账号按需登录。本仓库不复制其他电脑的凭据库设置、网站登录或 Codex 凭据。使用 Windows 上的 Codex 控制这台工作机，无需在 Linux 中再次登录 Codex。

常规安装会自动完成新凭据库初始化，无需另选专项菜单；仅需单独检查此项时使用 **09 → 13 初始化新凭据库为空密码 / Keyring**，原生 Debian 为 **14 → 9**。此操作仅初始化新库，保留已有凭据库和旧凭据，不关闭浏览器或重启实例；已有带密码的库仍需自己解锁。空密码会降低本机凭据的保护，确认前会展示影响。

只有希望直接在 Linux 中使用 Codex CLI 时，才需要另行授权；以下命令为可选项：

```powershell
wsl.exe --distribution ai-dev --user agent --exec /home/agent/.local/bin/codex login --device-auth
wsl.exe --distribution ai-dev --user agent --exec /home/agent/.local/bin/codex
```

“一键部署”指软件环境自动安装；真实网站账号登录由使用者完成。Linux Codex CLI 及其授权均不是浏览器工作机运行的前提。

### 由 Windows Codex 控制现有工作机

若希望 Windows Codex 使用普通 SSH 命令，初始化完成后会准备专用 SSH 服务和 `oneDebian-<实例名>` 别名；已有工作机通过 **09 → 2 安装／检查补齐** 自动补配置。默认示例为 `ssh oneDebian-ai-dev`，命令可写成 `ssh oneDebian-ai-dev 'cd ~/workspaces/my-app && pnpm dev'`。这仍是 Windows Codex 调用 SSH，不是设置中的“SSH 远程项目”，无需在 Linux 中授权 Codex。

使用 `-NoWait` 时只提交后台安装；通过状态入口查看，完成后再次选择 **09 → 2 安装／检查补齐**，自动检查 SSH 和查看入口。已有配置的自定义 SSH 端口会沿用；只有明确调整端口时才在 **09 → 14 SSH** 使用 `-SshPort 2223` 等参数。回环 SSH 不直接向局域网开放。原生 Debian 可通过 **14 → 10** 提供公钥后配置，或继续使用原有 SSH 服务。

别名的 `ProxyCommand` 通过 `wsl.exe --distribution <实例名> --user agent --exec /usr/bin/nc 127.0.0.1 2222` 进入指定实例，使用实例名而非 WSL 的 NAT IP。它不创建 Windows 22 端口的监听，也不修改全局 WSL 网络，因此 `ssh 127.0.0.1` 不是这个入口。其他服务正在监听该端口时会拒绝，保留原服务；旧 SSH 服务移除后仍存活的已建立会话不会被终止，也不妨碍重新安装。

Windows 专用私钥保存在 `~/.ssh/onedebian_agent_ed25519`，只将公钥传入客机。每个实例的 SSH 配置和可信 host key 存于 `~/.ssh/onedebian-agent/`；主配置只增加一条位于文件开头的 Include，原有条目保留。连接强制公钥、严格 host key 检查；创建时会执行一次无密码登录验证。WSL 重建时，以选中实例中可信读取到的新 host key 更新自有记录，不关闭身份校验。遇已有同名别名、未知密钥或修改过的自有记录会拒绝覆盖。

完整撤销安装后，只清理该实例中校验未变的自有 Windows SSH 别名和 host-key 文件；Windows 私钥和其他实例的条目保留，修改过的记录保留并说明原因。

新装的系统级 `ssh.service`／`ssh.socket` 使用自有保护片段，避免意外改为监听 22；原有系统 SSH 不改动。轻量卸载保留软件包时也保留保护片段；完整撤销若不能安全移除 SSH 包，同样保留并报告。需要改为自行管理系统 SSH 时，应先核对并撤销对应的 oneDebian 保护片段。

保持 Codex 运行在 Windows。命令通过 `wsl.exe` 在所选实例执行，浏览器通过 Windows 回环转发连接 Debian 中的 MCP；同机不需要 SSH，也无需 Linux Codex 授权。在 **09 → 8 启动本机转发** 选择目标实例，或运行：

```powershell
.\agent-via-wsl.ps1 -Action RelayStart -DistroName ai-dev
.\agent-via-wsl.ps1 -Action Open -DistroName ai-dev
```

在 Windows 的 Codex 配置（通常为 `$env:USERPROFILE\.codex\config.toml`）添加或更新对应服务，避免重复同名段落：

```toml
[mcp_servers.vm_browser]
url = "http://127.0.0.1:18931/mcp"
startup_timeout_sec = 30
tool_timeout_sec = 120
disabled_tools = ["browser_close"]
```

重载 MCP 连接后，用 `/mcp` 检查 `vm_browser`。配置字段依据 [OpenAI 官方 MCP 文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)；自定义转发端口时同步修改 URL。本机只做连接转发，MCP 服务和 Chromium 仍在 Debian 内运行。

让 Windows Codex 运行项目命令时，显式指定实例和普通用户。通用形式为 `wsl.exe -d <实例名> -u agent -- bash -lc '<命令>'`，例如：

```powershell
wsl.exe -d ai-dev -u agent -- bash -lc 'cd /home/agent/workspaces/my-app && /home/agent/.local/bin/npm run dev -- --host 127.0.0.1'
```

项目保存在 Linux 的 `/home/agent/workspaces`，避免使用 `/mnt/c` 作为工作目录。可向 Codex 明确说明：“命令统一通过 ai-dev 的 wsl.exe 执行，浏览器统一使用 vm_browser；保留工作标签页，连接失败先报告状态。”前端监听 Linux 回环即可由同实例 Chromium 访问。

基本检查使用 **09 → 5 验收**。完成首次凭据库设置、交还 Codex 后，可再运行完整浏览器验收；它只使用合成页面和 Cookie：

```powershell
wsl.exe --distribution ai-dev --user root --exec /bin/bash /opt/onedebian-agent/agent.sh verify --browser
```

若后台驻留或可选的 Windows 登录自启无法验证，创建流程会保留实例和安装器并报告原错误，不会继续提交安装任务。先在 **07 状态** 修复该实例对应策略，再使用 **09 → 2 安装／检查补齐**；若尚未提交过安装任务，自定义镜像源和端口仍需使用原参数。已进入安装的工作机自动沿用其配置。

实机验收已覆盖 Windows x64 + WSL2 的新 Debian 13 实例：MCP 输入／点击／截图、noVNC 原生键鼠、接管与交还、实例冷启动、页面与合成 Cookie 保留，以及 Codex 登录保留。ARM64 和原生 Debian 共用安装逻辑，但尚未完成各自硬件上的全链路实测；GPU 加速由目标机器验收决定，失败使用软件渲染。

已有系统须显式指定：

```powershell
.\agent-via-wsl.ps1 -Action Install -DistroName <指定的WSL2实例>
```

默认保留已有镜像源、挂载和互操作设置。首次安装中断时沿用当时已确认的软件源，完成安装后检查补齐默认保留用户当前源。如 PID 1 不是 systemd，会提示只重启该实例；可以推迟。首次使用非本工具管理的 `agent` 账号须明确确认接纳或使用 `-AdoptUser`；本工具已经接纳的账号无需再次确认。工具不改变其密码，也不导入任何旧凭据。已有工作机再次安装不会重复首次启动初始化、网络保护或隔离设置。

`agent` 应为专用账号，不与其他正在使用的图形桌面共用用户 D-Bus 会话。

## 原生 Debian 13

进入 **menu.sh → 14 Agent 环境**，或在仓库中运行：

```bash
sudo bash ./agent.sh plan
sudo bash ./agent.sh install --wait
sudo bash ./agent.sh status
sudo bash ./agent.sh verify --browser
```

只安装必要依赖，不执行 `apt upgrade`，不调用原桌面／nvm 菜单，不安装显示管理器或改变物理桌面。中断或需要补齐时更新仓库后再次执行同一条 `sudo bash ./agent.sh install --wait`。`--mirror tuna|ustc|official` 是显式换源；已有环境默认保留当前源，首次安装中断时沿用已确认源。首次资源不足时默认停止，了解影响后可明确加 `--allow-low-resources`；已通过预检的安装不会因正常消耗磁盘再次要求 32 GiB 空闲，但实际空间不足仍会报错。新装端口可用 `--viewer-port`、`--mcp-port`、`--cdp-port` 设置，已有配置自动沿用。

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

Windows 通过 **09 → 打开桌面** 或 `-Action Open` 自动携带本地令牌。初始只读；需要手动操作时先停止 Codex 当前任务，再切换 noVNC 输入模式，点击悬浮按钮“接管浏览器”并确认。安全接管后同一个按钮切换为“交还 Codex”；点击并确认后，切回只读并要求 Codex 重新读取标签页继续。

悬浮按钮可以拖动，位置保存在普通用户的 `~/.local/share/onedebian-agent/controls-position.json`，重开桌面后恢复；显示器尺寸变化时会调整到可见区域。拖到屏幕工作区边缘会收成小标签，点击标签只展开，不会接管或交还；需要切换时再点击展开的按钮。拖动本身不会切换状态。

已有工作机拉取新版后，使用 **09 → 15 更新桌面控件与浏览器入口**，或运行 `./agent-via-wsl.ps1 -Action DesktopUpdate -DistroName debian-wsl-main`；原生 Debian 使用 **14 → 11**。确认后会更新受管组件源码和桌面快捷方式，并重新打开悬浮控件，保留 Chromium、MCP、桌面会话、构建任务和本机转发。桌面的 **Agent 工作浏览器** 入口指向受管的工作浏览器，避免从通用 Chromium 图标打开另一套默认资料。

新安装及上述桌面更新会将 `agent` 用户的 XFCE 首选网页浏览器、HTTP／HTTPS 链接关联设为 **Agent 工作浏览器**。面板“网络浏览器”的命令可保留 `exo-open --launch WebBrowser %u`；若要直接指定，使用 `/usr/bin/python3 /opt/onedebian-agent/focus-browser.py %u`。无网址时定位现有工作页面；带网址时在同一个受管浏览器中新增标签，保留其他页面。只接受 HTTP／HTTPS 和明确的内部诊断页，不接管本地 HTML 文件关联。原有其他应用偏好保留，撤销时仅恢复仍与本工具写入内容一致的配置。

这个入口同时适用于软件和硬件模式，使用安装／显卡验收已经选定的渲染后端。受管浏览器正常关闭后，再点击入口会启动原 Chromium 服务并恢复同一份 profile；运行时只复用现有浏览器。启动不会清除人工接管标记、启用 MCP 或重启桌面。

安装和桌面更新会通过 sudoers 仅授权 `agent` 运行固定的浏览器启动 helper；它持有安装／GPU／清理共用的操作锁，只能启动受管 Chromium。不会授予通用免密码 sudo，也不会自动重启、清空 profile 或解除人工接管。若启动失败，弹窗会给出服务日志与 root 恢复命令。

按钮同时检查持久接管标记、实际 MCP 服务和端口状态。只有确认 MCP 已停止且端口不再监听，才显示可交还的人工模式；接管未完成时仍允许重试接管，状态未知时暂时禁用切换并显示原因。刷新状态不会自动启停 MCP，也不会关闭工作页面或停止构建任务。

如果全局 `.wslconfig` 已设置 `localhostForwarding=false`，工作机就绪后会自动启动当前用户的专用回环转发，无须修改该设置或重启其他 WSL。`Open` 也会先验证入口身份，再按需启动转发；已有可验证的 WSL 原生转发可继续使用。未确认身份的占用端口会报错，不会停止其他程序，也不会把桌面令牌发给它。

**09 → 8／9／10** 分别启动、停止、查看专用转发，也可使用 `-Action RelayStart|RelayStop|RelayStatus`。转发只在 Windows 当前用户会话中运行；只绑定 `127.0.0.1` 的 noVNC／MCP 同号端口，经 `wsl.exe` 把字节送入明确选定的发行版，不转发 CDP，不在 Windows 部署 MCP。端口仍以工作机 `status` 为准。

转发器通过本机 .NET Framework 编译，无须管理员或 Windows Python。更新仓库后再次执行安装／检查补齐，即使已 READY，也会使用最新受管组件并检查连接入口；健康的 SSH 和转发配置优先复用。转发器代码升级时如检测到旧版转发仍运行，请先 `RelayStop` 再 `RelayStart`。停止转发只断开查看／MCP 连接，保留 Debian、浏览器页面和构建任务；人工接管时 MCP 暂停不妨碍桌面查看。卸载工作机前会先停止它自己的本机转发。

接管会停止 MCP，保留浏览器、页面及独立构建任务；人工标记跨重启保留。断开 MCP、查看页或 SSH 隧道不退出桌面。令牌文件权限为 0600，状态与日志不输出令牌。查看入口校验 Host/Origin 并禁止 iframe 嵌入。

远程原生 Debian 使用已有的 SSH 密钥入口，不复制私钥、不放宽 sshd。先建立隧道：

```bash
ssh -N -L 127.0.0.1:16080:127.0.0.1:16080 -L 127.0.0.1:18931:127.0.0.1:18931 <已有SSH用户>@<Debian地址>
```

在服务器上以 `agent` 运行 `python3 /opt/onedebian-agent/runtime.py open-url`，将输出的带片段令牌地址放到自己本机浏览器。自定义端口时隧道两端保持一致；工具不将监听地址改为 `0.0.0.0`。

新安装在 Chromium 启动前自动创建空密码 keyring，首次启动不再要求输入新库密码；空密码表示本机凭据未加密。已有库和密码保留，自动登录不能解锁已有加密 keyring，也不通过 Chromium 的 `password-store=basic` 绕过凭据库。真实网站账号由用户首次授权。已有工作机可用 **09 → 13 Keyring**（原生 **14 → 9**）初始化新库；若旧“创建 keyring”弹窗已经打开，先取消该旧弹窗一次。配置为 `keyring_mode: manual` 可继续使用手动初始化。

## GPU、状态与恢复

GPU 分为原生 DRM 和 WSL DXG／Mesa D3D12 两条路径。`/dev/dxg` 不是 DRM render node；只有设备存在或 `glxinfo` 显示加速，还不足以认定浏览器通过。验收要求原生 EGL 实际绘制、Chromium WebGL1/2 着色与像素回读，以及对应后端的进程／设备证据。失败使用软件模式，不安装宿主显卡驱动、不更换内核，也不通过 WSLg 把窗口弹到 Windows 桌面。

已经安装、处于软件模式的工作机无需重装。拉取新版仓库，选择 **09 → 12 重新检测／启用加速 / Graphics**；原生 Debian 使用 **14 → 8**。也可从 Windows 显式指定已有实例：

```powershell
.\agent-via-wsl.ps1 -Action Graphics -DistroName ai-dev
```

确认后先在临时 profile 中探测；必要时短暂重启工作机 Chromium，保留项目、浏览器资料、页面和凭据，失败回到软件模式。不会重启桌面或 WSL，也不停止本机转发。人工接管期间拒绝调整，先自行交还 Codex 再重试；工具不自动清除人工标记。菜单显示后端、原因和 GPU 日志路径。`-Yes` 仅用于已明确授权的自动化，并仍须指定目标实例。

本机 i5-1240P 的独立 VNC 桌面已直接实测通过 D3D12 原生 EGL 和 Chromium WebGL1/2 实际着色／像素回读；另一台 i5-1340P 为用户回传正式脚本验收通过。其他目标机器仍需运行上述检查。GPU 验收可单独运行 `sudo bash ./agent.sh verify --gpu`；软件模式下该硬件验收应失败，普通浏览器验收仍应通过。

安装任务由 `onedebian-agent-install.service` 执行，关闭进度窗口不会主动取消后台任务，但 WSL 实例仍需保持运行。已有实例的驻留策略不会自动改变，可在 **07 状态** 中确认。日志在 `/var/lib/onedebian-agent/install.log`，阶段／版本／GPU 证据保存在 `/var/lib/onedebian-agent/` 和 `/etc/onedebian-agent/`。再次执行 Install 会暂存当前仓库代码；任务仍运行时只观察，不启动第二个并发任务；中断后再次执行同一入口，保留已下载文件和原配置。

安装阶段停留较久时，先查看 `install.log` 中的最后几行，区分仍在下载、重试或已经失败。网络、DNS、代理以及上游服务可达性都会影响耗时；国内 APT 源只影响 APT，不能加速 GitHub、Node.js 或 npm 的下载。个别下载有各自的超时和重试，但 APT、fnm 安装 Node 和 npm 安装没有统一覆盖的阶段总超时，不能保证网络异常会在固定时间内结束。

Windows 安装等待界面每 10 秒显示进度，中文说明后用一个简短英文标签概括：

```text
[00:05:46] debian-wsl-main：[2/5] 检查并补齐系统依赖：桌面、浏览器、中文支持 / Packages
[00:05:56] debian-wsl-main：[3/5] 检查并补齐开发工具：fnm、Node.js、Codex CLI、浏览器 MCP / Runtime
```

时间是本次等待已用时，再次执行安装时重新计时，不是剩余时间；`2/5`、`3/5` 是阶段序号，不是下载百分比。后续阶段为配置和启动工作环境（Services）、运行检查（Verification），最后显示软件渲染或硬件加速就绪。失败时仍保留错误原文和日志路径；JSON／状态文件中的阶段码不变。

```bash
sudo tail -n 40 /var/lib/onedebian-agent/install.log
sudo bash /opt/onedebian-agent/agent.sh install --wait
sudo bash /opt/onedebian-agent/agent.sh verify --browser
sudo bash /opt/onedebian-agent/agent.sh uninstall --yes
```

卸载只移除校验一致的自有服务与文件，修改过的服务须人工检查；保留账号、项目、profile、keyring、安装记录和已安装依赖。APT 源、WSL 设置与后台驻留也保留，按原菜单或备份另行恢复。不会自动注销或删除 WSL。浏览器资料位于 `~/.local/share/onedebian-agent/profile`，接管标记为同目录上一级的 `manual`。

### 撤销 Agent 安装

**09 → 7** 保留原来的轻量卸载行为。若要撤销 **09 → 2 安装到已有 WSL** 新增的工作环境，使用 **09 → 11 撤销 Agent 安装 / Undo**；原生 Debian 在 **14 Agent 环境 → 7**。这不是删除整个发行版，项目、浏览器资料、keyring 和账号登录凭据会保留。

Windows 也可从仓库目录执行：

```powershell
.\agent-via-wsl.ps1 -Action CleanupPlan -DistroName debian-wsl-main
.\agent-via-wsl.ps1 -Action Cleanup -DistroName debian-wsl-main
```

第一条只检查并展示清单，使用仓库中暂存的最新脚本，不覆盖正在使用的已部署组件。第二条也会先显示计划；确认目标后输入完整的 `UNDO debian-wsl-main` 才开始撤销，`-Yes` 和单独输入 `Y` 不能替代这次确认。计划列明删除项、恢复项、保留项和阻止执行的原因，长清单可选择完整展示；Windows 只在确认后停止该实例自己的转发。

后续安装记录安装前状态，撤销时仅处理能确认属于本次安装、且未被后来修改或共享使用的内容。老版本安装缺少基线时，来源不明的软件或设置会保留并明确报告，不能保证回到安装前的完全相同状态。不会使用全局 `autoremove`，也不会执行 `wsl --unregister` 或 `wsl --shutdown`。

安装任务仍运行时会拒绝清理。清理中检测到计划变化、外部依赖或归属不明的内容时，不会跳过检查强删；请按结果中的保留／阻止原因处理。恢复的 WSL 启动设置若需重启生效，由使用者另行安排，只影响所选实例。

另行确认的 WSL 首次启动初始化和 eth0 网络保护会保留，由对应菜单管理。清理失败后，重新选择撤销入口会根据剩余内容生成新计划；安装／检查补齐入口用于安装环境，不能代替撤销。

清理执行时，原生命令输出保存到仅 root 可读的 `/var/lib/onedebian-agent/cleanup.log`，不混入 JSON 结果；Windows 无论清理完成还是失败都会显示返回的日志路径。排查时可在目标系统运行 `sudo tail -n 80 /var/lib/onedebian-agent/cleanup.log`。计划预览没有执行清理，不代表已经产生该日志。

此环境没有 PVE 宿主级内网隔离，WSL 也不是用于运行不可信代码的强隔离边界。首版不移植 PVE 防火墙、显卡直通或 SLS。

新安装同时以 `agent` 用户在 fnm 管理的 Node 中全局安装固定版本 pnpm，记录于 `/etc/onedebian-agent/versions.json`；不需要 `sudo npm`。已有工作机可用以下命令补装，不必重装：

```bash
~/.local/share/fnm/fnm --fnm-dir ~/.local/share/fnm exec --using=/etc/onedebian-agent/node-version npm install -g pnpm@12.18.0
```
