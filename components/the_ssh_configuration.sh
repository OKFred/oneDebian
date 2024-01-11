#!/bin/bash
#@description: 用于SSH初始化
#@author: Fred Zhang Qi
#@datetime: 2023-12-24

#文件依赖
#none
sshd_file=/etc/ssh/sshd_config
original_sshd_file=/etc/ssh/sshd_config.bak
ssh_pub_key=$HOME/.ssh/id_rsa.pub
ssh_private_key=$HOME/.ssh/id_rsa

the_ssh_configuration() {
  the_config_backup
  echo -e "\033[33m 🚀need SSH--是否需要SSH？(y/n)"
  read need_ssh
  echo -e "\033[0m"
  if [ "$need_ssh" != "y" ]; then
    echo "skip--不需要SSH，跳过..."
    # apt remove ssh openssh-server -y
  else
    apt install ssh openssh-server -y
    the_root_login
    the_service_restart
  fi
}

the_config_backup() {
  if [ ! -f "$original_sshd_file" ]; then
    mv $sshd_file $original_sshd_file
    echo "has backup--已备份原有sshd_config -> sshd_config.bak"
  else
    echo "skip--备份文件已存在，跳过"
  fi
}

the_root_login() {
  echo -e "\033[33m 🚀SSH login by root--是否允许root用户远程登录？(y/n)"
  read need_root_login
  echo -e "\033[0m"
  if [ "$need_root_login" != "y" ]; then
    echo "skip--跳过..."
  else
    cp $original_sshd_file $sshd_file
    read -p "log in by key--通过密钥登录？(y/n)" need_key_login
    if [ "$need_key_login" == "y" ]; then
      sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/g' $sshd_file
      sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' $sshd_file
      the_key_init
    else
      read -p "log in by password--通过密码登录？(y/n)" need_password_login
      if [ "$need_password_login" == "y" ]; then
        sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' $sshd_file
      fi
    fi
    grep "PermitRootLogin" $sshd_file
  fi
}

the_key_init() {
  echo -e "\033[33m 🚀SSH key generate--是否需要初始化密钥？(y/n)"
  read need_key_init
  echo -e "\033[0m"
  if [ "$need_key_init" != "y" ]; then
    echo "skip--跳过..."
  elif [ ! -f $ssh_pub_key ]; then
    ssh-keygen -t rsa -P "" -f $ssh_private_key
    echo "generated--密钥已生成"
  else
    echo -e "\033[33m 🚀key file override--密钥已存在，是否覆盖？(y/n)"
    read need_key_cover
    echo -e "\033[0m"
    if [ "$need_key_cover" != "y" ]; then
      echo "skip--跳过..."
    else
      ssh-keygen -t rsa -P "" -f $ssh_private_key
      echo "key file generated--密钥已生成"
    fi
  fi
  if [ -f $ssh_pub_key ]; then
    check_permission
  fi
}

#检查文件夹和文件的权限
check_permission() {
  permission_dir_dot_ssh=$(stat -c %a $HOME/.ssh)
  permission_file_id_rsa=$(stat -c %a $HOME/.ssh/id_rsa)
  permission_file_id_rsa_pub=$(stat -c %a $HOME/.ssh/id_rsa.pub)
  if [ "$permission_dir_dot_ssh" != "700" ]; then
    chmod 700 $HOME/.ssh
  fi
  if [ "$permission_file_id_rsa" != "600" ]; then
    chmod 600 $HOME/.ssh/id_rsa
  fi
  if [ "$permission_file_id_rsa_pub" != "644" ]; then
    chmod 644 $HOME/.ssh/id_rsa.pub
  fi
}

the_service_restart() {
  echo -e "\033[33m 🚀SSH restart--是否需要重启SSH服务？(y/n)"
  read need_service_restart
  echo -e "\033[0m"
  if [ "$need_service_restart" != "y" ]; then
    echo "skip--跳过..."
  else
    service ssh restart
    echo "SSH restarted--服务已重启"
    echo "check--运行 systemctl status sshd.service 查看服务状态"
  fi
}
