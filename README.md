# Sing-box 全协议一键脚本 (SBA v2)

一个面向自用 VPS 的 sing-box 部署与管理脚本。v2 把节点配置收敛成一份 `nodes.json` 作为唯一数据源，`config.json` 每次由脚本重新生成，因此改端口、加节点、换证书都不会把家宽接管或 Argo 配置冲掉。

相比 v1 的三个变化：可安装的协议从 5 种扩到 **30 种**（sing-box 能对外提供的入站基本全覆盖）；家宽落地（ISP 模块）默认改成 **接管本机所有节点的全部流量**，按节点／按端口接管降级为高级选项；新增 **Argo (Cloudflare Tunnel)** 节点，无域名也能拿到一个走 CDN 的 443 入口。

## 环境要求

主流 Linux 发行版即可，推荐 Debian 12 / Ubuntu 22.04，Alpine、CentOS/RHEL 系也做了包管理适配。必须 root 运行（`sudo su -` 后再执行）。脚本会自行安装 `curl`、`jq`、`openssl`、`tar` 等依赖，并在需要时安装 sing-box 内核（默认 1.14.0 分支）与 `cloudflared`。

家宽或 CGNAT 线路下 GitHub 常常不通，可以先设置加速前缀再运行：

```bash
export GH_PROXY="https://你的加速前缀/"
```

