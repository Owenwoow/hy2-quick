#!/usr/bin/env bash
# install.sh - Debian/Ubuntu 一键部署 Hysteria 2 (v2) + 自签证书 + UDP 端口跳跃(20000-30000 -> 443) + 卸载清理
# 修复点：
# 1) 交互 read 在非交互/TTY 异常时不再导致脚本提前退出（read 失败不触发 set -e）
# 2) systemd 服务名使用官方安装脚本创建的 hysteria-server.service（不是 hysteria.service）
# 3) 启动/自启使用 hysteria-server.service
# 4) 更稳健地从 config 解析端口与密码，并输出 URI
# 新增：
# - Uninstall_Hy2：支持菜单选择或参数 --remove / --uninstall，按流程图进行卸载与环境清理（iptables 删除为唯一交互点）

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
  die "请使用 root 权限运行：sudo bash $0"
fi

# ---------- 环境检查 ----------
if ! command -v apt-get >/dev/null 2>&1; then
  die "仅支持 Debian/Ubuntu（未找到 apt-get）"
fi

export DEBIAN_FRONTEND=noninteractive

# ---------- 工具函数 ----------
gen_pass_20() {
  openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 20
}

get_default_iface() {
  ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}'
}

get_public_ipv4() {
  local ip=""
  ip="$(curl -4fsSL --max-time 8 https://ip.sb 2>/dev/null || true)"
  [[ -z "${ip}" ]] && ip="$(curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "${ip}" ]] && ip="$(curl -4fsSL --max-time 8 https://ipinfo.io/ip 2>/dev/null || true)"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  echo "${ip}"
}

urlencode_fragment() {
  echo -n "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/&/%26/g'
}

# 更安全的 read：read 失败（无TTY/EOF）不让脚本退出
safe_read() {
  # 用法：safe_read VAR "提示语"
  local __var="$1"
  local __prompt="$2"
  local __tmp=""
  # shellcheck disable=SC2162
  if read -r -p "${__prompt}" __tmp; then
    :
  else
    __tmp=""
  fi
  printf -v "${__var}" '%s' "${__tmp}"
}

# ============================================================
#  卸载与环境清理（严格遵循流程图顺序）
# ============================================================
Uninstall_Hy2() {
  local SERVICE="hysteria-server.service"

  echo -e "${CYAN}========== Hysteria 2 卸载与环境清理 ==========${RESET}"

  # 1) 检查服务状态 (Check Service)
  log "检查 systemd 服务：${SERVICE} ..."
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${SERVICE}"; then
    # 分支 A：存在
    if systemctl is-active --quiet "${SERVICE}"; then
      log "检测到服务正在运行，尝试停止..."
      systemctl stop "${SERVICE}" >/dev/null 2>&1 || true
      ok "服务已停止"
    else
      ok "检测到服务存在，但未运行"
    fi

    log "调用官方卸载命令（--remove）..."
    bash <(curl -fsSL https://get.hy2.sh/) --remove || true
    ok "服务已移除"
  else
    # 分支 B：不存在
    warn "未检测到 Hysteria 服务安装，跳过服务卸载步骤"
  fi

  # 2) 检查防火墙规则 (Check IPTables NAT)
  log "检查 iptables NAT PREROUTING 规则..."
  if ! command -v iptables >/dev/null 2>&1; then
    warn "未找到 iptables，跳过防火墙规则检查"
    echo -e "${GREEN}========== 环境清理/卸载流程结束 ==========${RESET}"
    exit 0
  fi

  local RULES
  RULES="$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null || true)"

  if echo "${RULES}" | awk 'BEGIN{has=0} $1 ~ /^[0-9]+$/ {has=1} END{exit (has?0:1)}'; then
    # 分支 A：有规则
    echo -e "${YELLOW}当前 NAT PREROUTING 规则如下（带行号）：${RESET}"
    echo "${RULES}"
    echo

    # 唯一交互点：选择要删除的规则行号（留空则不删）
    local DELNO=""
    safe_read DELNO "请输入要删除的规则行号（留空回车则默认不删除）："

    # 容错：非数字/越界不崩溃
    if [[ -z "${DELNO}" ]]; then
      warn "未输入行号，默认不删除任何规则"
    elif [[ ! "${DELNO}" =~ ^[0-9]+$ ]]; then
      warn "输入不是数字：${DELNO}，跳过删除"
    else
      if echo "${RULES}" | awk -v n="${DELNO}" '$1==n {found=1} END{exit(found?0:1)}'; then
        log "删除规则：iptables -t nat -D PREROUTING ${DELNO}"
        if iptables -t nat -D PREROUTING "${DELNO}" >/dev/null 2>&1; then
          ok "规则已删除"
          if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
            ok "已持久化保存（netfilter-persistent save）"
          else
            warn "未找到 netfilter-persistent，无法自动持久化（你可手动保存规则）"
          fi
        else
          warn "删除失败：行号可能已变化或规则不存在（未中断）"
        fi
      else
        warn "未找到行号 ${DELNO} 对应的规则，跳过删除"
      fi
    fi
  else
    # 分支 B：无规则
    ok "未检测到 NAT PREROUTING 规则，跳过"
  fi

  # 3) 结束程序 (Exit)
  echo -e "${GREEN}========== 环境清理/卸载流程结束 ==========${RESET}"
  exit 0
}

# ============================================================
#  安装主逻辑（把你现有脚本主体封装成函数）
# ============================================================
Install_Hy2() {
  # ---------- 交互输入 ----------
  echo -e "${CYAN}========== Hysteria 2 一键部署脚本 ==========${RESET}"

  # 1) 密码：用户自定义 或 自动生成 20 位
  safe_read USER_PASS "请输入密码（直接回车=自动生成20位强随机密码）: "
  if [[ -z "${USER_PASS}" ]]; then
    PASS="$(gen_pass_20)"
    ok "已生成随机密码：${PASS}"
  else
    PASS="${USER_PASS}"
    ok "使用用户提供的密码"
  fi

  # 2) [公网IP/域名]:[port]（port 仅用于客户端链接展示；服务端固定监听 443）
  safe_read HOSTPORT "请输入 [公网IP/域名]:[port]（例：1.2.3.4:443 或 example.com:443，直接回车=自动获取IP并使用443）: "

  HOST=""
  PORT=""
  if [[ -z "${HOSTPORT}" ]]; then
    HOST="$(get_public_ipv4 2>/dev/null || true)"
    [[ -z "${HOST}" ]] && warn "自动获取公网IPv4失败（稍后会再尝试一次）"
    PORT="443"
  else
    [[ "${HOSTPORT}" != *":"* ]] && die "格式错误：必须是 [公网IP/域名]:[port]，例如 1.2.3.4:443"
    HOST="${HOSTPORT%:*}"
    PORT="${HOSTPORT##*:}"
    [[ -z "${HOST}" || -z "${PORT}" ]] && die "格式错误：HOST 或 PORT 为空"
    [[ ! "${PORT}" =~ ^[0-9]+$ ]] && die "端口必须为数字"
  fi

  # 3) 节点名称：用户输入 或 随机系统命名
  safe_read NODE_NAME "请输入节点名称（直接回车=随机系统命名）: "
  if [[ -z "${NODE_NAME}" ]]; then
    NODE_NAME="hy2-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    ok "已生成节点名称：${NODE_NAME}"
  else
    ok "使用节点名称：${NODE_NAME}"
  fi

  # 4) 跳跃端口：默认 20000-30000；可选择不需要
  safe_read WANT_MPORT "是否启用 UDP 端口跳跃 20000-30000 -> 443？（回车=启用 / 输入 n=不需要）: "
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
  apt-get install -y --no-install-recommends openssl curl jq iptables iptables-persistent ca-certificates >/dev/null
  ok "依赖安装完成"

  # ---------- 安装 Hysteria 2 ----------
  log "安装 Hysteria 2（官方脚本）..."
  bash <(curl -fsSL https://get.hy2.sh/)
  ok "Hysteria 2 安装完成"

  # ---------- 生成自签证书（CN=bing.com，100年） ----------
  log "生成自签证书（CN=bing.com，有效期100年）..."
  install -d -m 0755 /etc/hysteria

  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=bing.com" \
    -days 36500 >/dev/null 2>&1

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
  [[ -n "${IFACE}" ]] && ok "检测到主网卡：${IFACE}" || warn "未能自动获取主网卡（不影响规则配置）"

  if [[ "${ENABLE_MPORT}" == "yes" ]]; then
    log "配置 iptables：UDP 20000-30000 重定向到 443（NAT PREROUTING）..."
    if iptables -t nat -C PREROUTING -p udp --dport 20000:30000 -j REDIRECT --to-ports 443 >/dev/null 2>&1; then
      ok "iptables 规则已存在，跳过添加"
    else
      iptables -t nat -A PREROUTING -p udp --dport 20000:30000 -j REDIRECT --to-ports 443
      ok "iptables 规则添加完成"
    fi

    log "持久化保存 iptables 规则..."
    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null
      ok "规则已持久化（netfilter-persistent）"
    else
      if [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4
        ok "规则已保存到 /etc/iptables/rules.v4"
      else
        warn "未找到 netfilter-persistent 或 /etc/iptables，持久化可能失败"
      fi
    fi
  fi

  # ---------- 服务管理（关键修复：服务名是 hysteria-server.service） ----------
  SERVICE_NAME="hysteria-server.service"
  SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

  if [[ ! -f "${SERVICE_PATH}" ]]; then
    if systemctl list-unit-files | grep -qE '^hysteria-server\.service'; then
      :
    else
      warn "未找到 ${SERVICE_PATH}，尝试列出相关 unit："
      systemctl list-unit-files | grep -E 'hysteria.*service' || true
      die "未检测到 hysteria-server.service，请确认官方安装脚本是否成功创建 systemd unit"
    fi
  fi

  log "设置 ${SERVICE_NAME} 开机自启并立即启动..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "${SERVICE_NAME}" >/dev/null

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    ok "${SERVICE_NAME} 服务已启动"
  else
    warn "${SERVICE_NAME} 未处于 active 状态，输出状态："
    systemctl status "${SERVICE_NAME}" --no-pager || true
    die "服务启动失败，请检查日志：journalctl -u ${SERVICE_NAME} -e --no-pager"
  fi

  # ---------- 生成客户端 URI（从最新配置文件读取） ----------
  CONF="/etc/hysteria/config.yaml"
  [[ -f "${CONF}" ]] || die "未找到配置文件：${CONF}"

  CONF_PASS="$(awk -F': ' '/^[[:space:]]*password:[[:space:]]*/{print $2; exit}' "${CONF}" | tr -d '\r')"
  CONF_LISTEN="$(awk -F': ' '/^[[:space:]]*listen:[[:space:]]*/{print $2; exit}' "${CONF}" | tr -d '\r')"
  CONF_PORT="${CONF_LISTEN##*:}"

  [[ -z "${CONF_PASS}" ]] && die "从配置读取密码失败"
  [[ -z "${CONF_PORT}" || ! "${CONF_PORT}" =~ ^[0-9]+$ ]] && die "从配置读取端口失败"

  if [[ -z "${HOST}" ]]; then
    HOST="$(get_public_ipv4 2>/dev/null || true)"
    [[ -z "${HOST}" ]] && die "获取公网 IPv4 失败，请手动填写后重试"
  fi

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
}

# ============================================================
#  入口：参数触发 或 菜单触发
# ============================================================

# 参数触发（适合自动化）：./install.sh --remove
case "${1:-}" in
  --remove|--uninstall)
    Uninstall_Hy2
    ;;
esac

# 菜单触发（交互使用）
echo -e "${CYAN}========== 请选择操作 ==========${RESET}"
echo "1) 安装 Hysteria 2"
echo "2) 卸载/环境清理"
safe_read CHOICE "请输入选项 [1-2]（默认1）："
CHOICE="${CHOICE:-1}"

case "${CHOICE}" in
  1) Install_Hy2 ;;
  2) Uninstall_Hy2 ;;
  *) warn "无效选项：${CHOICE}，默认执行安装"; Install_Hy2 ;;
esac