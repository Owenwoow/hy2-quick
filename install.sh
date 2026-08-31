#!/bin/bash
set -euo pipefail

# ============================================================
# Hysteria 2 一键部署脚本
# 项目地址: https://github.com/Owenwoow/hy2-quick-install
#
# TLS 证书策略：推荐通过 ACME 自动申请受信任证书（Let's Encrypt / ZeroSSL）。
# 自签证书仅用于快速安装与无域名场景，客户端兼容性有限。
# ============================================================

SCRIPT_VERSION="2.2"
REPO_URL="https://github.com/Owenwoow/hy2-quick-install"
RAW_URL="https://raw.githubusercontent.com/Owenwoow/hy2-quick-install/main/install.sh"
CLI_NAME="hy2"
CLI_PATH="/usr/local/bin/${CLI_NAME}"

# ---------- 颜色与制表字符 ----------
# 具体取值由 ui_detect_caps 按终端能力填充，这里只做声明
C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_GRAY=""; C_BOLD=""; C_RESET=""
UI_TL=""; UI_TR=""; UI_BL=""; UI_BR=""; UI_H=""; UI_V=""; UI_ARROW=""

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

# ---------- 部署状态 ----------
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

# 连续读到 EOF 的次数：用于识别「无终端 / 管道执行」并及时中止，避免死循环
READ_EOF_COUNT=0


# ============================================================
#  UI 层：所有输出都经由这里，保证风格统一
# ============================================================

UI_W=72

ui_init() {
    local cols
    cols="$(tput cols 2>/dev/null || echo 80)"
    [[ "${cols}" =~ ^[0-9]+$ ]] || cols=80
    UI_W=$(( cols - 4 ))
    (( UI_W > 72 )) && UI_W=72
    (( UI_W < 48 )) && UI_W=48
    # 末尾必须显式 return 0：上面的 (( )) 判定为假时返回 1，set -e 下会中止整个脚本
    return 0
}

# 探测终端能力，决定用哪套颜色与制表字符
#
# 颜色用 $'...' 生成真正的 ESC 字节，而不是字面的 "\033"。字面写法只有 echo -e
# 才会解释，printf '%s' 会把 \033[36m 原样打出来，提示符就会漏出转义序列。
#
# 制表字符只在 UTF-8 环境启用，且只用兼容面最广的直角框线（┌┐└┘│─）；
# 圆角框线、Braille 点阵、对勾叉号等字符在老终端或缺字体的环境会显示成方块，
# 因此消息前缀、转轮、箭头一律使用纯 ASCII。
ui_detect_caps() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
        C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
        C_CYAN=$'\033[36m';  C_GRAY=$'\033[90m'
        C_BOLD=$'\033[1m';   C_RESET=$'\033[0m'
    fi

    local enc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    case "${enc}" in
        *UTF-8*|*utf-8*|*UTF8*|*utf8*)
            UI_TL='┌'; UI_TR='┐'; UI_BL='└'; UI_BR='┘'
            UI_H='─';  UI_V='│';  UI_ARROW='->'
            ;;
        *)
            UI_TL='+'; UI_TR='+'; UI_BL='+'; UI_BR='+'
            UI_H='-';  UI_V='|';  UI_ARROW='->'
            ;;
    esac
    return 0
}

# 重复字符 n 次
ui_repeat() {
    local ch="$1" n="$2" out=""
    while (( n > 0 )); do out+="${ch}"; n=$(( n - 1 )); done
    printf '%s' "${out}"
}

# 计算字符串的终端显示宽度（CJK 字符占 2 列）
#
# 不能用 ${#s}：系统 locale 非 UTF-8 时（精简镜像常见 C/POSIX），${#s} 按字节而非
# 字符计数，中文宽度会被算成 3 倍，补白全部失效。这里直接遍历 UTF-8 字节：
# 跳过延续字节（0x80-0xBF），按首字节判定该字符占 1 列还是 2 列。
str_width() {
    printf '%s' "$1" | od -An -tu1 -v 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                b = $i
                if      (b < 128) w += 1      # ASCII
                else if (b < 192) continue    # UTF-8 延续字节，不计
                else if (b < 224) w += 1      # 2 字节：拉丁扩展等
                else if (b < 240) w += 2      # 3 字节：CJK、全角标点
                else              w += 2      # 4 字节：emoji
            }
        }
        END { print w + 0 }'
}

# 补足空格到指定显示宽度
# 注意：必须直接输出，不能写成 $(ui_pad ...)——命令替换会剥离尾部空格，补白会全部失效
ui_pad() {
    local s="$1" target="$2" w
    w="$(str_width "${s}")"
    printf '%s' "${s}"
    (( target > w )) && printf '%*s' $(( target - w )) ''
    return 0
}

ui_blank() { echo; }

# 顶部标题框
ui_header() {
    local title="$1" right="${2:-}"
    local inner=$(( UI_W - 2 ))
    local tw rw gap
    tw="$(str_width "${title}")"
    rw="$(str_width "${right}")"
    gap=$(( inner - tw - rw - 2 ))
    (( gap < 1 )) && gap=1

    printf '%s%s%s%s%s\n' "${C_CYAN}" "${UI_TL}" "$(ui_repeat "${UI_H}" "${inner}")" "${UI_TR}" "${C_RESET}"
    printf '%s%s%s %s%s%s' "${C_CYAN}" "${UI_V}" "${C_RESET}" "${C_BOLD}" "${title}" "${C_RESET}"
    printf '%*s' "${gap}" ''
    printf '%s%s%s %s%s%s\n' "${C_GRAY}" "${right}" "${C_RESET}" "${C_CYAN}" "${UI_V}" "${C_RESET}"
    printf '%s%s%s%s%s\n' "${C_CYAN}" "${UI_BL}" "$(ui_repeat "${UI_H}" "${inner}")" "${UI_BR}" "${C_RESET}"
}

# 整行分隔线
ui_rule() {
    printf '%s%s%s\n' "${C_GRAY}" "$(ui_repeat "${UI_H}" "${UI_W}")" "${C_RESET}"
}

# 小节标题：-- 标题 ------------
ui_section() {
    local title="$1" tw rest
    tw="$(str_width "${title}")"
    rest=$(( UI_W - tw - 4 ))
    (( rest < 2 )) && rest=2
    echo
    printf '%s%s%s %s%s%s %s%s%s\n' \
        "${C_GRAY}" "$(ui_repeat "${UI_H}" 2)" "${C_RESET}" \
        "${C_BOLD}" "${title}" "${C_RESET}" \
        "${C_GRAY}" "$(ui_repeat "${UI_H}" "${rest}")" "${C_RESET}"
}

# 键值对（键区固定 12 列，中文宽度感知）
ui_kv() {
    local key="$1" value="$2" note="${3:-}"
    printf '  %s' "${C_GRAY}"
    ui_pad "${key}" 12
    printf '%s  %s' "${C_RESET}" "${value}"
    [[ -n "${note}" ]] && printf '  %s%s%s' "${C_GRAY}" "${note}" "${C_RESET}"
    printf '\n'
}

