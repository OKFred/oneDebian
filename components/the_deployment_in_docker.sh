#!/bin/bash
#@description:  使用docker进行本地构建、拉取、推送等：
#@author: Fred Zhang Qi
#@datetime: 2023-12-20

#dependencies--文件依赖
# none

current_dir=$(pwd) # 获取当前工作目录的绝对路径
current_folder=$(basename "$PWD")
parent_dir=$(dirname "$current_dir")    # 获取当前工作目录的父目录路径
parent_folder=$(basename "$parent_dir") # 获取父目录的名称
project_name=$(whoami)_nodejs_$parent_folder

the_deployment_in_docker() {
  if ! command -v docker &>/dev/null; then
    echo "please install docker--请先安装docker等"
    return 1
  else
    cd $parent_dir
    the_docker_check_old_batch $project_name
    echo -e "\033[33m🚀remote registry--是否需要用到远程仓库？(y/n)"
    read need_registry
    echo -e "\033[0m"
    if [ "$need_registry" == "y" ]; then
      the_docker_registry_operation
    fi
    echo -e "\033[33m🚀docker build--是否需要使用docker构建项目？(y/n)"
    read need_dockerization
    echo -e "\033[0m"
    if [ "$need_dockerization" == "y" ]; then
      echo "build locally--本地构建"
      the_docker_build
      if [ $? -eq 0 ]; then
        echo "✅build success--构建成功！"
        the_docker_run
      else
        echo "❌build fail--构建失败！"
      fi
    fi
    cd $current_dir
  fi
}

the_docker_check_old() {
  local old_container_id=$1
  echo "🚩stopping old container--正在停止旧容器..."
  docker stop $old_container_id
  echo "🚩deleting old container--旧容器已停止，正在删除..."
  docker rm $old_container_id
  echo "🚩deleted old container--旧容器已删除"
}