## 安装与使用

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/JBl9527/singbox-all/main/install.sh)
```

装完之后任何时候用快捷命令进菜单：

```bash
sba
```

主菜单顶部会显示服务状态、内核版本、节点数量、家宽接管状态和 Argo 状态，功能项为：安装/重装（1）、节点管理（2）、Argo 隧道（3）、家宽流量接管（4）、证书管理（5）、服务管理与内核更新与 BBR（6）、Realm 端口转发（7）、更新脚本（8）、卸载（9）、一键自检（d）。

其中 4 和 7 会调用同目录的 `isp.sh` / `realm.sh`，本地没有这两个文件时自动从仓库拉取，所以单独下载 `install.sh` 也能用。

## 支持的协议

安装时的编号即下表顺序。直接回车＝全部 30 种；输入 `c` ＝精选常用 5 种（VLESS-REALITY、AnyTLS、Hysteria2、TUIC、VMess-WS-TLS）；也可以输入 `1 3 5`、`1-8`、`1,4-6` 这类组合只装其中几种。

| # | 协议 | 加密 | 传输 | 需要域名证书 |
|---|------|------|------|--------------|
| 1 | VLESS + REALITY + Vision | REALITY | TCP | 否 |
| 2 | VLESS + REALITY + gRPC | REALITY | gRPC | 否 |
| 3 | VLESS + TCP + TLS | TLS | TCP | 是 |
| 4 | VLESS + WS + TLS | TLS | WS | 是 |
| 5 | VLESS + gRPC + TLS | TLS | gRPC | 是 |
| 6 | VLESS + HTTPUpgrade + TLS | TLS | HTTPUpgrade | 是 |
| 7 | VLESS + WS 明文 | 无 | WS | 否（套 CDN 用） |
| 8 | VMess + REALITY | REALITY | TCP | 否 |
| 9 | VMess + TCP 明文 | 无 | TCP | 否 |
| 10 | VMess + TCP + TLS | TLS | TCP | 是 |
| 11 | VMess + WS 明文 | 无 | WS | 否（套 CDN 用） |
| 12 | VMess + WS + TLS | TLS | WS | 是 |
| 13 | VMess + gRPC + TLS | TLS | gRPC | 是 |
| 14 | Trojan + REALITY | REALITY | TCP | 否 |
| 15 | Trojan + TCP + TLS | TLS | TCP | 是 |
| 16 | Trojan + WS + TLS | TLS | WS | 是 |
| 17 | Trojan + gRPC + TLS | TLS | gRPC | 是 |
| 18 | AnyTLS | TLS | — | 是 |
| 19 | AnyTLS + REALITY | REALITY | — | 否 |
| 20 | Hysteria2（含端口跳跃） | TLS | QUIC | 是 |
| 21 | Hysteria v1 | TLS | QUIC | 是 |
| 22 | TUIC v5 | TLS | QUIC | 是 |
| 23 | ShadowTLS v3 + SS2022 | 无（外层伪装 TLS） | TCP | 否 |
| 24 | Shadowsocks 2022 | 无 | TCP/UDP | 否 |
| 25 | Shadowsocks aes-256-gcm | 无 | TCP/UDP | 否 |
| 26 | Snell v5 | 无 | TCP | 否 |
| 27 | NaiveProxy | TLS | HTTP/2 | 是（必须真实证书） |
| 28 | SOCKS5 | 无 | TCP | 否 |
| 29 | HTTP 代理 | 无 | TCP | 否 |
| 30 | Mixed (SOCKS5 + HTTP) | 无 | TCP | 否 |

“需要域名证书”为是的协议，如果没有域名也能装：脚本会退回 10 年期自签证书、SNI 用 `bing.com`，客户端勾选「跳过证书验证 / allowInsecure」即可，生成的分享链接里已经自动带上 `allowInsecure=1` / `insecure=1`。唯一例外是 NaiveProxy，它的客户端不接受自签证书。

注意 **Xray 26.x 起删除了 `allowInsecure`**，v2rayN 换用新内核后连自签证书的 TLS 节点会直接失败（真连接测试 -1），详见下面的[一键自检](#一键自检客户端连不上--真连接测试--1)。没有域名时最稳的选择是 REALITY 系节点。

## 安装流程

选完协议后依次是端口、证书、REALITY 目标站、凭据这几步，每一步都有推荐值可以直接回车带过。

端口有三种分配方式：全部随机（默认）、从某个起始端口连续分配、逐个手动输入。连续分配时脚本会跳过已被占用和已被其它节点用掉的端口。

证书三选一：临时自签（无域名可用）、acme.sh Standalone 申请（需域名解析到本机且 80 端口空闲）、Cloudflare DNS API 申请（不占 80 端口，支持 API Token 或 Global Key）。所选协议里没有 TLS 类时会自动跳过这一步。

REALITY 的 dest 默认 `addons.mozilla.org`，可以改成任何支持 TLS 1.3 + H2 的站点；密钥对由内核 `generate reality-keypair` 生成，short_id 随机。同类协议共用一套 UUID / 密码，所以客户端只需要记一组凭据。

选了 Hysteria2 时会额外问端口跳跃和混淆：跳跃填 `40000:41000` 这样的范围，脚本用 iptables / ip6tables 的 `REDIRECT` 规则把整段端口打到监听端口，规则写进 systemd 单元的 `ExecStartPost`，服务停止时自动清理；混淆用 salamander，密码随机生成并写进分享链接。

装完会打印每个节点的分享链接、Base64 聚合订阅，可以按编号显示二维码，同时把这些内容保存到 `/usr/local/etc/sing-box/links.txt`（权限 600）。

## 节点管理

菜单 2 里可以随时增删改节点：追加协议（同样支持多选）、改端口 / SNI / UUID 与密码 / WS 与 HTTPUpgrade 路径 / gRPC serviceName / Hysteria2 跳跃区间 / 备注、启停或删除单个节点、重置全局凭据、手动重新生成 `config.json` 并重启。每次改动都会先用 `sing-box check` 校验新配置，只有校验通过才会替换 `config.json`，重启后服务没起来则自动回滚上一份可用配置。

## Argo 隧道

菜单 3。脚本会建一个只监听 `127.0.0.1` 的 VMess + WS 后端节点（明文端口不对公网暴露），再由 cloudflared 把它接到 Cloudflare 边缘，客户端拿到的是标准的 VMess + WS + TLS / 443 链接，host 与 sni 为隧道域名，路径带 `?ed=2048` 早期数据。

两种模式：临时隧道不需要域名也不需要登录，用 `trycloudflare.com` 的随机域名，脚本从 cloudflared 日志里抓取域名，重启后域名会变；固定隧道用 Cloudflare 面板生成的 Tunnel Token 加自有域名，域名不变，适合长期用。

菜单里还能查看链接、重启隧道、看 cloudflared 日志、指定 CDN 优选 IP 或优选域名（填了之后链接的 `add` 用优选地址、`host`/`sni` 仍是隧道域名）。卸载 Argo 会同时删掉后端节点并重新生成配置。

## 一键自检（客户端连不上 / 真连接测试 -1）

主菜单输入 `d`。这是专门为「VPS 上自己测都是通的，但客户端显示 -1」准备的，一共七步：服务是否在跑、VPS 自己能不能访问测速地址（IPv4 与 IPv6 分开测）、每个节点端口是否真的在监听、端口跳跃的 nat 规则是否还在、系统防火墙类型、**外网能不能连进来**、家宽接管是否开着，最后**用 sing-box 自己当客户端从回环逐个真连一遍**每个节点并访问 `https://www.gstatic.com/generate_204`，输出「通 / 不通 / 跳过」。

