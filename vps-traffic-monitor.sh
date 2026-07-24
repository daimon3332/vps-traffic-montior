#!/bin/bash
# VPS Traffic Monitor — multi-server bandwidth guard with numeric TUI
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/vps-traffic-monitor.sh)
#   ./vps-traffic-monitor.sh
#   ./vps-traffic-monitor.sh --check
sh_v="1.1.0"

# ── colors (linux-tools-daimon style) ──────────────────────────────
gl_hui='\e[37m'
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_lan='\033[34m'
gl_bai='\033[0m'
gl_zi='\033[35m'
gl_kjlan='\033[96m'

# ── paths ──────────────────────────────────────────────────────────
VTM_NAME="vps-traffic-monitor"
VTM_ROOT="${VTM_ROOT:-/root/vps-traffic-monitor}"
VTM_BIN_LINK="/usr/local/bin/vtm"
VTM_CONFIG="$VTM_ROOT/config.conf"
VTM_STATE_DIR="${VTM_STATE_DIR:-/var/lib/vps-traffic-monitor}"
VTM_STATE="$VTM_STATE_DIR/state"
VTM_LOG="${VTM_LOG:-/var/log/vps-traffic-monitor.log}"
VTM_SCRIPT_PATH="$VTM_ROOT/vps-traffic-monitor.sh"
VTM_REPO_RAW="${VTM_REPO_RAW:-https://raw.githubusercontent.com/daimon3332/vps-traffic-montior/main/vps-traffic-monitor.sh}"
VTM_UNIT_DIR="/etc/systemd/system"
VTM_SERVICE="vps-traffic-monitor.service"
VTM_TIMER="vps-traffic-monitor.timer"

# ── runtime defaults (overridden by config) ────────────────────────
INSTANCE_NAME=""
INTERFACE=""
METRIC="up"
RESET_DAY=1
TIMEZONE="Asia/Shanghai"
QUOTA=""
TG_ENABLED=0
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_ENDPOINT="https://api.telegram.org/bot"
MAIL_ENABLED=0
MAIL_HOST=""
MAIL_PORT=465
MAIL_USE_SSL=1
MAIL_USER=""
MAIL_PASS=""
MAIL_FROM=""
MAIL_TO=""
SHUTDOWN_ENABLED=1
SHUTDOWN_CMD="/sbin/shutdown -h now"
SHUTDOWN_DELAY=30
# 固定终止动作：停止 address（路径可改）
ADDRESS_STOP_CMD="/root/address/app/ops/stop.sh"
DRY_RUN=0
CHECK_INTERVAL_MIN=5

# rules: name|threshold|metric|actions
declare -a RULE_LINES=()
declare -A CMD_MAP=()

# ═══════════════════════════════════════════════════════════════════
# helpers
# ═══════════════════════════════════════════════════════════════════

log() {
  local msg="[$(date '+%F %T')] $*"
  echo "$msg" >>"$VTM_LOG" 2>/dev/null || true
}

info()  { echo -e "${gl_kjlan}$*${gl_bai}"; }
ok()    { echo -e "${gl_lv}$*${gl_bai}"; }
warn()  { echo -e "${gl_huang}$*${gl_bai}"; }
err()   { echo -e "${gl_hong}$*${gl_bai}"; }

press_any() {
  echo ""
  echo -e "${gl_hui}按任意键继续...${gl_bai}"
  read -n 1 -s -r _ || true
}

confirm_yes() {
  local prompt="${1:-确认?}"
  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

confirm_YES() {
  local prompt="${1:-危险操作，输入 YES 确认}"
  local ans
  read -r -p "$prompt: " ans
  [ "$ans" = "YES" ]
}

ensure_dirs() {
  mkdir -p "$VTM_ROOT" "$VTM_STATE_DIR" "$(dirname "$VTM_LOG")" 2>/dev/null || true
}

is_root() { [ "$(id -u)" -eq 0 ]; }

resolve_self_source() {
  local src=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] \
    && ! echo "${BASH_SOURCE[0]}" | grep -Eq '^/dev/fd/|^/proc/.*/fd/'; then
    src="${BASH_SOURCE[0]}"
  elif [ -f "$0" ] && ! echo "$0" | grep -Eq '^/dev/fd/|^/proc/.*/fd/'; then
    src="$0"
  fi
  if [ -n "$src" ]; then
    echo "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
  fi
}

# ── human size ─────────────────────────────────────────────────────
# bytes -> human (awk, 1024 base)
bytes_to_human() {
  awk -v b="$1" 'BEGIN{
    if (b < 0) b = 0
    u[0]="B"; u[1]="KB"; u[2]="MB"; u[3]="GB"; u[4]="TB"; u[5]="PB"
    i=0
    while (b >= 1024 && i < 5) { b/=1024; i++ }
    if (i==0) printf "%d %s", b, u[i]
    else printf "%.2f %s", b, u[i]
  }'
}

# parse 6.5T / 10G / 1024M / bare number(bytes) -> bytes (mawk-safe)
parse_size() {
  local s="$1"
  echo "$s" | awk '
  {
    s=$0
    gsub(/ /,"",s)
    n = s + 0
    u = s
    sub(/^[0-9.]+/, "", u)
    u = tolower(u)
    m = 1
    if (u ~ /^k/) m = 1024
    else if (u ~ /^m/) m = 1024 * 1024
    else if (u ~ /^g/) m = 1024 * 1024 * 1024
    else if (u ~ /^t/) m = 1024 * 1024 * 1024 * 1024
    else if (u ~ /^p/) m = 1024 * 1024 * 1024 * 1024 * 1024
    printf "%.0f", n * m
  }'
}

# percent used/quota
pct_of() {
  awk -v u="$1" -v q="$2" 'BEGIN{
    if (q+0 <= 0) { print "n/a"; exit }
    p = (u * 100.0) / q
    if (p > 0 && p < 0.01) printf "%.4f", p
    else printf "%.2f", p
  }'
}

# ── interface / counters ───────────────────────────────────────────
detect_interface() {
  local iface
  iface=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -z "$iface" ]; then
    iface=$(awk -F: 'NR>2 {
      gsub(/ /,"",$1)
      if ($1!="lo" && $1 !~ /^docker/ && $1 !~ /^br-/ && $1 !~ /^veth/ && $1 !~ /^virbr/) {
        print $1; exit
      }
    }' /proc/net/dev 2>/dev/null)
  fi
  echo "${iface:-enp0s6}"
}

# print: rx_bytes tx_bytes
read_counters() {
  local iface="$1"
  awk -v iface="$iface" -F: '
    NR > 2 {
      name = $1
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      if (name == iface) {
        n = split($2, f, /[ \t]+/)
        idx = 1
        if (f[1] == "") idx = 2
        rx = f[idx] + 0
        tx = f[idx + 8] + 0
        print rx, tx
        exit
      }
    }
  ' /proc/net/dev
}

get_iface() {
  if [ -n "$INTERFACE" ]; then
    echo "$INTERFACE"
  else
    detect_interface
  fi
}

# ── timezone / billing cycle ───────────────────────────────────────
now_in_tz() {
  # prints YYYY-MM-DD HH:MM:SS in TIMEZONE if possible
  if command -v timedatectl >/dev/null 2>&1 || [ -n "$TIMEZONE" ]; then
    TZ="$TIMEZONE" date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
  else
    date '+%Y-%m-%d %H:%M:%S'
  fi
}

