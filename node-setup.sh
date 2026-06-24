#!/bin/bash
# ==================================================================
# node-setup.sh — 一键节点初始化（无凭据版，凭据运行时通过环境变量注入）
#   1) 阿里云 GTM 地址自动注册 + 定时跟踪本机 IP（gtm-register）
#   2) 安装 nyanpass nodeclient
#
# 本脚本不含任何密钥，可公开托管。凭据通过环境变量在运行时传入：
#
#   AK_ID=<阿里云AK> AK_SECRET=<阿里云Secret> \
#   GTM_ADDRESS_ID=<addr-xxx> GTM_PREFIX=<前缀> \
#   NYAN_TOKEN=<nyanpass节点token> \
#     bash <(curl -fsSL https://raw.githubusercontent.com/sblg-claw/gtm-register-public/main/node-setup.sh)
#
# 必填: AK_ID, AK_SECRET, GTM_ADDRESS_ID, NYAN_TOKEN
# 选填: GTM_PREFIX(默认 node), NYAN_URL(默认 https://pyn2.nypanel.top),
#       GTM_SCRIPT_URL(默认公开仓库 gtm-register.sh)
# ==================================================================
set -euo pipefail

# ---------- 默认值（非敏感，可被环境变量覆盖）----------
GTM_SCRIPT_URL="${GTM_SCRIPT_URL:-https://raw.githubusercontent.com/sblg-claw/gtm-register-public/main/gtm-register.sh}"
GTM_PREFIX="${GTM_PREFIX:-node}"
NYAN_URL="${NYAN_URL:-https://pyn2.nypanel.top}"

# ---------- 敏感/必填参数（必须运行时传入）----------
AK_ID="${AK_ID:-}"
AK_SECRET="${AK_SECRET:-}"
GTM_ADDRESS_ID="${GTM_ADDRESS_ID:-}"
NYAN_TOKEN="${NYAN_TOKEN:-}"

# ---------- 校验 ----------
if [ "$(id -u)" -ne 0 ]; then
  echo "!!! 请以 root 运行（sudo bash 或 root 用户）" >&2; exit 1
fi
miss=""
[ -z "$AK_ID" ]         && miss="$miss AK_ID"
[ -z "$AK_SECRET" ]     && miss="$miss AK_SECRET"
[ -z "$GTM_ADDRESS_ID" ] && miss="$miss GTM_ADDRESS_ID"
[ -z "$NYAN_TOKEN" ]    && miss="$miss NYAN_TOKEN"
if [ -n "$miss" ]; then
  echo "!!! 缺少必填环境变量:$miss" >&2
  echo "    示例: AK_ID=... AK_SECRET=... GTM_ADDRESS_ID=addr-xxx NYAN_TOKEN=... bash $0" >&2
  exit 1
fi

echo "==================================================="
echo "  节点初始化开始"
echo "  GTM AddressId : $GTM_ADDRESS_ID  (prefix=$GTM_PREFIX)"
echo "  nyanpass panel: $NYAN_URL"
echo "==================================================="

# ---------- 第 0 步：确保 curl + ca 证书 ----------
ensure_curl() {
  if command -v curl >/dev/null 2>&1; then echo ">>> [0/2] curl 已存在 ✅"; return 0; fi
  echo ">>> [0/2] 未检测到 curl，正在安装..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q curl ca-certificates
  elif command -v yum >/dev/null 2>&1; then yum install -y -q curl ca-certificates
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl ca-certificates
  elif command -v zypper >/dev/null 2>&1; then zypper -n install curl ca-certificates
  else echo "!!! 无法识别包管理器，请手动安装 curl 后重试" >&2; exit 1; fi
  command -v curl >/dev/null 2>&1 || { echo "!!! curl 安装失败" >&2; exit 1; }
  echo ">>> [0/2] curl 安装完成 ✅"
}
ensure_curl

# ---------- 第 1 步：GTM 地址自动注册 ----------
echo
echo ">>> [1/2] 安装 GTM 自动注册（开机 + 每分钟跟踪 IP）..."
GTM_SCRIPT_URL="$GTM_SCRIPT_URL" \
AK_ID="$AK_ID" AK_SECRET="$AK_SECRET" \
  bash <(curl -fsSL "$GTM_SCRIPT_URL") \
  --prefix "$GTM_PREFIX" --address-id "$GTM_ADDRESS_ID"
echo ">>> [1/2] GTM 自动注册完成。"

# ---------- 第 2 步：nyanpass nodeclient ----------
echo
echo ">>> [2/2] 安装 nyanpass nodeclient..."
S=nyanpass OPTIMIZE=1 bash <(curl -fLSs https://dl.nyafw.com/download/nyanpass-install.sh) \
  rel_nodeclient "-t $NYAN_TOKEN -u $NYAN_URL"
echo ">>> [2/2] nyanpass nodeclient 安装完成。"

echo
echo "==================================================="
echo "  ✅ 全部完成"
echo "  查看 GTM 状态:  gtm-status"
echo "==================================================="