# 菜单项
ui_item() {
    local key="$1" name="$2" desc="${3:-}"
    printf '  %s%s%s  ' "${C_CYAN}" "${key}" "${C_RESET}"
    ui_pad "${name}" 14
    [[ -n "${desc}" ]] && printf '%s%s%s' "${C_GRAY}" "${desc}" "${C_RESET}"
    printf '\n'
}

# ---------- 消息 ----------
# 前缀一律用等宽的 ASCII 标签：任何终端、任何字体都能正确显示，且天然对齐。
# 一律用 printf 而非 echo -e，避免消息内容里的反斜杠被再解释一次。
log()  { printf '  %s[*]%s %s\n'  "${C_GRAY}"   "${C_RESET}" "$*"; }
ok()   { printf '  %s[+]%s %s\n'  "${C_GREEN}"  "${C_RESET}" "$*"; }
warn() { printf '  %s[!]%s %s\n'  "${C_YELLOW}" "${C_RESET}" "$*"; }
note() { printf '      %s%s%s\n'  "${C_GRAY}"   "$*"         "${C_RESET}"; }
die()  { printf '  %s[x]%s %s\n'  "${C_RED}"    "${C_RESET}" "$*" >&2; exit 1; }

# 步骤标题
step() { printf '\n  %s==%s %s%s%s\n' "${C_CYAN}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}"; }


# ============================================================
#  输入层
# ============================================================

# 用户在任意输入处键入 b / back / 返回 时，输入函数返回 1，
# 由调用方决定回退到哪一层。所有交互函数都遵循这个约定：
#   返回 0 = 取得有效输入；返回 1 = 用户要求返回上一级
is_back_cmd() {
    case "$1" in
        b|B|back|BACK|Back|返回) return 0 ;;
        *) return 1 ;;
    esac
}

# 在小节开头提示一次返回方式，避免每个提示符都重复啰嗦
back_hint() {
    note "输入 ${C_BOLD}b${C_RESET}${C_GRAY} 可返回上一级"
}

# 读取一行输入。无终端或输入流结束时不会陷入死循环：
# 连续 3 次读到 EOF 即判定为非交互环境并中止，提示正确的运行方式。
# 内部变量统一加 __sr_ 前缀：bash 是动态作用域，若与调用方的局部变量重名，
# printf -v 会写进本函数的 local 而不是调用方的变量，导致读到的输入被静默丢弃。
safe_read() {
    local __sr_name="$1" __sr_prompt="$2" __sr_value=""

    if read -r -p "$(printf '  %s>%s %s' "${C_CYAN}" "${C_RESET}" "${__sr_prompt}")" __sr_value; then
        READ_EOF_COUNT=0
    else
        __sr_value=""
        READ_EOF_COUNT=$(( READ_EOF_COUNT + 1 ))
        echo
        if (( READ_EOF_COUNT >= 3 )); then
            echo
            warn "检测到输入流已结束，无法继续交互。"
            note "若使用了管道方式运行（curl ... | bash），请改用："
            note "  bash <(curl -fsSL ${RAW_URL})"
            note "或使用非交互的快速安装：bash install.sh --quick"
            die "已中止。"
        fi
    fi

    # 返回指令不写入目标变量，直接以返回 1 通知调用方回退
    if is_back_cmd "${__sr_value}"; then
        return 1
    fi

    printf -v "${__sr_name}" '%s' "${__sr_value}"
    return 0
}

# 带默认值的输入：提示里显示默认值，直接回车即采用。返回 1 表示用户要返回上一级
ask_default() {
    local __ad_name="$1" __ad_label="$2" __ad_default="$3" __ad_value=""
    safe_read __ad_value "${__ad_label} ${C_GRAY}[${__ad_default}]${C_RESET} " || return 1
    printf -v "${__ad_name}" '%s' "${__ad_value:-${__ad_default}}"
    return 0
}

