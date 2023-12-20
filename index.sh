#!/bin/bash
#@description: 用于Ubuntu/Debian服务器初始化
#@author: Fred Zhang Qi
#@datetime: 2023-12-16

#文件依赖
#⚠️import--需要引入包含函数的文件
source ./components/the_repo_localization.sh
source ./components/the_node_installation.sh
source ./components/the_cockpit_installation.sh
source ./components/the_docker_installation.sh

main() {
  echo -e "\033[32m"
  date
  echo "执行需要管理员权限。请注意"
  echo -e "script running....开始运行\033[0m"
  echo "# 🚩 ① Ubuntu / debian 换源："
  the_repo_localization

  echo "# 🚩  ②安装基础工具："
  apt install -y nano net-tools htop wget

  echo "# 🚩  ③安装nvm、nodeJS 、npm等"
  the_node_installation

  echo "# 🚩  ④安装docker、dockerd、portainer等"
  the_docker_installation

  echo "# 🚩  ⑤安装cockpit："
  the_cockpit_installation

  echo "# 🚩  ⑥收工"
  echo -e "\033[33m 🚀reboot--是否需要重启？(y/n)"
  read need_reboot
  if [ "$need_reboot" != "y" ]; then
    echo "done--大功告成"
  else
    echo '感谢使用， bye~'
    reboot
  fi
  echo -e "\033[0m"
}

main
