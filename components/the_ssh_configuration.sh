#!/bin/bash
#@description: 用于SSH初始化
#@author: Fred Zhang Qi
#@datetime: 2023-12-24

#文件依赖
#none
sshd_file=/etc/ssh/sshd_config
original_sshd_file=/etc/ssh/sshd_config.bak
ssh_pub_key=/root/.ssh/id_rsa.pub
ssh_private_key=/root/.ssh/id_rsa

the_ssh_configuration() {
  the_config_backup
  echo -e "\033[33m 🚀SSH--是否需要SSH？(y/n)"
  read need_ssh
  echo -e "\033[0m"
  if [ "$need_ssh" != "y" ]; then
    echo "不需要SSH，跳过..."
    # apt remove ssh openssh-server -y
  else
    apt install ssh openssh-server -y
    the_root_login
  fi
}

the_config_backup() {
  if [ ! -f "$original_sshd_file" ]; then
    mv $sshd_file $original_sshd_file
    echo "已备份原有sshd_config -> sshd_config.bak"
  else
    echo "备份文件已存在，跳过"
  fi
}

the_root_login() {
  echo -e "\033[33m 🚀SSH--是否允许root用户远程登录？(y/n)"
  read need_root_login
  echo -e "\033[0m"
  if [ "$need_root_login" != "y" ]; then
    echo "跳过..."
  else
    read -p "允许密码登录？(y/n)" need_password_login
    read -p "允许密钥登录？(y/n)" need_key_login
    if [ "$need_password_login" == "y" ]; then
      cp $original_sshd_file $sshd_file
      sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/g' $sshd_file
      sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' $sshd_file
    elif [ "$need_key_login" == "y" ]; then
      cp $original_sshd_file $sshd_file
      sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' $sshd_file
      the_key_init
    else
      echo "跳过..."
    fi
  fi
}

the_key_init() {
  echo -e "\033[33m 🚀SSH--是否需要初始化密钥？(y/n)"
  read need_key_init
  echo -e "\033[0m"
  if [ "$need_key_init" != "y" ]; then
    echo "跳过..."
  elif [ ! -f $ssh_pub_key ]; then
    ssh-keygen -t rsa -P "" -f ~$ssh_private_key
    echo "密钥已生成"
  else
    echo "密钥已存在，跳过"
  fi
  if [ -f $ssh_pub_key ]; then
    check_permission
  fi
}

#检查文件夹和文件的权限
check_permission() {
  permission_dir_dot_ssh=$(stat -c %a /root/.ssh)
  permission_file_id_rsa=$(stat -c %a /root/.ssh/id_rsa)
  permission_file_id_rsa_pub=$(stat -c %a /root/.ssh/id_rsa.pub)
  if [ "$permission_dir_dot_ssh" != "700" ]; then
    chmod 700 /root/.ssh
  fi
  if [ "$permission_file_id_rsa" != "600" ]; then
    chmod 600 /root/.ssh/id_rsa
  fi
  if [ "$permission_file_id_rsa_pub" != "644" ]; then
    chmod 644 /root/.ssh/id_rsa.pub
  fi
}