#循环查找旧容器，询问是否删除
the_docker_check_old_batch() {
  local repo_name=$1
  echo $(docker ps -a | grep $repo_name)
  local repo_array
  local repo_array_length=$(docker ps -a | grep $repo_name | wc -l)
  local repo_array_to_remove=()
  for ((i = 0; i < $repo_array_length; i++)); do
    local old_container_id=$(docker ps -a | grep $repo_name | awk '{print $1}' | sed -n "$((i + 1))p")
    local repo_array[$i]=$old_container_id
    if [ -n "$old_container_id" ]; then
      echo -e "\033[33m🚀old container discovered--发现旧容器，ID：$old_container_id，是否删除？(y/n)"
      read need_remove_old
      echo -e "\033[0m"
      if [ "$need_remove_old" == "y" ]; then
        repo_array_to_remove+=($old_container_id) #push
      fi
    fi
  done
  echo "container pending removal--待清理的容器数量：" ${#repo_array_to_remove[*]}
  for ((i = 0; i < ${#repo_array_to_remove[*]}; i++)); do
    the_docker_check_old ${repo_array_to_remove[$i]}
  done
}

the_docker_build() {
  if [ ! -f "Dockerfile" ]; then
    echo "file missing--配置文件Dockerfile不存在！"
    return 1
  fi
  docker build -t $project_name .
}

the_docker_run() {
  echo "container starting--正在启动容器..."
  echo "random port assigned--端口随机分配，记得做好端口映射哦"
  docker run -d -P $project_name
  if [ $? -eq 0 ]; then
    echo "service registered--✅服务注册成功！"
    docker ps | grep $project_name
  else
    echo "service unabled to register--❌服务注册失败！"
  fi
}

the_docker_registry_operation() {
  #检查之前是否保存过仓库地址
  config_file=$HOME/my-docker-data/my.docker.conf
  if [ ! -d "$HOME/my-docker-data" ]; then
    mkdir -p $HOME/my-docker-data
  fi
  if [ -f "$config_file" ]; then
    #echo "配置文件$config_file已存在，将自动读取"
    registry_url=$(cat $config_file)
  else
    echo
    #echo "配置文件$config_file不存在，将自动创建..."
  fi
  echo -e "\033[32m🚀current registry url--当前仓库地址为：$registry_url"
  echo -e "\033[33m"
  read -p "🚩registy address modification--是否需要修改仓库地址？(y/n)" need_modify_registry_url
  if [ "$need_modify_registry_url" == "y" ]; then
    echo -e "\033[33m🚀registry url--请输入仓库地址，http(s)://...："
    read registry_url
    echo -e "\033[0m"
    if [ -z "$registry_url" ]; then
      echo "stay default--未输入，默认为docker.io"
    else
      echo "🚩registry url--仓库地址为：$registry_url"
      echo "🚩saving--正在保存..."
      echo $registry_url >$config_file
    fi
  fi
  docker login $registry_url
  registry_url_no_http=$(echo $registry_url | sed 's/http[s]*:\/\///g')
  if [ $? -eq 0 ]; then
    echo "✅log in success--登录成功！"
    the_image_push
    the_image_pull
  else
    echo "❌log in fail--登录失败！"
  fi
}

the_image_push() {
  echo -e "\033[33m🚀push to the registry--是否要推送该项目到仓库？(y/n)"
  read need_push
  echo -e "\033[0m"
  if [ "$need_push" != "y" ]; then
    echo "skip--已跳过"
  else
    local project_name=$parent_folder
    local project_version
    read -p "🚩project version--请输入项目版本：" project_version
    if [ -z "$project_version" ]; then
      echo "stay default--未输入，已默认为latest"
      project_version="latest"
    fi
    echo "🚩building--正在打包..."
    local docker_tag=$registry_url_no_http/$project_name:$project_version
    docker build -t $docker_tag .
    if [ $? -eq 0 ]; then
      echo "✅build success--打包成功！"
    else
      echo "❌build fail--打包失败！"
      return 1
    fi
    echo "🚩pushing--准备推送..."
    docker push $docker_tag
    if [ "$project_version" != "latest" ]; then
      echo -e "\033[33m🚀mark as latest--是否同时标记为最新版推送？(y/n)"
      read upload_as_latest
      echo -e "\033[0m"
      if [ "$upload_as_latest" == "y" ]; then
        project_version="latest"
      else
        return 1
      fi
      echo "🚩building--正在打包..."
      local docker_tag=$registry_url_no_http/$project_name:$project_version
      docker build -t $docker_tag .
      if [ $? -eq 0 ]; then
        echo "✅build success--打包成功！"
      else
        echo "❌build fail--打包失败！"
        return 1
      fi
      echo "🚩pushing--准备推送..."
      docker push $docker_tag
    fi
  fi
}

the_image_pull() {
  echo -e "\033[33m🚀extra images needed--是否有额外的镜像要从仓库中拉取？(y/n)"
  read need_pull
  echo -e "\033[0m"
  if [ "$need_pull" != "y" ]; then
    echo "skip--已跳过"
  else
    local repo_name
    local repo_version
    read -p "🚩repo name--请输入镜像名称：" repo_name
    if [ -z "$repo_name" ]; then
      echo "exit--未输入，结束任务"
      return 1
    fi
    read -p "🚩repo version--请输入镜像版本（默认latest）：" repo_version
    if [ -z "$repo_version" ]; then
      echo "stay default--未输入，已默认为latest"
      repo_version="latest"
    fi
    echo "🚩pulling--准备拉取..."
    local docker_tag=$registry_url_no_http/$repo_name:$repo_version
    docker pull $docker_tag
    if [ $? -eq 0 ]; then
      echo "✅pull success--拉取成功！"
    else
      echo "❌pull fail--拉取失败！"
      return 1
    fi
    the_container_deployment $docker_tag $repo_name
  fi
}

the_container_deployment() {
  local docker_tag=$1
  local repo_name=$2
  echo -e "\033[33m🚀start now--现在启动？(y/n)"
  read need_deployment
  if [ "$need_deployment" != "y" ]; then
    echo "skip--已跳过"
  else
    the_docker_check_old_batch $repo_name
    echo -e "\033[33m"
    echo "container name--输入容器名称（可选）："
    read container_name
    echo "host port--请输入需要映射的主机端口（若有）："
    read host_port
    echo "container port--请输入需要映射的容器端口（若有）："
    read container_port
    echo "host port extra--请输入需要额外映射的主机端口（若有）："
    read host_port_extra
    echo "container port extra--请输入需要额外映射的容器端口（若有）："
    read container_port_extra
    echo "host directory--请输入需要挂载的主机目录（若有）："
    read host_dir
    echo "container directory--请输入需要挂载的容器目录（若有）："
    read container_dir
    echo "host directory extra--请输入需要额外挂载的主机目录（若有）："
    read host_dir_extra
    echo "container directory extra--请输入需要额外挂载的容器目录（若有）："
    read container_dir_extra
    echo "auto restart--是否需要自动启动？(--restart=always)? (y/n)"
    read need_auto_restart
    local params=""
    if [ -n "$container_name" ]; then
      params="$params --name $container_name"
    fi
    if [ -n "$host_port" ] && [ -n "$container_port" ]; then
      params="$params -p $host_port:$container_port"
    else
      echo "⚠️random ports--未映射端口，将随机分配"
      params="$params -P"
    fi
    if [ -n "$host_port_extra" ] && [ -n "$container_port_extra" ]; then
      params="$params -p $host_port_extra:$container_port_extra"
    fi
    if [ -n "$host_dir" ] && [ -n "$container_dir" ]; then
      params="$params -v $host_dir:$container_dir"
    fi
    if [ -n "$host_dir_extra" ] && [ -n "$container_dir_extra" ]; then
      params="$params -v $host_dir_extra:$container_dir_extra"
    fi
    if [ -z "$need_auto_restart" ]; then
      echo "⚠️stay default auto restart--已默认自动启动"
      need_auto_restart="y"
    fi
    if [ "$need_auto_restart" == "y" ]; then
      params="$params --restart=always"
    fi
    echo "🚀environment variable--是否需要设置环境变量？(y/n)"
    read need_env
    echo -e "\033[0m"
    if [ "$need_env" == "y" ]; then
      env_file=$HOME/my-docker-data/$container_name.env
      if [ ! -f "$env_file" ]; then
        echo "config file generating--配置文件$env_file不存在，将自动创建👇"
        if ! command -v nano &>/dev/null; then
          vi $env_file
        else
          nano $env_file
        fi
      else
        echo "reading config file--配置文件$env_file已存在，将自动打开👇"
        if ! command -v nano &>/dev/null; then
          vi $env_file
        else
          nano $env_file
        fi
      fi
      cat $env_file
      echo "confirm environment--将设置以上环境变量，确定？(y/n)"
      read need_env_confirm
      if [ "$need_env_confirm" == "y" ]; then
        params="$params --env-file $env_file"
      else
        echo "skip--已跳过"
        return
      fi
    fi
    echo "🚩starting container with the following params--正在启动容器...，参数为：$params $docker_tag"
    docker run -d $params $docker_tag
    echo -e "\033[32m"
    echo "✅deployed--容器部署完成"
    echo -e "\033[0m"
    docker ps | grep $docker_tag
    echo -e "\033[33m"
    # -m 1 只显示第一行(多的就不管了)
    echo "hint--运维提示："
    echo "1. read log params--容器启动后，可以通过 docker logs --details $(docker ps | grep -m 1 $docker_tag | awk '{print $1}') 查看日志"
    echo "2. shell params--容器启动后，可以通过 docker exec -it $(docker ps | grep -m 1 $docker_tag | awk '{print $1}') sh 进入容器，运行shell命令"
    echo -e "\033[0m"
  fi
}
