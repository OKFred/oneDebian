#!/bin/bash
#@description: 清理端口
#@author: Fred Zhang Qi
#@datetime: 2024-02-09

#文件依赖
#⚠️import--需要引入包含函数的文件

the_nginx_conf_dir="/etc/nginx/conf.d"

the_nginx_port_cleaner() {
  local port_list=$(the_port_getter)
  if [ ${#port_list[@]} -eq 0 ]; then
    echo "没有端口"
    return 1
  fi
  echo "端口列表："
  for port in ${port_list[@]}; do
    echo $port
  done
  echo -e "\033[33m"
  echo "🚩port--请输入要清理的端口"
  read port
  echo -e "\033[0m"
  if [ $(echo ${port_list[@]} | grep -w $port | wc -l) -eq 0 ]; then
    echo "端口：$port 不存在"
    return 1
  fi
  rm -f $the_nginx_conf_dir/$port.conf
  echo "端口：$port 已清理"
  ls -la $the_nginx_conf_dir
  read -p "是否重启nginx？(y/n)" the_user_choice
  if [ "$the_user_choice" == "y" ]; then
    nginx -s reload
    echo "nginx已重启"
  fi
  return 0
}

the_port_getter() {
  #从$the_nginx_conf_dir获取端口
  #返回端口列表
  local port_list=()
  for file in $(ls $the_nginx_conf_dir); do
    if [ "${file##*.}" != "conf" ]; then
      continue
    fi #如果文件不是以.conf结尾，则跳过
    port=$(cat $the_nginx_conf_dir/$file | grep "listen" | awk '{print $2}' | awk -F";" '{print $1}')
    port_list+=($port)
  done
  echo ${port_list[@]}
}
