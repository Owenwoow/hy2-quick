# Hysteria 2 一键部署脚本

<div align="center">
  <img src="https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-blue" alt="OS Support">
  <img src="https://img.shields.io/badge/Hysteria-2.x-green" alt="Hysteria Version">
  <img src="https://img.shields.io/badge/Author-Owen__W-orange" alt="Author">
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License">
</div>

> **项目地址**: [https://github.com/Owenwoow/hy2-quick-install](https://github.com/Owenwoow/hy2-quick-install)

为您带来极为简洁、稳定且功能完善的 **Hysteria 2** 服务端一键自动化部署工具。


## ⚙️ 系统要求

- 操作系统：`Debian 10+` / `Ubuntu 18.04+`（暂不支持 CentOS 等红帽系系统）
- `root` 用户执行
- 确保服务商面板（安全组 / 防火墙）已放行对应的 **UDP** 端口及跳跃区间端口


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
| `1` | **自定义安装**：自动检测并安装缺失依赖 → 交互配置 → 启动服务 → 输出客户端 URI |
| `2` | 卸载并清理所有配置、证书、服务文件及 sysctl 优化 |
| `3` | 单独管理 iptables 端口跳跃规则（查看 / 按行号删除） |
| `4` | **读取订阅链接**：直接输出已保存的客户端 URI；若缓存不存在则自动从配置重新生成 |
| `5` | **快速安装**：全自动无交互一键部署（自动生成参数、全静默安装），适合极速部署环境 |
| `0` | 退出脚本 |


## ⚡ 依赖安装优化（选项 1）

依赖安装流程经过大幅优化：

- **跳过已安装包**：通过 `dpkg-query` 精确检测每个依赖的安装状态，已安装的包直接跳过，二次安装几乎瞬间完成
- **删除 `apt-get upgrade`**：移除了对全系统软件包的无关升级（原耗时 1–15 分钟），专注于安装 Hysteria 2 所需的 5 个依赖
- **`--no-install-recommends`**：仅安装直接依赖，减少下载量

| 场景 | 优化前 | 优化后 |
|------|--------|--------|
| 全新系统首次安装 | 2–15 min | 20–60 s |
| 二次安装（依赖已存在） | 2–15 min | **< 1 s** |
| 依赖部分存在 | 2–15 min | 10–30 s |


## 🔄 Spinner 进度条

依赖安装和 Hysteria 2 安装过程全程后台静默执行，前台显示旋转动画与阶段提示：

```text
[INFO] 正在检查并安装依赖...
[INFO] 缺少以下依赖：iptables iptables-persistent

  ✔ 更新软件源索引...
  ⠹ 安装依赖包：iptables iptables-persistent...   ← 旋转动画实时转动
  ✔ 安装依赖包：iptables iptables-persistent...   ← 完成后变为绿色 ✔

[OK] 所有依赖安装完成
```

失败时自动打印错误日志末尾 20 行，便于快速定位问题。


## ⏱️ 超时保护机制

脚本对所有关键外部操作启用超时保护，避免网络不佳或 dpkg 锁占用时 SSH 会话无限挂起：

| 操作 | 超时阈值 |
|------|----------|
| `apt-get update` | 120 s |
| `apt-get install` | 300 s |
| 下载 Hysteria 2 安装脚本（`curl`） | 60 s |
| 执行 Hysteria 2 官方安装脚本 | 180 s |

超时后显示 `⏱ （超时 Xs，已中断）` 提示并输出最后日志，脚本安全退出。

> Hysteria 2 安装已拆分为「下载脚本」和「执行安装」两个独立阶段，分别控制超时，定位问题更精确。


## 📋 选项 4 — 读取订阅链接

安装完成后，客户端 URI 会自动保存到 `/etc/hysteria/link.bak`。

选择 `4) 读取订阅链接` 时脚本执行逻辑：

1. 检测 Hysteria 2 是否已安装（同时检测 `hysteria` 命令和 systemd 服务，任意一项存在即视为已安装）
2. 若 `/etc/hysteria/link.bak` 存在且非空 → 直接输出
3. 若缓存文件不存在 → 从 `config.yaml` 读取端口 / 密码，自动获取公网 IP，检测 iptables 端口跳跃规则，重新生成 URI 并保存到 `link.bak`


## ⚡ 选项 5 — 快速安装

适用于追求极致部署速度或自动化批量部署的场景。

选择 `5` 后，脚本将：
- **全程无交互**，全自动静默执行
- 自动检测并补齐缺失依赖
- 自动获取公网 IP 并生成强随机密码和随机节点名称
- 默认设置伪装网站（bing.com）和端口跳跃规则（20000-20100 → 443）
- 部署完成后直接打印客户端连接 URI


## 🔧 高级：命令行参数

脚本支持非交互式直接调用：

```bash
# 快速卸载并清理
bash install.sh --remove
# 或
bash install.sh --uninstall
```


## ⚠️ 常见问题

**1. 部署完成后连不上？**
- 检查监听端口和端口跳跃区间，确保 VPS 安全组已放行 **UDP** 协议。
- 绝大多数情况属于防火墙未放通 UDP 端口所致。

**2. 如何更新 Hysteria 2？**
- 菜单选择 `1) 自定义安装`，同意覆盖安装即可完成更新。

**3. 能否更换伪装域名？**
- 安装过程中可自定义伪装网站 URL；若遭到阻断，建议填写具有海外节点的常见网站（默认为 `https://www.bing.com`）。

**4. 安装完成后如何再次查看客户端 URI？**
- 菜单选择 `4) 读取订阅链接` 即可直接输出，无需重新安装。

**5. 依赖安装超时怎么办？**
- 超时说明网络延迟过高或 dpkg 锁被占用。可检查 `/var/lib/dpkg/lock-frontend` 是否被占用，或更换软件源后重试。


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
