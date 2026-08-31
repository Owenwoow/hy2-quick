# Hysteria 2 一键部署脚本

<div align="center">
  <img src="https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-blue" alt="OS Support">
  <img src="https://img.shields.io/badge/Hysteria-2.x-green" alt="Hysteria Version">
  <img src="https://img.shields.io/badge/Author-Owen__W-orange" alt="Author">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License">
</div>

> **项目地址**：[https://github.com/Owenwoow/hy2-quick-install](https://github.com/Owenwoow/hy2-quick-install)

简洁、稳定的 **Hysteria 2** 服务端一键部署工具。支持 ACME 自动申请受信任证书，安装后可用 `hy2` 命令随时呼出管理面板。


## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Owenwoow/hy2-quick-install/main/install.sh)
```

安装完成后，以后直接输入 `hy2` 即可再次打开管理面板。

> 请使用 `bash <(curl ...)` 形式，不要用 `curl ... | bash` —— 后者会占用标准输入，导致脚本无法交互。


## 系统要求

- `Debian 10+` / `Ubuntu 18.04+`，以 `root` 用户执行
- 服务商安全组放行 **UDP** 监听端口及端口跳跃区间
- 若使用 ACME 申请证书：需要一个**已解析到本机的域名**；HTTP 验证方式还需放行 **80/tcp**


## 选择哪种安装方式

| | 自定义安装 | 快速安装 |
|---|---|---|
| 证书 | ACME 受信任证书 / 已有证书 / 自签 | **自签证书** |
| 交互 | 逐项配置 | 全自动，零输入 |
| 客户端兼容性 | 好 | **有限** |
| 需要域名 | 是（自签除外） | 否 |

**推荐使用「自定义安装」并填写域名与邮箱申请 ACME 证书。**

快速安装使用自签证书，虽然一条命令即可装完，但客户端兼容性有限：Xray-core 自 `v26.2.6` 起移除了用于跳过证书校验的 `allowInsecure`，并从 **2026-08-01** 起彻底停用（[v2rayN 官方说明](https://github.com/2dust/v2rayN/discussions/9460)），**v2rayN 等基于 Xray 的客户端可能无法连接**。脚本会在链接中附带 `pinSHA256` 证书指纹作为替代方案，但并非所有客户端都支持。

给快速安装加上 `-d 域名` 即可改用 ACME 申请受信任证书：

```bash
hy2 --quick -d hy2.example.com
```


## 管理面板

```text
╭──────────────────────────────────────────────────────────╮
│ Hysteria 2 一键部署脚本                              v2.1 │
╰──────────────────────────────────────────────────────────╯

  当前状态      ● 运行中

  1  自定义安装    选择证书方式，逐项配置
  2  快速安装      自签证书，全自动无交互
  3  订阅链接      查看客户端连接 URI
  4  端口跳跃      查看 / 清理 iptables 规则
  5  更新脚本      从 GitHub 拉取最新版本
  6  卸载清理      移除服务与全部配置
  0  退出
```

**任意输入处键入 `b` 都会返回上一级**，不需要退出程序重来：在参数填写阶段退回上一个问题，在证书方式选择处退回主菜单。


## 更新脚本

菜单选 `5`，或直接：

```bash
hy2 --update
```

会从 GitHub 拉取最新版本，校验通过后覆盖 `/usr/local/bin/hy2`，并可选择立即以新版本重新载入。**更新只替换脚本本身，不影响已部署的服务端配置与证书**，无需重新部署节点。

若下载到的内容不是有效脚本（例如遇到网络劫持或 404 页面），会拒绝覆盖并保留原有版本。


## TLS 证书方式

自定义安装时可选四种证书来源：

| 方式 | 适用场景 | 前提条件 |
|------|---------|---------|
| **ACME · HTTP-01**（推荐） | 有域名、80 端口可用 | 域名 A 记录指向本机；放行 80/tcp 且未被占用；**不可开启 Cloudflare 小黄云代理** |
| **ACME · Cloudflare DNS-01** | 80 端口不可用，或域名走 CDN 代理 | Cloudflare API Token（需 `Zone:DNS:Edit` 权限） |
| **已有证书文件** | 已用 acme.sh 等工具签发过证书 | `.crt` / `.key` 的绝对路径 |
| **自签证书** | 无域名时的兜底 | 无 |

证书由 Hysteria 内置 ACME 客户端申请并**自动续期**，存放于 `/var/lib/hysteria/acme`，无需额外配置 cron。HTTP-01 的续期同样走 80 端口，请保持该端口长期放行。

**客户端不需要导入任何证书文件。** Let's Encrypt 是公共受信任 CA，根证书已预装在各操作系统中，客户端用域名连接即可通过标准 TLS 校验。只有自签证书才需要客户端跳过校验或固定指纹。

配置细节参见官方文档：[ACME 配置](https://v2.hysteria.network/zh/docs/advanced/Full-Server-Config/) · [ACME DNS 验证](https://v2.hysteria.network/zh/docs/advanced/ACME-DNS-Config/)


## 命令行参数

```bash
hy2 --help
```

**动作**

| 参数 | 说明 |
|------|------|
| `--quick` / `--fast` | 快速安装（自签证书，全自动无交互） |
| `--link` / `--info` | 输出客户端订阅链接 |
| `--clean` | 清理 iptables 端口跳跃规则 |
| `--update` / `--upgrade` | 拉取最新脚本并覆盖 `/usr/local/bin/hy2` |
| `--remove` / `--uninstall` | 卸载并清理环境 |
| `-h` / `--help` | 显示帮助 |

**证书选项**（配合 `--quick`；不指定域名时默认自签）

| 参数 | 说明 |
|------|------|
| `-d`, `--domain <域名>` | 指定域名后改用 ACME HTTP-01 申请受信任证书 |
| `-e`, `--email <邮箱>` | ACME 联系邮箱，默认 `admin@<域名>` |
| `--cf-token <Token>` | Cloudflare API Token，改用 DNS-01 验证 |
| `--ca <letsencrypt\|zerossl>` | 证书颁发机构，默认 `letsencrypt` |
| `--self-signed` | 强制使用自签证书 |

**其他选项**（配合 `--quick`）

| 参数 | 说明 |
|------|------|
| `-p`, `--port <端口>` | 监听端口，默认 `443` |
| `-k`, `--password <密码>` | 连接密码，默认随机 20 位 |
| `-m`, `--mport <范围\|off>` | 端口跳跃范围，默认 `20000-20100` |
| `--masquerade <URL>` | 伪装网站，默认 `https://www.bing.com` |
| `-n`, `--name <节点名>` | 节点名称，默认随机生成 |

**示例**

```bash
hy2 --quick -d hy2.example.com -e me@example.com
```

```bash
hy2 --quick -d hy2.example.com --cf-token cf_xxx -p 8443
```


## 故障排查

服务异常时先看日志：

```bash
journalctl -u hysteria-server.service -e --no-pager
```

**证书申请失败**

- 域名未解析到本机，或 Cloudflare 开启了代理（小黄云）—— HTTP-01 会失败，改用 DNS-01
- 80/tcp 未放行，或被 nginx / apache 占用
- Cloudflare API Token 权限不足（需 `Zone:DNS:Edit`）
- 触发 Let's Encrypt 速率限制，可改用 `--ca zerossl`

**服务正常但客户端连不上**

在服务器本地自测，可区分「服务端问题」还是「网络 / 客户端问题」：

```bash
cat > /tmp/hy2-test.yaml <<'EOF'
server: 你的域名:443
auth: 你的密码
socks5:
  listen: 127.0.0.1:10808
EOF
hysteria client -c /tmp/hy2-test.yaml & sleep 5
curl -x socks5h://127.0.0.1:10808 --max-time 15 -sI https://www.cloudflare.com | head -1
```

本地能通说明服务端正常，问题在客户端或链路：确认客户端内核支持 Hysteria2（**Xray-core 不支持**，v2rayN 需装 sing-box 内核）、云厂商安全组已放行 UDP、域名 DNS 缓存已刷新。


## 文件位置

| 路径 | 说明 |
|------|------|
| `/etc/hysteria/config.yaml` | 服务端配置 |
| `/etc/hysteria/link.bak` | 客户端订阅链接 |
| `/var/lib/hysteria/acme/` | ACME 证书与账户密钥 |
| `/usr/local/bin/hy2` | 管理面板快捷命令 |


## 鸣谢

- **[Hysteria](https://github.com/apernet/hysteria)** — Apernet 团队开发的高性能网络协议，本脚本的运行核心


## 免责声明

本项目仅供个人学习、技术研究及网络环境测试使用。使用前请了解并遵守所在国家和地区的法律法规及云服务商的使用条款。对于使用本脚本产生的任何风险、损失或不当行为，作者概不负责。**使用即表示您已阅读、理解并接受本声明。**


<div align="center">
  <sub>如果这个项目对你有帮助，欢迎点个 ⭐ Star</sub><br>
  <sub>Made with ❤️ by <b>Owen_W</b></sub>
</div>
