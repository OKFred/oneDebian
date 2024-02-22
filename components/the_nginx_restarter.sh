#!/bin/bash
#@description: 重启nginx进程
#@author: Fred Zhang Qi
#@datetime: 2024-02-08

#文件依赖
#⚠️import--需要引入包含函数的文件
#none

the_nginx_restarter() {
  #openwrt
  nginx -s reload
}
