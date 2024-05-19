### @description: 用于 Ubuntu/Debian 服务器初始化

### @author: Fred Zhang Qi

### @datetime: 2023-12-16

## 运行方法

### 面向过程的方法

`cd $HOME && git clone https://github.com/OKFred/oneDebian`

`cd $HOME/oneDebian && git reset --hard HEAD && git pull && chmod +x menu.sh && ./menu.sh`

#### 菜单预览

1.  更换国内源
2.  安装基础工具 nano、wget、git 等
3.  配置 SSH
4.  安装 nvm、nodeJS 、npm 等
5.  安装 cockpit--方便运维
6.  安装 docker、dockerd、portainer 等
7.  部署项目
8.  磁盘分区、格式化、挂载
10. 更新到新版的linux镜像
11. 清理未使用的linux版本镜像
99.  关于
00. 退出