current_cycle_id() {
  # YYYY-MM based on reset_day in TIMEZONE
  # If today < reset_day, still previous month cycle until reset_day
  TZ="$TIMEZONE" date '+%Y-%m-%d' 2>/dev/null | awk -v rd="$RESET_DAY" -F- '
  {
    y=$1+0; m=$2+0; d=$3+0
    rd=rd+0
    if (rd < 1) rd=1
    if (rd > 28) rd=28
    if (d < rd) {
      m-=1
      if (m < 1) { m=12; y-=1 }
    }
    printf "%04d-%02d", y, m
  }'
}

# ── state file ─────────────────────────────────────────────────────
# state keys (shell-sourceable):
# CYCLE_ID=2026-07
# BASE_RX=... BASE_TX=...
# LAST_RX=... LAST_TX=...
# ACC_RX=0 ACC_TX=0   # extra accumulated across counter resets
# FIRED_rule-name=1

state_init_defaults() {
  CYCLE_ID=""
  BASE_RX=0
  BASE_TX=0
  LAST_RX=0
  LAST_TX=0
  ACC_RX=0
  ACC_TX=0
}

load_state() {
  state_init_defaults
  ensure_dirs
  if [ -f "$VTM_STATE" ]; then
    # shellcheck disable=SC1090
    source "$VTM_STATE" 2>/dev/null || true
  fi
  BASE_RX=${BASE_RX:-0}
  BASE_TX=${BASE_TX:-0}
  LAST_RX=${LAST_RX:-0}
  LAST_TX=${LAST_TX:-0}
  ACC_RX=${ACC_RX:-0}
  ACC_TX=${ACC_TX:-0}
}

save_state() {
  ensure_dirs
  local tmp fired_lines=""
  tmp="${VTM_STATE}.tmp.$$"
  {
    echo "# vps-traffic-monitor state — do not edit while running"
    echo "CYCLE_ID='${CYCLE_ID}'"
    echo "BASE_RX=${BASE_RX}"
    echo "BASE_TX=${BASE_TX}"
    echo "LAST_RX=${LAST_RX}"
    echo "LAST_TX=${LAST_TX}"
    echo "ACC_RX=${ACC_RX}"
    echo "ACC_TX=${ACC_TX}"
    # preserve FIRED_* from current environment
    if [ -f "$VTM_STATE" ]; then
      grep -E '^FIRED_[A-Za-z0-9_.=-]+=' "$VTM_STATE" 2>/dev/null || true
    fi
  } >"$tmp"
  # re-write FIRED from memory map if we set VTM_FIRED_LIST
  if [ -n "${VTM_FIRED_EXPORT:-}" ]; then
    {
      echo "# vps-traffic-monitor state — do not edit while running"
      echo "CYCLE_ID='${CYCLE_ID}'"
      echo "BASE_RX=${BASE_RX}"
      echo "BASE_TX=${BASE_TX}"
      echo "LAST_RX=${LAST_RX}"
      echo "LAST_TX=${LAST_TX}"
      echo "ACC_RX=${ACC_RX}"
      echo "ACC_TX=${ACC_TX}"
      echo "$VTM_FIRED_EXPORT"
    } >"$tmp"
  fi
  mv -f "$tmp" "$VTM_STATE"
}

mark_fired() {
  local name="$1"
  local safe tmp
  safe=$(echo "$name" | sed 's/[^A-Za-z0-9_]/_/g')
  ensure_dirs
  tmp="${VTM_STATE}.tmp.$$"
  if [ -f "$VTM_STATE" ]; then
    grep -v "^FIRED_${safe}=" "$VTM_STATE" >"$tmp" 2>/dev/null || true
  else
    {
      echo "CYCLE_ID='${CYCLE_ID}'"
      echo "BASE_RX=${BASE_RX:-0}"
      echo "BASE_TX=${BASE_TX:-0}"
      echo "LAST_RX=${LAST_RX:-0}"
      echo "LAST_TX=${LAST_TX:-0}"
      echo "ACC_RX=${ACC_RX:-0}"
      echo "ACC_TX=${ACC_TX:-0}"
    } >"$tmp"
  fi
  echo "FIRED_${safe}=1" >>"$tmp"
  mv -f "$tmp" "$VTM_STATE"
}

is_fired() {
  local name="$1"
  local safe
  safe=$(echo "$name" | sed 's/[^A-Za-z0-9_]/_/g')
  [ -f "$VTM_STATE" ] && grep -q "^FIRED_${safe}=1" "$VTM_STATE" 2>/dev/null
}

clear_fired() {
  if [ -f "$VTM_STATE" ]; then
    local tmp="${VTM_STATE}.tmp.$$"
    grep -v '^FIRED_' "$VTM_STATE" >"$tmp" 2>/dev/null || true
    mv -f "$tmp" "$VTM_STATE"
  fi
}

# update counters, handle cycle reset & reboot; sets globals:
# RX_USED TX_USED SUM_USED BILL_USED IFACE_NOW
refresh_usage() {
  local iface rx tx cur_cycle
  iface=$(get_iface)
  IFACE_NOW="$iface"
  read -r rx tx <<<"$(read_counters "$iface")"
  rx=${rx:-0}
  tx=${tx:-0}

  load_state
  cur_cycle=$(current_cycle_id)

  if [ -z "$CYCLE_ID" ] || [ "$CYCLE_ID" != "$cur_cycle" ]; then
    CYCLE_ID="$cur_cycle"
    BASE_RX=$rx
    BASE_TX=$tx
    LAST_RX=$rx
    LAST_TX=$tx
    ACC_RX=0
    ACC_TX=0
    save_state
    clear_fired
    # re-save cycle after clear
    CYCLE_ID="$cur_cycle"
    BASE_RX=$rx
    BASE_TX=$tx
    LAST_RX=$rx
    LAST_TX=$tx
    ACC_RX=0
    ACC_TX=0
    save_state
  fi

  # counter reboot / wrap: current < last
  if [ "$(awk -v a="$rx" -v b="$LAST_RX" 'BEGIN{print (a+0 < b+0) ? 1 : 0}')" -eq 1 ]; then
    ACC_RX=$(awk -v a="$ACC_RX" -v l="$LAST_RX" -v b="$BASE_RX" 'BEGIN{print a + (l - b)}')
    BASE_RX=0
  fi
  if [ "$(awk -v a="$tx" -v b="$LAST_TX" 'BEGIN{print (a+0 < b+0) ? 1 : 0}')" -eq 1 ]; then
    ACC_TX=$(awk -v a="$ACC_TX" -v l="$LAST_TX" -v b="$BASE_TX" 'BEGIN{print a + (l - b)}')
    BASE_TX=0
  fi

  LAST_RX=$rx
  LAST_TX=$tx
  save_state

  RX_USED=$(awk -v a="$ACC_RX" -v r="$rx" -v b="$BASE_RX" 'BEGIN{v=a+(r-b); if(v<0)v=0; printf "%.0f", v}')
  TX_USED=$(awk -v a="$ACC_TX" -v t="$tx" -v b="$BASE_TX" 'BEGIN{v=a+(t-b); if(v<0)v=0; printf "%.0f", v}')
  SUM_USED=$(awk -v r="$RX_USED" -v t="$TX_USED" 'BEGIN{printf "%.0f", r+t}')
  BILL_USED=$(compute_metric_value "$METRIC" "$RX_USED" "$TX_USED")
}

