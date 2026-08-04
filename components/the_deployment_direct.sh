#!/bin/bash
#@description:  项目初始化：
#@author: Fred
#@datetime: 2023-12-20

#dependencies--文件依赖
# none

current_dir=$(pwd) # 获取当前工作目录的绝对路径
current_folder=$(basename "$PWD")
parent_dir=$(dirname "$current_dir")    # 获取当前工作目录的父目录路径
parent_folder=$(basename "$parent_dir") # 获取父目录的名称
project_name=$(whoami)_nodejs_$parent_folder

the_deployment_direct() {
  if ! command -v npm &>/dev/null; then
    echo "prerequisites--请先安装nodejs、npm等"
    return 1
  else
    echo -e "\033[33m🚀init project--是否需要启动项目？(y/n)"
    read need_start_project
    echo -e "\033[0m"
    if [ "$need_start_project" != "y" ]; then
      echo "skip--项目未启动"
    else
      echo "🚩starting project--正在启动项目..."
      the_entrypoint_initialization
      if [ $? -ne 0 ]; then
        echo "❌start fail--启动失败！"
        return 1
      fi
      the_service_registration
      echo "✅start success--启动完成！"
    fi
  fi
}

the_entrypoint_initialization() {
  if [ ! -f "$parent_dir/package.json" ]; then
    echo "config file missing--配置文件package.json不存在！"
    return 1
  fi
  echo "#!/bin/bash
#@description:  node项目启动脚本
#@datetime: $(date +%Y-%m-%d)

#dependencies--文件依赖
#-- package.json

#启动项目
date
cd $parent_dir
npm install
npm run build" >$parent_dir/_app.sh
  chmod +x $parent_dir/_app.sh
}

the_service_registration() {
  echo "#datetime: $(date +%Y-%m-%d)
    [Unit]
    Description=$project_name@守护脚本
    After=default.target

    [Service]
    ExecStart=$parent_dir/_app.sh

    [Install]
    WantedBy=default.target
  " >$project_name.service
  mv $project_name.service /etc/systemd/system/$project_name.service
  if [ -f "/etc/systemd/system/$project_name.service" ]; then
    echo "✅service registered--服务注册成功！"
  else
    echo "❌service unable to register--服务注册失败！"
    return 1
  fi
  systemctl daemon-reload
  systemctl restart $project_name

  echo -e "\033[33m🚀start on boot--是否需要设置开机自启？(y/n)"
  read need_start_on_boot
  echo -e "\033[0m"
  if [ "$need_start_on_boot" != "y" ]; then
    systemctl disable $project_name
    echo "❌skip--已取消开机自启"
  else
    systemctl enable $project_name
    echo "✅enable start on boot--已设置开机自启"
  fi
  echo "status check--登录cockpit查看运行情况，或运行：systemctl status $project_name"
}
