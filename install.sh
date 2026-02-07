#!/usr/bin/env bash
# install.sh - Debian/Ubuntu 一键部署 Hysteria 2 (v2) + 自签证书 + UDP 端口跳跃(20000-30000 -> 443)
# 需求：root 运行；静默安装依赖；官方安装脚本；自动写入 /etc/hysteria/config.yaml；iptables 持久化；输出客户端 URI

set -euo pipefail

# ---------- 颜色输出 ----------
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

log() { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()  { echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
die() { echo -e "${RED}[ERR]${RESET} $*" >&2; exit 1; }

# ---------- root 检查 ----------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "请使用 root 权限运行：sudo bash install.sh"
fi

# ---------- 环境检查 ----------
if ! command -v apt-get >/dev/null 2>&1; then
  die "仅支持 Debian/Ubuntu（未找到 apt-get）"
fi

export DEBIAN_FRONTEND=noninteractive

# ---------- 工具函数 ----------
gen_pass_20() {
  # 生成 20 位强随机密码（URL 安全字符），尽量避免特殊字符导致 URI 解析问题
  # 使用 openssl base64 -> 过滤成 [A-Za-z0-9]，截取 20
  openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 20
}

get_default_iface() {
  # 获取默认路由的主网卡名
  ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}'
}

get_public_ipv4() {
  # 尝试多个源获取公网 IPv4
  local ip=""
  ip="$(curl -4fsSL --max-time 8 https://ip.sb 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4fsSL --max-time 8 https://ipinfo.io/ip 2>/dev/null || true)"
  fi
  # 简单校验
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo ""
    return 1
  fi
  echo "${ip}"
}

urlencode_fragment() {
  # 仅用于 URI 的 #fragment(节点名)；这里做最小化编码：空格->%20，其它常见字符也做编码
  # shellcheck disable=SC2001
  echo -n "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/&/%26/g'
}

# ---------- 交互输入 ----------
echo -e "${CYAN}========== Hysteria 2 一键部署脚本 ==========${RESET}"

# 1) 密码：用户自定义 或 自动生成 20 位
read -r -p "请输入密码（直接回车=自动生成20位强随机密码）: " USER_PASS || true
if [[ -z "${USER_PASS}" ]]; then
  PASS="$(gen_pass_20)"
  ok "已生成随机密码：${PASS}"
else
  PASS="${USER_PASS}"
  ok "使用用户提供的密码"
fi

# 2) [公网IP/域名]:[port]（port 仅用于客户端链接展示；服务端固定监听 443）
read -r -p "请输入 [公网IP/域名]:[port]（例：1.2.3.4:443 或 example.com:443，直接回车=自动获取IP并使用443）: " HOSTPORT || true

HOST=""
PORT=""
if [[ -z "${HOSTPORT}" ]]; then
  HOST="$(get_public_ipv4 || true)"
  [[ -z "${HOST}" ]] && warn "自动获取公网IPv4失败，稍后仍会再次尝试" && HOST=""
  PORT="443"
else
  if [[ "${HOSTPORT}" != *":"* ]]; then
    die "格式错误：必须是 [公网IP/域名]:[port]，例如 1.2.3.4:443"
  fi
  HOST="${HOSTPORT%:*}"
  PORT="${HOSTPORT##*:}"
  [[ -z "${HOST}" || -z "${PORT}" ]] && die "格式错误：HOST 或 PORT 为空"
  [[ ! "${PORT}" =~ ^[0-9]+$ ]] && die "端口必须为数字"
fi

# 3) 节点名称：用户输入 或 随机系统命名
read -r -p "请输入节点名称（直接回车=随机系统命名）: " NODE_NAME || true
if [[ -z "${NODE_NAME}" ]]; then
  NODE_NAME="hy2-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
  ok "已生成节点名称：${NODE_NAME}"
else
  ok "使用节点名称：${NODE_NAME}"
fi

# 4) 跳跃端口：默认 20000-30000；可选择不需要（留空则启用默认范围；输入 n/N 则不启用）
read -r -p "是否启用 UDP 端口跳跃 20000-30000 -> 443？（回车=启用 / 输入 n=不需要）: " WANT_MPORT || true
ENABLE_MPORT="yes"
if [[ "${WANT_MPORT}" =~ ^[nN]$ ]]; then
  ENABLE_MPORT="no"
  warn "已选择不启用端口跳跃"
else
  ok "将启用端口跳跃：20000-30000 -> 443"
fi

# ---------- 安装依赖 ----------
log "更新软件源并静默安装依赖（openssl/curl/jq/iptables-persistent）..."
apt-get update -y >/dev/null
# iptables-persistent 安装时可能弹出保存规则提示，这里通过 DEBIAN_FRONTEND=noninteractive 避免交互
apt-get install -y --no-install-recommends openssl curl jq iptables iptables-persistent ca-certificates >/dev/null

ok "依赖安装完成"

# ---------- 安装 Hysteria 2 ----------
log "安装 Hysteria 2（官方脚本）..."
bash <(curl -fsSL https://get.hy2.sh/)
ok "Hysteria 2 安装完成"

# ---------- 生成自签证书（CN=bing.com，100年） ----------
log "生成自签证书（CN=bing.com，有效期100年）..."
install -d -m 0755 /etc/hysteria

# 使用 ECC P-256 生成自签证书
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" \
  -days 36500 >/dev/null 2>&1

# 尝试把证书权限归属给 hysteria 用户（若存在）
if id -u hysteria >/dev/null 2>&1; then
  chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
else
  chmod 600 /etc/hysteria/server.key
  chmod 644 /etc/hysteria/server.crt
fi

ok "证书生成完成：/etc/hysteria/server.crt /etc/hysteria/server.key"

# ---------- sysctl 网络优化 ----------
log "写入 sysctl 优化：net.core.rmem_max=16777216"
cat >/etc/sysctl.d/99-hy2.conf <<'EOF'
net.core.rmem_max=16777216
EOF
sysctl --system >/dev/null
ok "sysctl 已生效"

# ---------- 写入配置文件 ----------
log "写入 /etc/hysteria/config.yaml（监听 :443，伪装 bing.com，自签证书）..."
cat >/etc/hysteria/config.yaml <<EOF
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${PASS}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

ignoreClientBandwidth: false
EOF

ok "配置文件写入完成"

# ---------- 端口跳跃 iptables 规则 ----------
IFACE="$(get_default_iface || true)"
if [[ -z "${IFACE}" ]]; then
  warn "未能自动获取主网卡名称（default route）。将继续配置规则（不依赖网卡名）"
else
  ok "检测到主网卡：${IFACE}"
fi

if [[ "${ENABLE_MPORT}" == "yes" ]]; then
  log "配置 iptables：UDP 20000-30000 重定向到 443（NAT PREROUTING）..."
  # 避免重复添加：先检查是否存在
  if iptables -t nat -C PREROUTING -p udp --dport 20000:30000 -j REDIRECT --to-ports 443 >/dev/null 2>&1; then
    ok "iptables 规则已存在，跳过添加"
  else
    iptables -t nat -A PREROUTING -p udp --dport 20000:30000 -j REDIRECT --to-ports 443
    ok "iptables 规则添加完成"
  fi

  log "持久化保存 iptables 规则..."
  # Debian/Ubuntu: iptables-persistent 使用 netfilter-persistent 管理
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null
    ok "规则已持久化（netfilter-persistent）"
  else
    # 兜底：直接保存到规则文件（不同系统路径可能不同）
    if [[ -d /etc/iptables ]]; then
      iptables-save > /etc/iptables/rules.v4
      ok "规则已保存到 /etc/iptables/rules.v4"
    else
      warn "未找到 netfilter-persistent 或 /etc/iptables，持久化可能失败"
    fi
  fi
fi

# ---------- 服务管理 ----------
log "设置 hysteria 开机自启并立即启动..."
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now hysteria >/dev/null

# 简单检查
if systemctl is-active --quiet hysteria; then
  ok "hysteria 服务已启动"
else
  warn "hysteria 服务未处于 active 状态，尝试输出状态："
  systemctl status hysteria --no-pager || true
  die "服务启动失败，请检查日志：journalctl -u hysteria -e --no-pager"
fi

# ---------- 生成客户端 URI（从最新配置文件读取） ----------
CONF="/etc/hysteria/config.yaml"
[[ -f "${CONF}" ]] || die "未找到配置文件：${CONF}"

# 从 config 读取 password 与 listen port（确保以最新配置为准）
CONF_PASS="$(awk -F': ' '/^[[:space:]]*password:[[:space:]]*/{print $2; exit}' "${CONF}" | tr -d '\r')"
CONF_LISTEN="$(awk -F': ' '/^[[:space:]]*listen:[[:space:]]*/{print $2; exit}' "${CONF}" | tr -d '\r')"
# listen 形如 :443
CONF_PORT="${CONF_LISTEN##*:}"
[[ -z "${CONF_PASS}" ]] && die "从配置读取密码失败"
[[ -z "${CONF_PORT}" || ! "${CONF_PORT}" =~ ^[0-9]+$ ]] && die "从配置读取端口失败"

# 公网IP：如果一开始没拿到，这里再拿一次
if [[ -z "${HOST}" ]]; then
  HOST="$(get_public_ipv4 || true)"
  [[ -z "${HOST}" ]] && die "获取公网 IPv4 失败，请手动填写后重试"
fi

# 端口：客户端链接使用用户输入的 port（若用户没输入则使用 config 的端口）
# 注意：服务端实际监听固定为 443（CONF_PORT），如果用户输入了其他 port，实际需要你在外层做转发/NAT 才能工作
if [[ -z "${PORT}" ]]; then
  PORT="${CONF_PORT}"
fi

ENC_NODE="$(urlencode_fragment "${NODE_NAME}")"

URI="hysteria2://${CONF_PASS}@${HOST}:${PORT}?sni=www.bing.com&insecure=1&allowInsecure=1"
if [[ "${ENABLE_MPORT}" == "yes" ]]; then
  URI="${URI}&mport=20000-30000#${ENC_NODE}"
else
  URI="${URI}#${ENC_NODE}"
fi

echo
echo -e "${GREEN}========== 部署完成 ==========${RESET}"
echo -e "${YELLOW}请复制以下客户端连接 URI：${RESET}"
echo -e "${GREEN}${URI}${RESET}"
echo
echo -e "${CYAN}提示：${RESET}因使用自签证书，链接已包含 insecure=1 / allowInsecure=1。"
if [[ "${ENABLE_MPORT}" == "yes" ]]; then
  echo -e "${CYAN}提示：${RESET}已启用端口跳跃 mport=20000-30000（UDP）-> 443。"
fi