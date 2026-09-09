# 中转 + 落地代理链（macOS / Clash Verge 全局 TUN）

自用翻墙链路：本机 → 自己的中转 VPS → 第三方落地代理 → 目标网站。

## 架构

```
                       ┌──────────────────┐  socks5/http   ┌────────────┐
                  ┌───▶│ 中转1 :443 ──────┼───── 认证 ────▶│  落地1     │──▶
 ┌──────────┐     │    │       :8443 ─────┼──────────────▶ │  落地2     │──▶
 │  Mac     │     │    └──────────────────┘                └────────────┘
 │  Clash   │─────┤        sing-box                          第三方代理
 │  TUN 全局│     │    ┌──────────────────┐                  出口 IP 在这
 └──────────┘     └───▶│ 中转2 :443 ──────┼──────────────▶  ┘
      VLESS-Reality     │       :8443 ─────┼──────────────▶
        （加密）         └──────────────────┘
```

**落地是买来的第三方代理**（`IP:端口:用户名:密码` 格式的 SOCKS5/HTTP），
上面装不了东西，所以代理服务端只能跑在中转 VPS 上：

- **中转 VPS**：跑 sing-box，对外是 VLESS-Reality（抗封锁、抗主动探测），对内把流量
  用 SOCKS5/HTTP 认证转给落地代理。
- **一个端口对应一个落地**：中转的 `443` → 落地1，`8443` → 落地2。
  客户端切端口 = 切落地，不用登服务器改配置。
- **2 中转 × 2 落地 = 4 个节点**，在 Clash 里随便切，另有 url-test 自动选最快的。

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
4. 代理页面选 `PROXY` 组里的节点，或用「自动选择」

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

> 这条链接是明文 HTTP，里面有节点凭据。路径带 64 位随机 token、
> 路径不对一律 404、不开目录列表，猜是猜不到的；但链路上的人能看到。
> 用完就关是最稳的做法。托管在 GitHub raw 之类的公开地方则绝对不行——
> 等于把你的节点白送给所有人。

> Clash Verge Rev 的 GUI TUN 设置会覆盖配置文件里的 `tun:` 段，以 GUI 开关为准。

## 节点名

节点名自动拼成 **「中转IP前两段 → 落地出口IP」**，箭头右边就是网站实际看到的你的 IP：

```
38.150 → 72.13.245.7        走中转 38.150.32.52，从 72.13.245.7 出去
154.29 → 198.65.46.163      走中转 154.29.155.128，从 198.65.46.163 出去
```

出口 IP 由 `install.sh` 探测后写进 `credentials.env`，不用手填。

想换成自己看得懂的名字（比如按地区），渲染前设这四个变量：

```bash
R1_LABEL=香港 R2_LABEL=日本 L1_LABEL=美西 L2_LABEL=美东 \
  R2=<中转2IP> bash client/render.sh credentials.env > my-vpn.yaml
```

在中转机上用 `serve-sub.sh` 出订阅时同理，把变量加在命令前面即可。

## 分流规则

| 流量 | 走向 |
|---|---|
| 国内域名 / 国内 IP | 直连 |
| 局域网、私有地址 | 直连 |
| 两台中转机 IP 本身 | 直连（不加会成环） |
| 广告域名 | 拒绝 |
| YouTube / Netflix / Disney / Spotify | 「国外媒体」组，可单独挑落地 |
| 其余境外流量 | PROXY 组 |

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
