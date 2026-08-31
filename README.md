# Hysteria 2 一键部署脚本

<div align="center">
  <img src="https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-blue" alt="OS Support">
  <img src="https://img.shields.io/badge/Hysteria-2.x-green" alt="Hysteria Version">
  <img src="https://img.shields.io/badge/Author-Owen__W-orange" alt="Author">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License">
</div>

> **项目地址**: [https://github.com/Owenwoow/hy2-quick-install](https://github.com/Owenwoow/hy2-quick-install)

为您带来极为简洁、稳定且功能完善的 **Hysteria 2** 服务端一键自动化部署工具。

> **⚠️ 重要变更（证书策略升级）**
>
> 脚本已由**自签证书**切换为 **ACME 自动申请受信任证书**。
> 原因：Xray-core 自 `v26.2.6` 起移除了用于跳过证书校验的 `allowInsecure`，并于 **2026-08-01** 起彻底停用；
> 依赖 `insecure=1` 的自签节点在 v2rayN 等基于 Xray 的客户端上已无法连接。
> 参考：[v2rayN 官方说明](https://github.com/2dust/v2rayN/discussions/9460)
>
> 老版本部署的自签节点建议重新执行一次安装，改用 ACME 方式。


## ⚙️ 系统要求

- 操作系统：`Debian 10+` / `Ubuntu 18.04+`（暂不支持 CentOS 等红帽系系统）
- `root` 用户执行
- 确保服务商面板（安全组 / 防火墙）已放行对应的 **UDP** 端口及跳跃区间端口
- **一个已解析到本机的域名**（ACME 申请证书必需）
- 使用 HTTP-01 验证时，还需放行 **80/tcp** 且该端口未被 nginx/apache 等占用


## 🚀 安装指南

### 方法一：单行命令部署（推荐）

登录 VPS 后直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Owenwoow/hy2-quick-install/main/install.sh)
```

> 若提示 `curl` 不存在，请先执行 `apt update && apt install curl -y`

### 方法二：手动克隆仓库

```bash
git clone https://github.com/Owenwoow/hy2-quick-install.git
cd hy2-quick-install
chmod +x install.sh
bash install.sh
```


## 🛠️ 脚本操作菜单

执行脚本后将自动清屏并展示全屏 TUI 风格菜单（自适应终端宽度）：

```text
══════════════════════════════════════════════════════════════
  Hysteria 2 一键部署脚本  |  作者: Owen_W
  项目: https://github.com/Owenwoow/hy2-quick-install
══════════════════════════════════════════════════════════════

  1) 自定义安装
  2) 卸载/环境清理
  3) 清理端口跳跃规则
  4) 读取订阅链接
  5) 快速安装
  0) 退出脚本

