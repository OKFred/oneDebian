#!/usr/bin/env bash
# Shared native Debian / WSL entry point. Never runs the toolbox's full upgrade.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$HERE/agent/install.py" ]]; then INSTALLER="$HERE/agent/install.py"; else INSTALLER="$HERE/install.py"; fi
if ! command -v python3 >/dev/null; then
  case "${1:-plan}" in
    install|resume|prepare-wsl|prepare-undo)
      [[ $(id -u) == 0 ]] || { echo 'Run with sudo/root to install Python 3.' >&2; exit 1; }
      . /etc/os-release
      [[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || { echo 'Debian 13 required.' >&2; exit 1; }
      if [[ -f "$HERE/agent/package-undo-hook.sh" ]]; then undo_hook="$HERE/agent/package-undo-hook.sh"; else undo_hook="$HERE/package-undo-hook.sh"; fi
      /bin/sh "$undo_hook" bootstrap-init
      undo_sources="$(dirname -- "$undo_hook")/undo-bootstrap-sources.sh"
      /bin/sh "$undo_sources" reset
      /bin/sh "$undo_hook" bootstrap-init
      /bin/sh "$undo_sources" before
      mirror=keep
      args=("$@")
      for ((i=0; i<${#args[@]}; i++)); do
        if [[ ${args[$i]} == --mirror ]]; then mirror=${args[$((i+1))]:-keep}; fi
      done
      if [[ $mirror != keep ]]; then
        if [[ -f "$HERE/components/the_repo_localization.sh" ]]; then helper="$HERE/components/the_repo_localization.sh"; else helper="$HERE/../components/the_repo_localization.sh"; fi
        source "$helper"
        the_localize_apt_sources Debian trixie /etc/apt "$mirror" >&2
      fi
      /bin/sh "$undo_sources" seal
      export DEBIAN_FRONTEND=noninteractive
      apt-get -o APT::Update::Error-Mode=any update >&2
      apt-get -o 'DPkg::Pre-Install-Pkgs::=/var/lib/onedebian-agent/package-undo-hook.sh record' \
        -o 'DPkg::Tools::Options::/var/lib/onedebian-agent/package-undo-hook.sh::Version=3' \
        -o 'DPkg::Post-Invoke::=/var/lib/onedebian-agent/package-undo-hook.sh finish' \
        install -y --no-install-recommends python3 ca-certificates >&2
      ;;
    *) echo 'Python 3 is not installed; plan/status made no changes. Run install or prepare-wsl as root.' >&2; exit 1 ;;
  esac
fi
exec python3 "$INSTALLER" "$@"
