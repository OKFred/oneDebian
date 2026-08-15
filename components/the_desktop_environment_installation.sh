#!/bin/bash
#@description: 安装桌面环境，可选安装并配置 xrdp
#@author: Fred
#@datetime: 2026-08-15

#dependencies--文件依赖
# none

the_desktop_environment_menu() {
  echo "请选择要安装的桌面环境："
  echo "1. XFCE（轻量，推荐用于 xrdp）"
  echo "2. LXQt（轻量）"
  echo "3. MATE（传统桌面）"
  echo "4. GNOME（功能完整，资源占用较高）"
  echo "5. KDE Plasma（功能完整，资源占用较高）"
  echo "0. cancel--取消"
}

the_xrdp_session_configuration() {
  local session_command="$1"
  local default_user="${SUDO_USER:-}"
  local xrdp_user
  local user_home
  local user_group
  local session_file
  local backup_file

  if ! command -v "$session_command" >/dev/null 2>&1; then
    echo "⚠️未找到桌面会话命令 $session_command，已跳过 .xsession 配置。"
    echo "请确认该桌面支持 X11 后再手动配置 xrdp 会话。"
    return 0
  fi

  if [ "$default_user" = "root" ]; then
    default_user=""
  fi

  echo
  echo "xrdp 使用 Linux 系统用户登录。"
  if [ -n "$default_user" ]; then
    echo -n "要为哪个用户配置桌面会话？（默认：$default_user；留空采用默认值）："
  else
    echo -n "要为哪个普通用户配置桌面会话？（留空跳过）："
  fi
  read -r xrdp_user
  xrdp_user="${xrdp_user:-$default_user}"

  if [ -z "$xrdp_user" ]; then
    echo "skip--未指定用户，已跳过 .xsession 配置。"
    echo "稍后可在目标用户家目录创建 .xsession，内容为：exec $session_command"
    return 0
  fi

  if ! id "$xrdp_user" >/dev/null 2>&1; then
    echo "❌用户不存在：$xrdp_user；已跳过 .xsession 配置。"
    return 0
  fi

  user_home=$(getent passwd "$xrdp_user" | cut -d: -f6)
  user_group=$(id -gn "$xrdp_user")
  if [ -z "$user_home" ] || [ ! -d "$user_home" ]; then
    echo "❌无法确定用户家目录：$xrdp_user；已跳过 .xsession 配置。"
    return 0
  fi

  session_file="$user_home/.xsession"
  if [ -e "$session_file" ]; then
    backup_file="$session_file.bak.$(date +%Y%m%d%H%M%S)"
    cp -a -- "$session_file" "$backup_file" || return 1
    echo "已有 .xsession 已备份到：$backup_file"
  fi

  printf '#!/bin/sh\nexec %s\n' "$session_command" >"$session_file" || return 1
  chown "$xrdp_user:$user_group" "$session_file" || return 1
  chmod 700 "$session_file" || return 1
  echo "✅已为 $xrdp_user 配置 xrdp 桌面会话。"
}

the_xrdp_installation() {
  local session_command="$1"
  local need_xrdp

  echo
  echo -n "是否同时安装 xrdp 远程桌面服务？(y/N)："
  read -r need_xrdp
  case "$need_xrdp" in
  y | Y | yes | YES | Yes) ;;
  *)
    echo "skip--已跳过 xrdp 安装。"
    return 0
    ;;
  esac

  echo "🚩installing--正在安装 xrdp..."
  if ! apt-get install -y xrdp xorgxrdp; then
    echo "❌xrdp 安装失败。"
    return 1
  fi

  if getent group ssl-cert >/dev/null 2>&1; then
    adduser xrdp ssl-cert >/dev/null 2>&1 || \
      echo "⚠️无法将 xrdp 加入 ssl-cert 用户组，请检查证书读取权限。"
  fi

  the_xrdp_session_configuration "$session_command" || return 1

  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if systemctl enable xrdp && systemctl restart xrdp; then
      echo "✅xrdp 已启用并启动，默认监听 TCP 3389。"
    else
      echo "⚠️xrdp 已安装，但服务启动失败；请运行 systemctl status xrdp 检查。"
      return 1
    fi
  else
    echo "⚠️xrdp 已安装，但当前系统未运行 systemd，服务尚未启动。"
    echo "启用 systemd 后执行：systemctl enable --now xrdp"
  fi

  echo "安全提示：脚本未自动开放防火墙的 TCP 3389 端口，请按实际网络范围配置。"
}

the_desktop_environment_installation() {
  local desktop_choice
  local desktop_name
  local session_command
  local -a desktop_packages

  if [ "$(id -u)" -ne 0 ]; then
    echo "❌Root Required--请使用 root 或 sudo 运行此安装项。"
    return 1
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "❌当前系统未找到 apt-get；本功能仅支持 Debian/Ubuntu 系统。"
    return 1
  fi

  while true; do
    the_desktop_environment_menu
    echo -n "your choice--请输入你的选择："
    read -r desktop_choice
    case "$desktop_choice" in
    1 | 01)
      desktop_name="XFCE"
      desktop_packages=(xfce4 xfce4-goodies dbus-x11)
      session_command="startxfce4"
      break
      ;;
    2 | 02)
      desktop_name="LXQt"
      desktop_packages=(lxqt dbus-x11)
      session_command="startlxqt"
      break
      ;;
    3 | 03)
      desktop_name="MATE"
      desktop_packages=(mate-desktop-environment-core mate-terminal dbus-x11)
      session_command="mate-session"
      break
      ;;
    4 | 04)
      desktop_name="GNOME"
      desktop_packages=(gnome-core dbus-x11)
      session_command="gnome-session"
      break
      ;;
    5 | 05)
      desktop_name="KDE Plasma"
      desktop_packages=(kde-plasma-desktop dbus-x11)
      session_command="startplasma-x11"
      break
      ;;
    0 | 00 | "")
      echo "cancel--已取消桌面环境安装。"
      return 0
      ;;
    *) echo "error input--输入有误，请重新输入！" ;;
    esac
  done

  echo "🚩installing--正在安装 $desktop_name..."
  if ! apt-get update; then
    echo "❌APT 软件包索引更新失败，未开始安装桌面环境。"
    return 1
  fi
  if ! apt-get install -y "${desktop_packages[@]}"; then
    echo "❌$desktop_name 安装失败。"
    return 1
  fi

  echo "✅$desktop_name 桌面环境安装完成。"
  the_xrdp_installation "$session_command"
}
