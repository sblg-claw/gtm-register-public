#!/bin/bash
# ==================================================================
# gtm-register.sh — 阿里云 Cloud GTM 地址自动注册 / IP 更新（无凭据版）
# ------------------------------------------------------------------
# 与旧版的区别（安全降权）：
#   1. 脚本内不含任何凭据（无阿里云 AK、无 GitHub token）。
#      AK 在「安装时」通过环境变量 / 参数注入，只落到 /etc/gtm-register/gtm.conf (600)。
#   2. 持久化到 /etc/gtm-register/ 的副本同样不含凭据 → 脚本可放公开位置。
#   3. 自更新（可选）从公开 URL 拉取，不带 Authorization 头。
#   4. 开机 / cron 只执行本地副本，不联网下载再执行。
#
# 推荐：为这把 AK 单独建一个 RAM 子用户，只挂下面这条最小权限策略：
#   {
#     "Version": "1",
#     "Statement": [{
#       "Effect": "Allow",
#       "Action": ["alidns:DescribeCloudGtmAddress","alidns:UpdateCloudGtmAddress"],
#       "Resource": "*"
#     }]
#   }
# 泄露最坏后果：只能读/改 GTM Cloud 地址 IP，碰不到 DNS/ECS/OSS/账单。
#
# 用法：
#   安装（凭据走环境变量，推荐）:
#     AK_ID=LTAI... AK_SECRET=... \
#       bash gtm-register.sh --prefix "oversea-hk" --address-id "addr-xxx"
#   安装（凭据走参数）:
#     bash gtm-register.sh --ak-id LTAI... --ak-secret ... \
#       --prefix "oversea-hk" --address-id "addr-xxx"
#   检测/更新 IP（cron/systemd/手动）:  bash gtm-register.sh --check-ip
#   查看状态:                          bash gtm-register.sh --status  (或 gtm-status)
#   自更新（需先设 GTM_SCRIPT_URL）:    bash gtm-register.sh --self-update
#   卸载:                              bash gtm-register.sh --uninstall
#
#   --prefix      地址名称前缀（默认 auto），最终名 = <prefix>-<公网IP>
#   --address-id  GTM 控制台预先建好的地址 ID，脚本只更新其 IP，不创建/删除地址对象
# ==================================================================
set -euo pipefail

# ---------- 常量 ----------
CONF_DIR="/etc/gtm-register"
CONF_FILE="$CONF_DIR/gtm.conf"
STATE_FILE="$CONF_DIR/state"
LOG_FILE="/var/log/gtm-register.log"
STATUS_BIN="/usr/local/bin/gtm-status"
SYSTEMD_SERVICE="/etc/systemd/system/gtm-register.service"
CRON_FILE="/etc/cron.d/gtm-check-ip"
SELF_SCRIPT="$CONF_DIR/gtm-register.sh"

# 区域（GTM 3.0 接口统一用 --region public，这里保留兼容字段）
REGION="${REGION:-cn-hangzhou}"

# 可选：公开的脚本地址，仅用于「管道安装时自持久化」和 --self-update。
# 例： GTM_SCRIPT_URL="https://raw.githubusercontent.com/<你的公开仓库>/main/gtm-register.sh"
GTM_SCRIPT_URL="${GTM_SCRIPT_URL:-}"

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

_writelog() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true; }
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; _writelog "[INFO]  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; _writelog "[WARN]  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; _writelog "[ERROR] $*"; exit 1; }
section() { echo -e "\n${BLUE}===== $* =====${NC}"; _writelog "===== $* ====="; }
log()     { _writelog "$*"; }

# ==================================================
# =================== 工具函数 =====================
# ==================================================

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "请以 root 身份运行此脚本（sudo bash $0）"
  fi
}

init_dirs() {
  mkdir -p "$CONF_DIR"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 700 "$CONF_DIR"
}

install_pkg() {
  local pkg="$1"
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
  elif command -v yum &>/dev/null; then
    yum install -y -q "$pkg"
  elif command -v dnf &>/dev/null; then
    dnf install -y -q "$pkg"
  else
    error "无法识别包管理器，请手动安装: $pkg"
  fi
}

