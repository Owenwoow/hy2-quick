<div align="center">

# Hysteria 2 一键部署脚本

简洁、稳定的 Hysteria 2 服务端部署工具，支持 ACME 自动申请受信任证书。

<img src="https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-blue" alt="OS Support">
<img src="https://img.shields.io/badge/Hysteria-2.x-green" alt="Hysteria Version">
<img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License">

</div>

---

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Owenwoow/hy2-quick-install/main/install.sh)
```

装完后，以后直接输入 `hy2` 就能再次打开管理面板。

> 请用 `bash <(curl ...)`，不要用 `curl ... | bash` —— 后者会占用标准输入，脚本无法交互。

**系统要求**：Debian 10+ / Ubuntu 18.04+，root 用户执行。


## 使用

运行后会看到管理面板：

```text
┌──────────────────────────────────────────────────────────┐
│ Hysteria 2 一键部署脚本                              v2.2 │
└──────────────────────────────────────────────────────────┘

  当前状态      [运行中]

  1  自定义安装    选择证书方式，逐项配置
  2  快速安装      自签证书，全自动无交互
  3  订阅链接      查看客户端连接 URI
  4  端口跳跃      查看 / 清理 iptables 规则
  5  更新脚本      从 GitHub 拉取最新版本
  6  卸载清理      移除服务与全部配置
  0  退出
```

界面会自动适配终端：UTF-8 环境用框线字符，非 UTF-8 环境自动降级为 ASCII（`+ - |`）；状态标签、进度指示一律用 ASCII，确保在各类 SSH 工具上都能正常显示。

安装完成后会输出客户端连接 URI，复制导入代理工具即可使用。

任意输入处键入 **`b`** 可以返回上一级，不用退出程序重来。


## 选哪种安装方式

| | 自定义安装 | 快速安装 |
|---|---|---|
| 证书 | ACME 受信任证书 | 自签证书 |
| 需要域名 | 需要 | 不需要 |
| 交互 | 逐项配置 | 全自动 |
| 客户端兼容性 | 好 | 有限 |

**推荐用「自定义安装」，填写域名和邮箱申请 ACME 证书。**

快速安装虽然一条命令就能装完，但用的是自签证书。v2rayN 等基于 Xray 的客户端已不再支持跳过证书校验，可能连不上。没有域名时才建议用它。


## 文档

- [详细使用说明](docs/usage.md) — 证书方式、命令行参数、更新、端口跳跃
- [故障排查](docs/troubleshooting.md) — 证书申请失败、客户端连不上


## 鸣谢

- [Hysteria](https://github.com/apernet/hysteria) — Apernet 团队开发的高性能网络协议，本脚本的运行核心


## 免责声明

本项目仅供个人学习、技术研究及网络环境测试使用。使用前请了解并遵守所在国家和地区的法律法规及云服务商的使用条款。对于使用本脚本产生的任何风险、损失或不当行为，作者概不负责。使用即表示您已阅读、理解并接受本声明。


## License

[MIT](LICENSE)

<div align="center">
  <sub>如果这个项目对你有帮助，欢迎点个 ⭐ Star</sub><br>
  <sub>Made with ❤️ by <b>Owen_W</b></sub>
</div>
