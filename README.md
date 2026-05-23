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


## 🔧 高级：命令行参数

脚本支持非交互式直接调用，方便配合自动化工具或脚本使用：

```bash
# 快速全自动静默安装
bash install.sh --quick
# 或
bash install.sh --fast

# 读取已保存的订阅链接
bash install.sh --link
# 或
bash install.sh --info

# 单独清理 iptables 端口跳跃规则
bash install.sh --clean

# 快速卸载并清理环境
bash install.sh --remove
# 或
bash install.sh --uninstall
```

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