check_deps() {
  section "检查系统依赖"

  if command -v apt-get &>/dev/null; then
    info "刷新软件包索引..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true
  fi

  if ! command -v curl &>/dev/null; then info "安装 curl...";    install_pkg curl;    else info "curl ✅";    fi
  if ! command -v python3 &>/dev/null; then info "安装 python3..."; install_pkg python3; else info "python3 ✅"; fi

  if ! command -v crontab &>/dev/null; then
    info "安装 cron..."
    if command -v apt-get &>/dev/null; then
      install_pkg cron
      systemctl enable cron --now 2>/dev/null || systemctl enable crond --now 2>/dev/null || true
    else
      install_pkg cronie
      systemctl enable crond --now 2>/dev/null || true
    fi
  else
    info "cron ✅"
  fi

  command -v systemctl &>/dev/null || error "系统不支持 systemd，无法继续"
  info "systemd ✅"

  if ! command -v aliyun &>/dev/null; then
    info "安装 aliyun CLI..."
    local arch cli_url=""
    arch=$(uname -m)
    [ "$arch" = "x86_64" ]  && cli_url="https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz"
    [ "$arch" = "aarch64" ] && cli_url="https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-arm64.tgz"
    [ -z "$cli_url" ] && error "不支持的系统架构: $arch"
    curl -fsSL "$cli_url" | tar -xz -C /usr/local/bin/
    command -v aliyun &>/dev/null || error "aliyun CLI 安装失败"
    info "aliyun CLI 安装成功: $(aliyun version 2>/dev/null | head -1)"
  else
    info "aliyun CLI ✅"
  fi
}

# 将脚本本身持久化到 $SELF_SCRIPT（systemd/cron 用固定路径调用本地副本，不联网）
ensure_local_script() {
  local src
  src=$(realpath "$0" 2>/dev/null || echo "$0")

  # 已在持久化路径执行
  if [ "$src" = "$SELF_SCRIPT" ]; then
    return 0
  fi

  # 作为本地文件执行 → 直接 cp（无需任何网络/凭据）
  if [ -f "$src" ]; then
    cp "$src" "$SELF_SCRIPT"
    chmod +x "$SELF_SCRIPT"
    info "脚本已持久化到: $SELF_SCRIPT"
    return 0
  fi

  # 管道运行（bash <(curl ...)）→ 从公开 URL 拉取一份持久化（无 Authorization 头）
  if [ -n "$GTM_SCRIPT_URL" ]; then
    info "检测到管道运行，从公开 URL 拉取脚本到 $SELF_SCRIPT"
    if curl -fsSL "$GTM_SCRIPT_URL" -o "$SELF_SCRIPT"; then
      chmod +x "$SELF_SCRIPT"
      info "脚本已持久化到: $SELF_SCRIPT"
      return 0
    fi
    error "无法从 $GTM_SCRIPT_URL 拉取脚本"
  fi

  error "管道运行但未设置 GTM_SCRIPT_URL，无法自持久化。请先把脚本下载为文件再运行，或设置 GTM_SCRIPT_URL 公开地址。"
}

wait_network() {
  info "等待网络就绪..."
  local i
  for i in $(seq 1 12); do
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then info "网络已就绪"; return 0; fi
    warn "第 $i 次等待网络 (5s)..."
    sleep 5
  done
  error "网络连接超时，请检查网络"
}

# ==================================================
# =================== GTM 操作 =====================
# ==================================================

get_public_ip() {
  local ip="" src
  local sources=(
    "https://api.ipify.org"
    "https://ifconfig.me"
    "https://icanhazip.com"
    "https://ipecho.net/plain"
  )
  for src in "${sources[@]}"; do
    ip=$(curl -4 -sf --max-time 5 "$src" | tr -d '[:space:]')
    if echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then echo "$ip"; return 0; fi
  done
  return 1
}

setup_aliyun_env() {
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  export ALIBABACLOUD_ACCESS_KEY_ID="$AK_ID"
  export ALIBABACLOUD_ACCESS_KEY_SECRET="$AK_SECRET"
}

# 写配置：凭据只写到这一个 600 文件（不进脚本、不进仓库）
write_conf() {
  local prefix="$1"
  cat > "$CONF_FILE" <<EOF
# GTM 配置文件 - 由 gtm-register.sh 生成于 $(date)
AK_ID="$AK_ID"
AK_SECRET="$AK_SECRET"
ADDR_ID="$ADDR_ID"
REGION="$REGION"
NAME_PREFIX="$prefix"
EOF
  chmod 600 "$CONF_FILE"
  info "配置文件已写入: $CONF_FILE (600)"
}