# 是 / 否 询问，$2 为默认值（y 或 n）。输入 b 等同于「否」
ask_yes_no() {
    local label="$1" default="${2:-y}" input="" hint
    if [[ "${default}" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    safe_read input "${label} ${C_GRAY}[${hint}]${C_RESET} " || return 1
    input="${input:-${default}}"
    [[ "${input}" == "y" || "${input}" == "Y" ]]
}

# 暂停，等待用户按回车
ui_pause() {
    local _discard=""
    echo
    safe_read _discard "${C_GRAY}按 Enter 返回主菜单${C_RESET}" || true
    return 0
}


# ============================================================
#  通用工具
# ============================================================

# 带旋转动画 + 超时保护执行命令
# 用法：run_with_spinner <超时秒数> "提示文字" command arg1 arg2 ...
run_with_spinner() {
    local timeout_sec="$1"; shift
    local msg="$1"; shift
    local logfile="/tmp/hy2_run_$$.log"
    # 纯 ASCII 转轮：Braille 点阵在老终端和缺字体的环境会显示成方块
    local spin=('-' '\' '|' '/')
    local i=0 pid exit_code

    timeout "${timeout_sec}" "$@" > "${logfile}" 2>&1 &
    pid=$!

    while kill -0 "${pid}" 2>/dev/null; do
        printf '\r  %s%s%s  %s' "${C_CYAN}" "${spin[$(( i % ${#spin[@]} ))]}" "${C_RESET}" "${msg}"
        i=$(( i + 1 ))          # 注意：不可写成 ((i++))，i 为 0 时返回码为 1，set -e 下会中止脚本
        sleep 0.1
    done

    wait "${pid}"; exit_code=$?

    if (( exit_code == 0 )); then
        printf '\r  %s[+]%s %s\n' "${C_GREEN}" "${C_RESET}" "${msg}"
        rm -f "${logfile}"
        return 0
    fi

    if (( exit_code == 124 )); then
        printf '\r  %s[x]%s %s %s(超时 %ss)%s\n' \
            "${C_RED}" "${C_RESET}" "${msg}" "${C_RED}" "${timeout_sec}" "${C_RESET}"
    else
        printf '\r  %s[x]%s %s\n' "${C_RED}" "${C_RESET}" "${msg}"
    fi
    printf '      %s最后 20 行输出：%s\n' "${C_GRAY}" "${C_RESET}"
    tail -20 "${logfile}" 2>/dev/null | sed 's/^/     /' || true
    rm -f "${logfile}"
    return "${exit_code}"
}

gen_pass_20() {
    openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 20
}

get_default_iface() {
    ip route show default | awk '/^default/{print $5; exit}'
}

get_public_ipv4() {
    local ip="" src
    for src in https://api.ip.sb/ip https://api4.ipify.org https://ifconfig.me; do
        ip="$(curl -4 -s --max-time 5 "${src}" 2>/dev/null || true)"
        [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "${ip}"; return 0; }
    done
    echo ""
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

# 将任意字符串包装成 YAML 双引号标量
# 密码 / Token / URL 可能含 # : " \ 等字符，裸写会被 YAML 解析成注释或结构
yaml_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "${s}"
}

# yaml_quote 的逆操作
yaml_unquote() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
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

validate_email() {
    [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

validate_port() {
    local p="$1"
    [[ "${p}" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# 校验端口跳跃范围；失败时打印原因
validate_mport() {
    local range="$1" start end
    if [[ ! "${range}" =~ ^[0-9]+-[0-9]+$ ]]; then
        warn "格式错误：需使用减号连接，例如 20000-20100"
        return 1
    fi
    start="${range%-*}"; end="${range#*-}"
    if (( start >= end )); then
        warn "起始端口必须小于结束端口"; return 1
    fi
    if (( start < 1 || end > 65535 )); then
        warn "端口号必须在 1-65535 之间"; return 1
    fi
    if (( PORT >= start && PORT <= end )); then
        warn "跳跃范围不能包含主监听端口 ${PORT}"; return 1
    fi
    return 0
}

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

# TCP 端口空闲返回 0
check_tcp_port_free() {
    local p="$1"
    ! ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${p}\$"
}

# UDP 端口空闲返回 0
check_udp_port_free() {
    local p="$1"
    ! ss -uln 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${p}\$"
}

# 证书 SHA256 指纹（形如 AA:BB:...），供客户端 pinSHA256 使用
cert_sha256_pin() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr -d ' \r\n'
}

# 证书是否自签（subject == issuer）
cert_is_selfsigned() {
    local subj issuer
    subj="$(openssl x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
    issuer="$(openssl x509 -in "$1" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')"
    [[ -n "${subj}" && "${subj}" == "${issuer}" ]]
}

# 证书的第一个域名（优先 SAN，退化到 CN）
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

hy2_installed() {
    command -v hysteria >/dev/null 2>&1 \
        || systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"
}


# ============================================================
#  环境检查与依赖
# ============================================================
check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        die "请以 root 用户执行脚本"
    fi
    if ! grep -qiE "debian|ubuntu" /etc/os-release; then
        die "本脚本仅支持 Debian / Ubuntu 系统"
    fi
}

dep_install() {
    step "检查依赖"

    # ca-certificates 用于 ACME/HTTPS 校验，dnsutils 用于域名解析自检
    local required_pkgs=(curl wget openssl ca-certificates dnsutils iptables iptables-persistent)
    local missing_pkgs=() pkg

    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
            missing_pkgs+=("${pkg}")
        fi
    done

    if (( ${#missing_pkgs[@]} == 0 )); then
        ok "依赖已就绪"
        return 0
    fi

    log "缺少 ${#missing_pkgs[@]} 个依赖：${missing_pkgs[*]}"
    run_with_spinner "${TIMEOUT_APT_UPDATE}" "更新软件源索引" apt-get update \
        || die "apt-get update 失败，请检查软件源或 dpkg 锁"
    run_with_spinner "${TIMEOUT_APT_INSTALL}" "安装 ${missing_pkgs[*]}" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends "${missing_pkgs[@]}" \
        || die "依赖安装失败"
    ok "依赖安装完成"
}


# ============================================================
#  证书子系统
# ============================================================

ask_domain() {
    local input
    while true; do
        safe_read input "请输入已解析到本机的域名（如 hy2.example.com）： " || return 1
        input="${input// /}"
        if [[ -z "${input}" ]]; then
            warn "ACME 申请证书必须提供域名"
            continue
        fi
        if ! validate_domain "${input}"; then
            warn "域名格式不合法：${input}"
            continue
        fi
        DOMAIN="${input}"
        ok "域名  ${DOMAIN}"
        return 0
    done
}

ask_email() {
    local input
    while true; do
        ask_default input "ACME 联系邮箱：" "admin@${DOMAIN}" || return 1
        if ! validate_email "${input}"; then
            warn "邮箱格式不合法：${input}"
            continue
        fi
        EMAIL="${input}"
        ok "邮箱  ${EMAIL}"
        return 0
    done
}

# HTTP-01 前置自检：域名解析 + 80 端口占用。用户选择放弃时返回 1
precheck_acme_http() {
    local resolved server_ip has_warn=0

    log "检查域名解析..."
    resolved="$(resolve_domain_ipv4 "${DOMAIN}")"
    server_ip="$(get_public_ipv4 2>/dev/null || true)"

    if [[ -z "${resolved}" ]]; then
        warn "无法解析 ${DOMAIN} 的 A 记录，DNS 可能尚未生效"
        has_warn=1
    elif [[ -n "${server_ip}" && "${resolved}" != "${server_ip}" ]]; then
        warn "域名解析到 ${resolved}，与本机公网 IP ${server_ip} 不一致"
        note "若开启了 Cloudflare 代理（小黄云），HTTP-01 会失败，请改用 DNS 验证"
        has_warn=1
    else
        ok "域名解析正常  ${DOMAIN} -> ${resolved}"
    fi

    if check_tcp_port_free 80; then
        ok "80/tcp 端口空闲"
    else
        warn "80/tcp 已被占用"
        ss -ltnp 2>/dev/null | grep -E "[:.]80\s" | sed 's/^/     /' || true
        note "请先停止占用进程（nginx / apache 等），否则证书申请会失败"
        has_warn=1
    fi

    note "证书续期同样走 80/tcp，请确保云服务商安全组长期放行该端口"

    # 非交互模式（--quick）不阻塞，仅提示
    if (( has_warn == 1 )) && [[ "${ACTION}" != "quick" ]]; then
        ask_yes_no "存在告警，仍要继续？" "y" || return 1
    fi
    return 0
}

# 生成自签证书：CN=bing.com，含 SAN，有效期 100 年
setup_selfsigned_cert() {
    log "生成自签证书（CN=bing.com，有效期 100 年）..."
    install -d -m 0755 "${HY_DIR}"

    # 使用 -pkeyopt 指定曲线，避免依赖进程替换
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${SELF_KEY}" -out "${SELF_CERT}" \
        -subj "/CN=bing.com" \
        -addext "subjectAltName=DNS:bing.com,DNS:www.bing.com" \
        -days 36500 >/dev/null 2>&1 \
        || die "自签证书生成失败，请检查 openssl 是否可用"

    if id -u hysteria >/dev/null 2>&1; then
        chown hysteria:hysteria "${SELF_KEY}" "${SELF_CERT}"
    fi
    chmod 600 "${SELF_KEY}"
    chmod 644 "${SELF_CERT}"

    CERT_PATH="${SELF_CERT}"
    KEY_PATH="${SELF_KEY}"
    PIN_SHA256="$(cert_sha256_pin "${SELF_CERT}")"
    SNI="bing.com"
    ok "自签证书已生成"
}

# ACME 证书目录（hysteria 以非 root 用户运行，需可写）
ensure_acme_dir() {
    install -d -m 0755 "${HY_HOME}"
    install -d -m 0700 "${ACME_DIR}"
    if id -u hysteria >/dev/null 2>&1; then
        chown -R hysteria:hysteria "${HY_HOME}" 2>/dev/null || true
    fi
    ok "证书目录  ${ACME_DIR}"
}

# 交互选择证书方式，收集对应参数
choose_cert_mode() {
    local choice token c k cert_dom input

    while true; do
        ui_section "TLS 证书方式"
        ui_item "1" "ACME - HTTP"  "推荐。需域名解析到本机并放行 80/tcp"
        ui_item "2" "ACME - DNS"   "Cloudflare API Token，无需 80 端口"
        ui_item "3" "已有证书"     "自行上传或 acme.sh 等工具签发"
        ui_item "4" "自签证书"     "无域名时的兜底，客户端兼容性有限"
        ui_item "b" "返回"         "回到主菜单"
        echo
        # 这一级是本流程的顶层，输入 b 即返回主菜单
        ask_default choice "请选择 [1-4]：" "1" || return 1

        case "${choice}" in
        1)
            CERT_MODE="acme-http"
            back_hint
            ask_domain || continue
            ask_email  || continue
            precheck_acme_http || continue
            HOST="${DOMAIN}"; SNI="${DOMAIN}"
            return 0
            ;;
        2)
            CERT_MODE="acme-dns-cf"
            back_hint
            ask_domain || continue
            ask_email  || continue
            token=""
            while [[ -z "${token}" ]]; do
                safe_read token "Cloudflare API Token（需 Zone:DNS:Edit 权限）： " || continue 2
                token="${token// /}"
                [[ -z "${token}" ]] && warn "API Token 不能为空"
            done
            CF_TOKEN="${token}"
            HOST="${DOMAIN}"; SNI="${DOMAIN}"
            ok "已配置 Cloudflare DNS-01 验证"
            return 0
            ;;
        3)
            CERT_MODE="manual"
            back_hint
            while true; do
                safe_read c "证书文件（.crt/.pem）绝对路径： " || continue 2
                if [[ -f "${c}" ]] && openssl x509 -in "${c}" -noout >/dev/null 2>&1; then
                    break
                fi
                warn "文件不存在或不是有效的 X.509 证书"
            done
            while true; do
                safe_read k "私钥文件（.key）绝对路径： " || continue 2
                [[ -f "${k}" ]] && break
                warn "文件不存在：${k}"
            done
            CERT_PATH="${c}"; KEY_PATH="${k}"
            cert_dom="$(cert_first_domain "${CERT_PATH}")"
            ask_default input "客户端连接使用的域名：" "${cert_dom:-}" || continue
            DOMAIN="${input}"
            if validate_domain "${DOMAIN}"; then
                HOST="${DOMAIN}"; SNI="${DOMAIN}"
            else
                warn "未能确定有效域名，将使用公网 IP 连接，证书校验可能失败"
                DOMAIN=""; HOST=""; SNI="${cert_dom}"
            fi
            if cert_is_selfsigned "${CERT_PATH}"; then
                warn "该证书为自签证书，链接中将附带 pinSHA256 指纹"
                PIN_SHA256="$(cert_sha256_pin "${CERT_PATH}")"
            fi
            ok "使用已有证书  ${CERT_PATH}"
            return 0
            ;;
        4)
            echo
            warn "自签证书不受客户端信任，需要客户端跳过证书校验。"
            note "Xray-core 自 v26.2.6 起移除 allowInsecure，2026-08-01 后彻底失效，"
            note "v2rayN 等基于 Xray 的客户端可能无法连接。建议优先使用 ACME。"
            echo
            ask_yes_no "确认仍使用自签证书？" "n" || continue
            CERT_MODE="selfsigned"
            return 0
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
    step "安装 Hysteria 2"
    timeout "${TIMEOUT_CURL_DOWNLOAD}" curl -fsSL https://get.hy2.sh/ -o /tmp/hy2_install.sh \
        || die "下载官方安装脚本超时（${TIMEOUT_CURL_DOWNLOAD}s），请检查网络"
    run_with_spinner "${TIMEOUT_HY2_INSTALL}" "运行官方安装脚本" bash /tmp/hy2_install.sh \
        || die "Hysteria 2 安装失败，请检查网络连接"
    rm -f /tmp/hy2_install.sh

    command -v hysteria >/dev/null 2>&1 || die "安装后未找到 hysteria 可执行文件"
    ok "已安装  $(command -v hysteria)"
}

# 把脚本自身安装为 hy2 命令，之后可随时呼出管理面板
install_cli_shortcut() {
    local src=""

    # 通过 bash <(curl ...) 运行时 BASH_SOURCE 指向管道，需重新下载
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    fi

    if [[ -n "${src}" && -f "${src}" ]]; then
        if [[ "${src}" != "${CLI_PATH}" ]]; then
            install -m 0755 "${src}" "${CLI_PATH}" 2>/dev/null || { warn "写入 ${CLI_PATH} 失败"; return 0; }
        fi
    else
        timeout "${TIMEOUT_CURL_DOWNLOAD}" curl -fsSL "${RAW_URL}" -o "${CLI_PATH}" 2>/dev/null \
            || { warn "下载脚本到 ${CLI_PATH} 失败，跳过快捷命令安装"; return 0; }
        chmod 0755 "${CLI_PATH}"
    fi

    ok "快捷命令已安装  输入 ${C_BOLD}${CLI_NAME}${C_RESET} 即可再次打开管理面板"
}

setup_sysctl() {
    cat > /etc/sysctl.d/99-hy2.conf <<'SYSCTL'
net.core.rmem_max=16777216
SYSCTL
    sysctl --system > /dev/null
    ok "sysctl 优化已生效"
}

# 根据 CERT_MODE 渲染 config.yaml 的证书配置段
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

    # 配置含密码与 API Token，收紧权限（hysteria 以非 root 运行，需可读）
    if id -u hysteria >/dev/null 2>&1; then
        chown root:hysteria "${CONFIG_FILE}" 2>/dev/null || true
        chmod 640 "${CONFIG_FILE}"
    else
        chmod 600 "${CONFIG_FILE}"
    fi
    ok "配置已写入  ${CONFIG_FILE}"
}

setup_port_hopping() {
    local iface ipt_range
    iface="$(get_default_iface || true)"
    [[ -n "${iface}" ]] && log "主网卡  ${iface}"

    if [[ "${ENABLE_MPORT}" != "yes" ]]; then
        return 0
    fi

    ipt_range="$(echo "${MPORT}" | tr '-' ':')"
    if iptables -t nat -C PREROUTING -p udp --dport "${ipt_range}" -j REDIRECT --to-ports "${PORT}" >/dev/null 2>&1; then
        ok "端口跳跃规则已存在"
    else
        iptables -t nat -A PREROUTING -p udp --dport "${ipt_range}" -j REDIRECT --to-ports "${PORT}"
        ok "端口跳跃  UDP ${MPORT} -> ${PORT}"
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save > /dev/null 2>&1 || true
        ok "iptables 规则已持久化"
    elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4
        ok "iptables 规则已保存到 /etc/iptables/rules.v4"
    else
        warn "未找到 netfilter-persistent，重启后规则可能丢失"
    fi
}

start_service() {
    local i
    if [[ ! -f "/etc/systemd/system/${SERVICE_NAME}" ]] \
        && ! systemctl list-unit-files | grep -qE "^${SERVICE_NAME}"; then
        die "未检测到 ${SERVICE_NAME}，请确认官方安装脚本是否成功创建 systemd unit"
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl enable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true

    # ACME 首次签发需要时间，等待证书落盘或服务退出
    if [[ "${CERT_MODE}" == acme-* ]]; then
        log "等待 ACME 签发证书（首次通常 10-60 秒）..."
        for i in $(seq 1 30); do
            systemctl is-active --quiet "${SERVICE_NAME}" || break
            compgen -G "${ACME_DIR}/*" >/dev/null 2>&1 && break
            sleep 2
        done
    fi

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "服务已启动并设为开机自启"
        return 0
    fi

    warn "${SERVICE_NAME} 未处于 active 状态"
    systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null | sed 's/^/     /' || true
    if [[ "${CERT_MODE}" == acme-* ]]; then
        echo
        warn "证书申请失败的常见原因："
        note "- 域名未解析到本机，或 Cloudflare 开启了代理（小黄云）"
        note "- 80/tcp 未放行或被其他程序占用（HTTP-01 验证）"
        note "- Cloudflare API Token 权限不足（需 Zone:DNS:Edit）"
        note "- 同一域名短时间内申请过多，触发 Let's Encrypt 速率限制"
    fi
    die "服务启动失败，请查看日志：journalctl -u ${SERVICE_NAME} -e --no-pager"
}

# 生成客户端连接 URI 并保存
build_uri() {
    local enc_node enc_pass q
    enc_node="$(urlencode "${NODE_NAME}")"
    enc_pass="$(urlencode "${PASS}")"

    q="sni=${SNI}"
    if [[ -n "${PIN_SHA256}" ]]; then
        # 自签证书：客户端需跳过链校验，并以指纹固定证书
        q="${q}&insecure=1&pinSHA256=${PIN_SHA256}"
    fi
    [[ "${ENABLE_MPORT}" == "yes" ]] && q="${q}&mport=${MPORT}"

    URI="hysteria2://${enc_pass}@${HOST}:${PORT}/?${q}#${enc_node}"

    install -d -m 0755 "${HY_DIR}"
    echo "${URI}" > "${LINK_FILE}"
    chmod 600 "${LINK_FILE}"
    return 0
}

cert_mode_desc() {
    case "${CERT_MODE}" in
    acme-http)   echo "ACME - HTTP-01（${CA_PROVIDER}）" ;;
    acme-dns-cf) echo "ACME - Cloudflare DNS-01（${CA_PROVIDER}）" ;;
    manual)      echo "已有证书文件" ;;
    selfsigned)  echo "自签证书" ;;
    *)           echo "未知" ;;
    esac
}

