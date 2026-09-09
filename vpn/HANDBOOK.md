# 运维速查手册

三个月后回来看这一份就够。架构和原理见 [README.md](README.md)，这里只讲**怎么操作**。

术语：**中转** = 你有 root 的两台 VPS，跑 sing-box；**落地** = 买来的第三方 SOCKS5/HTTP 代理。

---

## 0. 记住这几件事

| | |
|---|---|
| 出订阅永远在**同一台**中转上跑 | 换一台 = 换链接，客户端要重新添加 |
| 所有凭据都在中转的 `/root/vpn-out/credentials.env` | 丢了就得重新生成并重导客户端 |
| 订阅链接存在 `/var/lib/clash-sub/.sub-meta` | 只要这文件在，重跑多少次链接都不变 |
| 节点能不能用 ≠ 订阅链接活着 | 链接过期不影响已导入的节点，一直能用 |

## 1. 登录

```bash
ssh root@<中转1IP>          # 或 <中转2IP>
hostname -I                 # 不确定在哪台时确认
exit                        # 退回自己电脑
```

## 2. 日常操作

### 看状态

```bash
systemctl status sing-box              # 服务在不在
journalctl -u sing-box -f              # 实时日志（Ctrl+C 退出）
ss -tnlp | grep sing-box               # 监听了哪些端口
cat /root/vpn-out/credentials.env      # 所有凭据和端口
cat /var/lib/clash-sub/.sub-meta       # 订阅链接的端口和 token
```

### 出订阅 / 更新客户端配置

```bash
cd ~/claude/vpn
R2=<另一台中转IP> bash relay/serve-sub.sh
```

打印出 `http://...yaml` 后：Clash Verge 里在已有订阅上点 **↻**（别新建）。导完关掉：

```bash
systemctl stop clash-sub
```

选项：`TTL=7200` 存活 2 小时 · `KEEP=1` 常驻不关 · `NEW_TOKEN=1` 换一条全新链接
· `QR=0` 不打二维码 · `R1_LABEL=香港 L1_LABEL=美西 ...` 自定义节点名

### 改配置后重新部署（不动凭据）

两台中转上都跑，命令一样：

```bash
cd ~/claude/vpn && git pull
set -a; . /root/vpn-out/credentials.env; set +a
bash relay/install.sh
```

`set -a` 那行把已有的 UUID / 密钥 / 落地账号全导入环境，所以**凭据不变、客户端不用重导**。

### 重启 / 排队

```bash
systemctl restart sing-box
systemctl stop clash-sub          # 只关订阅服务，不影响节点
```

## 3. 验证

**在自己电脑上**（不连服务器）：

```bash
curl -s https://api.ipify.org; echo                      # 出口 IP，应等于节点名里那个
curl -s https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc)='
curl -s -o /dev/null -w '%{http_code}\n' <订阅链接>       # 200=服务开着 000=已关
```

**在中转上**：

```bash
# 落地代理还活着吗（IP/端口/账号密码从 credentials.env 里的 LANDING1_SPEC 取）
curl --max-time 15 -x 'socks5h://用户:密码@落地IP:端口' https://api.ipify.org
```

## 4. 排错

| 症状 | 原因 / 处理 |
|---|---|
| Clash 里节点全部超时 | 按链路排：`nc -vz <中转IP> 443` → 中转上 curl 测落地 → `systemctl status sing-box` |
| 只有部分节点超时 | 那条对应的落地挂了或流量用完，换节点；或中转某端口没放行 |
| 能连上但立刻断 | Reality 参数没对上。核对客户端的 uuid / public-key / short-id / servername 与 `credentials.env` 是否逐字一致 |
| 4 个节点只有 2 个能连 | 两台中转的凭据不一致。在坏的那台上用 §2「改配置后重新部署」重跑 |
| 订阅导入报「无效的订阅链接」 | 粘的是 `clash://`。那个框只收 `http://` 开头的 |
| 点更新拉取失败 | 订阅服务已停，先在中转上重跑 `serve-sub.sh`（链接不变），再点更新 |
| 国内网站慢 | geo 数据没下下来。Clash Verge → 设置 → 检查更新 GeoData |
| 开 TUN 后其他 VPN/虚拟机坏了 | `strict-route` 保持 false；再不行把 `tun.stack` 从 `gvisor` 换成 `system` |
| `sing-box check` 不过 | 看报错行号，多半是落地账号密码里有特殊字符；`DEST` 必须是纯域名，不能带 `https://` 或 markdown 链接格式 |

服务起不来时先看日志，别猜：

```bash
journalctl -u sing-box -n 50 --no-pager
```

## 5. 从零重建

服务器重装了、或者换了新机器：

```bash
# ① 每台中转上
apt update && apt install -y git
git clone -b <分支名> <仓库地址>
cd claude/vpn

# ② 第一台（会生成全新凭据，并打印第二台要跑的命令）
LANDING1='落地1IP:端口:用户名:密码' LANDING2='落地2IP:端口:用户名:密码' bash relay/install.sh

# ③ 第二台：粘贴第一台打印出来的那条命令（带同一套凭据）

# ④ 回第一台出订阅
R2=<第二台IP> bash relay/serve-sub.sh

# ⑤ Clash Verge 导入，装「服务模式」，开 Tun Mode
```

换落地代理（IP 或密码变了）时，凭据不用换：

```bash
set -a; . /root/vpn-out/credentials.env; set +a
LANDING1='新的IP:端口:用户名:密码' LANDING2='...' bash relay/install.sh
```

客户端完全不用动（除非出口 IP 变了想改节点名）。

## 6. 端口分配

每台中转都监听三个端口，**一个端口 = 一个出口**：

| 端口 | 出口 |
|---|---|
| 2053 | 中转机自己（直出） |
| 443 | 落地1 |
| 8443 | 落地2 |

两台中转 × 三个端口 = 6 种组合都是通的。客户端默认只配了 4 个节点
（两台各自直出 + 各自转一个落地），想要全部 6 个就在配置里照着加。

## 7. 安全

- **别把真实凭据提交进仓库**。仓库是公开的，`.gitignore` 已排除
  `credentials.env` / `my-vpn.yaml`，别用 `git add -f` 绕过。
- 订阅链接里有节点凭据，**只发给自己的设备**。给了别人 = 节点随便用。
- 中转到落地那一段是**裸 SOCKS5/HTTP，不加密**，落地代理商能看到全部流量元数据。
  别用这条链路登网银、公司内网。
- 定期换掉 VPS 的 root 密码，改用 SSH 密钥：
  ```bash
  passwd
  # 然后 /etc/ssh/sshd_config 里设 PasswordAuthentication no
  systemctl restart sshd
  ```
- 怀疑订阅链接泄露：`NEW_TOKEN=1 bash relay/serve-sub.sh` 换一条，旧的立刻作废。
- 怀疑节点凭据泄露：两台中转都重跑 `install.sh`，第一台**不带**凭据参数
  （让它重新生成），第二台粘它打印的命令，然后客户端重导订阅。