# 取当前地址的健康探测配置，更新时原样回传（避免覆盖丢失）
get_health_args() {
  local addr_id="$1" desc
  desc=$(aliyun alidns DescribeCloudGtmAddress \
    --region public --AcceptLanguage "zh-CN" --AddressId "$addr_id" 2>/dev/null)

  HEALTH_JUDGEMENT=$(echo "$desc" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('HealthJudgement','any_ok'))
except: print('any_ok')
" 2>/dev/null)
  HEALTH_JUDGEMENT="${HEALTH_JUDGEMENT:-any_ok}"

  HEALTH_TASKS=$(echo "$desc" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    ts=d.get('HealthTasks',{}).get('HealthTask',[])
    print(json.dumps([{'TemplateId':t['TemplateId'],'Port':t.get('Port',0)} for t in ts]))
except:
    print('')
" 2>/dev/null)
  HEALTH_TASKS="${HEALTH_TASKS:-}"
  log "健康探测配置: judgement=$HEALTH_JUDGEMENT tasks=$HEALTH_TASKS"
}

do_update_address() {
  local addr_id="$1" ip="$2" name="$3"
  local cmd="aliyun alidns UpdateCloudGtmAddress \
    --region public --AcceptLanguage zh-CN \
    --AddressId $addr_id --Address $ip --Name $name \
    --HealthJudgement $HEALTH_JUDGEMENT"
  if [ -n "$HEALTH_TASKS" ] && [ "$HEALTH_TASKS" != "[]" ]; then
    cmd="$cmd --HealthTasks '$HEALTH_TASKS'"
  fi
  eval "$cmd" 2>&1
}

_update_success() {
  echo "$1" | python3 -c "
import sys,json
try: print(str(json.load(sys.stdin).get('Success','')).lower())
except: print('')
" 2>/dev/null
}

gtm_init() {
  local public_ip="$1"
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  setup_aliyun_env

  local address_name="${NAME_PREFIX}-${public_ip}"
  section "初始化 GTM 地址: $address_name (AddressId=$ADDR_ID)"

  get_health_args "$ADDR_ID"
  local result; result=$(do_update_address "$ADDR_ID" "$public_ip" "$address_name")
  log "UpdateCloudGtmAddress 返回: $result"
  [ "$(_update_success "$result")" = "true" ] || error "初始化 GTM 地址失败: $result"

  cat > "$STATE_FILE" <<EOF
ADDR_ID="$ADDR_ID"
LAST_IP="$public_ip"
REGISTERED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
ADDRESS_NAME="$address_name"
EOF
  chmod 600 "$STATE_FILE"
  info "✅ GTM 初始化成功: $public_ip → AddressId=$ADDR_ID"
}

gtm_check_ip() {
  section "检测 IP 变更"

  if [ ! -f "$STATE_FILE" ]; then
    warn "未找到注册状态，执行初始化..."
    wait_network
    local ip; ip=$(get_public_ip) || error "无法获取公网 IP"
    gtm_init "$ip"
    return 0
  fi

  # shellcheck source=/dev/null
  source "$STATE_FILE"
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  setup_aliyun_env

  local current_ip
  current_ip=$(get_public_ip) || { warn "无法获取公网 IP，跳过本次检测"; return 0; }

  if [ "$current_ip" = "$LAST_IP" ]; then
    info "IP 未变更: $current_ip"
    log "IP 检测: 无变更 ($current_ip)"
    return 0
  fi

  info "检测到 IP 变更: $LAST_IP → $current_ip"
  local new_name="${NAME_PREFIX}-${current_ip}"

  get_health_args "$ADDR_ID"
  local result; result=$(do_update_address "$ADDR_ID" "$current_ip" "$new_name")
  log "UpdateCloudGtmAddress 返回: $result"
  if [ "$(_update_success "$result")" != "true" ]; then
    warn "UpdateCloudGtmAddress 失败: $result"
    return 1
  fi

  cat > "$STATE_FILE" <<EOF
ADDR_ID="$ADDR_ID"
LAST_IP="$current_ip"
REGISTERED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
ADDRESS_NAME="$new_name"
EOF
  info "✅ IP 更新成功: $LAST_IP → $current_ip（AddressId=$ADDR_ID 不变）"
}

# ==================================================
# ================ 开机服务 / Cron =================
# ==================================================

setup_systemd() {
  section "配置 Systemd 服务（开机自启，执行本地副本）"
  cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=GTM IP Register Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF_SCRIPT --check-ip
RemainAfterExit=yes
TimeoutStartSec=120
Restart=no

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable gtm-register.service
  info "✅ Systemd 服务已启用"
}

setup_cron() {
  section "配置 Cron（每分钟检测 IP，执行本地副本）"
  if crontab -l 2>/dev/null | grep -q "gtm-register"; then
    crontab -l 2>/dev/null | grep -v "gtm-register" | crontab - 2>/dev/null || true
    info "已清理 root crontab 中遗留的 gtm-register 任务"
  fi
  mkdir -p /etc/cron.d
  cat > "$CRON_FILE" <<EOF
# GTM IP 检测 - 每分钟执行（system crontab 格式：第六字段为用户名）
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root /bin/bash $SELF_SCRIPT --check-ip >> $LOG_FILE 2>&1
EOF
  chmod 644 "$CRON_FILE"
  if systemctl is-active --quiet cron 2>/dev/null; then systemctl restart cron
  elif systemctl is-active --quiet crond 2>/dev/null; then systemctl restart crond; fi
  info "✅ Cron 任务已配置: $CRON_FILE"
}

setup_status_cmd() {
  cat > "$STATUS_BIN" <<'STATEOF'
#!/bin/bash
CONF_FILE="/etc/gtm-register/gtm.conf"
STATE_FILE="/etc/gtm-register/state"
LOG_FILE="/var/log/gtm-register.log"
GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "\n${BLUE}========== GTM 注册状态 ==========${NC}"
if [ ! -f "$STATE_FILE" ]; then echo -e "${RED}未注册${NC} - 状态文件不存在"; exit 1; fi
source "$STATE_FILE"; source "$CONF_FILE" 2>/dev/null
CURRENT_IP=$(curl -4 -sf --max-time 5 https://api.ipify.org | tr -d '[:space:]' || echo "获取失败")
echo -e "本机当前 IP:   ${GREEN}$CURRENT_IP${NC}"
echo -e "注册 IP:       ${GREEN}$LAST_IP${NC}"
if [ "$CURRENT_IP" = "$LAST_IP" ]; then echo -e "IP 状态:       ${GREEN}✅ 一致${NC}"
else echo -e "IP 状态:       ${RED}⚠️  不一致，等待下次 cron 同步${NC}"; fi
echo -e "AddressId:     $ADDR_ID"
echo -e "地址名称:      $ADDRESS_NAME"
echo -e "注册时间:      $REGISTERED_AT"
echo ""
echo -e "Systemd 服务:  $(systemctl is-active gtm-register.service 2>/dev/null || echo '未知')"
echo -e "Cron 任务:     $([ -f /etc/cron.d/gtm-check-ip ] && echo '✅ 已配置' || echo '❌ 未配置')"
echo ""
echo -e "${BLUE}最近 10 条日志:${NC}"
tail -10 "$LOG_FILE" 2>/dev/null || echo "暂无日志"
echo -e "${BLUE}==================================${NC}\n"
STATEOF
  chmod +x "$STATUS_BIN"
  info "✅ 快捷命令已创建: gtm-status"
}

do_self_update() {
  check_root
  [ -n "$GTM_SCRIPT_URL" ] || error "未设置 GTM_SCRIPT_URL（公开脚本地址），无法自更新"
  section "自更新（从公开 URL，无凭据）"
  local tmp; tmp=$(mktemp)
  if curl -fsSL "$GTM_SCRIPT_URL" -o "$tmp"; then
    head -1 "$tmp" | grep -q '^#!/bin/bash' || error "下载内容不是脚本，已中止"
    cp "$tmp" "$SELF_SCRIPT"; chmod +x "$SELF_SCRIPT"; rm -f "$tmp"
    info "✅ 已更新本地副本: $SELF_SCRIPT（凭据仍只在 $CONF_FILE）"
  else
    rm -f "$tmp"; error "无法从 $GTM_SCRIPT_URL 拉取脚本"
  fi
}

do_uninstall() {
  section "卸载 GTM 自动注册"
  systemctl is-active --quiet gtm-register.service 2>/dev/null && systemctl stop gtm-register.service
  systemctl is-enabled --quiet gtm-register.service 2>/dev/null && systemctl disable gtm-register.service
  rm -f "$SYSTEMD_SERVICE"; systemctl daemon-reload
  info "Systemd 服务已移除"
  rm -f "$CRON_FILE"
  crontab -l 2>/dev/null | grep -v "gtm-register" | crontab - 2>/dev/null || true
  info "Cron 任务已移除"
  rm -f "$STATUS_BIN"
  if [ -d "$CONF_DIR" ]; then
    read -r -p "是否删除配置目录 $CONF_DIR（含凭据）？[y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then rm -rf "$CONF_DIR"; info "配置目录已删除"
    else info "配置目录已保留: $CONF_DIR"; fi
  fi
  info "✅ 卸载完成"
}

do_status() {
  if command -v gtm-status &>/dev/null; then gtm-status; return 0; fi
  echo ""; echo "===== GTM 注册状态 ====="
  [ -f "$STATE_FILE" ] || { echo "未注册"; return 0; }
  # shellcheck source=/dev/null
  source "$STATE_FILE"
  echo "注册 IP:   $LAST_IP"; echo "AddressId: $ADDR_ID"
  echo "注册时间:  $REGISTERED_AT"; echo "地址名称:  $ADDRESS_NAME"
}

# ==================================================
# ==================== 主流程 ======================
# ==================================================

parse_args() {
  MODE=""
  OPT_PREFIX="auto"
  OPT_ADDR_ID=""
  # 凭据：环境变量优先，可被 --ak-id/--ak-secret 覆盖
  AK_ID="${AK_ID:-}"
  AK_SECRET="${AK_SECRET:-}"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --prefix)      OPT_PREFIX="$2";  shift 2 ;;
      --address-id)  OPT_ADDR_ID="$2"; shift 2 ;;
      --ak-id)       AK_ID="$2";       shift 2 ;;
      --ak-secret)   AK_SECRET="$2";   shift 2 ;;
      --uninstall)   MODE="uninstall"; shift ;;
      --status)      MODE="status";    shift ;;
      --check-ip)    MODE="check-ip";  shift ;;
      --self-update) MODE="self-update"; shift ;;
      *) error "未知参数: $1" ;;
    esac
  done
  [ -z "$MODE" ] && MODE="install"
}