# 部署结果面板
print_result() {
    local title="$1"

    echo
    ui_header "${title}" "Hysteria 2"
    echo
    ui_kv "连接地址" "${HOST}"
    ui_kv "监听端口" "${PORT}"
    ui_kv "密码" "${PASS}"
    ui_kv "SNI" "${SNI}"
    ui_kv "节点名称" "${NODE_NAME}"
    ui_kv "伪装网站" "${FAKE_URL}"
    [[ "${ENABLE_MPORT}" == "yes" ]] && ui_kv "端口跳跃" "${MPORT} -> ${PORT}"
    ui_kv "证书方式" "$(cert_mode_desc)"
    [[ -n "${PIN_SHA256}" ]] && ui_kv "证书指纹" "${PIN_SHA256:0:23}..." "完整值见配置输出"
    [[ "${CERT_MODE}" == acme-* ]] && ui_kv "证书目录" "${ACME_DIR}" "自动续期"
    ui_kv "配置文件" "${CONFIG_FILE}"
    ui_kv "订阅链接" "${LINK_FILE}"

    ui_section "客户端连接 URI"
    printf "  %s%s%s
" "${C_GREEN}" "${URI}" "${C_RESET}"

    ui_section "后续操作"
    ui_kv "管理面板" "${CLI_NAME}" "随时呼出本脚本"
    ui_kv "查看链接" "${CLI_NAME} --link"
    ui_kv "查看日志" "journalctl -u ${SERVICE_NAME} -e --no-pager"

    echo
    if [[ "${CERT_MODE}" == "acme-http" ]]; then
        note "证书续期同样走 HTTP-01，请保持 80/tcp 长期放行且不被占用。"
    elif [[ "${CERT_MODE}" == "selfsigned" ]]; then
        note "自签证书需客户端跳过校验，v2rayN 等 Xray 系客户端可能无法连接。"
        note "如需更好的兼容性，请改用自定义安装并填写域名申请 ACME 证书。"
    fi
    echo
    ui_rule
    printf '  %s项目地址  %s%s\n' "${C_GRAY}" "${REPO_URL}" "${C_RESET}"
    printf '  %s官方文档  https://v2.hysteria.network/%s\n' "${C_GRAY}" "${C_RESET}"
}


