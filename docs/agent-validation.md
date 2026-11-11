# Agent 工作机验收记录

2026-11-11，在独立 Debian 13 WSL2 测试实例中验证；原生 Debian 的硬件和独立开机流程尚未实机测试。

## 自动检查

- PowerShell 207 个独立用例通过，其中 Agent 新增 19 个；Agent 入口也通过 Windows PowerShell 5.1 检查。
- Debian 中 Python 60 个用例全部通过，包括真实 websockify HTTP／WebSocket 鉴权、Host／Origin、代理和重定向边界，以及 GPU 权限与精确回退。
- Bash 镜像源／初始化 20 个、原 Cockpit 扩展 28 个用例通过。
- Linux 图形和进程验收模块仅在 Linux 执行；Windows 不导入该模块。

## 实机链路

| 检查 | 结果 |
|---|---|
| 新建、校验 rootfs、无 Windows 磁盘挂载的分块传输 | 通过 |
| firstboot 屏蔽、网络保护在首次 systemd 启动前完成 | 新实例复测通过 |
| Node 交互／非交互／版本文件包装器／MCP | 均为 fnm 的 v26.13.0 |
| Codex CLI | 0.166.0，真实账号授权留给用户 |
| Git／SSH 客户端 | Git 2.47.3，OpenSSH 客户端可用；不安装 SSH 服务端 |
| 私有桌面与监听地址 | 1600×900；VNC Unix socket，三个 TCP 服务均为回环 |
| MCP 打开前端、输入、提交、截图、独立 DOM 核对 | 通过 |
| VNC Unix socket、已授权 WebSocket 的真实画面 | 两者均通过 |
| WebSocket 键鼠接管后，MCP 重新读取人工输入 | 通过，无输入重放，浏览器 PID 保持 |
| 单独重启 MCP | 浏览器 PID、标签页及 URL 保持 |
| 关闭查看连接后使用 MCP | 输入、点击和截图仍通过 |
| 只重启测试 WSL 实例 | 桌面自启、原 profile 和五个页面恢复 |
| 人工标记跨实例重启 | MCP 停止且端口关闭，显式交还后恢复 |
| keyring | 使用非空测试密码完成设置；重启后经真实 VNC 人工解锁 |
| 合成 Cookie 跨实例重启 | 解锁后通过；未使用真实网站账号 |
| 其他四个 WSL | 配置未修改、未重启；最终运行状态、默认实例及共享 IP／路由一致 |

首次试验暴露了通用 rootfs 的 networkd 接管 WSL 共享网络问题，已恢复原网络，并将网络保护移至首次 systemd 启动之前。随后使用另一个全新临时实例复测，启动与清理前后的共享网络保持一致。

## 边界

- 本机只有 DXG，没有 DRM render 节点；实际 Chromium 是 llvmpipe **软件渲染**。未将它报告为硬件加速通过；原生 EGL／DRM 硬件路径仍需对应设备验收。
- 当前 Windows 全局 `localhostForwarding=false`，因此未通过 Windows 浏览器直接访问回环入口。菜单已提前提示，工具保留该设置；真实 noVNC WebSocket、画面和键鼠在目标环境内完成验收。
- 正常 keyring 不会因为桌面自动启动而自动解锁。初次设置、冷启动解锁及真实 Codex／网站账号授权仍由用户完成；生产脚本不保存或注入 keyring 密码。
- 自动 `verify` 报告中的人工检查占位项与本次人工／冷启动证据分别记录，不以服务 active 代替实机验收。
