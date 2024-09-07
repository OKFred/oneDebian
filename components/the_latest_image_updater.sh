#!/bin/bash
#@description: 用于在 Debian Bookworm 上升级到最新版本的内核
#@author: Fred Zhang Qi
#@datetime: 2024-05-19

the_latest_image_updater() {
  # 更新软件包列表
  echo "Updating package list..."
  sudo apt update

  # 添加 backports 源
  echo "Adding backports repository..."
  echo "deb http://deb.debian.org/debian bookworm-backports main contrib non-free" | sudo tee /etc/apt/sources.list.d/backports.list

  # 再次更新软件包列表以包含 backports 包
  echo "Updating package list with backports..."
  sudo apt update
  apt upgrade
  #查看安装的image版本，并安装headers
  
  # 更新 GRUB 配置
  echo "Updating GRUB configuration..."
  sudo update-initramfs -u
  sudo update-grub

  # 提示用户重启系统
  echo "Kernel upgrade complete. Please reboot your system to use the new kernel."

}
