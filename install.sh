#!/bin/bash
set -euo pipefail

# ============================================================
# Hysteria 2 一键部署脚本
# 项目地址: https://github.com/Owenwoow/hy2-quick-install
#
# TLS 证书策略：默认通过 ACME 自动申请受信任证书（Let's Encrypt / ZeroSSL），
# 自签证书仅作为无域名场景的兜底，并输出 pinSHA256 供客户端做证书固定。
# ============================================================


# ---------- 颜色输出 ----------
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# ---------- 超时设置（秒） ----------
TIMEOUT_APT_UPDATE=120
TIMEOUT_APT_INSTALL=300
TIMEOUT_HY2_INSTALL=180
TIMEOUT_CURL_DOWNLOAD=60

# ---------- 路径常量 ----------
HY_DIR="/etc/hysteria"
CONFIG_FILE="${HY_DIR}/config.yaml"
LINK_FILE="${HY_DIR}/link.bak"
HY_HOME="/var/lib/hysteria"
ACME_DIR="${HY_HOME}/acme"
SELF_CERT="${HY_DIR}/server.crt"
SELF_KEY="${HY_DIR}/server.key"
SERVICE_NAME="hysteria-server.service"

# ---------- 部署状态（全局） ----------
CERT_MODE=""        # acme-http | acme-dns-cf | manual | selfsigned
DOMAIN=""
EMAIL=""
CA_PROVIDER="letsencrypt"
CF_TOKEN=""
CERT_PATH=""
KEY_PATH=""
PIN_SHA256=""
PASS=""
PORT=""
HOST=""
SNI=""
FAKE_URL=""
NODE_NAME=""
ENABLE_MPORT="no"
MPORT=""
URI=""

# ---------- 命令行参数 ----------
ACTION=""
ARG_DOMAIN=""
ARG_EMAIL=""
ARG_CF_TOKEN=""
ARG_CA=""
ARG_PORT=""
ARG_PASS=""
ARG_MPORT=""
ARG_FAKE=""
ARG_NAME=""
ARG_SELF_SIGNED="no"

log() { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()  { echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
die() { echo -e "${RED}[ERR]${RESET} $*" >&2; exit 1; }


# ---------- 工具函数 ----------

# 带旋转动画 + 超时保护执行后台命令
# 用法：run_with_spinner <超时秒数> "提示文字" command arg1 arg2 ...
run_with_spinner() {
    local timeout_sec="$1"; shift
    local msg="$1"; shift
    local logfile="/tmp/hy2_install_$$.log"
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    # 后台执行命令（带 timeout 包裹）
    timeout "${timeout_sec}" "$@" > "${logfile}" 2>&1 &
    local pid=$!

    printf "  ${CYAN}%s${RESET} %s" "${spin_chars:0:1}" "${msg}"
    while kill -0 "${pid}" 2>/dev/null; do
        local char="${spin_chars:$((i % ${#spin_chars})):1}"
        printf "\r  ${CYAN}%s${RESET} %s" "${char}" "${msg}"
        ((i++))
        sleep 0.1
    done

    wait "${pid}"
    local exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
        printf "\r  ${GREEN}✔${RESET} %s\n" "${msg}"
    elif [[ ${exit_code} -eq 124 ]]; then
        printf "\r  ${RED}✘${RESET} %s ${RED}(超时 ${timeout_sec}s)${RESET}\n" "${msg}"
        echo -e "${RED}最后输出：${RESET}"
        tail -10 "${logfile}" 2>/dev/null || true
        rm -f "${logfile}"
        return ${exit_code}
    else
        printf "\r  ${RED}✘${RESET} %s\n" "${msg}"
        echo -e "${RED}错误日志（最后20行）：${RESET}"
        tail -20 "${logfile}" 2>/dev/null || true
        rm -f "${logfile}"
        return ${exit_code}
    fi
    rm -f "${logfile}"
}

gen_pass_20() {
    openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 20
}

# 获取默认出口网卡
get_default_iface() {
    ip route show default | awk '/^default/{print $5; exit}'
}

# 获取公网 IPv4
get_public_ipv4() {
    local ip=""
    # 强制通过 IPv4 协议向多个 API 请求
    ip="$(curl -4 -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || true)"

    # 正则校验：如果不是标准的 IPv4 格式，则尝试下一个备用源
    if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        ip="$(curl -4 -s --max-time 5 https://api4.ipify.org 2>/dev/null || true)"
    fi

    if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        ip="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    fi

    echo "${ip}"
}

# URL 编码（优先 python3，保证中文节点名正确；无 python3 时退化为纯 ASCII 编码）
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null && return 0
    local s="$1" out="" c i
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "${c}" in
            [A-Za-z0-9.~_-]) out+="${c}" ;;
            *) out+="$(printf '%%%02X' "'${c}" 2>/dev/null || printf '%s' "${c}")" ;;
        esac
    done
    printf '%s\n' "${out}"
}

# 更安全的 read：避免无TTY或EOF时触发 set -e 导致脚本直接退出
safe_read() {
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

# 将任意字符串包装成 YAML 双引号标量
# 密码 / Token / URL 可能含 # : " \ 等字符，裸写会被 YAML 解析成注释或结构，必须转义
yaml_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "${s}"
}