# ============================================================
#  安装参数交互
# ============================================================

ask_password() {
    local input
    safe_read input "连接密码（回车 = 随机生成 20 位）： " || return 1
    if [[ -z "${input}" ]]; then
        PASS="$(gen_pass_20)"
        ok "已生成随机密码  ${PASS}"
    else
        PASS="${input}"
        ok "已设置密码"
    fi
    return 0
}

ask_port() {
    local input
    while true; do
        ask_default input "监听端口：" "443" || return 1
        PORT="${input}"
        if ! validate_port "${PORT}"; then
            warn "端口必须是 1-65535 之间的数字"
            continue
        fi
        if ! check_udp_port_free "${PORT}"; then
            warn "UDP ${PORT} 已被占用，请换一个"
            continue
        fi
        ok "监听端口  ${PORT}"
        return 0
    done
}

ask_public_ip() {
    local auto_ip input
    log "获取公网 IPv4..."
    auto_ip="$(get_public_ipv4 2>/dev/null || true)"
    if [[ -n "${auto_ip}" ]]; then
        ask_default input "服务器公网 IP：" "${auto_ip}" || return 1
        HOST="${input}"
    else
        safe_read input "自动获取失败，请手动输入服务器公网 IP： " || return 1
        [[ -z "${input}" ]] && die "公网 IP 不能为空"
        HOST="${input}"
    fi
    ok "服务器 IP  ${HOST}"
    return 0
}

ask_masquerade() {
    ask_default FAKE_URL "伪装网站：" "https://www.bing.com" || return 1
    ok "伪装网站  ${FAKE_URL}"
    return 0
}

ask_node_name() {
    local input
    ask_default input "节点名称：" "hy2-$(printf '%04d' $(( RANDOM % 10000 )))" || return 1
    NODE_NAME="${input}"
    ok "节点名称  ${NODE_NAME}"
    return 0
}

