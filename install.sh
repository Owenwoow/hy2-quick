#!/bin/bash
set -euo pipefail

# ============================================================
# Hysteria 2 一键部署脚本
# 项目地址: https://github.com/Owenwoow/hy2-quick-install
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
        printf "\r  ${RED}⏱${RESET} %s ${RED}（超时 ${timeout_sec}s，已中断）${RESET}\n" "${msg}"
        echo -e "${RED}可能原因：网络不佳或主机性能不足${RESET}"
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

# URL 片段编码（节点名中的特殊字符）
urlencode_fragment() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1" 2>/dev/null \
    || printf '%s' "$1"
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


# ---------- 依赖安装 ----------
dep_install() {
    log "正在检查并安装依赖..."

    # 所有必需的包列表
    local required_pkgs=(curl wget openssl iptables iptables-persistent)
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
#  公共安装核心逻辑（交互输入 + 安装 + 配置 + 服务 + URI）
# ============================================================
_do_install_core() {
    # 注意：调用方需已声明以下 local 变量：
    #   PASS PORT HOST FAKE_URL NODE_NAME ENABLE_MPORT mport
    #   ENC_NODE URI SERVICE_NAME SERVICE_PATH IFACE mport_start mport_end

    # ---------- 交互输入 ----------
    # 1) 密码
    local user_pass
    safe_read user_pass "请输入密码 (直接回车 = 自动生成 20 位强随机密码): "
    if [[ -z "${user_pass}" ]]; then
        PASS="$(gen_pass_20)"
        ok "已生成随机密码：${PASS}"
    else
        PASS="${user_pass}"
        ok "使用用户提供的密码"
    fi

    # 2) 端口
    local input_port
    while true; do
        safe_read input_port "请输入 Hysteria 2 监听端口 (直接回车 = 默认 443): "
        PORT=${input_port:-443}
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

    # 3) 公网 IP
    local auto_ip input_ip
    log "正在获取公网 IPv4..."
    auto_ip="$(get_public_ipv4 2>/dev/null || true)"
    if [[ -n "${auto_ip}" ]]; then
        safe_read input_ip "检测到公网 IP: ${auto_ip}，确认请直接回车 或 输入其他 IP 覆盖: "
        HOST="${input_ip:-${auto_ip}}"
    else
        safe_read input_ip "自动获取公网 IP 失败，请手动输入服务器公网 IP: "
        [[ -z "${input_ip}" ]] && die "公网 IP 不能为空"
        HOST="${input_ip}"
    fi
    ok "服务器 IP：${HOST}"

    # 4) 伪装网站
    local input_fake
    safe_read input_fake "请输入伪装网站的 URL (直接回车 = 默认 https://www.bing.com): "
    FAKE_URL="${input_fake:-https://www.bing.com}"
    ok "伪装网站：${FAKE_URL}"

    # 5) 节点名称
    local input_name
    safe_read input_name "请输入节点名称 (直接回车 = 自动生成随机名称): "
    if [[ -z "${input_name}" ]]; then
        NODE_NAME="hy2-$(printf "%04d" $((RANDOM % 10000)))"
        ok "已生成随机节点名：${NODE_NAME}"
    else
        NODE_NAME="${input_name}"
        ok "使用用户提供的节点名：${NODE_NAME}"
    fi

    # 6) 端口跳跃及格式/语义验证
    local input_jump input_mport mport_start mport_end
    safe_read input_jump "是否启用 UDP 端口跳跃？(直接回车 = 启用 / 输入 n = 不启用): "
    input_jump="${input_jump:-y}"
    if [[ "${input_jump}" == "y" || "${input_jump}" == "Y" ]]; then
        while true; do
            safe_read input_mport "请输入 UDP 端口跳跃范围 (直接回车 = 默认 20000-20100): "
            mport="${input_mport:-20000-20100}"
            if [[ ! "${mport}" =~ ^[0-9]+-[0-9]+$ ]]; then
                warn "格式错误：跳跃范围必须使用减号连接（例如 20000-20100）！"
                continue
            fi
            mport_start="${mport%-*}"
            mport_end="${mport#*-}"
            if [ "${mport_start}" -ge "${mport_end}" ]; then
                warn "起始端口必须小于结束端口！"; continue
            fi
            if [ "${mport_start}" -lt 1 ] || [ "${mport_end}" -gt 65535 ]; then
                warn "端口号必须在 1-65535 之间！"; continue
            fi
            if [ "${PORT}" -ge "${mport_start}" ] && [ "${PORT}" -le "${mport_end}" ]; then
                warn "跳跃范围不能包含主监听端口 ${PORT}！"; continue
            fi
            ENABLE_MPORT="yes"
            ok "将启用端口跳跃：${mport} -> ${PORT}"
            break
        done
    else
        ENABLE_MPORT="no"
        log "不启用端口跳跃"
    fi


    # ---------- 安装 Hysteria 2 ----------
    log "下载 Hysteria 2 安装脚本..."
    timeout ${TIMEOUT_CURL_DOWNLOAD} curl -fsSL https://get.hy2.sh/ -o /tmp/hy2_install.sh \
        || die "下载 Hysteria 2 安装脚本超时（${TIMEOUT_CURL_DOWNLOAD}s），请检查网络！"
    run_with_spinner ${TIMEOUT_HY2_INSTALL} "安装 Hysteria 2（官方脚本）..." \
        bash /tmp/hy2_install.sh \
        || die "Hysteria 2 安装失败！请检查网络连接。"
    rm -f /tmp/hy2_install.sh
    ok "Hysteria 2 安装完成"


    # ---------- 生成自签证书（CN=bing.com，100年） ----------
    log "生成自签证书（CN=bing.com，有效期100年）..."
    install -d -m 0755 /etc/hysteria

    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/server.key \
        -out    /etc/hysteria/server.crt \
        -subj   "/CN=bing.com" \
        -days   36500 >/dev/null 2>&1

    if id -u hysteria >/dev/null 2>&1; then
        chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
    else
        chmod 600 /etc/hysteria/server.key
        chmod 644 /etc/hysteria/server.crt
    fi
    ok "证书生成完成：/etc/hysteria/server.crt  /etc/hysteria/server.key"


    # ---------- sysctl 网络优化 ----------
    log "写入 sysctl 优化：net.core.rmem_max=16777216..."
    cat > /etc/sysctl.d/99-hy2.conf <<'EOF'
net.core.rmem_max=16777216
EOF
    sysctl --system > /dev/null
    ok "sysctl 已生效"


    # ---------- 写入配置文件 ----------
    log "写入 /etc/hysteria/config.yaml..."
    cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${PASS}

masquerade:
  type: proxy
  proxy:
    url: ${FAKE_URL}
    rewriteHost: true

ignoreClientBandwidth: false
EOF
    ok "配置文件写入完成"


    # ---------- 端口跳跃 iptables 规则 ----------
    local IFACE
    IFACE="$(get_default_iface || true)"
    [[ -n "${IFACE}" ]] && ok "检测到主网卡：${IFACE}" || warn "未能自动获取主网卡（不影响规则配置）"

    if [[ "${ENABLE_MPORT}" == "yes" ]]; then
        local ipt_range
        ipt_range="$(echo "${mport}" | tr '-' ':')"
        log "配置 iptables：UDP ${mport} 重定向到 ${PORT}（NAT PREROUTING）..."
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
    fi


    # ---------- 服务管理 ----------
    local SERVICE_NAME SERVICE_PATH
    SERVICE_NAME="hysteria-server.service"
    SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

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

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "${SERVICE_NAME} 服务已启动"
    else
        warn "${SERVICE_NAME} 未处于 active 状态，输出状态："
        systemctl status "${SERVICE_NAME}" --no-pager || true
        die "服务启动失败，请检查日志：journalctl -u ${SERVICE_NAME} -e --no-pager"
    fi


    # ---------- 生成客户端 URI ----------
    local ENC_NODE URI
    ENC_NODE="$(urlencode_fragment "${NODE_NAME}")"
    URI="hysteria2://${PASS}@${HOST}:${PORT}?sni=www.bing.com&insecure=1&allowInsecure=1"
    if [[ "${ENABLE_MPORT}" == "yes" ]]; then
        URI="${URI}&mport=${mport}#${ENC_NODE}"
    else
        URI="${URI}#${ENC_NODE}"
    fi

    # ---------- 保存链接到 link.bak ----------
    echo "${URI}" > /etc/hysteria/link.bak
    ok "订阅链接已保存到 /etc/hysteria/link.bak"

    # ---------- 格式化展示安装结果 ----------
    local term_width border_line
    term_width=$(tput cols 2>/dev/null || echo 60)
    border_line=$(printf '═%.0s' $(seq 1 "${term_width}"))

    echo
    echo -e "${GREEN}${border_line}${RESET}"
    echo -e "${GREEN}  ✅  Hysteria 2 部署完成${RESET}"
    echo -e "${GREEN}${border_line}${RESET}"
    echo
    echo -e "  ${CYAN}服务器 IP       ${RESET} ${HOST}"
    echo -e "  ${CYAN}监听端口        ${RESET} ${PORT}"
    echo -e "  ${CYAN}密码            ${RESET} ${PASS}"
    echo -e "  ${CYAN}伪装网站        ${RESET} ${FAKE_URL}"
    echo -e "  ${CYAN}节点名称        ${RESET} ${NODE_NAME}"
    if [[ "${ENABLE_MPORT}" == "yes" ]]; then
        echo -e "  ${CYAN}端口跳跃        ${RESET} ${mport} → ${PORT}"
    fi
    echo -e "  ${CYAN}证书            ${RESET} /etc/hysteria/server.crt  (自签，insecure)"
    echo -e "  ${CYAN}配置文件        ${RESET} /etc/hysteria/config.yaml"
    echo -e "  ${CYAN}订阅链接        ${RESET} /etc/hysteria/link.bak"
    echo
    echo -e "  ${YELLOW}▶ 客户端连接 URI（复制后导入代理工具）：${RESET}"
    echo -e "  ${GREEN}${URI}${RESET}"
    echo
    echo -e "  ${CYAN}🔗 项目地址：${RESET}https://github.com/Owenwoow/hy2-quick-install"
    echo -e "  ${CYAN}🔗 Hysteria 2 官方文档：${RESET}https://v2.hysteria.network/"
    echo
    echo -e "${GREEN}${border_line}${RESET}"
}


# ============================================================
#  安装主逻辑
# ============================================================
Install_Hy2() {
    local CONFIRM PASS PORT HOST FAKE_URL NODE_NAME ENABLE_MPORT mport

    # 检查服务是否存在
    if [[ -f "/etc/systemd/system/hysteria-server.service" ]]; then
        warn "检测到 Hysteria 2 服务已存在！"
        safe_read CONFIRM "是否覆盖安装？(y/n, 默认: n): "
        CONFIRM=${CONFIRM:-n}
        if [[ "${CONFIRM}" != "y" ]]; then
            log "已取消安装。"
            return
        fi
    fi

    # 安装环境和依赖
    dep_install

    log "========== Hysteria 2 一键部署脚本 =========="
    _do_install_core
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

    local LINK_FILE="/etc/hysteria/link.bak"

    if [[ -f "${LINK_FILE}" && -s "${LINK_FILE}" ]]; then
        ok "读取到已保存的订阅链接："
        echo
        echo -e "${GREEN}$(cat "${LINK_FILE}")${RESET}"
        echo
    else
        log "未找到已保存的链接，正在重新生成..."

        # 从配置文件读取参数
        local config="/etc/hysteria/config.yaml"
        if [[ ! -f "${config}" ]]; then
            die "未找到 /etc/hysteria/config.yaml，无法自动生成链接！"
        fi

        local PORT PASS
        PORT="$(grep '^listen:' "${config}" | awk -F':' '{print $NF}' | tr -d ' "')"
        if [[ -z "${PORT}" || ! "${PORT}" =~ ^[0-9]+$ ]]; then
            die "无法从 config.yaml 中解析出有效端口，请手动检查配置文件！"
        fi
        PASS="$(grep 'password:' "${config}" | awk '{print $2}' | tr -d '"')"
        local HOST
        HOST="$(get_public_ipv4 2>/dev/null || true)"

        if [[ -z "${HOST}" ]]; then
            safe_read HOST "自动获取公网 IP 失败，请手动输入服务器公网 IP: "
            [[ -z "${HOST}" ]] && die "公网 IP 不能为空"
        fi

        # 检测端口跳跃规则
        local mport_arg=""
        if command -v iptables > /dev/null 2>&1; then
            local jump_rule
            jump_rule="$(iptables -t nat -L PREROUTING -n 2>/dev/null \
                | awk '/redir ports/{match($0,/[0-9]+:[0-9]+/); if(RLENGTH>0) print substr($0,RSTART,RLENGTH)}' \
                | head -1 || true)"
            if [[ -n "${jump_rule}" ]]; then
                mport_arg="$(echo "${jump_rule}" | tr ':' '-')"
                ok "检测到端口跳跃规则：${mport_arg}"
            fi
        fi

        local NODE_NAME="hy2-$(printf "%04d" $((RANDOM % 10000)))"
        local ENC_NODE
        ENC_NODE="$(urlencode_fragment "${NODE_NAME}")"

        local URI
        URI="hysteria2://${PASS}@${HOST}:${PORT}?sni=www.bing.com&insecure=1&allowInsecure=1"
        if [[ -n "${mport_arg}" ]]; then
            URI="${URI}&mport=${mport_arg}#${ENC_NODE}"
        else
            URI="${URI}#${ENC_NODE}"
        fi

        # 保存链接
        install -d -m 0755 /etc/hysteria
        echo "${URI}" > "${LINK_FILE}"
        ok "订阅链接已生成并保存到 ${LINK_FILE}"
        echo
        echo -e "${GREEN}${URI}${RESET}"
        echo
    fi
}


# ============================================================
#  卸载与环境清理
# ============================================================
Uninstall_Hy2() {
    local SERVICE="hysteria-server.service"

    echo
    log "========== Hysteria 2 卸载与环境清理 =========="

    # 1) 检查并停止服务
    log "检查 systemd 服务：${SERVICE} ..."
    if [[ -f "/etc/systemd/system/${SERVICE}" ]] || command -v hysteria >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}"; then
        if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
            log "检测到服务正在运行，尝试停止..."
            systemctl stop "${SERVICE}" >/dev/null 2>&1 || true
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

    # 2) 深度清理残余文件和用户
    log "清理配置文件、证书及内核优化残留..."
    rm -rf /etc/hysteria
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

    local DELETED_COUNT=0
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
#  快速安装（全自动，无交互，使用默认参数直接安装）
# ============================================================
Quick_Install_Hy2() {
    local PASS PORT HOST FAKE_URL NODE_NAME ENABLE_MPORT mport

    local term_width border_line
    term_width=$(tput cols 2>/dev/null || echo 60)
    border_line=$(printf '─%.0s' $(seq 1 "${term_width}"))

    echo
    echo -e "${CYAN}${border_line}${RESET}"
    echo -e "${CYAN}  ⚡  快速安装模式 — 全自动，不进行自定义交互${RESET}"
    echo -e "${CYAN}${border_line}${RESET}"
    echo

    # ---------- 安装依赖（强制 update + 安装缺失包）----------
    dep_install

    # ---------- 验证关键依赖是否安装成功 ----------
    log "校验关键依赖..."
    local check_failed=0
    for pkg in curl wget openssl iptables; do
        if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
            warn "依赖 ${pkg} 安装失败或未找到！"
            check_failed=1
        fi
    done
    if [[ ${check_failed} -eq 1 ]]; then
        die "依赖校验未通过，请检查软件源后重试。"
    fi
    ok "所有关键依赖校验通过"
    echo

    # ---------- 自动生成所有参数（无需交互）----------
    PASS="$(gen_pass_20)"
    PORT=443
    log "正在获取公网 IPv4..."
    HOST="$(get_public_ipv4 2>/dev/null || true)"
    [[ -z "${HOST}" ]] && die "无法自动获取公网 IP，请使用选项 1（安装 Hysteria 2）手动输入。"
    FAKE_URL="https://www.bing.com"
    NODE_NAME="hy2-$(printf "%04d" $((RANDOM % 10000)))"
    mport="20000-20100"
    ENABLE_MPORT="yes"
    local mport_start mport_end
    mport_start="${mport%-*}"
    mport_end="${mport#*-}"

    echo
    echo -e "  ${CYAN}自动配置参数如下：${RESET}"
    echo -e "  ${CYAN}服务器 IP       ${RESET} ${HOST}"
    echo -e "  ${CYAN}监听端口        ${RESET} ${PORT}"
    echo -e "  ${CYAN}密码            ${RESET} ${PASS}"
    echo -e "  ${CYAN}伪装网站        ${RESET} ${FAKE_URL}"
    echo -e "  ${CYAN}节点名称        ${RESET} ${NODE_NAME}"
    echo -e "  ${CYAN}端口跳跃        ${RESET} ${mport} → ${PORT}"
    echo

    # ---------- 安装 Hysteria 2 ----------
    log "下载 Hysteria 2 安装脚本..."
    timeout ${TIMEOUT_CURL_DOWNLOAD} curl -fsSL https://get.hy2.sh/ -o /tmp/hy2_install.sh \
        || die "下载 Hysteria 2 安装脚本超时（${TIMEOUT_CURL_DOWNLOAD}s），请检查网络！"
    run_with_spinner ${TIMEOUT_HY2_INSTALL} "安装 Hysteria 2（官方脚本）..." \
        bash /tmp/hy2_install.sh \
        || die "Hysteria 2 安装失败！请检查网络连接。"
    rm -f /tmp/hy2_install.sh
    ok "Hysteria 2 安装完成"

    # ---------- 验证 hysteria 二进制是否存在 ----------
    if ! command -v hysteria >/dev/null 2>&1; then
        die "Hysteria 2 安装后未找到可执行文件，请手动排查！"
    fi
    ok "hysteria 二进制校验通过：$(command -v hysteria)"

    # ---------- 生成自签证书 ----------
    log "生成自签证书（CN=bing.com，有效期100年）..."
    install -d -m 0755 /etc/hysteria
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/server.key \
        -out    /etc/hysteria/server.crt \
        -subj   "/CN=bing.com" \
        -days   36500 >/dev/null 2>&1
    if id -u hysteria >/dev/null 2>&1; then
        chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
    else
        chmod 600 /etc/hysteria/server.key
        chmod 644 /etc/hysteria/server.crt
    fi
    ok "证书生成完成"

    # ---------- sysctl 优化 ----------
    cat > /etc/sysctl.d/99-hy2.conf <<'SYSCTL'
net.core.rmem_max=16777216
SYSCTL
    sysctl --system > /dev/null
    ok "sysctl 已生效"

    # ---------- 写入配置文件 ----------
    log "写入 /etc/hysteria/config.yaml..."
    cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${PASS}

masquerade:
  type: proxy
  proxy:
    url: ${FAKE_URL}
    rewriteHost: true

ignoreClientBandwidth: false
EOF
    ok "配置文件写入完成"

    # ---------- iptables 端口跳跃 ----------
    local IFACE
    IFACE="$(get_default_iface || true)"
    [[ -n "${IFACE}" ]] && ok "检测到主网卡：${IFACE}"
    local ipt_range
    ipt_range="$(echo "${mport}" | tr '-' ':')"
    log "配置 iptables：UDP ${mport} 重定向到 ${PORT}..."
    if iptables -t nat -C PREROUTING -p udp --dport "${ipt_range}" -j REDIRECT --to-ports "${PORT}" >/dev/null 2>&1; then
        ok "iptables 规则已存在，跳过添加"
    else
        iptables -t nat -A PREROUTING -p udp --dport "${ipt_range}" -j REDIRECT --to-ports "${PORT}"
        ok "iptables 规则添加完成"
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save > /dev/null
        ok "规则已持久化（netfilter-persistent）"
    elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4
        ok "规则已保存到 /etc/iptables/rules.v4"
    fi

    # ---------- 服务管理 ----------
    local SERVICE_NAME="hysteria-server.service"
    local SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
    if [[ ! -f "${SERVICE_PATH}" ]]; then
        if ! systemctl list-unit-files | grep -qE '^hysteria-server\.service'; then
            die "未检测到 hysteria-server.service，请确认官方安装脚本是否成功创建 systemd unit"
        fi
    fi
    log "设置 ${SERVICE_NAME} 开机自启并立即启动..."
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl enable --now "${SERVICE_NAME}" >/dev/null
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "${SERVICE_NAME} 服务已启动"
    else
        warn "${SERVICE_NAME} 未处于 active 状态："
        systemctl status "${SERVICE_NAME}" --no-pager || true
        die "服务启动失败，请检查日志：journalctl -u ${SERVICE_NAME} -e --no-pager"
    fi

    # ---------- 生成客户端 URI ----------
    local ENC_NODE URI
    ENC_NODE="$(urlencode_fragment "${NODE_NAME}")"
    URI="hysteria2://${PASS}@${HOST}:${PORT}?sni=www.bing.com&insecure=1&allowInsecure=1&mport=${mport}#${ENC_NODE}"

    install -d -m 0755 /etc/hysteria
    echo "${URI}" > /etc/hysteria/link.bak
    ok "订阅链接已保存到 /etc/hysteria/link.bak"

    # ---------- 格式化展示安装结果 ----------
    term_width=$(tput cols 2>/dev/null || echo 60)
    border_line=$(printf '═%.0s' $(seq 1 "${term_width}"))
    echo
    echo -e "${GREEN}${border_line}${RESET}"
    echo -e "${GREEN}  ✅  Hysteria 2 快速安装完成${RESET}"
    echo -e "${GREEN}${border_line}${RESET}"
    echo
    echo -e "  ${CYAN}服务器 IP       ${RESET} ${HOST}"
    echo -e "  ${CYAN}监听端口        ${RESET} ${PORT}"
    echo -e "  ${CYAN}密码            ${RESET} ${PASS}"
    echo -e "  ${CYAN}伪装网站        ${RESET} ${FAKE_URL}"
    echo -e "  ${CYAN}节点名称        ${RESET} ${NODE_NAME}"
    echo -e "  ${CYAN}端口跳跃        ${RESET} ${mport} → ${PORT}"
    echo -e "  ${CYAN}证书            ${RESET} /etc/hysteria/server.crt  (自签，insecure)"
    echo -e "  ${CYAN}配置文件        ${RESET} /etc/hysteria/config.yaml"
    echo -e "  ${CYAN}订阅链接        ${RESET} /etc/hysteria/link.bak"
    echo
    echo -e "  ${YELLOW}▶ 客户端连接 URI（复制后导入代理工具）：${RESET}"
    echo -e "  ${GREEN}${URI}${RESET}"
    echo
    echo -e "  ${CYAN}🔗 项目地址：${RESET}https://github.com/Owenwoow/hy2-quick-install"
    echo -e "  ${CYAN}🔗 Hysteria 2 官方文档：${RESET}https://v2.hysteria.network/"
    echo
    echo -e "${GREEN}${border_line}${RESET}"
}



# ============================================================
#  入口：参数触发 或 菜单触发
# ============================================================
menu() {
    # 参数触发（适合自动化）：./hy2.sh --remove
    case "${1:-}" in
    --remove|--uninstall)
        Uninstall_Hy2
        exit 0
        ;;
    esac

    # 菜单触发（交互使用）
    while true; do
        clear
        local term_width border
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
    check_root
    menu "$@"
}


# 执行主函数
main "$@"
