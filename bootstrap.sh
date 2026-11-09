#!/bin/bash
# Run menu 01 and 02 once, without driving the interactive menu.

if ! declare -F the_repo_localization >/dev/null || ! declare -F the_basic_setup >/dev/null; then
  BOOTSTRAP_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
  source "$BOOTSTRAP_DIR/components/the_repo_localization.sh" || exit 1
  source "$BOOTSTRAP_DIR/components/the_basic_setup.sh" || exit 1
fi

the_bootstrap() {
  local package status audit
  export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1
  the_repo_localization || return 1
  the_basic_setup --yes || return 1
  for package in nano net-tools htop wget curl git; do
    status=$(dpkg-query -W -f='${db:Status-Status}' "$package") || return 1
    [ "$status" = installed ] || { printf 'Package was not installed: %s\n' "$package" >&2; return 1; }
  done
  audit=$(dpkg --audit) || return 1
  [ -z "$audit" ] || { printf '%s\n' "$audit" >&2; return 1; }
  printf 'ONEDEBIAN_BOOTSTRAP_OK\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  the_bootstrap "$@"
fi