compute_metric_value() {
  local m="$1" rx="$2" tx="$3"
  case "$m" in
    up|tx|upload|out) echo "$tx" ;;
    down|rx|download|in) echo "$rx" ;;
    sum|total) awk -v r="$rx" -v t="$tx" 'BEGIN{printf "%.0f", r+t}' ;;
    min) awk -v r="$rx" -v t="$tx" 'BEGIN{printf "%.0f", (r<t)?r:t}' ;;
    max|*) awk -v r="$rx" -v t="$tx" 'BEGIN{printf "%.0f", (r>t)?r:t}' ;;
  esac
}

metric_label() {
  case "$1" in
    up|tx|upload|out) echo "上行(up)" ;;
    down|rx|download|in) echo "下行(down)" ;;
    sum|total) echo "合计(sum)" ;;
    min) echo "较小值(min)" ;;
    max) echo "较大值(max)" ;;
    *) echo "$1" ;;
  esac
}

# ── config ─────────────────────────────────────────────────────────
default_config_body() {
  cat <<'EOF'
# VPS Traffic Monitor config
# 建议用菜单添加规则，不必手改

INSTANCE_NAME=""
INTERFACE=""
METRIC="up"
RESET_DAY=1
TIMEZONE="Asia/Shanghai"
QUOTA="10T"

# 规则: name|阈值|方向(up/down/sum)|动作
# 动作固定含 notify；可选 stop_address、shutdown
# RULE_1="stop-app|6.5T|up|notify,stop_address"
# RULE_2="poweroff|8T|up|notify,shutdown"

TG_ENABLED=0
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_ENDPOINT="https://api.telegram.org/bot"

MAIL_ENABLED=0
MAIL_HOST=""
MAIL_PORT=465
MAIL_USE_SSL=1
MAIL_USER=""
MAIL_PASS=""
MAIL_FROM=""
MAIL_TO=""

SHUTDOWN_ENABLED=1
SHUTDOWN_CMD="/sbin/shutdown -h now"
SHUTDOWN_DELAY=30
ADDRESS_STOP_CMD="/root/address/app/ops/stop.sh"
DRY_RUN=0
CHECK_INTERVAL_MIN=5
EOF
}

write_default_config() {
  ensure_dirs
  if [ ! -f "$VTM_CONFIG" ]; then
    default_config_body >"$VTM_CONFIG"
    # set instance default
    local hn
    hn=$(hostname 2>/dev/null || echo "vps")
    sed -i "s/^INSTANCE_NAME=\"\"/INSTANCE_NAME=\"$hn\"/" "$VTM_CONFIG" 2>/dev/null || true
    ok "已生成默认配置: $VTM_CONFIG"
  fi
}