ask_port_hopping() {
    local input
    if ! ask_yes_no "启用 UDP 端口跳跃？" "y"; then
        ENABLE_MPORT="no"
        log "不启用端口跳跃"
        return 0
    fi
    while true; do
        ask_default input "跳跃范围：" "20000-20100" || return 1
        MPORT="${input}"
        validate_mport "${MPORT}" || continue
        ENABLE_MPORT="yes"
        ok "端口跳跃  ${MPORT} -> ${PORT}"
        return 0
    done
}

# 安装前的覆盖确认；用户放弃时返回 1
confirm_overwrite() {
    hy2_installed || return 0
    warn "检测到 Hysteria 2 已安装"
    ask_yes_no "是否覆盖安装？" "n" || { log "已取消"; return 1; }
    return 0
}

# 安装收尾：写配置、起服务、出链接
finalize_install() {
    local title="$1"

    step "配置服务"
    if [[ "${CERT_MODE}" == "selfsigned" ]]; then
        setup_selfsigned_cert
    elif [[ "${CERT_MODE}" == acme-* ]]; then
        ensure_acme_dir
    fi
    setup_sysctl
    write_config
    setup_port_hopping
    install_cli_shortcut

    step "启动服务"
    start_service
    build_uri

    print_result "${title}"
    return 0
}


# ============================================================
#  1) 自定义安装
# ============================================================

# 基础参数收集：做成可回退的步骤机，任一步输入 b 都退回上一个问题，
# 在第一个问题上再输入 b 则返回 1，由调用方退回到证书方式选择。
collect_params() {
    # $1：是否需要询问公网 IP。必须由调用方一次性判定并传入——
    # 不能在循环里用 [[ -z "${HOST}" ]] 判断，否则回退到第一步时 HOST 已被填上，
    # 条件不再成立，这一步会被直接跳过，回退等于失效。
    local need_ip="$1" stage=1

    while true; do
        case ${stage} in
        1)
            if (( need_ip == 0 )); then
                stage=2; continue
            fi
            ask_public_ip || return 1
            ;;
        2) ask_password     || { stage=1; continue; } ;;
        3) ask_port         || { stage=2; continue; } ;;
        4) ask_masquerade   || { stage=3; continue; } ;;
        5) ask_node_name    || { stage=4; continue; } ;;
        6) ask_port_hopping || { stage=5; continue; } ;;
        *) return 0 ;;
        esac
        stage=$(( stage + 1 ))
    done
}

Install_Hy2() {
    ui_section "自定义安装"
    confirm_overwrite || return 0

    dep_install

    # 两级流程：证书方式 ⇄ 基础参数，任一级都能退回上一级或主菜单
    local need_ip
    while true; do
        choose_cert_mode || return 0        # 在证书方式选择处返回 = 回主菜单

        # 自签 / 未确定域名时才需要询问公网 IP；ACME 模式下连接地址就是域名
        need_ip=0
        [[ -z "${HOST}" ]] && need_ip=1

        ui_section "基础参数"
        back_hint
        if collect_params "${need_ip}"; then
            break
        fi
        # 基础参数第一项再按 b：清空证书选择，回到证书方式菜单
        CERT_MODE=""; DOMAIN=""; EMAIL=""; CF_TOKEN=""
        CERT_PATH=""; KEY_PATH=""; PIN_SHA256=""; HOST=""; SNI=""
    done

    install_hysteria_core
    finalize_install "部署完成"
    return 0
}


# ============================================================
#  2) 快速安装（默认自签、全自动；传入域名则走 ACME）
# ============================================================
Quick_Install_Hy2() {
    ui_section "快速安装"

    if [[ "${ACTION}" != "quick" ]]; then
        confirm_overwrite || return 0
    fi

    # 证书方式：默认自签，指定域名或 CF Token 时改走 ACME
    if [[ -n "${ARG_CF_TOKEN}" ]]; then
        CERT_MODE="acme-dns-cf"
        CF_TOKEN="${ARG_CF_TOKEN}"
    elif [[ -n "${ARG_DOMAIN}" && "${ARG_SELF_SIGNED}" != "yes" ]]; then
        CERT_MODE="acme-http"
    else
        CERT_MODE="selfsigned"
    fi

    if [[ "${CERT_MODE}" == "selfsigned" ]]; then
        warn "快速安装使用自签证书，客户端兼容性有限"
        note "v2rayN 等 Xray 系客户端可能无法连接。"
        note "如需最佳兼容性，请使用自定义安装并填写域名申请 ACME 证书。"
    fi

    dep_install

    if [[ "${CERT_MODE}" == acme-* ]]; then
        if [[ -n "${ARG_DOMAIN}" ]]; then
            validate_domain "${ARG_DOMAIN}" || die "域名格式不合法：${ARG_DOMAIN}"
            DOMAIN="${ARG_DOMAIN}"
        else
            ask_domain
        fi
        EMAIL="${ARG_EMAIL:-admin@${DOMAIN}}"
        validate_email "${EMAIL}" || die "邮箱格式不合法：${EMAIL}"
        HOST="${DOMAIN}"; SNI="${DOMAIN}"
        if [[ "${CERT_MODE}" == "acme-http" ]]; then
            precheck_acme_http || { log "已取消"; return 0; }
        fi
    else
        HOST="$(get_public_ipv4 2>/dev/null || true)"
        [[ -z "${HOST}" ]] && die "无法自动获取公网 IP，请改用自定义安装"
    fi

    [[ -n "${ARG_CA}" ]] && CA_PROVIDER="${ARG_CA}"

    PASS="${ARG_PASS:-$(gen_pass_20)}"
    PORT="${ARG_PORT:-443}"
    validate_port "${PORT}" || die "端口不合法：${PORT}"
    FAKE_URL="${ARG_FAKE:-https://www.bing.com}"
    NODE_NAME="${ARG_NAME:-hy2-$(printf '%04d' $(( RANDOM % 10000 )))}"

    if [[ "${ARG_MPORT}" == "off" || "${ARG_MPORT}" == "no" ]]; then
        ENABLE_MPORT="no"
    else
        MPORT="${ARG_MPORT:-20000-20100}"
        validate_mport "${MPORT}" || die "端口跳跃范围不合法：${MPORT}"
        ENABLE_MPORT="yes"
    fi

    echo
    ui_kv "连接地址" "${HOST}"
    ui_kv "监听端口" "${PORT}"
    ui_kv "证书方式" "$(cert_mode_desc)"
    [[ "${ENABLE_MPORT}" == "yes" ]] && ui_kv "端口跳跃" "${MPORT} -> ${PORT}"

    install_hysteria_core
    finalize_install "快速安装完成"
    return 0
}


