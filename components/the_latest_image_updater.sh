#!/bin/bash
# 脚本用于在 Debian Bookworm 上升级到最新版本的内核

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

  # 查找并安装最新的内核镜像和头文件包
  echo "Installing the latest kernel image and headers from backports..."
  KERNEL_IMAGE=$(apt-cache search linux-image | grep bookworm-backports | sort -V | tail -n 1 | awk '{print $1}')
  KERNEL_HEADERS=$(apt-cache search linux-headers | grep bookworm-backports | sort -V | tail -n 1 | awk '{print $1}')

  if [ -z "$KERNEL_IMAGE" ] || [ -z "$KERNEL_HEADERS" ]; then
    echo "No kernel updates found in backports. Exiting."
    exit 1
  fi

  sudo apt -t bookworm-backports install -y $KERNEL_IMAGE $KERNEL_HEADERS
  # 更新 GRUB 配置
  echo "Updating GRUB configuration..."
  sudo update-initramfs -u
  sudo update-grub

  # 提示用户重启系统
  echo "Kernel upgrade complete. Please reboot your system to use the new kernel."

}