# Read KEY=value or KEY="value" from conf line (value may contain | , : etc.)
conf_parse_value() {
  local line="$1"
  local val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  if [[ "$val" == \"*\" ]]; then
    val="${val:1:${#val}-2}"
    val="${val//\\\"/\"}"
  elif [[ "$val" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$val"
}

load_config() {
  RULE_LINES=()
  CMD_MAP=()
  write_default_config

  # Source only safe scalar keys (no RULE_/CMD_ — values may contain | )
  local tmp_src
  tmp_src=$(mktemp)
  grep -E '^(INSTANCE_NAME|INTERFACE|METRIC|RESET_DAY|TIMEZONE|QUOTA|TG_|MAIL_|SHUTDOWN_|ADDRESS_|DRY_RUN|CHECK_INTERVAL)' \
    "$VTM_CONFIG" 2>/dev/null | grep -vE '^\s*#' >"$tmp_src" || true
  # shellcheck disable=SC1090
  source "$tmp_src" 2>/dev/null || true
  rm -f "$tmp_src"

  INSTANCE_NAME=${INSTANCE_NAME:-$(hostname 2>/dev/null || echo vps)}
  METRIC=${METRIC:-up}
  RESET_DAY=${RESET_DAY:-1}
  TIMEZONE=${TIMEZONE:-Asia/Shanghai}
  TG_ENABLED=${TG_ENABLED:-0}
  MAIL_ENABLED=${MAIL_ENABLED:-0}
  MAIL_PORT=${MAIL_PORT:-465}
  MAIL_USE_SSL=${MAIL_USE_SSL:-1}
  SHUTDOWN_ENABLED=${SHUTDOWN_ENABLED:-1}
  SHUTDOWN_DELAY=${SHUTDOWN_DELAY:-30}
  ADDRESS_STOP_CMD=${ADDRESS_STOP_CMD:-/root/address/app/ops/stop.sh}
  DRY_RUN=${DRY_RUN:-0}
  CHECK_INTERVAL_MIN=${CHECK_INTERVAL_MIN:-5}
  TG_ENDPOINT=${TG_ENDPOINT:-https://api.telegram.org/bot}

  local line key val name
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    val=$(conf_parse_value "$line")
    [ -n "$val" ] && RULE_LINES+=("$val")
  done < <(grep -E '^RULE_[0-9]+=' "$VTM_CONFIG" 2>/dev/null | sort -t_ -k2 -n)

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    name="${key#CMD_}"
    val=$(conf_parse_value "$line")
    [ -n "$name" ] && CMD_MAP["$name"]="$val"
  done < <(grep -E '^CMD_[A-Za-z0-9_]+=' "$VTM_CONFIG" 2>/dev/null)
}

set_config_kv() {
  local key="$1" val="$2"
  ensure_dirs
  [ -f "$VTM_CONFIG" ] || write_default_config
  local tmp esc
  tmp="${VTM_CONFIG}.tmp.$$"
  # escape \ and " for double-quoted conf values
  esc=$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/"/\\"/g')
  if grep -q "^${key}=" "$VTM_CONFIG" 2>/dev/null; then
    grep -v "^${key}=" "$VTM_CONFIG" >"$tmp"
    echo "${key}=\"${esc}\"" >>"$tmp"
  else
    cp "$VTM_CONFIG" "$tmp"
    echo "${key}=\"${esc}\"" >>"$tmp"
  fi
  mv -f "$tmp" "$VTM_CONFIG"
}

# rewrite all RULE_* from RULE_LINES array
save_rules() {
  local tmp i
  tmp="${VTM_CONFIG}.tmp.$$"
  grep -vE '^RULE_[0-9]+=' "$VTM_CONFIG" >"$tmp" 2>/dev/null || true
  i=1
  local line
  for line in "${RULE_LINES[@]}"; do
    # escape quotes in line
    local esc
    esc=$(printf '%s' "$line" | sed 's/"/\\"/g')
    echo "RULE_${i}=\"${esc}\"" >>"$tmp"
    i=$((i + 1))
  done
  mv -f "$tmp" "$VTM_CONFIG"
}

save_cmd() {
  local name="$1" path="$2"
  set_config_kv "CMD_${name}" "$path"
}

delete_cmd() {
  local name="$1"
  local tmp
  tmp="${VTM_CONFIG}.tmp.$$"
  grep -vE "^CMD_${name}=" "$VTM_CONFIG" >"$tmp" 2>/dev/null || true
  mv -f "$tmp" "$VTM_CONFIG"
}

# ── notify ─────────────────────────────────────────────────────────
mask_secret() {
  local s="$1"
  local n=${#s}
  if [ "$n" -le 4 ]; then
    echo "****"
  else
    echo "${s:0:2}***${s: -2}"
  fi
}

# Send Telegram using current TG_* globals (does not check TG_ENABLED).
notify_telegram() {
  local title="$1" body="$2"
  [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || {
    err "Telegram 未配置 token/chat_id"
    return 1
  }
  local text url resp
  text=$(printf '<b>%s</b>\n%s' "$title" "$body")
  url="${TG_ENDPOINT:-https://api.telegram.org/bot}${TG_BOT_TOKEN}/sendMessage"
  resp=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    "$url" 2>&1) || {
    log "telegram fail: $resp"
    err "Telegram 请求失败: $resp"
    return 1
  }
  if echo "$resp" | grep -q '"ok":true\|"ok": true'; then
    return 0
  fi
  log "telegram bad resp: $resp"
  err "Telegram API 返回失败: $resp"
  return 1
}

# Send email using current MAIL_* globals (does not check MAIL_ENABLED).
notify_email() {
  local title="$1" body="$2"
  [ -n "$MAIL_HOST" ] && [ -n "$MAIL_FROM" ] && [ -n "$MAIL_TO" ] || {
    err "邮件未配置 host/from/to"
    return 1
  }

  if command -v curl >/dev/null 2>&1; then
    local url mailfile rcpt
    if [ "${MAIL_USE_SSL:-1}" = "1" ] && [ "${MAIL_PORT:-465}" = "465" ]; then
      url="smtps://${MAIL_HOST}:${MAIL_PORT}"
    else
      url="smtp://${MAIL_HOST}:${MAIL_PORT:-465}"
    fi
    mailfile=$(mktemp)
    {
      echo "From: ${MAIL_FROM}"
      echo "To: ${MAIL_TO}"
      echo "Subject: ${title}"
      echo "MIME-Version: 1.0"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Date: $(date -R 2>/dev/null || date)"
      echo ""
      echo "$body"
    } >"$mailfile"

    local curl_args=( -sS --connect-timeout 15 --max-time 60
      --url "$url"
      --mail-from "$MAIL_FROM"
      --upload-file "$mailfile"
    )
    IFS=',' read -ra _rcpts <<<"$MAIL_TO"
    for rcpt in "${_rcpts[@]}"; do
      rcpt=$(echo "$rcpt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$rcpt" ] && curl_args+=( --mail-rcpt "$rcpt" )
    done
    if [ -n "$MAIL_USER" ]; then
      curl_args+=( --user "${MAIL_USER}:${MAIL_PASS}" )
    fi
    if [ "${MAIL_USE_SSL:-1}" = "1" ] && [ "${MAIL_PORT:-465}" != "465" ]; then
      curl_args+=( --ssl-reqd )
    fi

    local cerr
    if cerr=$(curl "${curl_args[@]}" 2>&1); then
      rm -f "$mailfile"
      return 0
    fi
    rm -f "$mailfile"
    log "email curl smtp failed: $cerr"
    err "邮件发送失败: $cerr"
  fi

  if command -v sendmail >/dev/null 2>&1; then
    if {
      echo "From: ${MAIL_FROM}"
      echo "To: ${MAIL_TO}"
      echo "Subject: ${title}"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | sendmail -t 2>>"$VTM_LOG"; then
      return 0
    fi
  fi
  return 1
}

test_telegram() {
  local title="${1:-VPS Traffic Monitor · Telegram 测试}"
  local body="${2:-}"
  [ -n "$body" ] || body=$(build_status_text 2>/dev/null || echo "Telegram channel test")
  info "正在测试 Telegram..."
  if notify_telegram "$title" "$body"; then
    ok "Telegram 测试成功"
    log "telegram test ok"
    return 0
  fi
  err "Telegram 测试失败，未写入配置"
  log "telegram test fail"
  return 1
}

test_email() {
  local title="${1:-VPS Traffic Monitor · 邮件测试}"
  local body="${2:-}"
  [ -n "$body" ] || body=$(build_status_text 2>/dev/null || echo "Email channel test")
  info "正在测试邮件..."
  if notify_email "$title" "$body"; then
    ok "邮件测试成功"
    log "email test ok"
    return 0
  fi
  err "邮件测试失败，未写入配置"
  log "email test fail"
  return 1
}

send_notify() {
  local title="$1" body="$2"
  local ok_any=0
  local lines=()

  if [ "$TG_ENABLED" = "1" ]; then
    if notify_telegram "$title" "$body"; then
      lines+=("Telegram: ok")
      ok_any=1
    else
      lines+=("Telegram: fail")
    fi
  fi
  if [ "$MAIL_ENABLED" = "1" ]; then
    if notify_email "$title" "$body"; then
      lines+=("Email: ok")
      ok_any=1
    else
      lines+=("Email: fail")
    fi
  fi

  if [ "$TG_ENABLED" != "1" ] && [ "$MAIL_ENABLED" != "1" ]; then
    warn "未启用任何通知通道"
    log "notify skipped: no channel"
    return 1
  fi

  local l
  for l in "${lines[@]}"; do
    echo "  $l"
    log "notify $l | $title"
  done
  [ "$ok_any" -eq 1 ]
}

build_status_text() {
  refresh_usage
  local qbytes="" qh="(未设配额)" pct="n/a"
  if [ -n "$QUOTA" ]; then
    qbytes=$(parse_size "$QUOTA")
    qh=$(bytes_to_human "$qbytes")
    pct=$(pct_of "$BILL_USED" "$qbytes")
  fi
  local hn ip
  hn=$(hostname 2>/dev/null || echo unknown)
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  cat <<EOF
实例: ${INSTANCE_NAME}
主机: ${hn}
IP: ${ip:-n/a}
网卡: ${IFACE_NOW}
周期: ${CYCLE_ID} (重置日 ${RESET_DAY}, TZ ${TIMEZONE})
计量: $(metric_label "$METRIC")
上行: $(bytes_to_human "$TX_USED")
下行: $(bytes_to_human "$RX_USED")
合计: $(bytes_to_human "$SUM_USED")
计费用量: $(bytes_to_human "$BILL_USED") / ${qh} (${pct}%)
时间: $(now_in_tz)
EOF
}

# ── actions ────────────────────────────────────────────────────────
run_named_cmd() {
  local name="$1"
  local cmd="${CMD_MAP[$name]:-}"
  if [ -z "$cmd" ]; then
    err "未定义命令: $name"
    log "missing command $name"
    return 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    warn "[dry-run] 将执行: $cmd"
    log "dry-run cmd $name: $cmd"
    return 0
  fi
  info "执行命令 [$name]: $cmd"
  log "run cmd $name: $cmd"
  # shellcheck disable=SC2086
  bash -c "$cmd"
}

do_shutdown() {
  if [ "$SHUTDOWN_ENABLED" != "1" ]; then
    warn "关机动作已禁用"
    return 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    warn "[dry-run] 将在 ${SHUTDOWN_DELAY}s 后执行: $SHUTDOWN_CMD"
    log "dry-run shutdown"
    return 0
  fi
  warn "将在 ${SHUTDOWN_DELAY} 秒后关机: $SHUTDOWN_CMD"
  log "shutdown in ${SHUTDOWN_DELAY}s"
  sleep "$SHUTDOWN_DELAY"
  # shellcheck disable=SC2086
  bash -c "$SHUTDOWN_CMD"
}

execute_actions() {
  local actions_csv="$1" rule_name="$2" detail="$3"
  local title body
  title="⚠️ 流量阈值触发: ${rule_name}"
  body=$(printf '%s\n规则: %s\n详情: %s\n' "$(build_status_text)" "$rule_name" "$detail")

  local a has_notify=0
  IFS=',' read -ra _acts <<<"$actions_csv"
  for a in "${_acts[@]}"; do
    a=$(echo "$a" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$a" in
      notify) has_notify=1 ;;
    esac
  done

  # notify first if requested
  if [ "$has_notify" -eq 1 ]; then
    if [ "$DRY_RUN" = "1" ]; then
      warn "[dry-run] 发送通知: $title"
      log "dry-run notify $rule_name"
    else
      send_notify "$title" "$body" || warn "通知发送部分失败"
    fi
  fi

  for a in "${_acts[@]}"; do
    a=$(echo "$a" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$a" in
      notify) ;;
      stop_address|stop-address)
        do_stop_address
        ;;
      shutdown)
        if [ "$has_notify" -ne 1 ]; then
          if [ "$DRY_RUN" = "1" ]; then
            warn "[dry-run] 关机前通知: $title"
          else
            send_notify "🛑 即将关机: ${rule_name}" "$body" || true
          fi
        fi
        do_shutdown
        ;;
      run:*)
        run_named_cmd "${a#run:}"
        ;;
      *)
        warn "未知动作: $a"
        ;;
    esac
  done
}

do_stop_address() {
  local cmd="${ADDRESS_STOP_CMD:-/root/address/app/ops/stop.sh}"
  if [ "$DRY_RUN" = "1" ]; then
    warn "[dry-run] 将停止 address: $cmd"
    log "dry-run stop_address: $cmd"
    return 0
  fi
  if [ ! -x "$cmd" ] && [ ! -f "$cmd" ]; then
    err "address 停止脚本不存在: $cmd"
    log "stop_address missing: $cmd"
    return 1
  fi
  info "停止 address: $cmd"
  log "stop_address: $cmd"
  bash "$cmd"
}

# 把 actions 列表显示成中文
actions_label() {
  local acts="$1" out="通知" a
  IFS=',' read -ra _al <<<"$acts"
  for a in "${_al[@]}"; do
    a=$(echo "$a" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$a" in
      notify) ;;
      stop_address|stop-address) out="${out}+停address" ;;
      shutdown) out="${out}+关机" ;;
      run:*) out="${out}+${a}" ;;
    esac
  done
  echo "$out"
}