# yaml_quote 的逆操作：去掉外层引号并还原转义
yaml_unquote() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # 去首部空白
    s="${s%"${s##*[![:space:]]}"}"   # 去尾部空白
    if [[ "${s}" == \"*\" ]]; then
        s="${s:1:${#s}-2}"
        s="${s//\\\"/\"}"
        s="${s//\\\\/\\}"
    elif [[ "${s}" == \'*\' ]]; then
        s="${s:1:${#s}-2}"
        s="${s//\'\'/\'}"
    fi
    printf '%s' "${s}"
}

# 域名格式校验（排除纯 IP）
validate_domain() {
    local d="$1"
    [[ "${d}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 1
    [[ "${d}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# 邮箱格式校验
validate_email() {
    [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# 解析域名的 A 记录（dig 优先，退化到 getent）
resolve_domain_ipv4() {
    local d="$1" out=""
    if command -v dig >/dev/null 2>&1; then
        out="$(dig +short A "${d}" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 || true)"
    fi
    if [[ -z "${out}" ]]; then
        out="$(getent ahostsv4 "${d}" 2>/dev/null | awk '{print $1; exit}' || true)"
    fi
    echo "${out}"
}

# 检查 TCP 端口是否空闲（空闲返回 0）
check_tcp_port_free() {
    local p="$1"
    ! ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${p}\$"
}

# 计算证书 SHA256 指纹（形如 AA:BB:CC:...），供客户端 pinSHA256 使用
cert_sha256_pin() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/.*=//' | tr -d ' \r\n'
}

# 判断证书是否为自签（subject == issuer）
cert_is_selfsigned() {
    local subj issuer
    subj="$(openssl x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
    issuer="$(openssl x509 -in "$1" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')"
    [[ -n "${subj}" && "${subj}" == "${issuer}" ]]
}

# 取证书的第一个域名（优先 SAN，退化到 CN）
cert_first_domain() {
    local d
    d="$(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | sed -n 's/.*DNS://p' | head -1 | tr -d ' \r\n')"
    if [[ -z "${d}" ]]; then
        d="$(openssl x509 -in "$1" -noout -subject 2>/dev/null \
            | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' | head -1 | tr -d ' \r\n')"
    fi
    echo "${d}"
}


# ---------- 依赖安装 ----------
dep_install() {
    log "正在检查并安装依赖..."

    # 所有必需的包列表（ca-certificates 用于 ACME/HTTPS 校验，dnsutils 用于域名解析自检）
    local required_pkgs=(curl wget openssl ca-certificates dnsutils iptables iptables-persistent)
    local missing_pkgs=()

    # 检测哪些包尚未安装
    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
            missing_pkgs+=("${pkg}")
        fi
    done

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        ok "所有依赖已安装，跳过"
        return
    fi

    log "缺少以下依赖：${missing_pkgs[*]}"
    echo ""

    # 阶段 1：强制更新软件源索引
    run_with_spinner ${TIMEOUT_APT_UPDATE} "更新软件源索引..." apt-get update \
        || die "apt-get update 失败，请检查软件源或 dpkg 锁！"

    # 阶段 2：仅安装缺失的包，不安装推荐包
    run_with_spinner ${TIMEOUT_APT_INSTALL} "安装依赖包：${missing_pkgs[*]}..." \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends "${missing_pkgs[@]}" \
        || die "依赖安装失败！"

    echo ""
    ok "所有依赖安装完成"
}


# ============================================================
#  检查 root 权限的函数
# ============================================================
check_root() {
    if [ $(id -u) != "0" ]; then
        die "请以 root 用户执行脚本！"
    fi
    if ! grep -qiE "debian|ubuntu" /etc/os-release; then
        die "本脚本仅支持 Debian/Ubuntu 系统！"
    fi
}


# ============================================================
#  证书子系统
# ============================================================

# 交互收集域名（带格式校验）
ask_domain() {
    local input
    while true; do
        safe_read input "请输入已解析到本机的域名 (例如 hy2.example.com): "
        input="${input// /}"
        if [[ -z "${input}" ]]; then
            warn "域名不能为空！ACME 申请证书必须提供域名。"
            continue
        fi
        if ! validate_domain "${input}"; then
            warn "域名格式不合法：${input}"
            continue
        fi
        DOMAIN="${input}"
        ok "域名：${DOMAIN}"
        break
    done
}

# 交互收集邮箱（回车使用 admin@域名）
ask_email() {
    local input
    while true; do
        safe_read input "请输入 ACME 联系邮箱 (直接回车 = admin@${DOMAIN}): "
        input="${input:-admin@${DOMAIN}}"
        if ! validate_email "${input}"; then
            warn "邮箱格式不合法：${input}"
            continue
        fi
        EMAIL="${input}"
        ok "ACME 邮箱：${EMAIL}"
        break
    done
}

# HTTP-01 验证的前置自检：域名解析 + 80 端口占用
precheck_acme_http() {
    local resolved server_ip
    log "检查域名解析（HTTP-01 验证要求 ${DOMAIN} 解析到本机）..."
    resolved="$(resolve_domain_ipv4 "${DOMAIN}")"
    server_ip="$(get_public_ipv4 2>/dev/null || true)"

    if [[ -z "${resolved}" ]]; then
        warn "无法解析 ${DOMAIN} 的 A 记录，DNS 可能尚未生效。"
    elif [[ -n "${server_ip}" && "${resolved}" != "${server_ip}" ]]; then
        warn "域名解析到 ${resolved}，与本机公网 IP ${server_ip} 不一致。"
        warn "若使用了 Cloudflare 小黄云代理，HTTP-01 验证会失败，请改用 DNS 验证方式。"
    else
        ok "域名解析正常：${DOMAIN} -> ${resolved}"
    fi

    log "检查 80/tcp 端口占用（HTTP-01 验证需要占用该端口）..."
    if check_tcp_port_free 80; then
        ok "80/tcp 端口空闲"
    else
        warn "80/tcp 已被占用："
        ss -ltnp 2>/dev/null | grep -E "[:.]80\s" || true
        warn "请先停止占用进程（如 nginx/apache），否则证书申请会失败。"
    fi

    warn "请确认云服务商安全组已放行 80/tcp，且证书续期时该端口需长期可用。"

    if [[ "${ACTION}" != "quick" ]]; then
        local go
        safe_read go "以上检查若有告警仍要继续？(直接回车 = 继续 / 输入 n = 返回重选): "
        [[ "${go}" == "n" || "${go}" == "N" ]] && return 1
    fi
    return 0
}

# 生成自签证书（兜底方案）：CN=bing.com，同时写入 SAN，有效期 100 年
setup_selfsigned_cert() {
    log "生成自签证书（CN=bing.com，有效期 100 年）..."
    install -d -m 0755 "${HY_DIR}"

    # 使用 -pkeyopt 指定曲线，避免依赖进程替换（部分精简 shell 环境不支持）
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${SELF_KEY}" \
        -out    "${SELF_CERT}" \
        -subj   "/CN=bing.com" \
        -addext "subjectAltName=DNS:bing.com,DNS:www.bing.com" \
        -days   36500 >/dev/null 2>&1 \
        || die "自签证书生成失败，请检查 openssl 是否可用！"

    if id -u hysteria >/dev/null 2>&1; then
        chown hysteria:hysteria "${SELF_KEY}" "${SELF_CERT}"
    fi
    chmod 600 "${SELF_KEY}"
    chmod 644 "${SELF_CERT}"

    CERT_PATH="${SELF_CERT}"
    KEY_PATH="${SELF_KEY}"
    PIN_SHA256="$(cert_sha256_pin "${SELF_CERT}")"
    SNI="bing.com"
    ok "自签证书生成完成，指纹：${PIN_SHA256}"
}

# 准备 ACME 证书存放目录（hysteria 以非 root 用户运行，需要可写）
ensure_acme_dir() {
    install -d -m 0755 "${HY_HOME}"
    install -d -m 0700 "${ACME_DIR}"
    if id -u hysteria >/dev/null 2>&1; then
        chown -R hysteria:hysteria "${HY_HOME}" 2>/dev/null || true
    fi
    ok "ACME 证书目录：${ACME_DIR}"
}

# 交互选择证书方式，并收集对应参数
choose_cert_mode() {
    local choice
    while true; do
        echo
        echo -e "${CYAN}请选择 TLS 证书方式：${RESET}"
        echo "  1) ACME 自动申请 · HTTP 验证        [推荐] 需域名解析到本机，且放行 80/tcp"
        echo "  2) ACME 自动申请 · Cloudflare DNS   需 API Token，无需 80 端口，可搭配 CDN 代理"
        echo "  3) 使用已有证书文件                  自行上传或由 acme.sh 等工具签发"
        echo "  4) 自签证书（不推荐）                无域名时的兜底，输出 pinSHA256 证书指纹"
        echo
        safe_read choice "请输入选项 [1-4] (直接回车 = 默认 1): "
        choice="${choice:-1}"

        case "${choice}" in
        1)
            CERT_MODE="acme-http"
            ask_domain
            ask_email
            precheck_acme_http || continue
            HOST="${DOMAIN}"; SNI="${DOMAIN}"
            break
            ;;
        2)
            CERT_MODE="acme-dns-cf"
            ask_domain
            ask_email
            local token
            while true; do
                safe_read token "请输入 Cloudflare API Token (需 Zone:DNS:Edit 权限): "
                token="${token// /}"
                [[ -n "${token}" ]] && break
                warn "API Token 不能为空！"
            done
            CF_TOKEN="${token}"
            HOST="${DOMAIN}"; SNI="${DOMAIN}"
            ok "已配置 Cloudflare DNS-01 验证"
            break
            ;;
        3)
            CERT_MODE="manual"
            local c k
            while true; do
                safe_read c "请输入证书文件（.crt/.pem）的绝对路径: "
                if [[ -f "${c}" ]] && openssl x509 -in "${c}" -noout >/dev/null 2>&1; then
                    break
                fi
                warn "文件不存在或不是有效的 X.509 证书：${c}"
            done
            while true; do
                safe_read k "请输入私钥文件（.key）的绝对路径: "
                [[ -f "${k}" ]] && break
                warn "文件不存在：${k}"
            done
            CERT_PATH="${c}"; KEY_PATH="${k}"
            local cert_dom
            cert_dom="$(cert_first_domain "${CERT_PATH}")"
            local input
            safe_read input "请输入客户端连接使用的域名 (直接回车 = 证书中的 ${cert_dom:-无}): "
            DOMAIN="${input:-${cert_dom}}"
            if ! validate_domain "${DOMAIN}"; then
                warn "未能确定有效域名，将使用公网 IP 连接，可能导致证书校验失败。"
                DOMAIN=""
                HOST=""; SNI="${cert_dom}"
            else
                HOST="${DOMAIN}"; SNI="${DOMAIN}"
            fi
            if cert_is_selfsigned "${CERT_PATH}"; then
                warn "检测到该证书为自签证书，将同时输出 pinSHA256 指纹。"
                PIN_SHA256="$(cert_sha256_pin "${CERT_PATH}")"
            fi
            ok "使用已有证书：${CERT_PATH}"
            break
            ;;
        4)
            echo
            warn "自签证书不受客户端信任，需要客户端跳过证书校验。"
            warn "Xray-core 自 v26.2.6 起已移除 allowInsecure，2026-08-01 后彻底失效；"
            warn "v2rayN 等基于 Xray 的客户端将无法用 insecure 方式连接，请优先使用 ACME。"
            local go
            safe_read go "确认仍使用自签证书？(y/N): "
            if [[ "${go}" != "y" && "${go}" != "Y" ]]; then
                continue
            fi
            CERT_MODE="selfsigned"
            break
            ;;
        *)
            warn "无效选项：${choice}"
            ;;
        esac
    done
}


# ============================================================
#  安装 / 配置 公共步骤
# ============================================================

install_hysteria_core() {
    log "下载 Hysteria 2 安装脚本..."
    timeout ${TIMEOUT_CURL_DOWNLOAD} curl -fsSL https://get.hy2.sh/ -o /tmp/hy2_install.sh \
        || die "下载 Hysteria 2 安装脚本超时（${TIMEOUT_CURL_DOWNLOAD}s），请检查网络！"
    run_with_spinner ${TIMEOUT_HY2_INSTALL} "安装 Hysteria 2（官方脚本）..." \
        bash /tmp/hy2_install.sh \
        || die "Hysteria 2 安装失败！请检查网络连接。"
    rm -f /tmp/hy2_install.sh

    if ! command -v hysteria >/dev/null 2>&1; then
        die "Hysteria 2 安装后未找到可执行文件，请手动排查！"
    fi
    ok "Hysteria 2 安装完成：$(command -v hysteria)"
}

setup_sysctl() {
    log "写入 sysctl 优化：net.core.rmem_max=16777216..."
    cat > /etc/sysctl.d/99-hy2.conf <<'SYSCTL'
net.core.rmem_max=16777216
SYSCTL
    sysctl --system > /dev/null
    ok "sysctl 已生效"
}

# 根据 CERT_MODE 渲染 config.yaml 中的证书配置段
render_cert_block() {
    case "${CERT_MODE}" in
    acme-http)
        cat <<EOF
acme:
  domains:
    - $(yaml_quote "${DOMAIN}")
  email: $(yaml_quote "${EMAIL}")
  ca: ${CA_PROVIDER}
  dir: $(yaml_quote "${ACME_DIR}")
  type: http
  http:
    altPort: 80
EOF
        ;;
    acme-dns-cf)
        cat <<EOF
acme:
  domains:
    - $(yaml_quote "${DOMAIN}")
  email: $(yaml_quote "${EMAIL}")
  ca: ${CA_PROVIDER}
  dir: $(yaml_quote "${ACME_DIR}")
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: $(yaml_quote "${CF_TOKEN}")
EOF
        ;;
    manual|selfsigned)
        cat <<EOF
tls:
  cert: $(yaml_quote "${CERT_PATH}")
  key: $(yaml_quote "${KEY_PATH}")
EOF
        ;;
    *)
        die "内部错误：未知的证书模式 ${CERT_MODE}"
        ;;
    esac
}

write_config() {
    log "写入 ${CONFIG_FILE}..."
    install -d -m 0755 "${HY_DIR}"

    {
        echo "listen: :${PORT}"
        echo ""
        render_cert_block
        cat <<EOF

auth:
  type: password
  password: $(yaml_quote "${PASS}")

masquerade:
  type: proxy
  proxy:
    url: $(yaml_quote "${FAKE_URL}")
    rewriteHost: true

ignoreClientBandwidth: false
EOF
    } > "${CONFIG_FILE}"

    # 配置内含密码与 API Token，收紧权限（hysteria 以非 root 用户运行，需可读）
    if id -u hysteria >/dev/null 2>&1; then
        chown root:hysteria "${CONFIG_FILE}" 2>/dev/null || true
        chmod 640 "${CONFIG_FILE}"
    else
        chmod 600 "${CONFIG_FILE}"
    fi
    ok "配置文件写入完成"
}

setup_port_hopping() {
    local IFACE
    IFACE="$(get_default_iface || true)"
    [[ -n "${IFACE}" ]] && ok "检测到主网卡：${IFACE}" || warn "未能自动获取主网卡（不影响规则配置）"

    [[ "${ENABLE_MPORT}" != "yes" ]] && return 0

    local ipt_range
    ipt_range="$(echo "${MPORT}" | tr '-' ':')"
    log "配置 iptables：UDP ${MPORT} 重定向到 ${PORT}（NAT PREROUTING）..."
    if iptables -t nat -C PREROUTING -p udp --dport "${ipt_range}" -j REDIRECT --to-ports "${PORT}" >/dev/null 2>&1; then
        ok "iptables 规则已存在，跳过添加"
    else
        iptables -t nat -A PREROUTING -p udp --dport "${ipt_range}" -j REDIRECT --to-ports "${PORT}"
        ok "iptables 规则添加完成"
    fi

    log "持久化保存 iptables 规则..."
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save > /dev/null
        ok "规则已持久化（netfilter-persistent）"
    elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4
        ok "规则已保存到 /etc/iptables/rules.v4"
    else
        warn "未找到 netfilter-persistent 或 /etc/iptables，持久化可能失败"
    fi
}

start_service() {
    local SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

    if [[ ! -f "${SERVICE_PATH}" ]]; then
        if ! systemctl list-unit-files | grep -qE '^hysteria-server\.service'; then
            warn "未找到 ${SERVICE_PATH}，尝试列出相关 unit："
            systemctl list-unit-files | grep -E 'hysteria.*service' || true
            die "未检测到 hysteria-server.service，请确认官方安装脚本是否成功创建 systemd unit"
        fi
    fi

    log "设置 ${SERVICE_NAME} 开机自启并立即启动..."
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl enable --now "${SERVICE_NAME}" >/dev/null

    # ACME 首次申请证书需要几秒到几十秒，给服务留出签发时间再判定
    if [[ "${CERT_MODE}" == acme-* ]]; then
        log "等待 ACME 申请证书（首次签发通常需要 10-60 秒）..."
        local i
        for i in $(seq 1 30); do
            systemctl is-active --quiet "${SERVICE_NAME}" || break
            if compgen -G "${ACME_DIR}/*" >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
    fi

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "${SERVICE_NAME} 服务已启动"
    else
        warn "${SERVICE_NAME} 未处于 active 状态，输出状态："
        systemctl status "${SERVICE_NAME}" --no-pager || true
        if [[ "${CERT_MODE}" == acme-* ]]; then
            echo
            warn "证书申请失败的常见原因："
            warn "  · 域名未解析到本机，或 Cloudflare 开启了代理（小黄云）"
            warn "  · 80/tcp 未放行或被其他程序占用（HTTP-01 验证）"
            warn "  · Cloudflare API Token 权限不足（需 Zone:DNS:Edit）"
            warn "  · 同一域名短时间内申请过多，触发 Let's Encrypt 速率限制"
        fi
        die "服务启动失败，请检查日志：journalctl -u ${SERVICE_NAME} -e --no-pager"
    fi
}

# 生成客户端连接 URI 并保存
build_uri() {
    local enc_node enc_pass q
    enc_node="$(urlencode "${NODE_NAME}")"
    enc_pass="$(urlencode "${PASS}")"

    q="sni=${SNI}"
    if [[ -n "${PIN_SHA256}" ]]; then
        # 自签证书：客户端需跳过链校验，并通过指纹固定证书（Xray 系客户端的官方替代方案）
        q="${q}&insecure=1&pinSHA256=${PIN_SHA256}"
    fi
    [[ "${ENABLE_MPORT}" == "yes" ]] && q="${q}&mport=${MPORT}"

    URI="hysteria2://${enc_pass}@${HOST}:${PORT}/?${q}#${enc_node}"

    install -d -m 0755 "${HY_DIR}"
    echo "${URI}" > "${LINK_FILE}"
    chmod 600 "${LINK_FILE}"
    ok "订阅链接已保存到 ${LINK_FILE}"
}

# 证书方式的中文描述
cert_mode_desc() {
    case "${CERT_MODE}" in
    acme-http)   echo "ACME · HTTP-01 自动申请（${CA_PROVIDER}）" ;;
    acme-dns-cf) echo "ACME · Cloudflare DNS-01 自动申请（${CA_PROVIDER}）" ;;
    manual)      echo "已有证书文件：${CERT_PATH}" ;;
    selfsigned)  echo "自签证书（不受信任，需 pinSHA256 固定）" ;;
    *)           echo "未知" ;;
    esac
}