第五步的「外网能不能连进来」是从外部视角补上的一环：脚本借 check-host.net 的海外探测点，按节点协议分别用 TCP / UDP 回连每个节点端口，逐个报「外网可达 / 外网进不来 / 无法判定」。同时它会判断本机是不是 **NAT / 端口映射机型**（网卡上是 `10.x`、`172.16-31.x`、`192.168.x`、`100.64-127.x` 这类内网地址，公网 IP 却不在本机）——这种小鸡只有服务商后台映射过的那几个端口能从外网进来，脚本随机分配的端口必然连不上，而且绝大多数服务商不映射 UDP，Hysteria2 / TUIC 这类 QUIC 节点根本没法用。安装时如果检测到是这种机型，分配端口之前就会提醒你改用手动填端口。不想联网探测可以用 `SBA_NO_EXTERNAL=1 sba` 关掉这一步。

这一步的意义是把责任分清：节点在服务端连通、端口从外网也进得来，问题就一定在客户端或本地网络；端口进不来就去安全组 / 服务商端口映射里解决；服务端就连不通，脚本会直接告诉你是服务没起来、端口没监听，还是家宽落地失效。自检末尾可以一键把所有节点端口放行到 ufw / firewalld / iptables，或重新应用一次配置。NaiveProxy 因为官方内核不含 cronet 无法自测，会显示为跳过。

真连接测试返回 -1 最常见的原因，按概率排：

1. **端口从外网进不来**。脚本只能改 VPS 系统内的防火墙，阿里云 / 腾讯云 / AWS / GCP 的安全组必须自己去控制台放行，且要同时放 **TCP 和 UDP**——Hysteria2、TUIC 走的是 UDP，只放 TCP 会一直 -1。NAT / 端口映射机型则要去服务商后台看分配给你的端口清单，用节点管理把端口改成清单里的端口。自检第五步会直接点出是哪几个端口进不来。
2. **自签证书 + 新版客户端内核**。TLS 类节点用自签证书时客户端必须跳过证书校验，而 **Xray 26.x 已经删除 `allowInsecure`**（改成了 `pinnedPeerCertSha256`），v2rayN 用新内核导入带 `allowInsecure=1` 的链接会在内核启动阶段就失败，表现同样是 -1。最省事的解决办法是改用 REALITY 节点（不需要证书），或者用真实域名申请证书；自检会打印本机证书的 SHA-256 指纹，需要固定内核时可以填进 `pinnedPeerCertSha256`。
3. **家宽接管开着但落地节点失效**。此时被接管节点的出站指向家宽，VPS 本机 curl 直连仍然正常，但这些节点全部 -1。自检第六步会拿落地出站真的走一次 `generate_204` 并打印经落地看到的出口 IP，落地挂了会直接报出来；也可以先在菜单 4 里关掉接管复测确认。
4. **落地节点用了 Xray 的 VLESS Encryption**。落地机如果是 Xray 侧的 `decryption: mlkem768x25519plus...` 入站，sing-box 出站没有 `encryption` 字段、根本不会协商，握手会**静默卡死**（TCP 连得上、没有任何日志），被接管的节点一律 -1。这种落地要么在落地机上换一个普通 VMess / VLESS+REALITY 入站给 VPS 用，要么把落地换成 sing-box。

另外，为了避免「VPS 有 IPv6 地址但 IPv6 路由是黑洞」这种情况把出站请求卡死（同样表现为客户端 -1、VPS 本机却看不出问题），生成的配置默认按 `prefer_ipv4` 解析域名。

