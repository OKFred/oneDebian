#!/bin/bash
#@description:  磁盘格式化&挂载：
#@author: Fred Zhang Qi
#@datetime: 2024-01-11

#dependencies--文件依赖
# none

the_disk_format_and_mount() {
  echo -e "\033[33m 🚀need disk tool--是否需要磁盘管理工具？(y/n)"
  read need_disk_tool
  echo -e "\033[0m"
  if [ "$need_disk_tool" != "y" ]; then
    echo "skip--不需要，跳过..."
  else
    lsblk
    echo "please select--请选择一个磁盘："
    local disk=$(the_disk_select)
    echo "your selection--您选择的磁盘是 $disk"
    the_disk_partition $disk
    the_disk_format $disk
    the_disk_mount $disk
  fi
}

the_disk_select() {
  local disks=$(lsblk -l -o NAME,TYPE | grep "disk" | awk '{print $1}')
  # 如果没有找到磁盘，则输出提示信息并退出脚本
  if [ -z "$disks" ]; then
    # echo "no disk available--未找到可用的磁盘。"
    exit 1
  fi
  # 提示用户选择磁盘
  select disk in $disks; do
    if [ -n "$disk" ]; then
      echo $disk
      # echo "your selection--您选择的磁盘是 $disk"
      break
      # else
      # echo "invalid selection--无效的选择，请重新选择。"
    fi
  done
}

the_disk_partition() {
  local disk=$1
  if (mount | grep "/dev/$disk"); then
    echo "disk mounted already--磁盘已经挂载，不能分区。请先卸载磁盘。"
    exit 1
  fi
  echo -e "\033[33m 🚀disk partition--是否需要分区？(y/n)"
  read need_disk_partition
  echo -e "\033[0m"
  if [ "$need_disk_partition" != "y" ]; then
    echo "skip--不需要，跳过..."
  else
    echo "commands--分区常用命令：p(打印分区表)、n(新建分区)、d(删除分区)、w(保存并退出)、q(不保存退出)"
    fdisk /dev/$disk
    #检查分区是否成功
    if (lsblk -l -o NAME,TYPE | grep "part" | grep "/dev/$disk"); then
      echo "partition failed--磁盘分区失败。"
      exit 1
    fi
    echo "partition success--磁盘分区完成。"
  fi
}

the_disk_format() {
  local disk=$1
  if (mount | grep "/dev/$disk"); then
    echo "disk mounted already--磁盘已经挂载，不能格式化。请先卸载磁盘。"
    exit 1
  fi
  echo -e "\033[33m 🚀disk format--是否需要格式化磁盘？(y/n)"
  read need_disk_format
  echo -e "\033[0m"
  if [ "$need_disk_format" != "y" ]; then
    echo "skip--不需要，跳过..."
  else
    echo "格式化常用命令：mkfs.ext4(格式化为ext4)、mkfs.xfs(格式化为xfs)"
    echo "格式化为ext4..."
    mkfs -t ext4 /dev/$disk
    #检查格式化是否成功
    if (lsblk -l -o NAME,FSTYPE | grep "/dev/$disk" | grep "ext4"); then
      echo "format failed--磁盘格式化失败。"
      exit 1
    fi
    echo "格式化完成。"
  fi
}

the_disk_mount() {
  local disk=$1
  if (mount | grep "/dev/$disk"); then
    echo "disk mounted already--磁盘已经挂载，不能再次挂载。"
    exit 1
  fi
  echo -e "\033[33m 🚀disk mount--是否需要挂载磁盘？(y/n)"
  read need_disk_mount
  echo -e "\033[0m"
  if [ "$need_disk_mount" != "y" ]; then
    echo "skip--不需要，跳过..."
  else
    echo -e "\033[33m 🚀mount path--自定义挂载路径（默认/mnt/$disk）："
    read mount_path
    echo -e "\033[0m"
    if [ -z "$mount_path" ]; then
      mount_path="/mnt/$disk"
    fi
    echo "mount path--挂载路径：$mount_path"
    mkdir -p $mount_path
    echo "mounting--挂载中..."
    mount /dev/$disk $mount_path
    #检查挂载是否成功
    if (mount | grep "/dev/$disk"); then
      echo "mount failed--磁盘挂载失败。"
      exit 1
    fi
    lsblk
    echo "mount success--磁盘挂载成功。"
  fi
}
