Sing-box 全能一键安装脚本使用说明
本项目提供了一个便捷的 Sing-box 一键安装与管理脚本，旨在帮助用户在 Linux 服务器上快速部署、配置和管理 Sing-box 代理服务。

⚙️ 系统与环境要求
支持的操作系统：主流 Linux 发行版（推荐使用 Debian 11/12 或 Ubuntu 20.04/22.04）。

权限要求：必须使用 root 用户执行此脚本。如果你使用的是普通用户，请先执行 sudo su - 切换到 root，或在命令前加上 sudo。

网络环境：一台拥有纯净系统的 VPS（虚拟专用服务器）。

🚀 一键安装命令
请通过 SSH 连接到你的服务器，然后复制并运行以下命令中的任意一条：

选项 1：国际网络直连（适用于海外 VPS）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/JBl9527/singbox-all/main/install.sh)
```


安装后快捷命令：

```bash
sba
```

执行命令：复制上方的“一键安装命令”并回车执行。

交互式菜单：脚本运行后会弹出交互式中文菜单。只需根据屏幕上的提示，输入对应的数字（如：1 为安装，2 为更新，3 为卸载等），然后回车即可完成自动化配置。

配置客户端：安装完成后，脚本通常会输出你的节点连接信息或订阅链接。请妥善保存，并将其导入到你的 Sing-box、v2rayN、Clash 等客户端中。

🛠️ 常用管理指令 (供参考)
(注：以下为标准 systemd 守护进程服务的常用命令。如果你在脚本中自定义了快捷指令，请按你的实际情况修改此处)

查看运行状态：

```bash
systemctl status sing-box
```
启动服务：


```bash
systemctl start sing-box
```
停止服务：

```bash
systemctl stop sing-box
```
重启服务：

```bash
systemctl restart sing-box

```
查看运行日志：

```bash
journalctl -u sing-box -f
```