## 家宽流量接管 (ISP 模块)


菜单 4（也可以单独运行 `isp.sh`）。用途是把 VPS 当入口、把真正的出网交给一台家宽机器，客户端看到的还是 VPS 的节点，落地 IP 变成家宽 IP。

落地节点参数有两种录入方式。推荐直接粘贴分享链接，支持 `vmess://`、`vless://`、`trojan://`、`ss://`（含 shadow-tls 插件的链式出站）、`hysteria2://` / `hy2://`、`hysteria://`、`tuic://`、`anytls://`、`socks://` / `socks5://`、`http://` / `https://`。手动填写则覆盖 SOCKS5、HTTP/HTTPS、Shadowsocks、Trojan、VMess、VLESS、Hysteria2、TUIC v5、AnyTLS、Snell 十种，其中 SOCKS5 是家宽机和指纹浏览器最常见的形式。

接管范围默认**全量**：所有节点的所有流量都走家宽，实现方式是把 `route.final` 指向落地出站。高级选项是按节点接管，只让选中的节点走家宽、其余保持直连；也可以输入端口，脚本会自动换算成对应节点的 tag（sing-box 1.14 的 `route.rules` 不支持直接写入站端口）。开启后可以切换范围而不用重新录入落地参数。

模块内还有状态查看（落地节点、接管范围、`config.json` 里是否真的生效）、连通性测试（探测落地端口、查出口 IP、看服务状态）和关闭接管。关闭时如果检测到 v2 的 `nodes.json` 就走正常的重新生成流程，老部署则直接在 `config.json` 上摘掉落地出站与相关规则、把 `final` 改回 `direct`，改动前会备份 `.bak_<时间戳>` 并在校验失败时回滚。

## 文件布局

| 路径 | 作用 |
|------|------|
| `/usr/local/etc/sing-box/nodes.json` | 唯一数据源：证书方式、REALITY 密钥、全局凭据、所有节点 |
| `/usr/local/etc/sing-box/isp.json` | 家宽接管配置（`mode` 为 `all` 或 `selective`、落地出站数组、目标节点） |
| `/usr/local/etc/sing-box/argo.json` | Argo 配置（模式、Token、域名、优选 IP、后端节点 tag / 端口 / 路径） |
| `/usr/local/etc/sing-box/config.json` | 由上面三份文件生成，**不要手改** |
| `/usr/local/etc/sing-box/links.txt` | 分享链接与 Base64 订阅 |
| `/usr/local/etc/sing-box/cert/` | 证书与私钥 |

想改任何参数都请走菜单，手改 `config.json` 会在下一次生成时被覆盖。

## 从 v1 升级

检测到旧的 `sba.conf` 时脚本会提示迁移，原有的端口、UUID、密码、AnyTLS padding、REALITY 密钥与 dest、证书方式都按原样搬进 `nodes.json`，节点 tag 沿用 v1 的 `reality-in`、`anytls-in`、`any-reality-in`、`hy2-in`、`tuic-in`，v1 通过「额外节点」加的节点变成 `reality-in-2`、`hy2-in-2` 之类。客户端已有的导入和原来的家宽规则都不需要动。

## 常用命令

```bash
systemctl status sing-box        # 运行状态
systemctl restart sing-box       # 重启
journalctl -u sing-box -f        # 实时日志
journalctl -u sba-argo -f        # Argo 日志
sing-box check -c /usr/local/etc/sing-box/config.json   # 手动校验配置
```

## 已知限制

sing-box 1.14 官方发布版不带 cronet 库，所以 NaiveProxy 只能做**入站**，不能作为家宽落地的出站；Snell 出站只实现到 v4（v5 的线路格式与 v4 相同，客户端 version 填 4 即可）；`route.rules` 没有 `inbound_port` 字段，按端口接管靠换算成节点 tag 实现；WireGuard 在 1.14 里属于 endpoint 而不是 outbound，因此没有放进落地协议列表；明文的 VLESS-WS / VMess-WS / VMess-TCP 只适合套在 CDN 或本机反代之后，不要直接暴露给公网使用。

