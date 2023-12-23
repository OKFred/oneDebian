#!/bin/bash
#@description:  安装基础工具：
#@author: Fred Zhang Qi
#@datetime: 2023-12-24

#dependencies--文件依赖
source ./components/the_deployment_direct.sh
source ./components/the_deployment_in_docker.sh

the_deployment() {
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
}
