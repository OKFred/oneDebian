#!/bin/bash
#@description: 菜单化显示工具箱列表
#@author: Fred Zhang Qi
#@datetime: 2023-12-24

#文件依赖
#⚠️import--需要引入包含函数的文件
source ./components/the_repo_localization.sh
source ./components/the_basic_setup.sh
source ./components/the_ssh_configuration.sh
source ./components/the_node_installation.sh
source ./components/the_cockpit_installation.sh
source ./components/the_docker_installation.sh
source ./components/the_deployment.sh

menu_title() {
  #clear
  date
  echo "执行需要管理员权限。请注意"
  echo "*********************"
  echo "*****   工具箱   *****"
}

menu_back() {
  echo
  echo -n "按任意键返回."
  read
}

main() {
  while (true); do
    menu_title
    echo "01. 更换国内源"
    echo "02. 安装基础工具nano、wget、git等"
    echo "03. 配置SSH"
    echo "04. 安装nvm、nodeJS 、npm等"
    echo "05. 安装cockpit--方便运维"
    echo "06. 安装docker、dockerd、portainer等"
    echo "07. 部署项目"
    echo "08. 更多"
    echo "09. 关于"
    echo "00. 退出"
    echo
    echo -n "请输入你的选择："
    read the_user_choice
    case "$the_user_choice" in
    01 | 1) the_repo_localization ;;
    02 | 2) the_basic_setup ;;
    03 | 3) the_ssh_configuration ;;
    04 | 4) the_node_installation ;;
    05 | 5) the_cockpit_installation ;;
    06 | 6) the_docker_installation ;;
    07 | 7) the_deployment ;;
    08 | 8) echo '敬请期待' ;;
    09 | 9) nano readme.md ;;
    00 | 0) exit 1 ;;
    u) echo "???" ;;
    *) echo "输入有误，请重新输入！" && menu_back ;;
    esac
    echo
  done
}

clear
main
