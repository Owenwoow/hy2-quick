# 故障排查

← 返回 [README](../README.md)

---

## 先看日志

绝大多数问题都能在日志里看到直接原因：

```bash
journalctl -u hysteria-server.service -e --no-pager
```


## 证书申请失败

服务无法启动，日志里有 ACME 相关报错。按以下顺序排查：

**域名解析**

HTTP-01 验证要求域名解析到本机，且**不能开启 Cloudflare 代理（小黄云）**。确认解析结果：

```bash
dig +short A 你的域名
curl -4 -s https://api.ip.sb/ip
```

两者一致才能通过 HTTP-01。如果域名必须走 CDN，改用 Cloudflare DNS-01 验证。

**80 端口**

HTTP-01 需要独占 80/tcp。确认没被占用：

```bash
ss -ltnp | grep ':80 '
```

同时确认云服务商安全组已放行 80/tcp。

**Cloudflare API Token**

DNS-01 验证需要 Token 具备 `Zone:DNS:Edit` 权限。权限不足会在日志里报授权失败。

**速率限制**

同一域名短时间内申请过多会触发 Let's Encrypt 的速率限制，等待或改用 ZeroSSL：

```bash
hy2 --quick -d 你的域名 --ca zerossl
```


## 服务正常但客户端连不上

先在**服务器本地**自测，这一步能把问题切开：是服务端没跑通，还是网络 / 客户端的问题。

```bash
cat > /tmp/hy2-test.yaml <<'EOF'
server: 你的域名:443
auth: 你的密码
socks5:
  listen: 127.0.0.1:10808
EOF
hysteria client -c /tmp/hy2-test.yaml & sleep 6
curl -x socks5h://127.0.0.1:10808 --max-time 15 -sI https://www.cloudflare.com | head -1
```

返回 `HTTP/2 200` 说明服务端完全正常，问题在客户端或链路。

### 客户端内核

**Xray-core 不支持 Hysteria2 协议**。v2rayN 里的 hysteria2 节点必须靠 sing-box 内核运行：

- v2rayN 菜单 → 检查更新 → 确认 sing-box 内核已下载
- 确认 v2rayN 本体是较新版本，旧版对 hysteria2 URI 的解析不完整

### UDP 连通性

Hysteria 走 UDP。确认云服务商安全组放行了：

- 主监听端口的 UDP（默认 `443/udp`）
- 端口跳跃区间的 UDP（默认 `20000-20100/udp`）

也确认 VPS 内部没有防火墙拦截：

```bash
ufw status
iptables -L INPUT -n | head -20
```

### DNS 缓存

刚解析的域名，本地 DNS 可能还缓存着旧记录或解析失败的负缓存。表现是手机能连、电脑不能连，过几分钟自愈。

Windows 下可手动刷新：

```
ipconfig /flushdns
```

### 逐步简化 URI

如果怀疑是客户端解析问题，用最朴素的 URI 试：

```
hysteria2://密码@域名:443?sni=域名#test
```

能连通后再逐个加回 `mport` 等参数，可以定位到具体是哪个参数导致的。


## 脚本运行相关

**提示「检测到输入流已结束」**

说明用了管道方式运行。请改用进程替换：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Owenwoow/hy2-quick-install/main/install.sh)
```

或者用非交互的快速安装 `bash install.sh --quick`。

**想中途退回上一步**

任意输入处键入 `b` 即可返回上一级，不需要退出程序重来。

**端口被占用**

安装时提示 UDP 端口冲突，换一个端口，或先停掉占用进程：

```bash
ss -ulnp | grep ':443 '
```
