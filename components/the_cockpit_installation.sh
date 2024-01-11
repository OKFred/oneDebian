#!/bin/bash
#@description:  安装cockpit：
#@author: Fred Zhang Qi
#@datetime: 2023-12-17

#dependencies--文件依赖
# none

the_cockpit_installation() {
  echo -e "\033[33m 🚀cockpit needed--是否需要cockpit？(y/n)"
  read need_cockpit
  echo -e "\033[0m"
  if [ "$need_cockpit" != "y" ]; then
    echo "skip--不需要cockpit，跳过..."
    # apt remove cockpit -y
  else
    apt install -y cockpit
    mv /etc/cockpit/disallowed-users /etc/cockpit/disallowed-users.bak
    echo "" >/etc/cockpit/disallowed-users
    systemctl enable --now cockpit.socket
  fi
}
