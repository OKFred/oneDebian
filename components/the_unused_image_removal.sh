#!/bin/bash

# 获取当前运行的内核版本
the_unused_image_removal() {
  current_kernel=$(uname -r)
  echo "当前内核版本: $current_kernel"

  # 获取所有已安装的内核映像和头文件
  installed_kernels=$(dpkg --list | grep -E 'linux-image|linux-headers' | awk '{print $2}')
  echo "已安装的内核和头文件:"
  echo "$installed_kernels"

  # 标记为保留的内核和头文件
  keep_kernels=$(dpkg --list | grep "$current_kernel" | awk '{print $2}')
  echo "需要保留的内核和头文件: $keep_kernels"

  # 删除不再需要的内核映像和头文件
  for kernel in $installed_kernels; do
    if ! echo "$keep_kernels" | grep -q "$kernel"; then
      echo "删除: $kernel"
      sudo apt-get remove --purge -y "$kernel"
    else
      echo "保留: $kernel"
    fi
  done

  # 清理不再使用的包
  sudo apt-get autoremove -y

  # 更新GRUB配置
  sudo update-grub

  echo "所有操作完成。"
}