# ── rules engine ───────────────────────────────────────────────────
# RULE line: name|threshold|metric|actions
check_rules() {
  load_config
  refresh_usage
  local line name th m acts th_bytes used
  local triggered=0
  for line in "${RULE_LINES[@]}"; do
    IFS='|' read -r name th m acts <<<"$line"
    name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    th=$(echo "$th" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    m=$(echo "${m:-$METRIC}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    acts=$(echo "$acts" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$name" ] && continue
    th_bytes=$(parse_size "$th")
    used=$(compute_metric_value "$m" "$RX_USED" "$TX_USED")
    if [ "$(awk -v u="$used" -v t="$th_bytes" 'BEGIN{print (u+0 >= t+0) ? 1 : 0}')" -eq 1 ]; then
      if is_fired "$name"; then
        log "rule $name already fired this cycle"
        continue
      fi
      info "触发规则: $name ($(bytes_to_human "$used") >= $th)"
      log "trigger $name used=$used threshold=$th_bytes"
      execute_actions "$acts" "$name" "$(metric_label "$m") $(bytes_to_human "$used") >= $th"
      mark_fired "$name"
      triggered=1
    fi
  done
  if [ "$triggered" -eq 0 ]; then
    log "check ok bill=$(bytes_to_human "$BILL_USED") cycle=$CYCLE_ID"
  fi
}

# ── install / systemd ──────────────────────────────────────────────
vtm_download_urls() {
  local url="$1"
  case "$url" in
    https://raw.githubusercontent.com/*|https://github.com/*)
      echo "https://gh-proxy.com/$url"
      echo "https://ghproxy.net/$url"
      echo "https://ghfast.top/$url"
      echo "$url"
      ;;
    *)
      echo "$url"
      ;;
  esac
}

vtm_validate_script_file() {
  local file="$1"
  [ -s "$file" ] || { err "校验失败：文件为空"; return 1; }
  head -1 "$file" 2>/dev/null | grep -q '^#!/bin/bash' || {
    err "校验失败：不是 bash 脚本"
    return 1
  }
  grep -q 'VTM_NAME="vps-traffic-monitor"' "$file" 2>/dev/null || {
    err "校验失败：未找到 vps-traffic-monitor 标识"
    return 1
  }
  return 0
}

vtm_download_script_to() {
  local target="$1"
  local url real_url
  url="${VTM_REPO_RAW}"
  while IFS= read -r real_url; do
    [ -z "$real_url" ] && continue
    info "尝试下载: $real_url"
    if curl -fsSL --connect-timeout 15 --max-time 120 -o "$target" "$real_url" \
      && vtm_validate_script_file "$target"; then
      return 0
    fi
    if command -v wget >/dev/null 2>&1 && wget -qO "$target" "$real_url" \
      && vtm_validate_script_file "$target"; then
      return 0
    fi
    rm -f "$target" 2>/dev/null || true
  done < <(vtm_download_urls "$url")
  return 1
}

install_local() {
  ensure_dirs
  local src
  src=$(resolve_self_source)
  if [ -n "$src" ] && [ -f "$src" ]; then
    cp -f "$src" "$VTM_SCRIPT_PATH"
  elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
    # bash <(curl ...) 场景：从 /dev/fd 落盘
    cp -f "${BASH_SOURCE[0]}" "$VTM_SCRIPT_PATH" 2>/dev/null \
      || cat "${BASH_SOURCE[0]}" >"$VTM_SCRIPT_PATH"
  elif [ -f "$VTM_SCRIPT_PATH" ]; then
    ok "使用已有脚本: $VTM_SCRIPT_PATH"
  else
    info "从远程下载脚本..."
    if ! vtm_download_script_to "$VTM_SCRIPT_PATH"; then
      err "下载失败: $VTM_REPO_RAW （也可先把脚本 scp 到本机再 --install）"
      return 1
    fi
  fi
  chmod +x "$VTM_SCRIPT_PATH"
  write_default_config
  if is_root; then
    ln -sfn "$VTM_SCRIPT_PATH" "$VTM_BIN_LINK" 2>/dev/null || true
  fi
  ok "已安装到 $VTM_ROOT"
  echo "  脚本: $VTM_SCRIPT_PATH"
  echo "  配置: $VTM_CONFIG"
  echo "  状态: $VTM_STATE"
  [ -L "$VTM_BIN_LINK" ] && echo "  命令: vtm"
}

# Download latest script from GitHub (main), keep config/state.
update_script() {
  ensure_dirs
  local tmp bak new_ver
  tmp=$(mktemp)
  info "更新地址: $VTM_REPO_RAW"
  if ! vtm_download_script_to "$tmp"; then
    err "更新下载失败"
    rm -f "$tmp"
    return 1
  fi
  new_ver=$(grep -E '^sh_v=' "$tmp" | head -1 | cut -d= -f2 | tr -d '"')
  bak="${VTM_SCRIPT_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  if [ -f "$VTM_SCRIPT_PATH" ]; then
    cp -f "$VTM_SCRIPT_PATH" "$bak"
    info "已备份: $bak"
  fi
  mv -f "$tmp" "$VTM_SCRIPT_PATH"
  chmod +x "$VTM_SCRIPT_PATH"
  if is_root; then
    ln -sfn "$VTM_SCRIPT_PATH" "$VTM_BIN_LINK" 2>/dev/null || true
  fi
  ok "脚本已更新 → v${new_ver:-?}  ($VTM_SCRIPT_PATH)"
  log "script updated to v${new_ver:-?} from $VTM_REPO_RAW"

  # If current process is the installed script, re-exec new version into menu
  local self
  self=$(resolve_self_source)
  if [ -n "$self" ] && [ "$(readlink -f "$self" 2>/dev/null || echo "$self")" = "$(readlink -f "$VTM_SCRIPT_PATH" 2>/dev/null || echo "$VTM_SCRIPT_PATH")" ]; then
    info "正在用新版本重新启动菜单..."
    exec bash "$VTM_SCRIPT_PATH" --menu
  fi
  info "下次运行将使用新版本。也可执行: bash $VTM_SCRIPT_PATH"
  return 0
}

