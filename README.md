# HY2-Quick

一键快速部署 Hysteria 2 (v2) 的 Bash 脚本，为 Debian/Ubuntu 系统提供自动化安装、配置、卸载解决方案。

## 项目简介

**HY2-Quick** 是一个功能完整的 Hysteria 2 部署脚本，集成了以下核心功能：

- ✅ **一键安装**：无需复杂配置，几秒内自动部署 Hysteria 2 服务
- ✅ **自签证书**：自动生成自签数字证书，无需外部依赖
- ✅ **端口跳跃**：自动配置 iptables 规则转发 UDP 20000-30000 -> 443
- ✅ **强密码生成**：自动生成 20 位强随机密码，支持自定义
- ✅ **交互式配置**：用户可自定义节点名称、公网 IP/域名等参数
- ✅ **客户端 URI**：自动生成标准的 Hysteria 2 客户端连接链接
- ✅ **一键卸载**：支持完整的服务卸载与环境清理
- ✅ **开机自启**：自动设置 systemd 开机自启和立即启动

## 系统需求

- **操作系统**：Debian 11+ / Ubuntu 20.04+ 或更高版本
- **权限**：必须使用 `root` 权限运行
- **网络**：需要能够访问互联网以下载依赖包和官方安装脚本

## 安装使用

### 快速开始

```bash
# 下载脚本
git clone https://github.com/yourusername/hy2-quick.git
cd hy2-quick

# 给脚本赋予执行权限
chmod +x bin/install.sh

# 使用 root 权限运行
sudo bash bin/install.sh
```

### 脚本参数

- `--install` 或无参数：启动安装向导（可选）
- `--remove` 或 `--uninstall`：启动卸载流程

### 交互式配置项

运行脚本后，您需要提供以下信息（或使用默认值）：

1. **密码**：
   - 脚本会自动生成 20 位强随机密码
   - 您也可以输入自定义密码
   - 留空则使用系统生成的密码

2. **公网 IP 或域名**：
   - 脚本会自动检测，您也可以手动输入
   - 用于生成客户端连接链接

3. **节点名称**：
   - 默认值为 `HY2-NODE`
   - 用于客户端识别节点

4. **端口跳跃**：
   - 默认启用，将 UDP 20000-30000 转发到 443
   - 用于绕过 ISP 限制

## 功能说明

### 安装流程

1. Root 权限检查
2. 系统兼容性检查（Debian/Ubuntu）
3. 安装依赖包（openssl, curl, jq, iptables-persistent）
4. 使用官方脚本安装 Hysteria 2
5. 生成自签证书（有效期 100 年）
6. 自动生成强密码
7. 创建 Hysteria 2 配置文件（`/etc/hysteria/config.yaml`）
8. 配置 iptables NAT 规则进行端口跳跃
9. 启用 systemd 开机自启
10. 启动服务并验证
11. 输出客户端连接 URI

### 卸载流程

1. 停止并移除 Hysteria 2 服务
2. 清理防火墙规则（可交互选择）
3. 可选清理配置文件
4. 还原系统初始状态

## 客户端连接

脚本执行完成后，您将获得如下格式的连接链接：

```
hysteria2://[password]@[public-ip]:[port]?sni=www.bing.com&insecure=1&allowInsecure=1&mport=20000#HY2-NODE
```

使用支持 Hysteria 2 的客户端（如 Clash、v2rayN 等）导入此链接即可连接。

## 配置文件

### Hysteria 2 配置位置

- 配置文件：`/etc/hysteria/config.yaml`
- 证书：`/etc/hysteria/server.crt`
- 密钥：`/etc/hysteria/server.key`
- 服务管理：`systemctl {start|stop|restart|status} hysteria-server`

### 主要配置参数

- 监听端口：`:443` (UDP)
- Masquerade：代理到 `https://www.bing.com`
- 忽略客户端带宽限制：`ignoreClientBandwidth: false`

## 日志查看

```bash
# 查看服务状态
systemctl status hysteria-server

# 实时日志
journalctl -u hysteria-server -f

# 历史日志
journalctl -u hysteria-server -n 100
```

## 故障排查

### 服务无法启动
1. 检查配置文件语法：`cat /etc/hysteria/config.yaml`
2. 查看错误日志：`journalctl -u hysteria-server -n 50`
3. 确保 443 端口未被占用：`netstat -tulpn | grep 443`

### 客户端无法连接
1. 确认服务正在运行：`systemctl status hysteria-server`
2. 检查防火墙规则：`iptables -t nat -L PREROUTING`
3. 确保公网 IP 正确：`curl https://ip.sb`

### iptables 规则丢失
运行卸载脚本后再次安装可重新配置，或手动执行：

```bash
iptables -t nat -A PREROUTING -i [interface] -p udp --dport 20000:30000 -j DNAT --to-destination :443
iptables-save > /etc/iptables/rules.v4
```

## 项目结构

```
hy2-quick/
├── README.md                          # 项目文档（本文件）
├── .gitignore                         # Git 忽略文件配置
├── bin/
│   └── install.sh                     # 主要部署脚本
└── docs/
    ├── design/
    │   └── idea.md                    # 功能设计思路
    └── dev_notes/
        ├── prompt_install_code.md     # 安装功能 Prompt
        └── prompt_uninstall_code.md   # 卸载功能 Prompt
```

## 注意事项

⚠️ **重要提示**：

1. 脚本仅支持 Debian/Ubuntu 系列系统
2. 必须使用 root 权限执行
3. 执行脚本会修改系统防火墙配置和网络设置，建议在测试环境先运行
4. 脚本会覆盖已有的 `/etc/hysteria/config.yaml` 配置
5. 卸载时删除 iptables 规则需用户手动确认

## 许可证

MIT License

## 贡献指南

欢迎提交 Issue 和 Pull Request！

## 常见问题

**Q: 可以在其他 Linux 发行版上运行吗？**  
A: 当前只支持 Debian/Ubuntu 系列。其他发行版可尝试修改包管理器相关语句。

**Q: 脚本支持 IPv6 吗？**  
A: 当前版本主要支持 IPv4，IPv6 支持可作为后续功能拓展。

**Q: 如何修改监听端口？**  
A: 编辑 `/etc/hysteria/config.yaml` 中的 `listen` 参数，修改后需重启服务。

---

**更新日期**：2026-02-08  
**维护者**：HY2-Quick Team