print_result() {
    local title="$1"
    local term_width border_line
    term_width=$(tput cols 2>/dev/null || echo 60)
    border_line=$(printf '═%.0s' $(seq 1 "${term_width}"))

    echo
    echo -e "${GREEN}${border_line}${RESET}"
    echo -e "${GREEN}  ✅  ${title}${RESET}"
    echo -e "${GREEN}${border_line}${RESET}"
    echo
    echo -e "  ${CYAN}连接地址        ${RESET} ${HOST}"
    echo -e "  ${CYAN}监听端口        ${RESET} ${PORT}"
    echo -e "  ${CYAN}密码            ${RESET} ${PASS}"
    echo -e "  ${CYAN}SNI             ${RESET} ${SNI}"
    echo -e "  ${CYAN}伪装网站        ${RESET} ${FAKE_URL}"
    echo -e "  ${CYAN}节点名称        ${RESET} ${NODE_NAME}"
    if [[ "${ENABLE_MPORT}" == "yes" ]]; then
        echo -e "  ${CYAN}端口跳跃        ${RESET} ${MPORT} → ${PORT}"
    fi
    echo -e "  ${CYAN}证书方式        ${RESET} $(cert_mode_desc)"
    if [[ -n "${PIN_SHA256}" ]]; then
        echo -e "  ${CYAN}证书指纹        ${RESET} ${PIN_SHA256}"
    fi
    if [[ "${CERT_MODE}" == acme-* ]]; then
        echo -e "  ${CYAN}证书存放        ${RESET} ${ACME_DIR}（由 Hysteria 自动续期）"
    fi
    echo -e "  ${CYAN}配置文件        ${RESET} ${CONFIG_FILE}"
    echo -e "  ${CYAN}订阅链接        ${RESET} ${LINK_FILE}"
    echo
    echo -e "  ${YELLOW}▶ 客户端连接 URI（复制后导入代理工具）：${RESET}"
    echo -e "  ${GREEN}${URI}${RESET}"
    echo
    if [[ "${CERT_MODE}" == "acme-http" ]]; then
        echo -e "  ${YELLOW}提示：证书续期同样走 HTTP-01，请保持 80/tcp 长期放行且不被占用。${RESET}"
    elif [[ "${CERT_MODE}" == "selfsigned" ]]; then
        echo -e "  ${YELLOW}提示：自签证书需客户端跳过校验，Xray-core 系客户端（v2rayN 等）可能已无法连接，${RESET}"
        echo -e "  ${YELLOW}      建议改用「ACME 自动申请」方式重新部署。${RESET}"
    fi
    echo
    echo -e "  ${CYAN}🔗 项目地址：${RESET}https://github.com/Owenwoow/hy2-quick-install"
    echo -e "  ${CYAN}🔗 Hysteria 2 官方文档：${RESET}https://v2.hysteria.network/"
    echo
    echo -e "${GREEN}${border_line}${RESET}"
}


