# 中转 + 落地 双机代理（macOS / Clash Verge 全局 TUN）

自用的翻墙链路：本机 → 中转机 → 落地机 → 目标网站。

## 架构

```
  你的 Mac                中转机 A                 落地机 B              互联网
 ┌──────────┐          ┌────────────┐          ┌────────────┐
 │  Clash   │  VLESS   │  nftables  │   裸TCP   │  sing-box  │
 │  Verge   │─Reality─▶│    DNAT    │──转发───▶│ VLESS-in   │──直连──▶
 │ TUN 全局 │  加密     │  内核转发   │  (仍加密) │  解密出口   │
 └──────────┘          └────────────┘          └────────────┘
              └──────────── 端到端加密，中转机看不到明文 ─────────┘
   IP 归属:                 中转机 IP                落地机 IP ← 网站看到的是这个
```

关键点：**中转机只做内核态 TCP 转发，不解密、不参与握手**。TLS/Reality 握手在落地机终结，
所以加密是从你的 Mac 一路到落地机的端到端。中转机就是一根管子，CPU 占用几乎为零，
也不需要装任何代理软件。中转机被查/被抓包也拿不到任何明文。

- **中转机 A**：选线路好的（比如 HK/JP CN2 GIA、移动优化线路），负责把国内到境外这段跑顺。
- **落地机 B**：选出口 IP 好的（美国/日本原生 IP，能解锁流媒体的那种），线路可以差一点。

## 部署步骤

### 1. 落地机（先做这台）

```bash
git clone <本仓库> && cd vpn
# RELAY_IP 填中转机 IP，会自动把端口锁死只允许中转机访问
RELAY_IP=<中转机IP> bash landing/install.sh
```

脚本会：装 sing-box → 生成 UUID/Reality 密钥对/shortId → 写配置并校验 →
配 systemd 开机自启 → 开 BBR → 收紧防火墙 → 打印客户端需要的全部参数。

参数同时存在落地机的 `/root/vpn-out/credentials.env`。

可选变量：`PORT=443`、`DEST=www.yahoo.com`（Reality 伪装目标）、`SB_VERSION=1.11.15`。

> **DEST 怎么选**：要支持 TLS1.3 + HTTP/2、不在国内被墙、且最好和落地机地理位置接近。
> 脚本会自动验证，不合格会直接报错让你换。备选：`addons.mozilla.org`、
> `www.icloud.com`、`dl.google.com`、`www.lovelive-anime.jp`。

### 2. 中转机

```bash
LANDING_IP=<落地机IP> bash relay/install.sh
```

用 nftables DNAT + masquerade 做转发，写在独立的 `table ip relay` 里，
不会动你机器上已有的 iptables/nftables 规则。开机自启由 `relay-forward.service` 负责。

**如果中转机是 OpenVZ / 部分 LXC，内核不支持 NAT**，或者落地机只有域名没固定 IP，
改用用户态转发：

```bash
LANDING=<落地机IP或域名>:443 bash relay/realm-alternative.sh
```

### 3. Mac 客户端

把落地机的凭据拉下来，渲染出配置：

```bash
scp root@<落地机IP>:/root/vpn-out/credentials.env .
RELAY_IP=<中转机IP> bash client/render.sh credentials.env > ~/Desktop/my-vpn.yaml
```

然后在 Clash Verge Rev 里：

1. **配置** → 右上角 `+` → 选 **Local** → 导入 `my-vpn.yaml`
2. **设置** → **服务模式** → 安装（TUN 必须要这个，会要一次管理员密码）
3. **设置** → 打开 **Tun Mode**
4. 代理页面选中 `landing` 节点

> Clash Verge Rev 的 GUI TUN 设置会覆盖配置文件里的 `tun:` 段，所以以 GUI 开关为准。
> 配置里那段 `tun:` 是留给直接跑 mihomo 二进制的场景。

## 分流规则

配置里已经配好：

| 流量 | 走向 |
|---|---|
| 国内域名 / 国内 IP (`GEOSITE,cn` / `GEOIP,CN`) | 直连 |
| 局域网、私有地址 | 直连 |
| 中转机 IP 本身 | 直连（不加这条会成环） |
| 广告域名 | 拒绝 |
| YouTube / Netflix / Disney / Spotify | 「国外媒体」组，可单独切 |
| 其余境外流量 | 走代理 |

DNS 用 fake-ip：走代理的域名不在本地解析，域名直接传给落地机去解析。
这样既不会 DNS 泄露，流媒体的地区判断也跟着落地机 IP 走。国内域名用阿里/腾讯 DoH 解析。

## 验证

```bash
# 出口 IP 应该等于落地机 IP，不是中转机 IP
curl -s https://api.ipify.org; echo

# DNS 是否泄露
curl -s https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc)='
```

中转机上看转发是否在工作：

```bash
nft list table ip relay
conntrack -L 2>/dev/null | grep <落地机IP>
```

落地机上看服务和连接：

```bash
systemctl status sing-box
journalctl -u sing-box -f
ss -tnp | grep sing-box
```

## 排错

**连不上，Clash 显示超时**

按链路顺序一段一段排：

1. 中转机端口通不通：本机 `nc -vz <中转机IP> 443`
2. 中转机能不能到落地机：中转机上 `nc -vz <落地机IP> 443`
3. 落地机服务在不在：落地机上 `systemctl status sing-box`
4. 落地机防火墙有没有放行中转机 IP（脚本带 `RELAY_IP` 跑过就没问题）

**能连上但一直握手失败 / 立刻断开**

九成是 Reality 参数没对上。检查客户端的 `uuid` / `public-key` / `short-id` / `servername`
是不是和落地机 `/root/vpn-out/credentials.env` 完全一致。`short-id` 在 YAML 里要带引号，
不然纯数字开头的会被解析成数字。

**能上网但访问国内网站很慢**

分流没生效，八成是 geo 数据文件没下下来。Clash Verge：设置 → 检查更新 GeoData。

**Mac 开了 TUN 之后其他 VPN / 虚拟机网络坏了**

`strict-route` 保持 `false`（配置里已经是）。还有问题就把 `tun.stack` 从 `gvisor`
换成 `system`。

**换落地机**

只需在中转机重跑 `LANDING_IP=<新落地机IP> bash relay/install.sh`，客户端不用动
（客户端连的是中转机 IP）—— 但新落地机的 UUID / 密钥必须和旧的一致，否则还是得重新渲染配置。

## 安全提醒

- 落地机务必带 `RELAY_IP=` 跑安装脚本，把 443 锁死只允许中转机访问，减少被主动探测的面。
- `credentials.env` 和 `my-vpn.yaml` 里有私钥性质的凭据，**别提交到 git、别发群里**。
  仓库的 `.gitignore` 已经把它们排除了。
- 两台机器都建议关掉 root 密码登录，只留 SSH 密钥。