══════════════════════════════════════════════════════════════
请输入选项 [0-5] (直接回车 = 默认 1):
```

| 选项 | 功能说明 |
|------|---------|
| `1` | **自定义安装**：安装依赖 → 选择证书方式 → 交互配置 → 启动服务 → 输出客户端 URI |
| `2` | 卸载并清理所有配置、证书、ACME 缓存、服务文件及 sysctl 优化 |
| `3` | 单独管理 iptables 端口跳跃规则（查看 / 按行号删除） |
| `4` | **读取订阅链接**：直接输出已保存的客户端 URI；若缓存不存在则自动从配置重新生成 |
| `5` | **快速安装**：除域名外全部使用默认值，适合极速部署环境 |
| `0` | 退出脚本 |


## 🔐 TLS 证书方式

自定义安装时会让你选择证书来源：

| 方式 | 适用场景 | 前提条件 |
|------|---------|---------|
| **1) ACME · HTTP-01**（推荐） | 有域名、80 端口可用 | 域名 A 记录指向本机；放行 80/tcp 且未被占用；**不可开启 Cloudflare 小黄云代理** |
| **2) ACME · Cloudflare DNS-01** | 80 端口不可用，或域名走 CDN 代理 | Cloudflare API Token（需 `Zone:DNS:Edit` 权限） |
| **3) 使用已有证书文件** | 已用 acme.sh 等工具签发过证书 | 提供 `.crt` / `.key` 的绝对路径 |
| **4) 自签证书** | **不推荐**，仅无域名时兜底 | 无 |

关于各方式的细节，可参考 Hysteria 2 官方文档的
[ACME 配置](https://v2.hysteria.network/zh/docs/advanced/Full-Server-Config/)
与 [ACME DNS 验证](https://v2.hysteria.network/zh/docs/advanced/ACME-DNS-Config/)。

**几点说明：**

- 证书由 Hysteria 内置 ACME 客户端自动申请与**自动续期**，无需额外配置 cron。
- 证书存放于 `/var/lib/hysteria/acme`，配置写在 `/etc/hysteria/config.yaml`。
- HTTP-01 的续期同样走 80 端口，请保持该端口**长期放行且不被占用**。
- 选择自签证书时，脚本会计算证书 SHA256 指纹并在 URI 中输出 `pinSHA256=...`
  （证书固定，Xray 官方推荐的 `allowInsecure` 替代方案），但部分客户端仍可能无法连接。


## 🔧 高级：命令行参数

脚本支持非交互式直接调用，方便配合自动化工具或脚本使用：

```bash
bash install.sh --help
```

**动作**

| 参数 | 说明 |
|------|------|
| `--quick` / `--fast` | 快速安装（除必要信息外全部使用默认值） |
| `--link` / `--info` | 输出已保存的客户端订阅链接 |
| `--clean` | 单独清理 iptables 端口跳跃规则 |
| `--remove` / `--uninstall` | 卸载并清理环境 |
| `-h` / `--help` | 显示帮助 |

**证书选项**（配合 `--quick`）

| 参数 | 说明 |
|------|------|
| `-d`, `--domain <域名>` | 申请证书用的域名，必须已解析到本机 |
| `-e`, `--email <邮箱>` | ACME 联系邮箱，默认 `admin@<域名>` |
| `--cf-token <Token>` | Cloudflare API Token，指定后改用 DNS-01 验证 |
| `--ca <letsencrypt\|zerossl>` | 证书颁发机构，默认 `letsencrypt` |
| `--self-signed` | 使用自签证书（不受信任，仅作兜底） |

**其他选项**（配合 `--quick`）

| 参数 | 说明 |
|------|------|
| `-p`, `--port <端口>` | 监听端口，默认 `443` |
| `-k`, `--password <密码>` | 连接密码，默认随机生成 20 位 |
| `-m`, `--mport <范围\|off>` | UDP 端口跳跃范围，默认 `20000-20100`，`off` 表示不启用 |
| `--masquerade <URL>` | 伪装网站，默认 `https://www.bing.com` |
| `-n`, `--name <节点名>` | 节点名称，默认随机生成 |

**示例**

```bash
# HTTP-01 验证，全自动无交互
bash install.sh --quick -d hy2.example.com -e me@example.com
```

```bash
# Cloudflare DNS-01 验证，无需放行 80 端口
bash install.sh --quick -d hy2.example.com --cf-token cf_xxx
```

```bash
# 自定义端口与跳跃范围
bash install.sh --quick -d hy2.example.com -p 8443 -m 30000-31000
```

```bash
# 读取已保存的订阅链接
bash install.sh --link
```

```bash
# 卸载并清理环境
bash install.sh --remove
```

> `--quick` 若未通过 `-d` 指定域名，脚本只会交互询问域名这一项，其余全部使用默认值。


## 🩺 证书申请失败排查

服务启动失败时优先查看日志：

```bash
journalctl -u hysteria-server.service -e --no-pager
```

常见原因：

- 域名未解析到本机，或 Cloudflare 开启了代理（小黄云）——HTTP-01 会失败，请改用 DNS-01
- 80/tcp 未放行，或被 nginx/apache 占用
- Cloudflare API Token 权限不足（需 `Zone:DNS:Edit`）
- 同一域名短时间内申请过多，触发 Let's Encrypt 速率限制（可改用 `--ca zerossl`）

## 🙏 鸣谢

- **[Hysteria](https://github.com/apernet/hysteria)**：由 Apernet 团队开发的高性能网络协议，是本脚本的运行核心。


## ⚠️ 免责声明

- 本项目仅供个人学习、技术研究及网络环境测试使用。
- 使用前请了解并遵守所在国家和地区的法律法规及云服务商的使用条款。
- 对于使用本脚本产生的任何风险、损失或不当行为，作者概不负责。**使用即表示您已阅读、理解并接受本声明。**


## 📄 参与与支持

如果本项目对您有帮助，请点击右上角 **⭐ Star** 支持！您的鼓励是持续维护的动力！

<div align="center">
  <sub>Made with ❤️ by <b>Owen_W</b>. </sub>
</div>
