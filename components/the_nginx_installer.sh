#!/bin/bash
#@description: 下载Openwrt的nginx包
#@author: Fred Zhang Qi
#@datetime: 2024-02-01

#文件依赖
#⚠️import--需要引入包含函数的文件
#none

the_nginx_installer() {
  apt update
  apt install nginx -y
  echo "nginx安装完成"
  echo "nginx版本："
  nginx -v
  the_nginx_setup
  the_nginx_template
}

the_nginx_setup() {
  #检查useradd命令是否存在
  if [ -z "$(which useradd)" ]; then
    echo "useradd命令不存在，正在自动安装"
    apt install shadow-useradd
    which useradd
  fi
  #检查是否存在nginx用户，如果不存在则创建
  if [ -z "$(cat /etc/passwd | grep nginx)" ]; then
    echo "创建nginx用户"
    useradd -r -s /sbin/nologin nginx
  fi
  #输出nginx.conf
  echo "
# nginx运行的用户名
user nginx;

# nginx进程数
worker_processes auto;

# 错误记录文件位置
error_log /var/log/nginx/error.log;

# pid文件地址，记录了nginx的pid，方便进程管理
pid	/var/run/nginx.pid;

# 每个worker_processes的最大并发链接数
events {
	worker_connections  1024;
}

# 提供http服务相关的一些配置参数
http {
    # 引入文件扩展名与文件类型映射表
	include       /etc/nginx/mime.types;
	
	# 默认文件类型
  default_type  application/octet-stream;

	#默认编码格式
	charset utf-8;

	# 设置日志的格式
  log_format  main  
  '时间: \$time_iso8601, '	'转发: \$http_x_forwarded_for, ' '用户: \$remote_user, '	'连接: \$connection, '
  '来源: \$http_referer, '	'状态: \$status, '	'地址: \$remote_addr, '	'请求: \$request, ';

	# 访问记录文件位置
  access_log  /var/log/nginx/access.log	main;

	# 是否使用sendfile函数输出文件
  sendfile	on;

	# TCP连接超时
  keepalive_timeout	61;

	# 读取虚拟主机配置表
  include /etc/nginx/conf.d/*.conf;

	# webSocket 兼容
  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }

  client_header_buffer_size 16k;
	# 修复报错 413 Request Entity Too Large
  # 方便传入到docker仓库
	client_max_body_size 2048M;

	#指令参数2为个数，16k为大小，默认是8k。申请2个16k。
	large_client_header_buffers 2 16k;
}
" >/etc/nginx/nginx.conf
  echo "nginx配置文件已生成"
}

the_nginx_template() {
  echo "开始配置nginx模板"
  echo -e "\033[33m"
  echo "🚩server_name--请输入域名，如abc.example.com"
  read server_name
  echo "⚠️检查SSL？(y/n)"
  read check_ssl
  echo "www root--请输入默认网站根目录"
  read wwwroot
  echo -e "\033[0m"

  #证书文件
  ssl_certificate=/etc/ssl/certs/$server_name.crt

  #私钥文件
  ssl_certificate_key=/etc/ssl/keys/$server_name.key
  if [ "$check_ssl" == "y" ]; then
    if [ ! -f $ssl_certificate ]; then
      echo "证书文件不存在：" $ssl_certificate
      exit 1
    fi
    if [ ! -f $ssl_certificate_key ]; then
      echo "私钥文件不存在：" $ssl_certificate_key
      exit 1
    fi
  fi
  #输出为模板，留在/etc/nginx/.env
  echo "server_name=$server_name
wwwroot=$wwwroot
" >/etc/nginx/.env
  echo "nginx模板已生成"
}
