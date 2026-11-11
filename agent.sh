#!/usr/bin/env bash
# Shared native Debian / WSL entry point. Never runs the toolbox's full upgrade.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$HERE/agent/install.py" ]]; then INSTALLER="$HERE/agent/install.py"; else INSTALLER="$HERE/install.py"; fi
if ! command -v python3 >/dev/null; then
  case "${1:-plan}" in
    install|resume|prepare-wsl)
      [[ $(id -u) == 0 ]] || { echo 'Run with sudo/root to install Python 3.' >&2; exit 1; }
      . /etc/os-release
      [[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || { echo 'Debian 13 required.' >&2; exit 1; }
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
      export DEBIAN_FRONTEND=noninteractive
      apt-get -o APT::Update::Error-Mode=any update >&2
      apt-get install -y --no-install-recommends python3 ca-certificates >&2
      ;;
    *) echo 'Python 3 is not installed; plan/status made no changes. Run install or prepare-wsl as root.' >&2; exit 1 ;;
  esac
fi
exec python3 "$INSTALLER" "$@"
