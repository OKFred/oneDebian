#!/usr/bin/env bash
# Dedicated Agent entry; existing Node/desktop installers stay independent.
the_agent_environment() {
  local action choice mirror=keep viewer=16080 mcp=18931 cdp=19222 report answer plan_id public_key key_file ssh_port
  local -a flags=()
  local entry="$MENU_DIR/agent.sh"
  printf '\n14 Agent 环境 / Agent workstation (Debian 13)\n'
  printf '1. 安装 / Install\n2. 继续安装 / Resume\n3. 状态 / Status\n4. 浏览器验收 / Verify browser\n5. 查看入口 / Viewer\n6. 卸载服务（保留资料）/ Uninstall services\n7. 撤销 Agent 安装（保留系统和资料） / Undo\n8. 重新检测／启用加速 / Graphics\n9. 初始化新凭据库为空密码（保留已有库） / Keyring\n10. 配置回环密钥 SSH / SSH\n11. 更新桌面控件与浏览器入口 / Desktop update\n0. 返回 / Back\n'
  read -r -p '选择 / Choice: ' choice
  case "$choice" in
    1)
      read -r -p 'APT 源 keep/tuna/ustc/official [keep]: ' mirror
      mirror=${mirror:-keep}
      case "$mirror" in keep|tuna|ustc|official) ;; *) echo 'Invalid mirror'; return 1 ;; esac
      read -r -p 'noVNC port [16080]: ' viewer
      read -r -p 'MCP port [18931]: ' mcp
      read -r -p 'CDP port [19222]: ' cdp
      flags=(--mirror "$mirror" --viewer-port "${viewer:-16080}" --mcp-port "${mcp:-18931}" --cdp-port "${cdp:-19222}")
      report=$(bash "$entry" plan "${flags[@]}") || return 1
      printf '%s\n' "$report"
      if id agent >/dev/null 2>&1 && [[ ! -f /var/lib/onedebian-agent/user-owned ]]; then
        read -r -p '已有 agent 用户，使用此账号并保留密码和资料？[y/N]: ' answer
        [[ $answer == [yY] ]] || return 0
        flags+=(--adopt-user)
      fi
      if grep -q '^warnings:' <<< "$report"; then
        read -r -p '资源不足，仍继续？[y/N]: ' answer
        [[ $answer == [yY] ]] || return 0
        flags+=(--allow-low-resources)
      fi
      printf '新凭据库自动设为空密码（未加密）；已有库保留；全局安装 pnpm。\n'
      read -r -p '安装以上环境？只安装依赖，不做全系统升级。[y/N]: ' answer
      [[ $answer == [yY] ]] || return 0
      bash "$entry" install --wait "${flags[@]}"
      ;;
    2) bash "$entry" resume --wait ;;
    3) bash "$entry" status ;;
    4) bash "$entry" verify --browser ;;
    5)
      printf '本机查看：以 agent 用户执行 python3 /opt/onedebian-agent/runtime.py open-url\n'
      printf '远程查看：先建立 SSH 隧道，再在本机打开上述地址。端口以 status 输出为准。\n'
      printf 'ssh -N -L 127.0.0.1:16080:127.0.0.1:16080 -L 127.0.0.1:18931:127.0.0.1:18931 <已有SSH用户>@<主机地址>\n'
      ;;
    6)
      read -r -p '移除本工具服务，保留账号、项目和浏览器资料？[y/N]: ' answer
      [[ $answer != [yY] ]] || bash "$entry" uninstall --yes
      ;;
    7)
      report=$(bash "$entry" cleanup-plan) || { printf '%s\n' "$report"; return 1; }
      printf '%s\n' "$report"
      plan_id=$(sed -n 's/^plan_id: \([a-f0-9]\{64\}\)$/\1/p' <<< "$report")
      [[ $plan_id =~ ^[a-f0-9]{64}$ ]] || { printf '清理计划标识无效 / Invalid plan\n'; return 1; }
      read -r -p '保留系统、项目和凭据；输入 UNDO 撤销上述安装变更 / Confirm: ' answer
      [[ $answer == UNDO ]] || { printf '已取消 / Cancelled\n'; return 0; }
      bash "$entry" cleanup --yes --plan-id "$plan_id"
      ;;
    8)
      printf '重新检测加速，必要时短暂重启工作机浏览器；保留资料和页面，失败回到软件模式。不重装系统、不重启桌面。\n'
      read -r -p '执行以上操作？/ Apply [y/N]: ' answer
      [[ $answer == [yY] ]] || { printf '已取消 / Cancelled\n'; return 0; }
      bash "$entry" gpu --yes
      ;;
    9)
      printf '仅将新凭据库初始化为空密码；保留已有库和旧凭据，不关闭浏览器或重启。空密码会降低本机保存凭据的保护。\n'
      read -r -p '允许新凭据库使用空密码？/ Allow [y/N]: ' answer
      [[ $answer == [yY] ]] || { printf '已取消 / Cancelled\n'; return 0; }
      bash "$entry" keyring --yes
      ;;
    10)
      read -r -p 'Debian 中的 SSH 公钥文件路径（不是私钥）: ' key_file
      [[ -f $key_file && ! -L $key_file ]] || { printf '公钥文件无效 / Invalid public key file\n'; return 1; }
      IFS= read -r public_key < "$key_file" || [[ -n $public_key ]] || return 1
      case "$public_key" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;;
        *) printf '只接受 SSH 公钥，未传递文件内容 / Public key required\n'; return 1 ;;
      esac
      read -r -p '回环 SSH 端口 / Port [2222]: ' ssh_port
      printf '仅 agent 公钥登录、仅本机回环监听；保留原系统 SSH。\n'
      read -r -p '配置并启动？/ Apply [y/N]: ' answer
      [[ $answer == [yY] ]] || return 0
      bash "$entry" ssh --yes --ssh-public-key "$public_key" --ssh-port "${ssh_port:-2222}"
      ;;
    11)
      printf '更新悬浮控件，将 Agent 工作浏览器设为首选；保留浏览器页面、构建任务和桌面会话。\n'
      read -r -p '更新桌面控件？/ Apply [y/N]: ' answer
      [[ $answer == [yY] ]] || { printf '已取消 / Cancelled\n'; return 0; }
      bash "$entry" desktop --yes
      ;;
    0|'') return 0 ;;
    *) printf 'Invalid choice\n'; return 1 ;;
  esac
}
