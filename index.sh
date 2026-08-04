#!/bin/bash
#@description: 用于Ubuntu/Debian服务器初始化
#@author: Fred
#@datetime: 2023-12-16

#文件依赖
#⚠️import--需要引入包含函数的文件
source ./components/the_repo_localization.sh
source ./components/the_node_installation.sh
source ./components/the_cockpit_installation.sh
source ./components/the_docker_installation.sh
source ./components/the_deployment_direct.sh
source ./components/the_deployment_in_docker.sh

main() {
  echo -e "\033[32m"
  date
  echo "执行需要管理员权限。请注意"
  echo -e "script running....开始运行\033[0m"
  echo "# 🚩 Ubuntu / debian 换源："
  the_repo_localization

  echo -e "\033[33m"
  echo "需要准备环境？(y/n)"
  read need_prepare_environment
  echo -e "\033[0m"
  if [ "$need_prepare_environment" != "y" ]; then
    echo "暂不需要环境准备"
  else
    echo "# 🚩  安装基础工具："
    apt install -y nano net-tools htop wget

    echo "# 🚩  安装nvm、nodeJS 、npm等"
    the_node_installation

    echo "# 🚩  安装docker、dockerd、portainer等"
    the_docker_installation

    echo "# 🚩  安装cockpit："
    the_cockpit_installation
  fi
  echo "# 🚩  项目部署"
  echo -e "\033[33m"
  echo "使用docker进行部署？(y/n)"
  read need_dockerize
  if [ "$need_dockerize" != "y" ]; then
    echo "原生系统直接部署？(y/n)"
    read need_raw_deployment
    if [ "$need_raw_deployment" != "y" ]; then
      echo "❌项目未部署"
    else
      echo "✅项目直接部署："
      the_deployment_direct
    fi
  else
    echo "docker本地构建并部署"
    the_deployment_in_docker
  fi
  echo "done--大功告成"
  echo -e "\033[0m"
}

main
