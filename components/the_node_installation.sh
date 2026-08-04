#!/bin/bash
#@description:  安装nvm、NodeJS、npm：
#@author: Fred
#@datetime: 2023-12-16

#dependencies--文件依赖
# none

the_node_installation() {
  echo -e "\033[33m🚀need node--是否要安装 Node.js？(y/n)"
  read needNode
  echo -e "\033[0m"
  if [ "$needNode" != "y" ]; then
    echo "skip--跳过 Node.js 的安装"
    # rm -rf ~/.nvm
  else
    echo "installing--尝试安装nodejs..."
    if apt search nodejs | grep ^nodejs/stable &>/dev/null; then
      apt install nodejs npm -y
    else
      echo "⏬downloading--正在下载nvm"
      wget -qO- online_nvm_install.sh https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
      export NVM_DIR="$HOME/.nvm" # 这里手动启用 NVM
      [ -s "$NVM_DIR/nvm.sh" ] && export NVM_DIR="$HOME/.nvm" && \. "$NVM_DIR/nvm.sh"

      echo -e "\033[33m🚀version--请输入需要的版本（默认18）"
      read node_version
      echo -e "\033[0m"

      # 如果用户输入为空，则设置默认版本为 18
      if [ -z "$node_version" ]; then
        node_version="18"
      fi
      echo "🚩installing--正在安装 Node.js。版本v$node_version"
      nvm install "$node_version"
    fi
    echo "✅install success--安装完成！"
    echo "version--Node.js 版本："
    node -v
    which node
    echo "version npm 版本："
    npm -v
    which npm
  fi
}
