Sing-box 多协议一键部署脚本
本脚本旨在为纯净的 Linux VPS 提供一键安装、配置和管理 Sing-box 的完整解决方案。默认配置包含了目前主流且抗封锁能力较强的四种协议，并采用了高位端口以提升隐蔽性。

🚀 包含协议与默认端口
VLESS + REALITY (TCP): 34433

VLESS + AnyTLS (TCP): 44433

Hysteria2 (UDP): 54433

TUIC v5 (UDP): 54434

🛠️ 环境准备
系统要求：推荐使用纯净的 Debian 11/12 或 Ubuntu 20.04/22.04/24.04 系统。

权限要求：必须以 root 用户登录执行脚本。

域名准备 (可选)：如果计划申请 ACME 永久域名证书，请提前将你的域名解析到当前 VPS 的 IP，并确保 VPS 的 80 端口未被占用。

📦 快速安装
将本仓库的 install.sh 脚本在你的 VPS 上运行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/JBl9527/singbox-all/main/install.sh)
```




安装过程选项说明
在运行脚本时，系统会提示你选择证书模式：

模式 1 (临时自签证书)：自动生成有效期 10 年的证书。适合单纯想要使用 REALITY（因为 REALITY 本身不需要你的真实域名证书），或者懒得解析域名、愿意在客户端开启“跳过证书验证”的用户。

模式 2 (永久域名证书)：调用 acme.sh 自动为你解析的域名申请 Let's Encrypt 证书。适合标准 TLS、Hysteria2 和 TUIC 协议，能够提供最标准的加密连接。

⚙️ 客户端配置指南
安装完成后，脚本终端会打印出核心凭证（UUID、密码、公钥等）。在你的本地客户端（如 Sing-box、OpenClash、v2rayN 等）中配置时，请对照以下要点：

1. REALITY 节点
协议：VLESS

端口：34433

UUID：填入脚本生成的 UUID

Flow：xtls-rprx-vision

SNI / 目标域名：www.microsoft.com (脚本默认值，可在 config.json 中修改)

Public Key (公钥)：填入脚本生成的公钥

Short ID：填入脚本生成的 Short ID

2. AnyTLS 节点
协议：VLESS

端口：44433

UUID：填入脚本生成的 UUID

TLS：开启

跳过证书验证 (Insecure)：如果安装时选择模式1 (自签证书)，此处必须开启。若是模式2，则保持关闭并填入你的域名。

3. Hysteria2 节点
协议：Hysteria2

端口：54433

密码 (Password)：填入脚本生成的密码

SNI / 主机名：同 AnyTLS 逻辑。模式1填 bing.com，模式2填你的真实域名。

跳过证书验证 (Insecure)：如果安装时选择模式1，此处必须开启。

4. TUIC 节点
协议：TUIC (版本 v5)

端口：54434

UUID：填入脚本生成的 UUID

密码 (Password)：填入脚本生成的密码

ALPN：h3

跳过证书验证 (Insecure)：如果安装时选择模式1，此处必须开启。

🛡️ 防火墙与网络注意事项
如果你发现配置完全正确但无法连接，通常是服务商防火墙的问题。请确保：

云服务商后台：在阿里云、腾讯云、AWS 等控制台面板的“安全组/防火墙”策略中，放行对应的 TCP 和 UDP 高位端口。

VPS 系统防火墙：如果系统开启了 ufw，需要执行以下命令放行：

Bash
ufw allow 34433/tcp
ufw allow 44433/tcp
ufw allow 54433/udp
ufw allow 54434/udp
🔧 服务管理命令
脚本将 Sing-box 注册为了系统级服务，你可以使用标准的 systemctl 命令进行日常管理：

查看运行状态：systemctl status sing-box

启动服务：systemctl start sing-box

停止服务：systemctl stop sing-box

重启服务：systemctl restart sing-box

查看实时日志：journalctl -u sing-box -f

配置文件路径：/usr/local/etc/sing-box/config.json