# ============================================================
#  3) 读取订阅链接
# ============================================================
Read_Link() {
    ui_section "订阅链接"

    if ! hy2_installed; then
        warn "未检测到 Hysteria 2，请先安装"
        return 0
    fi

    if [[ -f "${LINK_FILE}" && -s "${LINK_FILE}" ]]; then
        echo
        printf "  %s%s%s
" "${C_GREEN}" "$(cat "${LINK_FILE}")" "${C_RESET}"
        echo
        return 0
    fi

    log "未找到缓存链接，正在从配置文件重建..."
    [[ -f "${CONFIG_FILE}" ]] || die "未找到 ${CONFIG_FILE}，无法生成链接"

    PORT="$(grep -E '^listen:' "${CONFIG_FILE}" | awk -F':' '{print $NF}' | tr -d ' "')"
    validate_port "${PORT}" || die "无法从配置解析出有效端口"
    PASS="$(yaml_unquote "$(grep -E '^ *password:' "${CONFIG_FILE}" | head -1 | sed 's/^ *password: *//')")"

    if grep -qE '^acme:' "${CONFIG_FILE}"; then
        CERT_MODE="acme-http"
        grep -qE '^ *type: *dns' "${CONFIG_FILE}" && CERT_MODE="acme-dns-cf"
        DOMAIN="$(yaml_unquote "$(awk '/^acme:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^ *- /{sub(/^ *- */,""); print; exit}' "${CONFIG_FILE}")")"
        [[ -z "${DOMAIN}" ]] && die "无法从 acme.domains 解析出域名"
        HOST="${DOMAIN}"; SNI="${DOMAIN}"
        ok "ACME 证书模式  ${DOMAIN}"
    else
        CERT_PATH="$(yaml_unquote "$(awk '/^tls:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^ *cert:/{sub(/^ *cert: */,""); print; exit}' "${CONFIG_FILE}")")"
        [[ -z "${CERT_PATH}" || ! -f "${CERT_PATH}" ]] && die "无法定位配置中的证书文件"
        SNI="$(cert_first_domain "${CERT_PATH}")"
        if cert_is_selfsigned "${CERT_PATH}"; then
            CERT_MODE="selfsigned"
            PIN_SHA256="$(cert_sha256_pin "${CERT_PATH}")"
            HOST="$(get_public_ipv4 2>/dev/null || true)"
            if [[ -z "${HOST}" ]]; then
                safe_read HOST "自动获取公网 IP 失败，请手动输入： " || return 0
                [[ -z "${HOST}" ]] && die "公网 IP 不能为空"
            fi
            warn "自签证书，链接将附带 insecure=1 与 pinSHA256"
        else
            CERT_MODE="manual"
            HOST="${SNI}"
            ok "受信任证书  ${SNI}"
        fi
    fi

    # 从 iptables 反查端口跳跃范围
    if command -v iptables >/dev/null 2>&1; then
        local jump_rule
        jump_rule="$(iptables -t nat -L PREROUTING -n 2>/dev/null \
            | awk '/redir ports/{match($0,/[0-9]+:[0-9]+/); if(RLENGTH>0) print substr($0,RSTART,RLENGTH)}' \
            | head -1 || true)"
        if [[ -n "${jump_rule}" ]]; then
            MPORT="$(echo "${jump_rule}" | tr ':' '-')"
            ENABLE_MPORT="yes"
            ok "端口跳跃  ${MPORT}"
        fi
    fi

    NODE_NAME="hy2-$(printf '%04d' $(( RANDOM % 10000 )))"
    build_uri
    echo
    printf "  %s%s%s
" "${C_GREEN}" "${URI}" "${C_RESET}"
    echo
    ok "已重新保存到 ${LINK_FILE}"
    return 0
}