# ============================================================
#  交互输入（安装参数）
# ============================================================

ask_password() {
    local input
    safe_read input "请输入密码 (直接回车 = 自动生成 20 位强随机密码): "
    if [[ -z "${input}" ]]; then
        PASS="$(gen_pass_20)"
        ok "已生成随机密码：${PASS}"
    else
        PASS="${input}"
        ok "使用用户提供的密码"
    fi
}

ask_port() {
    local input
    while true; do
        safe_read input "请输入 Hysteria 2 监听端口 (直接回车 = 默认 443): "
        PORT="${input:-443}"
        if [[ ! "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
            warn "格式错误：端口必须是 1-65535 之间的纯数字！"
            continue
        fi
        if ss -uln | grep -qwE ":${PORT}"; then
            warn "端口冲突：UDP ${PORT} 已被其他程序占用！请重新输入。"
            continue
        fi
        ok "监听端口：${PORT}"
        break
    done
}

# 自签证书 / 无域名场景下询问公网 IP
ask_public_ip() {
    local auto_ip input
    log "正在获取公网 IPv4..."
    auto_ip="$(get_public_ipv4 2>/dev/null || true)"
    if [[ -n "${auto_ip}" ]]; then
        safe_read input "检测到公网 IP: ${auto_ip}，确认请直接回车 或 输入其他 IP 覆盖: "
        HOST="${input:-${auto_ip}}"
    else
        safe_read input "自动获取公网 IP 失败，请手动输入服务器公网 IP: "
        [[ -z "${input}" ]] && die "公网 IP 不能为空"
        HOST="${input}"
    fi
    ok "服务器 IP：${HOST}"
}

ask_masquerade() {
    local input
    safe_read input "请输入伪装网站的 URL (直接回车 = 默认 https://www.bing.com): "
    FAKE_URL="${input:-https://www.bing.com}"
    ok "伪装网站：${FAKE_URL}"
}

ask_node_name() {
    local input
    safe_read input "请输入节点名称 (直接回车 = 自动生成随机名称): "
    if [[ -z "${input}" ]]; then
        NODE_NAME="hy2-$(printf "%04d" $((RANDOM % 10000)))"
        ok "已生成随机节点名：${NODE_NAME}"
    else
        NODE_NAME="${input}"
        ok "使用用户提供的节点名：${NODE_NAME}"
    fi
}

# 校验端口跳跃范围，合法返回 0
validate_mport() {
    local range="$1" start end
    if [[ ! "${range}" =~ ^[0-9]+-[0-9]+$ ]]; then
        warn "格式错误：跳跃范围必须使用减号连接（例如 20000-20100）！"
        return 1
    fi
    start="${range%-*}"
    end="${range#*-}"
    if [ "${start}" -ge "${end}" ]; then
        warn "起始端口必须小于结束端口！"; return 1
    fi
    if [ "${start}" -lt 1 ] || [ "${end}" -gt 65535 ]; then
        warn "端口号必须在 1-65535 之间！"; return 1
    fi
    if [ "${PORT}" -ge "${start}" ] && [ "${PORT}" -le "${end}" ]; then
        warn "跳跃范围不能包含主监听端口 ${PORT}！"; return 1
    fi
    return 0
}

ask_port_hopping() {
    local input_jump input_mport
    safe_read input_jump "是否启用 UDP 端口跳跃？(直接回车 = 启用 / 输入 n = 不启用): "
    input_jump="${input_jump:-y}"
    if [[ "${input_jump}" != "y" && "${input_jump}" != "Y" ]]; then
        ENABLE_MPORT="no"
        log "不启用端口跳跃"
        return
    fi
    while true; do
        safe_read input_mport "请输入 UDP 端口跳跃范围 (直接回车 = 默认 20000-20100): "
        MPORT="${input_mport:-20000-20100}"
        validate_mport "${MPORT}" || continue
        ENABLE_MPORT="yes"
        ok "将启用端口跳跃：${MPORT} -> ${PORT}"
        break
    done
}


# ============================================================
#  安装主逻辑（自定义安装）
# ============================================================
Install_Hy2() {
    local CONFIRM

    # 检查服务是否存在
    if [[ -f "/etc/systemd/system/${SERVICE_NAME}" ]]; then
        warn "检测到 Hysteria 2 服务已存在！"
        safe_read CONFIRM "是否覆盖安装？(y/n, 默认: n): "
        CONFIRM="${CONFIRM:-n}"
        if [[ "${CONFIRM}" != "y" ]]; then
            log "已取消安装。"
            return
        fi
    fi

    dep_install

    log "========== Hysteria 2 一键部署脚本 =========="

    # 1) 证书方式（决定连接地址与 SNI）
    choose_cert_mode
    [[ -z "${HOST}" ]] && ask_public_ip

    # 2) 其余参数
    ask_password
    ask_port
    ask_masquerade
    ask_node_name
    ask_port_hopping

    # 3) 安装与配置
    install_hysteria_core
    if [[ "${CERT_MODE}" == "selfsigned" ]]; then
        setup_selfsigned_cert
    elif [[ "${CERT_MODE}" == acme-* ]]; then
        ensure_acme_dir
    fi
    setup_sysctl
    write_config
    setup_port_hopping
    start_service
    build_uri
    print_result "Hysteria 2 部署完成"
}


# ============================================================
#  快速安装（默认参数 + 命令行传参，缺少域名时才交互）
# ============================================================
Quick_Install_Hy2() {
    local term_width border_line
    term_width=$(tput cols 2>/dev/null || echo 60)
    border_line=$(printf '─%.0s' $(seq 1 "${term_width}"))

    echo
    echo -e "${CYAN}${border_line}${RESET}"
    echo -e "${CYAN}  ⚡  快速安装模式 — 除必要信息外全部使用默认值${RESET}"
    echo -e "${CYAN}${border_line}${RESET}"
    echo

    dep_install

    # ---------- 验证关键依赖是否安装成功 ----------
    log "校验关键依赖..."
    local check_failed=0 pkg
    for pkg in curl wget openssl iptables; do
        if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
            warn "依赖 ${pkg} 安装失败或未找到！"
            check_failed=1
        fi
    done
    [[ ${check_failed} -eq 1 ]] && die "依赖校验未通过，请检查软件源后重试。"
    ok "所有关键依赖校验通过"
    echo

    # ---------- 证书方式：由命令行参数决定 ----------
    if [[ "${ARG_SELF_SIGNED}" == "yes" ]]; then
        CERT_MODE="selfsigned"
        warn "已指定 --self-signed，将使用自签证书（不受信任，仅作兜底）。"
    elif [[ -n "${ARG_CF_TOKEN}" ]]; then
        CERT_MODE="acme-dns-cf"
        CF_TOKEN="${ARG_CF_TOKEN}"
    else
        CERT_MODE="acme-http"
    fi

    if [[ "${CERT_MODE}" == acme-* ]]; then
        if [[ -n "${ARG_DOMAIN}" ]]; then
            validate_domain "${ARG_DOMAIN}" || die "域名格式不合法：${ARG_DOMAIN}"
            DOMAIN="${ARG_DOMAIN}"
            ok "域名：${DOMAIN}"
        else
            warn "未通过 -d/--domain 指定域名，ACME 申请证书必须提供域名。"
            ask_domain
        fi

        EMAIL="${ARG_EMAIL:-admin@${DOMAIN}}"
        validate_email "${EMAIL}" || die "邮箱格式不合法：${EMAIL}"
        ok "ACME 邮箱：${EMAIL}"

        HOST="${DOMAIN}"; SNI="${DOMAIN}"
        if [[ "${CERT_MODE}" == "acme-http" ]]; then
            if ! precheck_acme_http; then
                warn "已取消安装。"
                return
            fi
        fi
    else
        HOST="$(get_public_ipv4 2>/dev/null || true)"
        [[ -z "${HOST}" ]] && die "无法自动获取公网 IP，请使用选项 1（自定义安装）手动输入。"
    fi

    [[ -n "${ARG_CA}" ]] && CA_PROVIDER="${ARG_CA}"

    # ---------- 其余参数：命令行优先，否则用默认值 ----------
    PASS="${ARG_PASS:-$(gen_pass_20)}"
    PORT="${ARG_PORT:-443}"
    if [[ ! "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
        die "端口不合法：${PORT}"
    fi
    FAKE_URL="${ARG_FAKE:-https://www.bing.com}"
    NODE_NAME="${ARG_NAME:-hy2-$(printf "%04d" $((RANDOM % 10000)))}"

    if [[ "${ARG_MPORT}" == "off" || "${ARG_MPORT}" == "no" ]]; then
        ENABLE_MPORT="no"
    else
        MPORT="${ARG_MPORT:-20000-20100}"
        validate_mport "${MPORT}" || die "端口跳跃范围不合法：${MPORT}"
        ENABLE_MPORT="yes"
    fi

    echo
    echo -e "  ${CYAN}配置参数如下：${RESET}"
    echo -e "  ${CYAN}连接地址        ${RESET} ${HOST}"
    echo -e "  ${CYAN}监听端口        ${RESET} ${PORT}"
    echo -e "  ${CYAN}密码            ${RESET} ${PASS}"
    echo -e "  ${CYAN}伪装网站        ${RESET} ${FAKE_URL}"
    echo -e "  ${CYAN}节点名称        ${RESET} ${NODE_NAME}"
    [[ "${ENABLE_MPORT}" == "yes" ]] && echo -e "  ${CYAN}端口跳跃        ${RESET} ${MPORT} → ${PORT}"
    echo -e "  ${CYAN}证书方式        ${RESET} $(cert_mode_desc)"
    echo

    install_hysteria_core
    if [[ "${CERT_MODE}" == "selfsigned" ]]; then
        setup_selfsigned_cert
    else
        ensure_acme_dir
    fi
    setup_sysctl
    write_config
    setup_port_hopping
    start_service
    build_uri
    print_result "Hysteria 2 快速安装完成"
}


# ============================================================
#  读取订阅链接
# ============================================================
Read_Link() {
    echo
    log "========== 读取订阅链接 =========="

    # 检测 Hysteria 2 是否已安装（OR 关系：任意一个检测到即认为已安装）
    if ! command -v hysteria > /dev/null 2>&1; then
        if ! systemctl list-unit-files 2>/dev/null | grep -q '^hysteria-server\.service'; then
            warn "未检测到 Hysteria 2 安装，请先执行安装操作！"
            return
        fi
    fi

    if [[ -f "${LINK_FILE}" && -s "${LINK_FILE}" ]]; then
        ok "读取到已保存的订阅链接："
        echo
        echo -e "${GREEN}$(cat "${LINK_FILE}")${RESET}"
        echo
        return
    fi

    log "未找到已保存的链接，正在从配置文件重新生成..."
    [[ -f "${CONFIG_FILE}" ]] || die "未找到 ${CONFIG_FILE}，无法自动生成链接！"

    PORT="$(grep -E '^listen:' "${CONFIG_FILE}" | awk -F':' '{print $NF}' | tr -d ' "')"
    if [[ -z "${PORT}" || ! "${PORT}" =~ ^[0-9]+$ ]]; then
        die "无法从 config.yaml 中解析出有效端口，请手动检查配置文件！"
    fi
    PASS="$(yaml_unquote "$(grep -E '^ *password:' "${CONFIG_FILE}" | head -1 | sed 's/^ *password: *//')")"

    if grep -qE '^acme:' "${CONFIG_FILE}"; then
        # ACME 模式：取 acme.domains 的第一个域名作为连接地址与 SNI
        CERT_MODE="acme-http"
        grep -qE '^ *type: *dns' "${CONFIG_FILE}" && CERT_MODE="acme-dns-cf"
        DOMAIN="$(yaml_unquote "$(awk '/^acme:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^ *- /{sub(/^ *- */,""); print; exit}' "${CONFIG_FILE}")")"
        [[ -z "${DOMAIN}" ]] && die "无法从 config.yaml 的 acme.domains 中解析出域名！"
        HOST="${DOMAIN}"; SNI="${DOMAIN}"
        ok "检测到 ACME 证书模式，域名：${DOMAIN}"
    else
        # 手动 / 自签证书模式
        CERT_PATH="$(yaml_unquote "$(awk '/^tls:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^ *cert:/{sub(/^ *cert: */,""); print; exit}' "${CONFIG_FILE}")")"
        [[ -z "${CERT_PATH}" || ! -f "${CERT_PATH}" ]] && die "无法定位配置中的证书文件，请手动检查配置文件！"
        SNI="$(cert_first_domain "${CERT_PATH}")"
        if cert_is_selfsigned "${CERT_PATH}"; then
            CERT_MODE="selfsigned"
            PIN_SHA256="$(cert_sha256_pin "${CERT_PATH}")"
            HOST="$(get_public_ipv4 2>/dev/null || true)"
            if [[ -z "${HOST}" ]]; then
                safe_read HOST "自动获取公网 IP 失败，请手动输入服务器公网 IP: "
                [[ -z "${HOST}" ]] && die "公网 IP 不能为空"
            fi
            warn "检测到自签证书，链接中将带 insecure=1 与 pinSHA256 指纹。"
        else
            CERT_MODE="manual"
            HOST="${SNI}"
            ok "检测到受信任证书，域名：${SNI}"
        fi
    fi

    # 检测端口跳跃规则
    if command -v iptables > /dev/null 2>&1; then
        local jump_rule
        jump_rule="$(iptables -t nat -L PREROUTING -n 2>/dev/null \
            | awk '/redir ports/{match($0,/[0-9]+:[0-9]+/); if(RLENGTH>0) print substr($0,RSTART,RLENGTH)}' \
            | head -1 || true)"
        if [[ -n "${jump_rule}" ]]; then
            MPORT="$(echo "${jump_rule}" | tr ':' '-')"
            ENABLE_MPORT="yes"
            ok "检测到端口跳跃规则：${MPORT}"
        fi
    fi

    NODE_NAME="hy2-$(printf "%04d" $((RANDOM % 10000)))"
    build_uri
    echo
    echo -e "${GREEN}${URI}${RESET}"
    echo
}


# ============================================================
#  卸载与环境清理
# ============================================================
Uninstall_Hy2() {
    echo
    log "========== Hysteria 2 卸载与环境清理 =========="

    # 1) 检查并停止服务
    log "检查 systemd 服务：${SERVICE_NAME} ..."
    if [[ -f "/etc/systemd/system/${SERVICE_NAME}" ]] || command -v hysteria >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            log "检测到服务正在运行，尝试停止..."
            systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
            ok "服务已停止"
        else
            ok "检测到遗留的服务文件或程序，准备清理"
        fi

        log "调用官方卸载脚本（--remove）..."
        bash <(curl -fsSL https://get.hy2.sh/) --remove >/dev/null 2>&1 || true
        ok "基础服务文件已移除"
    else
        warn "未检测到 Hysteria 服务安装，跳过服务主体卸载步骤"
    fi

    # 2) 深度清理残余文件和用户（含 ACME 证书目录）
    log "清理配置文件、证书、ACME 缓存及内核优化残留..."
    rm -rf "${HY_DIR}"
    rm -rf "${HY_HOME}"
    rm -f /etc/sysctl.d/99-hy2.conf
    sysctl --system >/dev/null 2>&1 || true
    if id -u hysteria >/dev/null 2>&1; then
        userdel -r hysteria >/dev/null 2>&1 || true
    fi
    ok "环境残留文件清理完成"

    # 3) 检查并清理 iptables 规则 (端口跳跃)
    Clean_Iptables

    echo
    ok "========== 环境清理与卸载流程结束 =========="
}


# ============================================================
#  清理端口跳跃规则 (iptables)
# ============================================================
Clean_Iptables() {
    log "检查 iptables NAT PREROUTING 规则..."
    if ! command -v iptables >/dev/null 2>&1; then
        warn "未找到 iptables，跳过防火墙规则检查"
        return
    fi

    local RULES
    RULES="$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null || true)"

    if ! echo "${RULES}" | awk 'BEGIN{has=0} $1 ~ /^[0-9]+$/ {has=1} END{exit (has?0:1)}'; then
        ok "未检测到 NAT PREROUTING 规则，跳过"
        return
    fi

    echo -e "${YELLOW}当前 NAT PREROUTING 规则如下（带行号）：${RESET}"
    echo "${RULES}"
    echo

    local DEL_INPUT=""
    safe_read DEL_INPUT "请输入要删除的规则行号 (支持多个用空格隔开; 输入 all 删除全部; 直接回车 = 不删除): "

    if [[ -z "${DEL_INPUT}" ]]; then
        warn "未输入行号，默认不删除任何规则"
        return
    fi

    local TO_DELETE=()
    if [[ "${DEL_INPUT}" == "all" || "${DEL_INPUT}" == "ALL" ]]; then
        # 获取所有规则行号，逆序排序（必须逆序以防行号变换错位）
        TO_DELETE=($(echo "${RULES}" | awk '$1 ~ /^[0-9]+$/ {print $1}' | sort -nr))
    else
        # 将用户输入的数字提取出来，并且逆序排序
        TO_DELETE=($(echo "${DEL_INPUT}" | tr ',' ' ' | awk '{for(i=1;i<=NF;i++) print $i}' | grep -E '^[0-9]+$' | sort -nr || true))
    fi

    if [[ ${#TO_DELETE[@]} -eq 0 ]]; then
        warn "输入无效或没有有效的规则行号，跳过删除"
        return
    fi

    local DELETED_COUNT=0 n
    for n in "${TO_DELETE[@]}"; do
        log "正在删除规则：iptables -t nat -D PREROUTING ${n}"
        if iptables -t nat -D PREROUTING "${n}" >/dev/null 2>&1; then
            ((DELETED_COUNT++))
        else
            warn "删除失败：行号 ${n} 可能已变化或规则不存在"
        fi
    done

    if [[ ${DELETED_COUNT} -gt 0 ]]; then
        ok "成功删除了 ${DELETED_COUNT} 条规则"
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
            ok "已持久化保存（netfilter-persistent）"
        else
            warn "未找到 netfilter-persistent，需手动保存规则"
        fi
    fi
}


# ============================================================
#  命令行参数
# ============================================================
show_help() {
    cat <<'USAGE'
Hysteria 2 一键部署脚本

用法：
  bash install.sh [动作] [选项]

动作（不指定则进入交互菜单）：
  --quick, --fast          快速安装（除必要信息外全部使用默认值）
  --link,  --info          输出已保存的客户端订阅链接
  --clean                  单独清理 iptables 端口跳跃规则
  --remove, --uninstall    卸载并清理环境
  -h, --help               显示本帮助

证书相关选项（配合 --quick 使用）：
  -d, --domain <域名>      申请证书用的域名，必须已解析到本机
  -e, --email <邮箱>       ACME 联系邮箱，默认 admin@<域名>
      --cf-token <Token>   Cloudflare API Token，指定后改用 DNS-01 验证
      --ca <letsencrypt|zerossl>
                           证书颁发机构，默认 letsencrypt
      --self-signed        使用自签证书（不受信任，仅作无域名时的兜底）

其他选项（配合 --quick 使用）：
  -p, --port <端口>        监听端口，默认 443
  -k, --password <密码>    连接密码，默认随机生成 20 位
  -m, --mport <范围|off>   UDP 端口跳跃范围，默认 20000-20100，off 表示不启用
      --masquerade <URL>   伪装网站，默认 https://www.bing.com
  -n, --name <节点名>      节点名称，默认随机生成

示例：
  # HTTP-01 验证，全自动无交互
  bash install.sh --quick -d hy2.example.com -e me@example.com

  # Cloudflare DNS-01 验证，无需放行 80 端口
  bash install.sh --quick -d hy2.example.com --cf-token cf_xxx

  # 自定义端口与跳跃范围
  bash install.sh --quick -d hy2.example.com -p 8443 -m 30000-31000
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --quick|--fast)         ACTION="quick" ;;
        --remove|--uninstall)   ACTION="remove" ;;
        --link|--info)          ACTION="link" ;;
        --clean)                ACTION="clean" ;;
        -h|--help)              show_help; exit 0 ;;
        -d|--domain)            ARG_DOMAIN="${2:-}";    shift ;;
        -e|--email)             ARG_EMAIL="${2:-}";     shift ;;
        --cf-token|--cloudflare-token)
                                ARG_CF_TOKEN="${2:-}";  shift ;;
        --ca)                   ARG_CA="${2:-}";        shift ;;
        --self-signed)          ARG_SELF_SIGNED="yes" ;;
        -p|--port)              ARG_PORT="${2:-}";      shift ;;
        -k|--password)          ARG_PASS="${2:-}";      shift ;;
        -m|--mport)             ARG_MPORT="${2:-}";     shift ;;
        --masquerade)           ARG_FAKE="${2:-}";      shift ;;
        -n|--name)              ARG_NAME="${2:-}";      shift ;;
        *)  die "未知参数：$1（使用 --help 查看用法）" ;;
        esac
        shift
    done

    if [[ -n "${ARG_CA}" && "${ARG_CA}" != "letsencrypt" && "${ARG_CA}" != "zerossl" ]]; then
        die "--ca 仅支持 letsencrypt 或 zerossl，当前值：${ARG_CA}"
    fi
}


