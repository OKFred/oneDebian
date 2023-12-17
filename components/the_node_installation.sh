#!/bin/bash
#@description:  安装nvm、NodeJS、npm：
#@author: Fred Zhang Qi
#@datetime: 2023-12-16

#dependencies--文件依赖
# none

the_node_installation() {
  echo -e "\033[33m🚀是否要安装 Node.js？(y/n)"
  read needNode
  echo -e "\033[0m"
  if [ "$needNode" != "y" ]; then
    echo "跳过 Node.js 的安装"
    rm -rf ~/.nvm
  else
    # 检查是否已经安装了 NVM
    echo "🚩正在安装 NVM..."
    if [ -f online_nvm_install.sh ]; then
      bash online_nvm_install.sh
    else
      echo "⏬正在下载nvm"
      wget -qO- online_nvm_install.sh https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
    fi
    export NVM_DIR="$HOME/.nvm" # 这里手动启用 NVM
    [ -s "$NVM_DIR/nvm.sh" ] && export NVM_DIR="$HOME/.nvm" && \. "$NVM_DIR/nvm.sh"

    echo -e "\033[33m🚀请输入需要的版本（默认18）"
    read node_version
    echo -e "\033[0m"

    # 如果用户输入为空，则设置默认版本为 18
    if [ -z "$node_version" ]; then
      node_version="18"
    fi

    echo "🚩正在安装 Node.js。版本v$node_version"
    nvm install "$node_version"
    echo "✅安装完成！"
    echo "Node.js 版本："
    node -v
    echo "npm 版本："
    npm -v
  fi
}