# ============================================================
#  4) 清理端口跳跃规则
# ============================================================
Clean_Iptables() {
    ui_section "端口跳跃规则"

    if ! command -v iptables >/dev/null 2>&1; then
        warn "未找到 iptables，跳过"
        return 0
    fi

    local rules
    rules="$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null || true)"

    if ! echo "${rules}" | awk 'BEGIN{has=0} $1 ~ /^[0-9]+$/ {has=1} END{exit (has?0:1)}'; then
        ok "当前没有 NAT PREROUTING 规则"
        return 0
    fi

    echo
    echo "${rules}" | sed 's/^/  /'
    echo

    local input
    safe_read input "输入要删除的行号（空格分隔 / all 全删 / 回车跳过）： " || return 0
    if [[ -z "${input}" ]]; then
        log "未删除任何规则"
        return 0
    fi

    local to_delete=()
    if [[ "${input}" == "all" || "${input}" == "ALL" ]]; then
        # 逆序删除，避免行号错位
        mapfile -t to_delete < <(echo "${rules}" | awk '$1 ~ /^[0-9]+$/ {print $1}' | sort -nr)
    else
        mapfile -t to_delete < <(echo "${input}" | tr ',' ' ' | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nr || true)
    fi

    if (( ${#to_delete[@]} == 0 )); then
        warn "没有有效的规则行号"
        return 0
    fi

    local deleted=0 n
    for n in "${to_delete[@]}"; do
        if iptables -t nat -D PREROUTING "${n}" >/dev/null 2>&1; then
            deleted=$(( deleted + 1 ))   # 注意：不可写成 ((deleted++))，deleted 为 0 时返回码为 1
            ok "已删除规则 ${n}"
        else
            warn "删除失败：行号 ${n} 可能已变化"
        fi
    done

    if (( deleted > 0 )) && command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
        ok "已持久化保存"
    fi
    return 0
}


# ============================================================
#  5) 更新脚本
# ============================================================
Update_Script() {
    ui_section "更新脚本"

    local tmp="/tmp/hy2_update_$$.sh" new_ver

    log "从 GitHub 拉取最新版本..."
    if ! timeout "${TIMEOUT_CURL_DOWNLOAD}" curl -fsSL "${RAW_URL}" -o "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        warn "下载失败，请检查网络或稍后重试"
        return 0
    fi

    # 覆盖前先校验：必须是可执行的 bash 脚本，避免把错误页面写进 hy2
    if ! head -1 "${tmp}" | grep -q '^#!/bin/bash' || ! bash -n "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        warn "下载内容不是有效的脚本，已放弃更新"
        return 0
    fi

    new_ver="$(grep -m1 '^SCRIPT_VERSION=' "${tmp}" | cut -d'"' -f2)"
    echo
    ui_kv "当前版本" "${SCRIPT_VERSION}"
    ui_kv "最新版本" "${new_ver:-未知}"
    echo

    if [[ -n "${new_ver}" && "${new_ver}" == "${SCRIPT_VERSION}" ]]; then
        ok "已是最新版本"
        if ! ask_yes_no "仍要强制覆盖？" "n"; then
            rm -f "${tmp}"
            return 0
        fi
    elif ! ask_yes_no "确认更新到 ${new_ver:-最新版}？" "y"; then
        rm -f "${tmp}"
        log "已取消更新"
        return 0
    fi

    if ! install -m 0755 "${tmp}" "${CLI_PATH}" 2>/dev/null; then
        rm -f "${tmp}"
        warn "写入 ${CLI_PATH} 失败，请确认权限"
        return 0
    fi
    rm -f "${tmp}"
    ok "已更新  ${CLI_PATH}"
    note "服务端配置不受影响，无需重新部署"

    if ask_yes_no "立即以新版本重新载入？" "y"; then
        exec "${CLI_PATH}"
    fi
    return 0
}


# ============================================================
#  6) 卸载与环境清理
# ============================================================
Uninstall_Hy2() {
    ui_section "卸载与环境清理"

    if [[ "${ACTION}" != "remove" ]]; then
        ask_yes_no "确认卸载 Hysteria 2 并清理所有配置？" "n" || { log "已取消"; return 0; }
    fi

    if hy2_installed || [[ -f "/etc/systemd/system/${SERVICE_NAME}" ]]; then
        systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
        systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
        ok "服务已停止"
        run_with_spinner 120 "运行官方卸载脚本" \
            bash -c "curl -fsSL https://get.hy2.sh/ -o /tmp/hy2_rm.sh && bash /tmp/hy2_rm.sh --remove" \
            || warn "官方卸载脚本执行异常，继续清理残留"
        rm -f /tmp/hy2_rm.sh
    else
        warn "未检测到 Hysteria 服务，仅清理残留"
    fi

    rm -rf "${HY_DIR}" "${HY_HOME}"
    rm -f /etc/sysctl.d/99-hy2.conf
    rm -f "${CLI_PATH}"
    sysctl --system >/dev/null 2>&1 || true
    if id -u hysteria >/dev/null 2>&1; then
        userdel -r hysteria >/dev/null 2>&1 || true
    fi
    ok "配置、证书、ACME 缓存及快捷命令已清理"

    Clean_Iptables

    echo
    ok "卸载流程结束"
    return 0
}


# ============================================================
#  命令行参数
# ============================================================
show_help() {
    cat <<USAGE

  Hysteria 2 一键部署脚本  v${SCRIPT_VERSION}

  用法
    ${CLI_NAME} [动作] [选项]
    bash install.sh [动作] [选项]

  动作（省略则进入交互菜单）
    --quick, --fast          快速安装（自签证书，全自动无交互）
    --link,  --info          输出客户端订阅链接
    --clean                  清理 iptables 端口跳跃规则
    --update, --upgrade      从 GitHub 拉取最新脚本并覆盖 ${CLI_PATH}
    --remove, --uninstall    卸载并清理环境
    -h, --help               显示本帮助

  证书选项（配合 --quick；不指定域名时默认自签）
    -d, --domain <域名>      指定域名后改用 ACME HTTP-01 申请受信任证书
    -e, --email <邮箱>       ACME 联系邮箱，默认 admin@<域名>
        --cf-token <Token>   Cloudflare API Token，改用 DNS-01 验证
        --ca <letsencrypt|zerossl>
                             证书颁发机构，默认 letsencrypt
        --self-signed        强制使用自签证书

  其他选项（配合 --quick）
    -p, --port <端口>        监听端口，默认 443
    -k, --password <密码>    连接密码，默认随机 20 位
    -m, --mport <范围|off>   端口跳跃范围，默认 20000-20100
        --masquerade <URL>   伪装网站，默认 https://www.bing.com
    -n, --name <节点名>      节点名称，默认随机生成

  示例
    ${CLI_NAME} --quick                                  自签，一条命令装完
    ${CLI_NAME} --quick -d hy2.example.com               申请受信任证书
    ${CLI_NAME} --quick -d hy2.example.com --cf-token cf_xxx
    ${CLI_NAME} --link                                   查看订阅链接

USAGE
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
        --quick|--fast)         ACTION="quick" ;;
        --remove|--uninstall)   ACTION="remove" ;;
        --link|--info)          ACTION="link" ;;
        --clean)                ACTION="clean" ;;
        --update|--upgrade)     ACTION="update" ;;
        -h|--help)              show_help; exit 0 ;;
        -d|--domain)            ARG_DOMAIN="${2:-}";   shift ;;
        -e|--email)             ARG_EMAIL="${2:-}";    shift ;;
        --cf-token|--cloudflare-token)
                                ARG_CF_TOKEN="${2:-}"; shift ;;
        --ca)                   ARG_CA="${2:-}";       shift ;;
        --self-signed)          ARG_SELF_SIGNED="yes" ;;
        -p|--port)              ARG_PORT="${2:-}";     shift ;;
        -k|--password)          ARG_PASS="${2:-}";     shift ;;
        -m|--mport)             ARG_MPORT="${2:-}";    shift ;;
        --masquerade)           ARG_FAKE="${2:-}";     shift ;;
        -n|--name)              ARG_NAME="${2:-}";     shift ;;
        *)  die "未知参数：$1（使用 --help 查看用法）" ;;
        esac
        shift
    done

    if [[ -n "${ARG_CA}" && "${ARG_CA}" != "letsencrypt" && "${ARG_CA}" != "zerossl" ]]; then
        die "--ca 仅支持 letsencrypt 或 zerossl，当前值：${ARG_CA}"
    fi
    return 0
}


# ============================================================
#  菜单
# ============================================================

# 当前部署状态，显示在菜单顶部
status_line() {
    if ! hy2_installed; then
        printf '%s[未安装]%s' "${C_GRAY}" "${C_RESET}"
        return 0
    fi
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        printf '%s[运行中]%s' "${C_GREEN}" "${C_RESET}"
    else
        printf '%s[已停止]%s' "${C_RED}" "${C_RESET}"
    fi
    return 0
}

menu() {
    local choice

    while true; do
        clear 2>/dev/null || true
        echo
        ui_header "Hysteria 2 一键部署脚本" "v${SCRIPT_VERSION}"
        echo
        ui_kv "当前状态" "$(status_line)"
        echo
        ui_item "1" "自定义安装" "选择证书方式，逐项配置"
        ui_item "2" "快速安装"   "自签证书，全自动无交互"
        ui_item "3" "订阅链接"   "查看客户端连接 URI"
        ui_item "4" "端口跳跃"   "查看 / 清理 iptables 规则"
        ui_item "5" "更新脚本"   "从 GitHub 拉取最新版本"
        ui_item "6" "卸载清理"   "移除服务与全部配置"
        ui_item "0" "退出"
        echo
        ui_rule
        # 主菜单是最顶层，输入 b 无处可退，等同于停留在本页
        ask_default choice "请选择 [0-6]：" "1" || continue

        case "${choice}" in
        1) Install_Hy2 ;;
        2) Quick_Install_Hy2 ;;
        3) Read_Link ;;
        4) Clean_Iptables ;;
        5) Update_Script ;;
        6) Uninstall_Hy2 ;;
        0) echo; ok "已退出"; exit 0 ;;
        *) warn "无效选项：${choice}"; sleep 1; continue ;;
        esac

        ui_pause
    done
}


# ============================================================
#  入口
# ============================================================
main() {
    # 必须先探测终端能力：颜色与制表字符在此之前都是空串，任何提前的输出都会失色
    ui_detect_caps
    ui_init
    parse_args "$@"
    check_root

    case "${ACTION}" in
    quick)  Quick_Install_Hy2; exit 0 ;;
    remove) Uninstall_Hy2;     exit 0 ;;
    link)   Read_Link;         exit 0 ;;
    clean)  Clean_Iptables;    exit 0 ;;
    update) Update_Script;     exit 0 ;;
    esac

    menu
}

main "$@"
