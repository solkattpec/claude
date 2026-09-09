# 中转 + 落地代理链（macOS / Clash Verge 全局 TUN）

自用翻墙链路：本机 → 自己的中转 VPS → 第三方落地代理 → 目标网站。

## 架构

```
                  ┌──────────────────────┐
             ┌───▶│ 中转1 :2053 ─────────┼──▶ 直接出网（出口 = 中转1 IP）
             │    │       :443  ─socks5──┼──▶ 落地1（出口 = 落地1 IP）
 ┌─────────┐ │    │       :8443 ─socks5──┼──▶ 落地2
 │  Mac    │─┤    └──────────────────────┘
 │  Clash  │ │    ┌──────────────────────┐
 │ TUN 全局│ └───▶│ 中转2 :2053 ─────────┼──▶ 直接出网（出口 = 中转2 IP）
 └─────────┘      │       :443  ─socks5──┼──▶ 落地1
   VLESS-Reality  │       :8443 ─socks5──┼──▶ 落地2
     （加密）      └──────────────────────┘
```

**落地是买来的第三方代理**（`IP:端口:用户名:密码` 格式的 SOCKS5/HTTP），
上面装不了东西，所以代理服务端只能跑在中转 VPS 上：

- **中转 VPS**：跑 sing-box，对外是 VLESS-Reality（抗封锁、抗主动探测）。
- **一个端口对应一个出口**：`2053` 直接从中转机出网，`443` 转给落地1，`8443` 转给落地2。
  客户端切端口 = 切出口，不用登服务器改配置。
- **默认给 4 个节点 = 4 个不同出口 IP**：两台中转各自直出，外加各自转一个落地。
  想要全部 6 种组合，在 `client/config.yaml` 里照着加节点即可。
- 落地代理的账号密码**只存在中转机上**，不进客户端配置。

### 加密边界（重要）

```
 Mac ══════ 加密 ══════ 中转VPS ────── 未加密 ────── 落地代理 ── 明文/HTTPS ── 网站
            Reality                  SOCKS5/HTTP
```

Mac 到中转这一段是 Reality 加密，翻墙要的就是这段。**中转到落地这段是裸的 SOCKS5/HTTP**，
协议本身不加密（HTTPS 网站内容仍有自身的 TLS 保护，但代理认证的用户名密码是明文传的）。
这是买来的落地代理的固有限制，不是配置问题。所以：

- 中转 VPS 上能看到你的明文流量（它要解密才能转发）——机器是你自己的，可接受。
- 落地代理商能看到你的全部流量元数据。**别用它登网银、公司内网这类敏感场景**。

## 部署

### 1. 第一台中转

```bash
git clone <本仓库> && cd vpn
LANDING1='落地1IP:端口:用户名:密码' \
LANDING2='落地2IP:端口:用户名:密码' \
bash relay/install.sh
```

脚本会：**自动探测落地代理是 SOCKS5 还是 HTTP**（两种都试，顺便打印真实出口 IP）→
校验 Reality 伪装域名支持 TLS1.3+h2 → 装 sing-box → 生成 UUID/密钥对/shortId →
写配置并用 `sing-box check` 校验 → 配 systemd 开机自启 → 开 BBR → 放行端口 →
打印客户端要的全部参数。

参数同时存在 `/root/vpn-out/credentials.env`。

可选变量：`PORT1=443`、`PORT2=8443`、`DEST=www.yahoo.com`、`SB_VERSION=1.11.15`。

> **DEST 怎么选**：要支持 TLS1.3 + HTTP/2、国内没被墙、最好和中转机地理位置接近。
> 脚本会自动验证，不合格直接报错。备选：`addons.mozilla.org`、`www.icloud.com`、`dl.google.com`。

### 2. 第二台中转

第一台跑完会直接打印第二台的完整命令（带上同一套 UUID/密钥），复制粘贴执行即可。
两台共用凭据，客户端配置里 4 个节点才能只差一个 IP。

### 3. Mac 客户端