main() {
  parse_args "$@"

  case "$MODE" in
    install)
      check_root; init_dirs
      log "========== 开始安装 =========="
      [ -n "$AK_ID" ]      || error "缺少 AK_ID：请用环境变量 AK_ID=... 或 --ak-id 传入（建议用最小权限 RAM 子用户 AK）"
      [ -n "$AK_SECRET" ]  || error "缺少 AK_SECRET：请用环境变量 AK_SECRET=... 或 --ak-secret 传入"
      [ -n "$OPT_ADDR_ID" ] || error "缺少 --address-id：GTM 控制台预建地址 ID"
      ADDR_ID="$OPT_ADDR_ID"

      echo ""; info "======================================"
      info "  GTM 地址自动注册 / IP 更新 安装"
      info "======================================"
      info "前缀:          $OPT_PREFIX"
      info "GTM AddressId: $ADDR_ID"
      echo ""

      check_deps
      ensure_local_script
      section "写入配置文件"; write_conf "$OPT_PREFIX"
      wait_network
      local public_ip; public_ip=$(get_public_ip) || error "无法获取公网 IP"
      info "本机公网 IP: $public_ip"
      gtm_init "$public_ip"
      setup_systemd
      setup_cron
      setup_status_cmd
      systemctl start gtm-register.service

      echo ""; info "======================================"
      info "  ✅ 安装完成！"
      info "======================================"
      echo ""
      info "查看状态:     gtm-status"
      info "查看日志:     tail -f $LOG_FILE"
      info "手动检测 IP:  bash $SELF_SCRIPT --check-ip"
      info "卸载:         bash $SELF_SCRIPT --uninstall"
      echo ""
      do_status
      ;;
    self-update) do_self_update ;;
    uninstall)   check_root; init_dirs; do_uninstall ;;
    status)      do_status ;;
    check-ip)    check_root; init_dirs; log "========== IP 检测触发 =========="; gtm_check_ip ;;
  esac
}

main "$@"