install_timer() {
  is_root || { err "需要 root"; return 1; }
  install_local || return 1
  load_config
  local mins="${CHECK_INTERVAL_MIN:-5}"
  [ "$mins" -ge 1 ] 2>/dev/null || mins=5

  cat >"$VTM_UNIT_DIR/$VTM_SERVICE" <<EOF
[Unit]
Description=VPS Traffic Monitor one-shot check
After=network-online.target

[Service]
Type=oneshot
ExecStart=$VTM_SCRIPT_PATH --check
Nice=10
EOF

  cat >"$VTM_UNIT_DIR/$VTM_TIMER" <<EOF
[Unit]
Description=VPS Traffic Monitor periodic check

[Timer]
OnBootSec=2min
OnUnitActiveSec=${mins}min
AccuracySec=30s
Unit=$VTM_SERVICE

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$VTM_TIMER"
  ok "已安装并启动 timer (每 ${mins} 分钟)"
  systemctl status "$VTM_TIMER" --no-pager -l | head -15 || true
}

uninstall_timer() {
  is_root || { err "需要 root"; return 1; }
  systemctl disable --now "$VTM_TIMER" 2>/dev/null || true
  rm -f "$VTM_UNIT_DIR/$VTM_SERVICE" "$VTM_UNIT_DIR/$VTM_TIMER"
  systemctl daemon-reload 2>/dev/null || true
  ok "已卸载 systemd timer"
}

timer_status_line() {
  if systemctl is-enabled "$VTM_TIMER" >/dev/null 2>&1; then
    echo "已安装"
  else
    echo "未安装"
  fi
}

# ── dashboard / TUI ────────────────────────────────────────────────
service_mark() {
  # $1 = 1 configured, 0 not
  if [ "${1:-0}" = "1" ]; then
    echo -e "${gl_lv}[✓]${gl_bai}"
  else
    echo -e "${gl_hui}[ ]${gl_bai}"
  fi
}

show_dashboard() {
  load_config
  refresh_usage 2>/dev/null || true

  local qh="未设" pct="n/a" qbytes=0
  if [ -n "$QUOTA" ]; then
    qbytes=$(parse_size "$QUOTA")
    qh=$(bytes_to_human "$qbytes")
    pct=$(pct_of "${BILL_USED:-0}" "$qbytes")
  fi

  local tg_s mail_s timer_s
  if [ "$TG_ENABLED" = "1" ] && [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    tg_s="已开启"
  else
    tg_s="未配置"
  fi
  if [ "$MAIL_ENABLED" = "1" ] && [ -n "$MAIL_HOST" ] && [ -n "$MAIL_TO" ]; then
    mail_s="已开启"
  else
    mail_s="未配置"
  fi
  timer_s=$(timer_status_line)

  clear 2>/dev/null || true
  echo -e "${gl_kjlan}VPS 流量监控${gl_bai}  v${sh_v}"
  echo -e "主机: $(hostname 2>/dev/null)  网卡: ${IFACE_NOW:-?}  周期: ${CYCLE_ID:-?} (每月${RESET_DAY}日重置)"
  echo "------------------------"
  echo -e "${gl_kjlan}【本月流量】${gl_bai}"
  echo "  上行: $(bytes_to_human "${TX_USED:-0}")"
  echo "  下行: $(bytes_to_human "${RX_USED:-0}")"
  echo "  合计: $(bytes_to_human "${SUM_USED:-0}")"
  [ -n "$QUOTA" ] && echo "  配额参考: ${qh} (默认计量 ${pct}%)"
  if [ "$DRY_RUN" = "1" ]; then
    echo -e "  ${gl_huang}模拟模式 dry-run：触发时不真正停服/关机${gl_bai}"
  fi
  echo "------------------------"
  echo -e "${gl_kjlan}【通知】${gl_bai} Telegram:${tg_s}  邮件:${mail_s}"
  echo -e "${gl_kjlan}【定时检查】${gl_bai} ${timer_s} (每 ${CHECK_INTERVAL_MIN} 分钟)"
  echo -e "${gl_kjlan}【终止动作】${gl_bai} 停address / 关机（规则里可选，通知始终发送）"
  echo "------------------------"
  echo -e "${gl_kjlan}【规则】${gl_bai}"
  if [ "${#RULE_LINES[@]}" -eq 0 ]; then
    echo -e "  ${gl_hui}(还没有规则，选 [3] 添加)${gl_bai}"
  else
    local line name th m acts flag used thb i=1
    for line in "${RULE_LINES[@]}"; do
      IFS='|' read -r name th m acts <<<"$line"
      m=${m:-up}
      used=$(compute_metric_value "$m" "${RX_USED:-0}" "${TX_USED:-0}")
      thb=$(parse_size "$th")
      if is_fired "$name"; then
        flag="${gl_huang}[已触发]${gl_bai}"
      elif [ "$(awk -v u="$used" -v t="$thb" 'BEGIN{print (u+0>=t+0)?1:0}')" -eq 1 ]; then
        flag="${gl_hong}[应触发]${gl_bai}"
      else
        flag="${gl_hui}[监控中]${gl_bai}"
      fi
      echo -e "  ${i}. ${name}  $(metric_label "$m") ≥ ${th}  → $(actions_label "$acts")  已用$(bytes_to_human "$used")  ${flag}"
      i=$((i + 1))
    done
  fi
  echo "------------------------"
  echo -e "${gl_lv}1.${gl_bai} 刷新"
  echo -e "${gl_lv}2.${gl_bai} 立即检查一次"
  echo -e "${gl_lv}3.${gl_bai} 添加规则"
  echo -e "${gl_lv}4.${gl_bai} 删除规则"
  echo -e "${gl_lv}5.${gl_bai} 通知设置 / 测试"
  echo -e "${gl_lv}6.${gl_bai} 开启或关闭定时检查"
  echo -e "${gl_lv}7.${gl_bai} 简单设置（配额/重置日/模拟模式等）"
  echo -e "${gl_lv}8.${gl_bai} 更新脚本"
  echo -e "${gl_lv}0.${gl_bai} 退出"
  echo "------------------------"
}

# ── menus ──────────────────────────────────────────────────────────

# 向导：名称 → 方向 → 阈值 → 可选终止动作（通知固定）
wizard_add_rule() {
  load_config
  clear 2>/dev/null || true
  echo -e "${gl_kjlan}添加规则${gl_bai}"
  echo "------------------------"
  echo "流程: 名称 → 流量方向 → 阈值 → 是否停 address / 关机"
  echo -e "${gl_hui}触发时一定发通知；停 address、关机可都不选、选一个或两个都选${gl_bai}"
  echo "------------------------"

  local name dir m th act_stop act_off acts
  read -r -p "1) 规则名称 (如 stop-at-6.5t): " name
  if [ -z "$name" ]; then err "名称不能为空"; press_any; return 1; fi
  name=$(echo "$name" | tr -d '[:space:]')

  echo ""
  echo "2) 统计哪边的流量?"
  echo "   1. 上行 (出站，Oracle 常用)"
  echo "   2. 下行 (入站)"
  echo "   3. 双向合计"
  read -r -p "请选择 [1]: " dir
  dir=${dir:-1}
  case "$dir" in
    1) m=up ;;
    2) m=down ;;
    3) m=sum ;;
    *) err "无效选择"; press_any; return 1 ;;
  esac

  echo ""
  read -r -p "3) 达到多少流量触发? (如 6.5T / 800G / 100M): " th
  if [ -z "$th" ]; then err "阈值不能为空"; press_any; return 1; fi
  if [ "$(parse_size "$th")" = "0" ]; then err "阈值格式无效"; press_any; return 1; fi

  echo ""
  echo "4) 额外动作（通知一定会发）"
  read -r -p "   达到后停止 address 服务? [y/N]: " act_stop
  read -r -p "   达到后关机? [y/N]: " act_off

  acts="notify"
  if [[ "$act_stop" =~ ^[Yy]$ ]]; then
    acts="${acts},stop_address"
  fi
  if [[ "$act_off" =~ ^[Yy]$ ]]; then
    acts="${acts},shutdown"
  fi

  echo ""
  echo "预览:"
  echo "  名称: $name"
  echo "  方向: $(metric_label "$m")"
  echo "  阈值: $th"
  echo "  动作: $(actions_label "$acts")"
  if ! confirm_yes "确认添加?"; then
    warn "已取消"
    press_any
    return 1
  fi

  RULE_LINES+=("${name}|${th}|${m}|${acts}")
  save_rules
  ok "已添加规则: $name"
  press_any
}