```bash
scp root@<中转1IP>:/root/vpn-out/credentials.env .
R2=<中转2IP> bash client/render.sh credentials.env > ~/Desktop/my-vpn.yaml
```

Clash Verge Rev 里：

1. **配置** → 右上角 `+` → **Local** → 导入 `my-vpn.yaml`
2. **设置** → **服务模式** → 安装（TUN 必需，要一次管理员密码）
3. **设置** → 打开 **Tun Mode**
4. 代理页面进 `PROXY` 组，挑一个节点

### 3'. 想要订阅链接而不是本地文件

不想 scp、想直接在 Clash Verge 里粘一条链接导入的话，让中转机自己把配置发出来。
**在【中转1】上**执行：

```bash
R2=<中转2的IP> bash relay/serve-sub.sh
```

会打印一条 `http://<中转1IP>:<随机端口>/<64位随机token>.yaml`，
以及一条 `clash://install-config?url=...` 一键导入链接。
Clash Verge：配置 → `+` → **Remote** → 粘贴。

链接**默认 30 分钟后自动失效**（导入一次就够了，不留长期暴露的入口）。
想让 Clash 能自动更新订阅就加 `KEEP=1`，代价是链接一直挂在公网上。
随时手动关：`systemctl stop clash-sub`；看谁取过：`journalctl -u clash-sub`。

**重跑本脚本链接不变**（端口和 token 存在 `/var/lib/clash-sub/.sub-meta`），
所以改完配置重跑一次，在 Clash Verge 里点该订阅的「更新」就能拿到新版本，
不用重新添加。想彻底换一条新链接：`NEW_TOKEN=1 bash relay/serve-sub.sh`。

### 链接失效 ≠ 订阅失效

链接过期**不影响已经导入的节点**：

| | 链接失效后 |
|---|---|
| 已导入的节点还能连吗 | 能，一直能。节点连的是中转机 IP:端口，跟订阅链接无关 |
| 配置会被清掉吗 | 不会。客户端保留最后一次成功下载的版本，更新失败也不动它 |
| 有什么变化 | 只有点「更新」会失败（连接被拒绝） |

临时链接**不会**下发 `Profile-Update-Interval`，客户端因此不会定时去拉一个
已经关掉的地址、天天报错。只有 `KEEP=1` 常驻模式才下发 24 小时自动更新。

> 这条链接是明文 HTTP，里面有节点凭据。路径带 64 位随机 token、
> 路径不对一律 404、不开目录列表，猜是猜不到的；但链路上的人能看到。
> 用完就关是最稳的做法。托管在 GitHub raw 之类的公开地方则绝对不行——
> 等于把你的节点白送给所有人。

### 分享给别的设备

同一条链接在任何设备上都能导入，脚本还会在终端里打一个**二维码**，
手机、平板直接扫就行（把终端窗口调大些才扫得到）。

支持 Clash 配置订阅的客户端：

| 平台 | 客户端 |
|---|---|
| macOS / Windows / Linux | Clash Verge Rev |
| Android | Clash Meta for Android、FlClash |
| iOS | Stash、Shadowrocket |

多台设备**共用同一份配置没问题**，同一个 UUID 可以同时连。

默认 30 分钟的存活时间给别的设备导可能不够，加长一点：

```bash
TTL=7200 R2=<另一台中转IP> bash relay/serve-sub.sh    # 2 小时
```

⚠️ 把这条链接发给别人 = 把你的节点给对方随便用，而且对方能看到落地代理的
出口 IP。只发给自己的设备。

> Clash Verge Rev 的 GUI TUN 设置会覆盖配置文件里的 `tun:` 段，以 GUI 开关为准。

## 节点名

节点名里写的**就是网站看到的你的出口 IP**：

```
直出 154.29.155.128       走中转1，直接从中转1 出网
直出 38.150.32.52         走中转2，直接从中转2 出网
154.29 → 72.13.245.7      走中转1，转给落地1，从 72.13.245.7 出网
38.150 → 198.65.46.163    走中转2，转给落地2，从 198.65.46.163 出网
```

