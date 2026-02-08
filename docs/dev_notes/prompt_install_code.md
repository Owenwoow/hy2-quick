# Role
你是一位精通 Linux Shell 编程和网络协议部署的高级运维工程师。

# Goal
请编写一个用于在 Debian/Ubuntu 系统上“一键快速部署” Hysteria 2 (v2) 的 Bash 脚本。
该脚本需要含有交互性，即用户执行脚本后，仅仅需要输入[密码自定义/系统生成的20位强随机密码]；[公网IP/域名]:[port];[节点名称/随机系统命名];[跳跃端口/不需要]，脚本自动完成所有安装、配置步骤，并在最后打印出客户端连接所需的 URI 链接。

# Constraints & Requirements
1. **运行环境**：脚本需强制要求以 root 权限运行，且主要适配 Debian/Ubuntu 环境（使用 apt）。
2. **静默安装**：安装依赖（如 `iptables-persistent`）时，必须设置 `DEBIAN_FRONTEND=noninteractive` 以跳过任何弹窗确认。
3. **核心组件**：
   - 使用官方命令 `bash <(curl -fsSL https://get.hy2.sh/)` 进行安装。
   - 需要安装 `openssl`, `curl`, `jq` (如有需要), `iptables-persistent`。
4. **自动化配置（关键）**：
   - **密码**：脚本自动生成一个 20 位强随机密码，不要使用默认密码。或者使用用户提供的密码。
   - **证书**：自动生成自签证书（Self-signed），Common Name 设置为 `bing.com`，有效期 100 年。
   - **配置文件**：自动写入 `/etc/hysteria/config.yaml`。监听 `:443`，开启 `masquerade` (proxy to https://www.bing.com)，开启 `ignoreClientBandwidth: false`。
5. **网络优化**：
   - **端口跳跃**：自动获取服务器的主网卡名称（Interface Name），配置 iptables 规则，将 UDP 端口 `20000-30000` 转发到 `443`，进行持久化配置。
6. **服务管理**：设置开机自启并立即启动服务。

# Output Logic (The Grand Finale)
脚本执行结束后，必须执行以下逻辑来生成客户端链接：
1. 自动通过 `curl` (如 ip.sb 或 ipinfo.io) 获取服务器的公网 IPv4 地址。
2. 按照 Hysteria 2 的标准 URI 格式拼接字符串，其中信息一点要从最新的config文件中读取确认：
   `hysteria2://[密码]@[公网IP]:[port]?sni=www.bing.com&insecure=1&allowInsecure=1&mport=[跳跃端口]#[节点名称]`
   *(注意：因为是自签证书，必须包含 insecure=1 参数)*
3. 在终端用醒目的颜色（如绿色或黄色）输出这个链接，并提示用户复制。

# Reference Commands (From User Notes)
请参考以下具体的配置参数：
- Cert generation: `openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=bing.com" -days 36500 && sudo chown hysteria /etc/hysteria/server.key && sudo chown hysteria /etc/hysteria/server.crt`
- Sysctl: `net.core.rmem_max=16777216`
- IPTables: `iptables -t nat -A PREROUTING -p udp --dport 20000:30000 -j REDIRECT --to-ports 443`
- source_config.yaml:
`# listen: :443 

acme:
  domains:
    - your.domain.net 
  email: your@email.com 

auth:
  type: password
  password: Se7RAuFZ8Lzg 

masquerade: 
  type: proxy
  proxy:
    url: https://news.ycombinator.com/ 
    rewriteHost: true
`
- my_config.yaml:
`listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: password

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/ 
    rewriteHost: true

ignoreClientBandwidth: false`


请直接输出完整的 `install.sh` 脚本代码，不要包含过多的解释性文字，代码中请包含必要的中文注释。