wizard_delete_rule() {
  load_config
  clear 2>/dev/null || true
  echo -e "${gl_kjlan}删除规则${gl_bai}"
  echo "------------------------"
  if [ "${#RULE_LINES[@]}" -eq 0 ]; then
    warn "当前没有规则"
    press_any
    return
  fi
  local i=1 line name th m acts
  for line in "${RULE_LINES[@]}"; do
    IFS='|' read -r name th m acts <<<"$line"
    echo "  $i) $name  $(metric_label "$m") ≥ $th  → $(actions_label "$acts")"
    i=$((i + 1))
  done
  echo "  0) 取消"
  echo "------------------------"
  local idx
  read -r -p "输入要删除的序号: " idx
  if [ "$idx" = "0" ] || [ -z "$idx" ]; then return; fi
  if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#RULE_LINES[@]}" ]; then
    local new=() j=1
    for line in "${RULE_LINES[@]}"; do
      [ "$j" -ne "$idx" ] && new+=("$line")
      j=$((j + 1))
    done
    RULE_LINES=("${new[@]}")
    save_rules
    ok "已删除"
  else
    err "无效序号"
  fi
  press_any
}

menu_notify() {
  while true; do
    load_config
    clear 2>/dev/null || true
    echo -e "${gl_kjlan}通知设置${gl_bai}"
    echo "------------------------"
    echo "Telegram: enabled=${TG_ENABLED} token=$( [ -n "$TG_BOT_TOKEN" ] && mask_secret "$TG_BOT_TOKEN" || echo 空 ) chat=$( [ -n "$TG_CHAT_ID" ] && mask_secret "$TG_CHAT_ID" || echo 空 )"
    echo "邮件:     enabled=${MAIL_ENABLED} host=${MAIL_HOST:-空} to=${MAIL_TO:-空}"
    echo -e "${gl_hui}配置时会先发测试，成功才保存${gl_bai}"
    echo "------------------------"
    echo "1. 配置 Telegram"
    echo "2. 配置邮件"
    echo "3. 测试 Telegram"
    echo "4. 测试邮件"
    echo "5. 测试已开启的通知"
    echo "6. 关闭 Telegram"
    echo "7. 关闭邮件"
    echo "0. 返回"
    echo "------------------------"
    local c
    read -r -p "请输入数字: " c
    case "$c" in
      1)
        load_config
        local t id ep
        local old_token="$TG_BOT_TOKEN" old_chat="$TG_CHAT_ID" old_ep="$TG_ENDPOINT"
        read -r -p "Bot Token (回车保留): " t
        read -r -p "Chat ID (回车保留): " id
        read -r -p "API Endpoint (回车保留): " ep
        [ -n "$t" ] && TG_BOT_TOKEN="$t"
        [ -n "$id" ] && TG_CHAT_ID="$id"
        [ -n "$ep" ] && TG_ENDPOINT="$ep"
        TG_ENDPOINT=${TG_ENDPOINT:-https://api.telegram.org/bot}
        if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
          err "Token 与 Chat ID 不能为空"
          TG_BOT_TOKEN="$old_token"; TG_CHAT_ID="$old_chat"; TG_ENDPOINT="$old_ep"
          press_any; continue
        fi
        if test_telegram "VPS 流量监控 · Telegram 测试" "$(build_status_text)"; then
          set_config_kv TG_BOT_TOKEN "$TG_BOT_TOKEN"
          set_config_kv TG_CHAT_ID "$TG_CHAT_ID"
          set_config_kv TG_ENDPOINT "$TG_ENDPOINT"
          set_config_kv TG_ENABLED 1
          ok "Telegram 已保存并开启"
        else
          TG_BOT_TOKEN="$old_token"; TG_CHAT_ID="$old_chat"; TG_ENDPOINT="$old_ep"
          warn "测试失败，未保存"
        fi
        press_any
        ;;
      2)
        load_config
        local h p u pw fr to ssl
        local old_h="$MAIL_HOST" old_p="$MAIL_PORT" old_u="$MAIL_USER" old_pw="$MAIL_PASS"
        local old_fr="$MAIL_FROM" old_to="$MAIL_TO" old_ssl="$MAIL_USE_SSL"
        read -r -p "SMTP Host (回车保留): " h
        read -r -p "SMTP Port [${MAIL_PORT:-465}]: " p
        read -r -p "Username (回车保留): " u
        read -r -p "Password (回车保留): " pw
        read -r -p "From (回车保留): " fr
        read -r -p "To (回车保留): " to
        read -r -p "Use SSL 1/0 [${MAIL_USE_SSL:-1}]: " ssl
        [ -n "$h" ] && MAIL_HOST="$h"
        [ -n "$p" ] && MAIL_PORT="$p" || MAIL_PORT=${MAIL_PORT:-465}
        [ -n "$u" ] && MAIL_USER="$u"
        [ -n "$pw" ] && MAIL_PASS="$pw"
        [ -n "$fr" ] && MAIL_FROM="$fr"
        [ -n "$to" ] && MAIL_TO="$to"
        [ -n "$ssl" ] && MAIL_USE_SSL="$ssl" || MAIL_USE_SSL=${MAIL_USE_SSL:-1}
        if [ -z "$MAIL_HOST" ] || [ -z "$MAIL_FROM" ] || [ -z "$MAIL_TO" ]; then
          err "Host / From / To 不能为空"
          MAIL_HOST="$old_h"; MAIL_PORT="$old_p"; MAIL_USER="$old_u"; MAIL_PASS="$old_pw"
          MAIL_FROM="$old_fr"; MAIL_TO="$old_to"; MAIL_USE_SSL="$old_ssl"
          press_any; continue
        fi
        if test_email "VPS 流量监控 · 邮件测试" "$(build_status_text)"; then
          set_config_kv MAIL_HOST "$MAIL_HOST"
          set_config_kv MAIL_PORT "$MAIL_PORT"
          set_config_kv MAIL_USER "$MAIL_USER"
          set_config_kv MAIL_PASS "$MAIL_PASS"
          set_config_kv MAIL_FROM "$MAIL_FROM"
          set_config_kv MAIL_TO "$MAIL_TO"
          set_config_kv MAIL_USE_SSL "$MAIL_USE_SSL"
          set_config_kv MAIL_ENABLED 1
          ok "邮件已保存并开启"
        else
          MAIL_HOST="$old_h"; MAIL_PORT="$old_p"; MAIL_USER="$old_u"; MAIL_PASS="$old_pw"
          MAIL_FROM="$old_fr"; MAIL_TO="$old_to"; MAIL_USE_SSL="$old_ssl"
          warn "测试失败，未保存"
        fi
        press_any
        ;;
      3) load_config; test_telegram; press_any ;;
      4) load_config; test_email; press_any ;;
      5)
        load_config
        local any=0
        if [ "$TG_ENABLED" = "1" ]; then test_telegram && any=1; else warn "Telegram 未开启"; fi
        if [ "$MAIL_ENABLED" = "1" ]; then test_email && any=1; else warn "邮件未开启"; fi
        [ "$any" -eq 1 ] && ok "测试结束" || err "没有可用通道"
        press_any
        ;;
      6) set_config_kv TG_ENABLED 0; ok "已关闭 Telegram"; press_any ;;
      7) set_config_kv MAIL_ENABLED 0; ok "已关闭邮件"; press_any ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_timer_simple() {
  clear 2>/dev/null || true
  echo -e "${gl_kjlan}定时检查${gl_bai}"
  echo "------------------------"
  echo "状态: $(timer_status_line)"
  echo "间隔: ${CHECK_INTERVAL_MIN:-5} 分钟（在「简单设置」可改）"
  echo "------------------------"
  echo "1. 开启定时检查（systemd）"
  echo "2. 关闭定时检查"
  echo "0. 返回"
  echo "------------------------"
  local c
  read -r -p "请输入数字: " c
  case "$c" in
    1) install_timer; press_any ;;
    2) uninstall_timer; press_any ;;
    0) return ;;
    *) warn "无效选项"; press_any ;;
  esac
}