落地的出口 IP 由 `install.sh` 探测后写进 `credentials.env`，不用手填。

想换成自己看得懂的名字（比如按地区），渲染前设这四个变量：

```bash
R1_LABEL=香港 R2_LABEL=日本 L1_LABEL=美西 L2_LABEL=美东 \
  R2=<另一台中转IP> bash relay/serve-sub.sh
```

## 分流规则

| 流量 | 走向 |
|---|---|
| 国内域名 / 国内 IP | 直连 |
| 局域网、私有地址 | 直连 |
| 两台中转机 IP 本身 | 直连（不加会成环） |
| 广告域名 | 拒绝 |
| 其余境外流量 | PROXY 组（在里面挑 4 个节点之一） |

DNS 用 fake-ip：走代理的域名不在本地解析，域名原样传给落地代理去解析。
既不 DNS 泄露，流媒体地区判断也跟着落地 IP 走。国内域名走阿里/腾讯 DoH。

## 验证

Mac 上：

```bash
# 出口 IP 应该等于「落地代理」的出口 IP（中转机脚本已经打印过），
# 不是中转机 IP，也不是你家宽带 IP
curl -s https://api.ipify.org; echo

# 切到 R1-L2 再跑一次，IP 应该变成落地2 的出口
curl -s https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc)='
```

中转机上：

```bash
systemctl status sing-box
journalctl -u sing-box -f          # 实时日志
ss -tnp | grep sing-box            # 看连接

# 单独验证落地代理还活着
curl --max-time 15 -x 'socks5h://用户:密码@落地IP:端口' https://api.ipify.org
```

## 排错

**Clash 里节点显示超时**

按链路一段段排：

1. Mac → 中转端口：`nc -vz <中转IP> 443`
2. 中转 → 落地：中转机上 `curl --max-time 15 -x 'socks5h://用户:密码@落地IP:端口' https://api.ipify.org`
3. 中转服务在不在：`systemctl status sing-box`

**能连上但立刻断开 / 握手失败**

九成是 Reality 参数没对上。核对客户端的 `uuid` / `public-key` / `short-id` / `servername`
是否和中转机 `/root/vpn-out/credentials.env` 完全一致。`short-id` 在 YAML 里必须带引号，
否则纯数字开头的会被当成数字解析。

两台中转如果没用同一套凭据，客户端 4 个节点只有 2 个能连——重跑第二台，
带上第一台输出的 `UUID=... PRIV_KEY=... PUB_KEY=... SHORT_ID=...`。

**节点能连、网页打不开**

多半是落地代理挂了或流量跑完了。中转机上用上面那条 curl 单独验证落地。
落地1 挂了就在 Clash 里切到 `R1-L2` / `R2-L2`。

**落地代理换了 IP 或密码**

在中转机上重跑 `relay/install.sh`，带新的 `LANDING1/LANDING2` 和旧的
`UUID/PRIV_KEY/PUB_KEY/SHORT_ID/DEST`，客户端完全不用动。

**国内网站慢**

分流没生效，一般是 geo 数据没下下来。Clash Verge → 设置 → 检查更新 GeoData。

**Mac 开 TUN 后其他 VPN / 虚拟机网络坏了**

`strict-route` 保持 `false`（配置里已是）。还不行就把 `tun.stack` 从 `gvisor` 换成 `system`。

## 安全

- **本仓库不含任何真实凭据**，全是占位符。`credentials.env`、`my-vpn.yaml`
  已在 `.gitignore` 里，别用 `git add -f` 强行加进来。
- 两台中转如果用的是同一个 root 密码，改掉，并换成 SSH 密钥登录、关掉密码登录：
  `PasswordAuthentication no` 写进 `/etc/ssh/sshd_config` 后 `systemctl restart sshd`。
- 落地代理商能看到你的全部流量元数据，敏感场景别走这条链路。
