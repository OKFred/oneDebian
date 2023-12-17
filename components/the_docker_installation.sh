#!/bin/bash
#@description:  安装docker、portainer.io、registry：
#@author: Fred Zhang Qi
#@datetime: 2023-12-17

#dependencies--文件依赖
# none

the_docker_installation() {
  echo -e "\033[33m🚀是否要安装docker-客户端？(y/n)"
  read need_docker
  echo -e "\033[0m"
  if [ "$need_docker" != "y" ]; then
    echo "已跳过 docker 的安装"
    apt remove docker docker-compose -y
  else
    echo "🚩正在安装 docker..."
    if which docker &>/dev/null; then
      echo "docker似乎已安装"
    else
      echo "⏬正在下载docker"
      wget -qO- online_docker_install.sh https://get.docker.com | bash
    fi
    docker -v
    docker ps
    the_portainer_installation
    the_registry_installation
  fi
}

the_portainer_installation() {
  echo -e "\033[33m🚀是否要安装portainer-管理工具？(y/n)"
  read need_portainer
  echo -e "\033[0m"
  if [ "$need_portainer" != "y" ]; then
    echo "已跳过 portainer 的安装"
  else
    echo "🚩正在安装 portainer..."
    docker volume create portainer_data
    docker run -d \
      -p 8000:8000 -p 9443:9443 \
      --name my-portainer \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data portainer/portainer-ce:latest
  fi
}

the_registry_installation() {
  echo -e "\033[33m🚀是否要安装registry-专用仓库？(y/n)"
  read need_registry
  echo -e "\033[0m"
  if [ "$need_registry" != "y" ]; then
    echo "已跳过 registry 的安装"
    docker rm -f $(docker ps | grep registry-ui | awk '{print $1}')
    docker rm -f $(docker ps | grep registry | awk '{print $1}')
  else
    echo -e "\033[33m🚀仓库地址？（需要配合nginx使用）"
    read registry_url
    echo -e "\033[0m"
    if [ -z "$registry_url" ]; then
      return 1
    fi
    echo "🚩正在安装 registry..."
    echo '创建目录'
    my_project_data_path="$HOME/my-docker-data/my-registry-data"
    echo "$my_project_data_path"
    mkdir -p "$my_project_data_path"
    chmod +x "$my_project_data_path"
    apt install -y docker-compose apache2-utils
    echo '创建docker-compose配置文件。记得公网内网地址根据实际调整'
    echo "
version: '2.0'
services:
  registry:
    image: registry:latest
    ports:
      - 8001:5000
    volumes:
      - $my_project_data_path/registry:/var/lib/registry
      - $my_project_data_path/credentials.yml:/etc/docker/registry/config.yml
      - $my_project_data_path/htpasswd:/var/docker-registry/registry-config/htpasswd #需要配合credentials.yml里的文件指向
    restart: always
  ui:
    image: joxit/docker-registry-ui:latest
    ports:
      - 8002:80
    environment:
      - REGISTRY_TITLE=My Private Docker Hub  # 自定义主页显示的Registry名称
      - REGISTRY_URL=$registry_url  # 不建议使用localhost
      - REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin="*"
      - SINGLE_REGISTRY=true
      - REGISTRY_SECURED=true
    depends_on:
      - registry
    restart: always
" >./docker-compose.yaml
    echo '创建registry配置文件。'
    echo "
version: 0.1
log:
  fields:
    service: registry
storage:
  delete:
    enabled: true
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
    Access-Control-Allow-Origin: ['$registry_url']  # 不建议使用localhost
    Access-Control-Allow-Methods: ['HEAD', 'GET', 'OPTIONS', 'DELETE']
    Access-Control-Allow-Headers: ['Authorization', 'Accept']
    Access-Control-Max-Age: [1728000]
    Access-Control-Allow-Credentials: ['true']
    Access-Control-Expose-Headers: ['Docker-Content-Digest']
auth:
  htpasswd:
    realm: basic-realm
    path: /var/docker-registry/registry-config/htpasswd  # 密码文件放置
" >"$my_project_data_path/credentials.yml"

    echo -e "\033[33m🚀输入用户名（默认admin）"
    read registry_user
    if [ -z "$registry_user" ]; then
      registry_user="admin" # 设置默认值
    fi
    echo "🚀创建密码"
    htpasswd -cB "$my_project_data_path/htpasswd" "$registry_user"
    echo "启动容器并通过$registry_url访问"
    potential_local_address=$(ip -4 address | grep /24 | awk '{split($2, parts, "/"); print parts[1]}')
    if [ -z "$potential_local_address" ]; then
      potential_local_url="http://127.0.0.1" # 设置默认值
    else
      potential_local_url="http://$potential_local_address" # 设置默认值
      echo "推测的内网地址：$potential_local_url；请根据实际情况修改"
    fi
    echo -e "\033[0m"
    echo "前提是配置好转发。nginx部分配置参考如下：
 # 私有仓库
 location /v2/ {
	proxy_set_header X-Real-IP \$remote_addr;
	proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
	proxy_set_header Host \$http_host;
	proxy_set_header X-NginX-Proxy true;
	proxy_set_header  X-Forwarded-Proto \$scheme;
 
	proxy_pass $potential_local_url:8001/v2/;
	proxy_redirect off;
	
	#WebSocket设置
	 proxy_read_timeout 300s;
	 proxy_send_timeout 300s;
	 
	 proxy_http_version 1.1;
	 proxy_set_header Upgrade \$http_upgrade;
	 proxy_set_header Connection \$connection_upgrade;
 }
 location /docker/ {
	proxy_set_header X-Real-IP \$remote_addr;
	proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
	proxy_set_header Host \$http_host;
	proxy_set_header X-NginX-Proxy true;
 
	proxy_pass $potential_local_url:8002/;
	proxy_redirect off;
	
	#WebSocket设置
	 proxy_read_timeout 300s;
	 proxy_send_timeout 300s;
	 
	 proxy_http_version 1.1;
	 proxy_set_header Upgrade \$http_upgrade;
	 proxy_set_header Connection \$connection_upgrade;
	if (\$request_method = OPTIONS ) {
		add_header Content-Length 0;
		add_header Content-Type text/plain;
		return 200;
	}
	#处理OPTIONS 请求
 }"
    docker-compose up -d
    rm -rf ./docker-compose.yaml
  fi
}