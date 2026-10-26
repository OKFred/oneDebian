#!/bin/bash
# Cockpit 集成文件管理与 SMB 共享；source 本文件不会执行安装。

the_cockpit_extensions_platform() {
  (
    . /etc/os-release || exit 1
    printf '%s:%s\n' "$ID" "${VERSION_CODENAME:-}"
  )
}

the_cockpit_extensions_precheck() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "❌Root Required--请使用 root 或 sudo 运行此安装项。"
    return 1
  fi
  case "$(the_cockpit_extensions_platform)" in
  debian:* | ubuntu:*) ;;
  *) echo "❌本安装项仅支持 Debian/Ubuntu。"; return 1 ;;
  esac
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    echo "❌未找到 APT/dpkg，无法安装 Cockpit 插件。"
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
    echo "❌当前系统未运行 systemd；请先启用 systemd 后再安装。"
    return 1
  fi
}

the_cockpit_extensions_confirm() {
  local answer
  printf '%s (y/N)：' "$1"
  read -r answer || return 1
  case "$answer" in
  y | Y | yes | YES | Yes) return 0 ;;
  *) echo "cancel--已取消安装。"; return 1 ;;
  esac
}

the_cockpit_extensions_download() {
  local url="$1" checksum="$2" destination="$3"
  if ! curl --fail --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 300 --retry 2 --output "$destination" "$url"; then
    echo "❌下载失败，未安装下载的组件。"
    return 1
  fi
  if ! printf '%s  %s\n' "$checksum" "$destination" | sha256sum --check --status; then
    echo "❌SHA256 校验失败，未安装下载的组件。"
    return 1
  fi
}

the_cockpit_extensions_enable() {
  local unit="$1"
  if ! systemctl enable --now "$unit" || ! systemctl is-active --quiet "$unit"; then
    echo "❌服务未正常运行：$unit。请运行 systemctl status $unit 检查。"
    return 1
  fi
}

the_cockpit_extensions_usage() {
  echo "访问 https://服务器IP:9090，使用现有 Linux 账号登录并按需启用管理访问。"
  echo "刷新 Cockpit 页面即可看到新菜单；已有终端无需关闭。"
  echo "防火墙请按所需网络范围放行 Cockpit TCP 9090。"
}

the_cockpit_file_browser_installation() (
  local candidate temp_dir stage_dir='' navigator_dir=/usr/share/cockpit/navigator
  the_cockpit_extensions_precheck || return 1
  the_cockpit_extensions_confirm "安装 Cockpit 集成文件浏览器（浏览、上传、下载、编辑文件）？" || return 0
  apt-get update || return 1

  # Files 45 修复了旧版的文件权限问题；不自动安装更旧的候选版本。
  candidate=$(LC_ALL=C apt-cache policy cockpit-files | awk '/Candidate:/ {print $2; exit}')
  if [ -n "$candidate" ] && [ "$candidate" != '(none)' ] && dpkg --compare-versions "$candidate" ge 45; then
    apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends cockpit cockpit-files || return 1
    echo "已安装 Cockpit Files，侧栏入口：File browser / 文件浏览器。"
  else
    apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends \
      cockpit python3 rsync zip file coreutils inotify-tools ca-certificates curl tar || return 1
    if [ -e "$navigator_dir" ] || [ -L "$navigator_dir" ]; then
      if [ ! -f "$navigator_dir/manifest.json" ]; then
        echo "❌Navigator 目标路径已存在但缺少 manifest.json，请先检查：$navigator_dir"
        return 1
      fi
      echo "检测到已有 Navigator，保留现有文件。"
    else
      temp_dir=$(mktemp -d /tmp/onedebian-navigator.XXXXXXXX) || return 1
      trap 'rm -rf -- "$temp_dir"; if [ -n "$stage_dir" ]; then rm -rf -- "$stage_dir"; fi' EXIT
      the_cockpit_extensions_download \
        'https://github.com/45Drives/cockpit-navigator/archive/refs/tags/v0.5.14-1.tar.gz' \
        'd53825143edc7bfc57c7d0d1a0afca7404f98413b3c4ee499698e0010c5cd434' \
        "$temp_dir/navigator.tar.gz" || return 1
      tar -xzf "$temp_dir/navigator.tar.gz" --no-same-owner -C "$temp_dir" \
        cockpit-navigator-0.5.14-1/navigator || return 1
      printf 'export let NAVIGATOR_VERSION = "0.5.14-1";\n' \
        >"$temp_dir/cockpit-navigator-0.5.14-1/navigator/version.js" || return 1
      # 上游脚本使用此绝对路径；不能改装到 /usr/local/share。
      install -d -m 0755 /usr/share/cockpit || return 1
      stage_dir=$(mktemp -d /usr/share/cockpit/.onedebian-navigator.XXXXXXXX) || return 1
      cp -R -- "$temp_dir/cockpit-navigator-0.5.14-1/navigator/." "$stage_dir/" || return 1
      chmod -R a+rX "$stage_dir" || return 1
      # 完整复制后才发布目录，失败不会留下被误认为已安装的半成品。
      mv -T -- "$stage_dir" "$navigator_dir" || return 1
      stage_dir=''
    fi
    echo "已安装 Cockpit Navigator，侧栏入口：Navigator / 文件导航。"
  fi
  the_cockpit_extensions_enable cockpit.socket || return 1
  echo "✅Cockpit 文件浏览器已就绪。"
  the_cockpit_extensions_usage
)