# ============================================================
#  入口：参数触发 或 菜单触发
# ============================================================
menu() {
    # 参数触发（适合自动化）
    case "${ACTION}" in
    quick)  Quick_Install_Hy2; exit 0 ;;
    remove) Uninstall_Hy2;     exit 0 ;;
    link)   Read_Link;         exit 0 ;;
    clean)  Clean_Iptables;    exit 0 ;;
    esac

    # 菜单触发（交互使用）
    local CHOICE term_width border
    while true; do
        clear
        term_width=$(tput cols 2>/dev/null || echo 60)
        border=$(printf '═%.0s' $(seq 1 "${term_width}"))

        echo -e "${CYAN}${border}${RESET}"
        echo -e "${CYAN}  Hysteria 2 一键部署脚本  |  作者: Owen_W${RESET}"
        echo -e "${CYAN}  项目: https://github.com/Owenwoow/hy2-quick-install${RESET}"
        echo -e "${CYAN}${border}${RESET}"
        echo ""
        echo "  1) 自定义安装"
        echo "  2) 卸载/环境清理"
        echo "  3) 清理端口跳跃规则"
        echo "  4) 读取订阅链接"
        echo "  5) 快速安装"
        echo "  0) 退出脚本"
        echo ""
        echo -e "${CYAN}${border}${RESET}"
        safe_read CHOICE "请输入选项 [0-5] (直接回车 = 默认 1): "
        CHOICE="${CHOICE:-1}"

        case "${CHOICE}" in
        1) Install_Hy2 ;;
        2) Uninstall_Hy2 ;;
        3) Clean_Iptables ;;
        4) Read_Link ;;
        5) Quick_Install_Hy2 ;;
        0) ok "退出脚本"; exit 0 ;;
        *) warn "无效选项：${CHOICE}，请重新输入"; continue ;;
        esac

        # 操作完成后暂停，让用户看清输出内容再清屏返回菜单
        echo ""
        echo -e "${CYAN}────────────────────────────────────────${RESET}"
        # shellcheck disable=SC2162
        read -r -p "  按 Enter 键返回主菜单..."
    done
}


# ============================================================
#  主函数（入口）
# ============================================================
main() {
    parse_args "$@"
    check_root
    menu
}


# 执行主函数
main "$@"
