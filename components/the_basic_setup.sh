#!/bin/bash

the_basic_setup() {
  local need_basic
  if [ "${1:-}" != --yes ]; then
    printf 'basic tools needed--是否需要安装基础工具？(y/n) '
    read -r need_basic || return 1
    if [ "$need_basic" != y ]; then printf 'skip--不需要，跳过...\n'; return 0; fi
  fi
  [ "$(id -u)" = 0 ] || { printf 'Root required.\n' >&2; return 1; }
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install nano net-tools htop wget curl git
}