the_cockpit_smb_package() {
  # 固定上游 release v4.6.3；校验值来自 GitHub release asset.digest。
  # 不使用不同发行版的包代替，也不自动添加第三方 APT 源。
  case "$1" in
  debian:bookworm) echo 'bookworm 84ce2d909aac33fee859fcb8600b00a3d10a54b5c4c3ca9c6cf82d3becfd9df6' ;;
  debian:trixie) echo 'trixie a7bd5196d218c3fe87c4fca1ff999e868c2d4fdbf85e5877dff1bfd54e8043d2' ;;
  ubuntu:focal) echo 'focal 20b79c67ad9a6e1161d943518932a4387d5de7aa6d81697d74aff0e217abc15e' ;;
  ubuntu:jammy) echo 'jammy 39e445cbcce0fb8a35d1d45ca920ca7a87833d45f60536787de4601fa1de254b' ;;
  *) echo "❌上游没有为 $1 提供已核验的 SMB 插件包；支持 Debian 12/13、Ubuntu 20.04/22.04。" >&2; return 1 ;;
  esac
}

the_cockpit_smb_installation() (
  local package_info suite checksum temp_dir package_file installed_version='' backup_file
  local -a packages=(cockpit samba samba-common-bin)
  # Debian/Ubuntu 的 samba-common 也可能通过 ucf 管理 smb.conf。
  export UCF_FORCE_CONFFOLD=1
  the_cockpit_extensions_precheck || return 1
  package_info=$(the_cockpit_smb_package "$(the_cockpit_extensions_platform)") || return 1
  read -r suite checksum <<<"$package_info"
  echo "安装 Samba 与 Cockpit File Sharing。上游插件也依赖 NFS 软件包。"
  echo "保留现有共享；安装后在 Cockpit 中选择共享目录和设置 Samba 密码。"
  the_cockpit_extensions_confirm "安装 Cockpit SMB 文件共享？" || return 0

  # APT 保留现有配置，并在安装前另存一份 smb.conf。
  if [ -f /etc/samba/smb.conf ]; then
    backup_file=$(mktemp /etc/samba/smb.conf.onedebian.XXXXXXXX.bak) || return 1
    cp -pL -- /etc/samba/smb.conf "$backup_file" || return 1
    echo "原 Samba 配置已备份：$backup_file"
  fi
  apt-get update || return 1
  apt-get install -y --no-install-recommends ca-certificates curl || return 1

  if [ "$(dpkg-query -W -f='${db:Status-Status}' cockpit-file-sharing 2>/dev/null)" = installed ]; then
    installed_version=$(dpkg-query -W -f='${Version}' cockpit-file-sharing) || return 1
  fi
  if [ -n "$installed_version" ] && dpkg --compare-versions "$installed_version" ge "4.6.3-1$suite"; then
    echo "保留已有 Cockpit File Sharing $installed_version。"
  else
    temp_dir=$(mktemp -d /tmp/onedebian-smb.XXXXXXXX) || return 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    package_file="$temp_dir/cockpit-file-sharing_4.6.3-1${suite}_all.deb"
    the_cockpit_extensions_download \
      "https://github.com/45Drives/cockpit-file-sharing/releases/download/v4.6.3/${package_file##*/}" \
      "$checksum" "$package_file" || return 1
    if [ "$(dpkg-deb -f "$package_file" Package)" != cockpit-file-sharing ] ||
      [ "$(dpkg-deb -f "$package_file" Version)" != "4.6.3-1$suite" ] ||
      [ "$(dpkg-deb -f "$package_file" Architecture)" != all ]; then
      echo "❌安装包元数据不匹配，已停止安装。"
      return 1
    fi
    # 允许 APT 的 _apt 用户读取临时包。
    chmod 0755 "$temp_dir" || return 1
    chmod 0644 "$package_file" || return 1
    packages+=("$package_file")
  fi
  apt-get -o Dpkg::Options::=--force-confold install -y --no-install-recommends "${packages[@]}" || return 1
  if ! testparm --suppress-prompt >/dev/null; then
    echo "❌Samba 配置校验失败；请修复 /etc/samba/smb.conf 后再启动服务。"
    return 1
  fi
  if [ "$(testparm -s --parameter-name='server role' 2>/dev/null)" = 'active directory domain controller' ]; then
    echo "❌当前主机是 AD 域控制器，请使用其既有 Samba 服务管理方式；未启用独立 smbd。"
    return 1
  fi
  the_cockpit_extensions_enable cockpit.socket || return 1
  the_cockpit_extensions_enable smbd || return 1
  echo "✅Cockpit SMB 组件已安装，Samba 服务已运行。"
  the_cockpit_extensions_usage
  echo "打开 File Sharing / 文件共享 → Samba；若提示 Misconfigured，点击 Fix now 启用 registry。"
  echo "然后添加共享，并在 Manage Samba Passwords 中为已有 Linux 用户设置 SMB 密码。"
  echo "原 smb.conf 中的共享继续保留；需要在界面管理时再使用 Import（会要求确认）。"
  echo 'Windows 访问：\\服务器IP\共享名；防火墙按所需网络范围放行 SMB TCP 445。'
)
