#!/bin/bash
#@description:  安装基础工具：
#@author: Fred
#@datetime: 2023-12-24

#dependencies--文件依赖
source ./components/the_deployment_direct.sh
source ./components/the_deployment_in_docker.sh

the_deployment() {
  echo "# 🚩  project deployment--项目部署"
  echo -e "\033[33m"
  echo "deploy in docker--使用docker进行部署？(y/n)"
  read need_dockerize
  if [ "$need_dockerize" != "y" ]; then
    echo "deploy directly--原生系统直接部署？(y/n)"
    read need_raw_deployment
    if [ "$need_raw_deployment" != "y" ]; then
      echo "❌cancel--项目未部署"
    else
      echo "✅deploying--项目直接部署："
      the_deployment_direct
    fi
  else
    echo "building in container--docker本地构建并部署"
    the_deployment_in_docker
  fi
}
