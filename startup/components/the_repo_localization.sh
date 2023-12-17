#!/bin/bash
#@description:  Ubuntu / debian 换源：
#@author: Fred Zhang Qi
#@datetime: 2023-12-16

#dependencies--文件依赖
current_directory=$(pwd)
if [[ $current_directory == *"components"* ]]; then
  #echo "当前路径包含 'components'"
  source the_os_release.sh
else
  #echo "当前路径不包含 'components'，也就是应该在以组件的形式调用"
  source "$current_directory/components/the_os_release.sh"
fi

my_code_name=''
the_repo_localization() {
  # 调用函数获取系统信息
  the_sources_backup
  my_os_release=$(the_os_release)
  my_code_name=$(the_code_name)
  echo "当前系统名称，$my_os_release；版本代号：$my_code_name"

  echo -e "\033[32m"
  # 使用返回的系统信息
  case "$my_os_release" in
  "Ubuntu")
    the_ubuntu_repo
    # 在这里执行 Ubuntu 相关的操作
    ;;
  "Debian")
    the_debian_repo
    # 在这里执行 Debian 相关的操作
    ;;
  "false")
    echo "未找到 /etc/os-release 文件"
    echo "🚫🚫函数执行出错，跳过"
    return 1
    ;;
  *)
    echo "未知错误"
    ;;
  esac
  echo -e "\033[0m"
}

the_sources_backup() {
  sources_list="/etc/apt/sources.list"
  backup_file="/etc/apt/sources.list.bak"

  if [ ! -f "$backup_file" ]; then
    mv /etc/apt/sources.list /etc/apt/sources.list.bak
    echo "已备份原有sources.list -> sources.list.bak"
  else
    echo "sources.list 文件已存在，跳过重复备份"
  fi
}

the_ubuntu_repo() {
  echo "# 更换国内源
	deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $my_code_name main restricted universe multiverse
	deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $my_code_name-updates main restricted universe multiverse
	deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $my_code_name-backports main restricted universe multiverse
	deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $my_code_name-security main restricted universe multiverse
	" >/etc/apt/sources.list
  echo "updating--开始更新源..."
  apt update && apt upgrade -y
}

the_debian_repo() {
  echo "# 更换国内源
	deb https://mirrors.ustc.edu.cn/debian/ $my_code_name main contrib
	deb-src https://mirrors.ustc.edu.cn/debian/ $my_code_name main contrib
	deb https://mirrors.ustc.edu.cn/debian/ $my_code_name-updates main contrib
	deb-src https://mirrors.ustc.edu.cn/debian/ $my_code_name-updates main contrib
	" >/etc/apt/sources.list
  echo "updating--开始更新源..."
  apt update && apt upgrade -y
}
