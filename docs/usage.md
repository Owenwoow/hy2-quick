# 详细使用说明

← 返回 [README](../README.md)

---

## 目录

- [证书方式](#证书方式)
- [命令行参数](#命令行参数)
- [更新脚本](#更新脚本)
- [端口跳跃](#端口跳跃)
- [文件位置](#文件位置)


## 证书方式

自定义安装时可选四种证书来源。

| 方式 | 适用场景 | 前提条件 |
|------|---------|---------|
| **ACME · HTTP-01**（推荐） | 有域名、80 端口可用 | 域名 A 记录指向本机；放行 `80/tcp` 且未被占用；**不可开启 Cloudflare 小黄云代理** |
| **ACME · Cloudflare DNS-01** | 80 端口不可用，或域名走 CDN 代理 | Cloudflare API Token（需 `Zone:DNS:Edit` 权限） |
| **已有证书文件** | 已用 acme.sh 等工具签发过证书 | `.crt` / `.key` 的绝对路径 |
| **自签证书** | 无域名时的兜底 | 无 |

### 自动续期

证书由 Hysteria 内置的 ACME 客户端申请并自动续期，存放于 `/var/lib/hysteria/acme`，不需要额外配置 cron。

HTTP-01 的续期同样走 80 端口，因此该端口需要**长期放行且不被占用**。如果服务器上还要跑 nginx 等占用 80 端口的服务，请改用 DNS-01 验证。

### 客户端不需要导入证书

Let's Encrypt 是公共受信任 CA，根证书已预装在各操作系统中，客户端用域名连接即可通过标准 TLS 校验。

只有**自签证书**才需要客户端跳过校验。脚本会在链接中附带 `pinSHA256` 证书指纹作为替代方案，但并非所有客户端都支持。

### 关于自签证书的兼容性

Xray-core 自 `v26.2.6` 起移除了用于跳过证书校验的 `allowInsecure`，并从 2026-08-01 起彻底停用（[v2rayN 官方说明](https://github.com/2dust/v2rayN/discussions/9460)）。基于 Xray 的客户端可能无法连接自签节点。

需要良好兼容性时，请使用 ACME 申请受信任证书。

> 配置字段细节参见 Hysteria 官方文档：[ACME 配置](https://v2.hysteria.network/zh/docs/advanced/Full-Server-Config/) · [ACME DNS 验证](https://v2.hysteria.network/zh/docs/advanced/ACME-DNS-Config/)


## 命令行参数

```bash
hy2 --help
```

### 动作

省略则进入交互菜单。

| 参数 | 说明 |
|------|------|
| `--quick` / `--fast` | 快速安装（自签证书，全自动无交互） |
| `--link` / `--info` | 输出客户端订阅链接 |
| `--clean` | 清理 iptables 端口跳跃规则 |
| `--update` / `--upgrade` | 拉取最新脚本并覆盖 `/usr/local/bin/hy2` |
| `--remove` / `--uninstall` | 卸载并清理环境 |
| `-h` / `--help` | 显示帮助 |

### 证书选项

配合 `--quick` 使用。不指定域名时默认自签。

| 参数 | 说明 |
|------|------|
| `-d`, `--domain <域名>` | 指定域名后改用 ACME HTTP-01 申请受信任证书 |
| `-e`, `--email <邮箱>` | ACME 联系邮箱，默认 `admin@<域名>` |
| `--cf-token <Token>` | Cloudflare API Token，改用 DNS-01 验证 |
| `--ca <letsencrypt\|zerossl>` | 证书颁发机构，默认 `letsencrypt` |
| `--self-signed` | 强制使用自签证书 |

### 其他选项

配合 `--quick` 使用。

| 参数 | 说明 |
|------|------|
| `-p`, `--port <端口>` | 监听端口，默认 `443` |
| `-k`, `--password <密码>` | 连接密码，默认随机 20 位 |
| `-m`, `--mport <范围\|off>` | 端口跳跃范围，默认 `20000-20100`，`off` 关闭 |
| `--masquerade <URL>` | 伪装网站，默认 `https://www.bing.com` |
| `-n`, `--name <节点名>` | 节点名称，默认随机生成 |

### 示例

申请受信任证书，全自动无交互：

```bash
hy2 --quick -d hy2.example.com -e me@example.com
```

用 Cloudflare DNS 验证，无需放行 80 端口：

```bash
hy2 --quick -d hy2.example.com --cf-token cf_xxx
```

自定义端口与跳跃范围：

```bash
hy2 --quick -d hy2.example.com -p 8443 -m 30000-31000
```


## 更新脚本

菜单选 `5`，或：

```bash
hy2 --update
```

流程：从 GitHub 拉取最新版本 → 校验是有效的 bash 脚本 → 显示版本对比 → 覆盖 `/usr/local/bin/hy2` → 可选立即以新版本重新载入。

**更新只替换脚本本身，不影响已部署的服务端配置与证书**，不需要重新部署节点。

若下载到的内容不是有效脚本（例如遇到网络劫持或 404 页面），会拒绝覆盖并保留原有版本。


## 端口跳跃

启用后脚本会写入一条 iptables NAT 规则，把指定 UDP 范围重定向到主监听端口：

```
iptables -t nat -A PREROUTING -p udp --dport 20000:20100 -j REDIRECT --to-ports 443
```

规则通过 `netfilter-persistent` 持久化，重启后仍然有效。

**注意**：脚本只写 iptables，不会动云服务商的安全组。需要自行在厂商面板放行整个跳跃区间的 UDP 端口。

菜单选 `4` 可以查看当前规则并按行号删除。


## 文件位置

| 路径 | 说明 |
|------|------|
| `/etc/hysteria/config.yaml` | 服务端配置 |
| `/etc/hysteria/link.bak` | 客户端订阅链接 |
| `/var/lib/hysteria/acme/` | ACME 证书与账户密钥 |
| `/usr/local/bin/hy2` | 管理面板快捷命令 |
| `/etc/sysctl.d/99-hy2.conf` | UDP 缓冲区优化 |

卸载（菜单 `6` 或 `hy2 --remove`）会清理以上全部内容。