menu_simple_settings() {
  load_config
  clear 2>/dev/null || true
  echo -e "${gl_kjlan}简单设置${gl_bai}"
  echo "------------------------"
  echo "当前:"
  echo "  实例名: $INSTANCE_NAME"
  echo "  网卡: ${INTERFACE:-自动}"
  echo "  月重置日: $RESET_DAY"
  echo "  时区: $TIMEZONE"
  echo "  配额展示: ${QUOTA:-未设}"
  echo "  检查间隔: ${CHECK_INTERVAL_MIN} 分钟"
  echo "  模拟模式 dry-run: $DRY_RUN  (1=只演练不真正停服/关机)"
  echo "  address 停止脚本: $ADDRESS_STOP_CMD"
  echo "  关机延迟秒: $SHUTDOWN_DELAY"
  echo "------------------------"
  local v
  read -r -p "实例名 (回车跳过): " v; [ -n "$v" ] && set_config_kv INSTANCE_NAME "$v"
  read -r -p "网卡 (空=自动, 输入 auto 恢复自动): " v
  if [ "$v" = "auto" ]; then set_config_kv INTERFACE ""
  elif [ -n "$v" ]; then set_config_kv INTERFACE "$v"; fi
  read -r -p "月重置日 1-28 (回车跳过): " v; [ -n "$v" ] && set_config_kv RESET_DAY "$v"
  read -r -p "时区 (回车跳过): " v; [ -n "$v" ] && set_config_kv TIMEZONE "$v"
  read -r -p "配额展示 如 10T (回车跳过): " v; [ -n "$v" ] && set_config_kv QUOTA "$v"
  read -r -p "检查间隔分钟 (回车跳过): " v; [ -n "$v" ] && set_config_kv CHECK_INTERVAL_MIN "$v"
  read -r -p "模拟模式 1开0关 (回车跳过): " v; [ -n "$v" ] && set_config_kv DRY_RUN "$v"
  read -r -p "address 停止脚本路径 (回车跳过): " v; [ -n "$v" ] && set_config_kv ADDRESS_STOP_CMD "$v"
  read -r -p "关机延迟秒 (回车跳过): " v; [ -n "$v" ] && set_config_kv SHUTDOWN_DELAY "$v"
  if confirm_yes "重置本月流量统计基准? (一般不用)"; then
    if confirm_YES "输入 YES 确认重置"; then
      local iface rx tx
      iface=$(get_iface)
      read -r rx tx <<<"$(read_counters "$iface")"
      CYCLE_ID=$(current_cycle_id)
      BASE_RX=$rx; BASE_TX=$tx; LAST_RX=$rx; LAST_TX=$tx; ACC_RX=0; ACC_TX=0
      save_state
      clear_fired
      CYCLE_ID=$(current_cycle_id)
      BASE_RX=$rx; BASE_TX=$tx; LAST_RX=$rx; LAST_TX=$tx; ACC_RX=0; ACC_TX=0
      save_state
      ok "已重置周期基准"
    fi
  fi
  ok "已保存。若改了检查间隔，请到菜单 6 重新开启定时检查"
  press_any
}

main_menu() {
  ensure_dirs
  write_default_config
  while true; do
    show_dashboard
    local c
    read -r -p "请输入数字: " c
    case "$c" in
      1) continue ;;
      2)
        info "执行检查..."
        check_rules
        ok "检查完成"
        echo ""
        build_status_text
        press_any
        ;;
      3) wizard_add_rule ;;
      4) wizard_delete_rule ;;
      5) menu_notify ;;
      6)
        load_config
        menu_timer_simple
        ;;
      7) menu_simple_settings ;;
      8)
        if confirm_yes "从 GitHub 更新脚本（保留本机配置）?"; then
          update_script
        fi
        press_any
        ;;
      0)
        echo "bye"
        exit 0
        ;;
      *)
        warn "无效选项"
        sleep 1
        ;;
    esac
  done
}

# ── entry ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
VPS Traffic Monitor v${sh_v}

用法:
  $0                打开 TUI 菜单
  $0 --menu         同上
  $0 --check        静默检查并执行规则 (systemd timer)
  $0 --status       打印流量状态
  $0 --test-notify        测试全部已启用通知
  $0 --test-telegram      仅测试 Telegram
  $0 --test-email         仅测试邮件
  $0 --install            安装脚本到 $VTM_ROOT
  $0 --update             从 GitHub 更新脚本
  $0 --install-timer      安装 systemd timer
  $0 --uninstall-timer
  $0 --help

一键运行:
  bash <(curl -fsSL ${VTM_REPO_RAW})
EOF
}

main() {
  ensure_dirs
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --check)
      load_config
      check_rules
      exit 0
      ;;
    --status)
      load_config
      build_status_text
      exit 0
      ;;
    --test-notify)
      load_config
      local rc=1
      [ "$TG_ENABLED" = "1" ] && test_telegram && rc=0
      [ "$MAIL_ENABLED" = "1" ] && test_email && rc=0
      if [ "$TG_ENABLED" != "1" ] && [ "$MAIL_ENABLED" != "1" ]; then
        err "未启用任何通知通道"
        exit 1
      fi
      exit $rc
      ;;
    --test-telegram)
      load_config
      test_telegram
      exit $?
      ;;
    --test-email)
      load_config
      test_email
      exit $?
      ;;
    --install)
      install_local
      exit $?
      ;;
    --update)
      update_script
      exit $?
      ;;
    --install-timer)
      install_timer
      exit $?
      ;;
    --uninstall-timer)
      uninstall_timer
      exit $?
      ;;
    --menu|"")
      main_menu
      ;;
    *)
      err "未知参数: $1"
      usage
      exit 1
      ;;
  esac
}

main "$@"
