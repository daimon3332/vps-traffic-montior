#!/bin/bash
# VPS Traffic Monitor — multi-server bandwidth guard with numeric TUI
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/vps-traffic-monitor.sh)
#   ./vps-traffic-monitor.sh
#   ./vps-traffic-monitor.sh --check
sh_v="1.3.0"

# ── colors (linux-tools-daimon style) ──────────────────────────────
gl_hui='\e[37m'
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_bai='\033[0m'
gl_kjlan='\033[96m'

# ── paths ──────────────────────────────────────────────────────────
# shellcheck disable=SC2034 # Download validation uses this literal as the script marker.
VTM_NAME="vps-traffic-monitor"
VTM_ROOT="${VTM_ROOT:-/root/vps-traffic-monitor}"
VTM_BIN_LINK="/usr/local/bin/vtm"
VTM_CONFIG="$VTM_ROOT/config.conf"
VTM_STATE_DIR="${VTM_STATE_DIR:-/var/lib/vps-traffic-monitor}"
VTM_STATE="$VTM_STATE_DIR/state"
VTM_LOCK="$VTM_STATE_DIR/lock"
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
# 终端快捷键，默认 m（输入 m 回车打开本菜单）
MENU_KEY="m"

# rules: name|threshold|metric|actions
declare -a RULE_LINES=()
declare -A CMD_MAP=()

# ═══════════════════════════════════════════════════════════════════
# helpers
# ═══════════════════════════════════════════════════════════════════

log() {
  local msg
  msg="[$(date '+%F %T')] $*"
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

# y/Y/yes 为是；n/N/no 或空为否
is_yes() {
  local a
  a=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$a" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

is_no() {
  local a
  a=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$a" in
    n|no|"") return 0 ;;
    *) return 1 ;;
  esac
}

confirm_yes() {
  local prompt="${1:-确认?}"
  local ans
  read -r -p "$prompt [y/N]: " ans
  is_yes "$ans"
}

confirm_YES() {
  local prompt="${1:-危险操作，输入 YES 确认}"
  local ans
  read -r -p "$prompt: " ans
  is_yes "$ans"
}

ensure_dirs() {
  mkdir -p "$VTM_ROOT" "$VTM_STATE_DIR" "$(dirname "$VTM_LOG")" 2>/dev/null || {
    err "无法创建运行目录"
    return 1
  }
  chmod 700 "$VTM_ROOT" "$VTM_STATE_DIR" 2>/dev/null || true
}

is_root() { [ "$(id -u)" -eq 0 ]; }

acquire_lock() {
  [ "${VTM_LOCK_HELD:-0}" = "1" ] && return 0
  ensure_dirs || return 1
  command -v flock >/dev/null 2>&1 || {
    err "缺少 flock，无法安全更新监控状态"
    log "state lock unavailable: flock missing"
    return 1
  }
  exec 9>"$VTM_LOCK" || return 1
  if ! flock -w 30 9; then
    exec 9>&-
    err "等待监控状态锁超时"
    log "state lock timeout"
    return 1
  fi
  VTM_LOCK_HELD=1
}

release_lock() {
  [ "${VTM_LOCK_HELD:-0}" = "1" ] || return 0
  flock -u 9 2>/dev/null || true
  exec 9>&-
  VTM_LOCK_HELD=0
}

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
    u[0]="B"; u[1]="KiB"; u[2]="MiB"; u[3]="GiB"; u[4]="TiB"; u[5]="PiB"; u[6]="EiB"
    i=0
    while (b >= 1024 && i < 6) { b/=1024; i++ }
    if (i==0) printf "%d %s", b, u[i]
    else printf "%.2f %s", b, u[i]
  }'
}

# parse 6.5T / 10G / 1024M / bare number(bytes) -> bytes (mawk-safe)
parse_size() {
  local s="${1//[[:space:]]/}" n u m
  s=${s^^}
  if [[ ! "$s" =~ ^([0-9]+([.][0-9]+)?)([KMGTPE]?I?B?)$ ]]; then
    return 1
  fi
  n="${BASH_REMATCH[1]}"
  u="${BASH_REMATCH[3]}"
  case "$u" in
    ""|B) m=1 ;;
    K|KB|KIB) m=1024 ;;
    M|MB|MIB) m=$((1024 ** 2)) ;;
    G|GB|GIB) m=$((1024 ** 3)) ;;
    T|TB|TIB) m=$((1024 ** 4)) ;;
    P|PB|PIB) m=$((1024 ** 5)) ;;
    E|EB|EIB) m=$(awk 'BEGIN{printf "%.0f", 1024^6}') ;;
    *) return 1 ;;
  esac
  awk -v n="$n" -v m="$m" 'BEGIN{printf "%.0f", n*m}'
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
  local iface net_root="${VTM_SYS_CLASS_NET:-/sys/class/net}"
  iface=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$iface" ] && [ -d "$net_root/$iface" ]; then
    printf '%s\n' "$iface"
    return 0
  fi
  for iface in "$net_root"/*; do
    [ -d "$iface" ] || continue
    iface=${iface##*/}
    case "$iface" in
      lo|docker*|br-*|veth*|virbr*) continue ;;
    esac
    printf '%s\n' "$iface"
    return 0
  done
  return 1
}

# print: rx_bytes tx_bytes
read_counters() {
  local iface="$1" net_root="${VTM_SYS_CLASS_NET:-/sys/class/net}" rx tx
  [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
  [ -r "$net_root/$iface/statistics/rx_bytes" ] || return 1
  [ -r "$net_root/$iface/statistics/tx_bytes" ] || return 1
  read -r rx <"$net_root/$iface/statistics/rx_bytes" || return 1
  read -r tx <"$net_root/$iface/statistics/tx_bytes" || return 1
  [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$rx" "$tx"
}

get_iface() {
  if [ -n "$INTERFACE" ] && [ "$INTERFACE" != "auto" ]; then
    printf '%s\n' "$INTERFACE"
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
# state keys (parsed as data, never executed):
# CYCLE_ID=2026-07
# BASE_RX=... BASE_TX=...
# LAST_RX=... LAST_TX=...
# ACC_RX=0 ACC_TX=0   # extra accumulated across counter resets
# OFFSET_RX=0 OFFSET_TX=0   # current-cycle manual calibration
# FIRED_rule-name=1

state_init_defaults() {
  CYCLE_ID=""
  STATE_IFACE=""
  BASE_RX=0
  BASE_TX=0
  LAST_RX=0
  LAST_TX=0
  ACC_RX=0
  ACC_TX=0
  OFFSET_RX=0
  OFFSET_TX=0
}

load_state() {
  state_init_defaults
  ensure_dirs || return 1
  if [ -f "$VTM_STATE" ]; then
    local line key val
    while IFS= read -r line; do
      [[ "$line" == *=* ]] || continue
      key=${line%%=*}
      val=$(conf_parse_value "$line")
      case "$key" in
        CYCLE_ID) [[ "$val" =~ ^[0-9]{4}-[0-9]{2}$ ]] && CYCLE_ID=$val ;;
        STATE_IFACE) [[ "$val" =~ ^[A-Za-z0-9_.:-]*$ ]] && STATE_IFACE=$val ;;
        BASE_RX|BASE_TX|LAST_RX|LAST_TX|ACC_RX|ACC_TX)
          if [[ "$val" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
            val=$(awk -v n="$val" 'BEGIN{printf "%.0f", n}')
            printf -v "$key" '%s' "$val"
          fi
          ;;
        OFFSET_RX|OFFSET_TX)
          [[ "$val" =~ ^-?[0-9]+$ ]] && printf -v "$key" '%s' "$val"
          ;;
      esac
    done <"$VTM_STATE"
  fi
}

save_state() {
  ensure_dirs || return 1
  local preserve_fired="${1:-1}" tmp
  tmp="${VTM_STATE}.tmp.$$"
  {
    echo "# vps-traffic-monitor state — do not edit while running"
    echo "CYCLE_ID='${CYCLE_ID}'"
    echo "STATE_IFACE='${STATE_IFACE}'"
    echo "BASE_RX=${BASE_RX}"
    echo "BASE_TX=${BASE_TX}"
    echo "LAST_RX=${LAST_RX}"
    echo "LAST_TX=${LAST_TX}"
    echo "ACC_RX=${ACC_RX}"
    echo "ACC_TX=${ACC_TX}"
    echo "OFFSET_RX=${OFFSET_RX}"
    echo "OFFSET_TX=${OFFSET_TX}"
    if [ "$preserve_fired" = "1" ] && [ -f "$VTM_STATE" ]; then
      grep -E '^FIRED_[A-Za-z0-9_.=-]+=' "$VTM_STATE" 2>/dev/null || true
    fi
  } >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$VTM_STATE"
  chmod 600 "$VTM_STATE" 2>/dev/null || true
}

mark_fired() {
  local name="$1"
  local safe tmp
  safe=${name//[^A-Za-z0-9_]/_}
  ensure_dirs || return 1
  tmp="${VTM_STATE}.tmp.$$"
  if [ -f "$VTM_STATE" ]; then
    grep -v "^FIRED_${safe}=" "$VTM_STATE" >"$tmp" 2>/dev/null || true
  else
    {
      echo "CYCLE_ID='${CYCLE_ID}'"
      echo "STATE_IFACE='${STATE_IFACE:-}'"
      echo "BASE_RX=${BASE_RX:-0}"
      echo "BASE_TX=${BASE_TX:-0}"
      echo "LAST_RX=${LAST_RX:-0}"
      echo "LAST_TX=${LAST_TX:-0}"
      echo "ACC_RX=${ACC_RX:-0}"
      echo "ACC_TX=${ACC_TX:-0}"
      echo "OFFSET_RX=${OFFSET_RX:-0}"
      echo "OFFSET_TX=${OFFSET_TX:-0}"
    } >"$tmp"
  fi
  echo "FIRED_${safe}=1" >>"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$VTM_STATE"
}

is_fired() {
  local name="$1"
  local safe
  safe=${name//[^A-Za-z0-9_]/_}
  [ -f "$VTM_STATE" ] && grep -q "^FIRED_${safe}=1" "$VTM_STATE" 2>/dev/null
}

clear_fired() {
  if [ -f "$VTM_STATE" ]; then
    local tmp="${VTM_STATE}.tmp.$$"
    grep -v '^FIRED_' "$VTM_STATE" >"$tmp" 2>/dev/null || true
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$VTM_STATE"
  fi
}

# update counters, handle cycle reset & reboot; sets globals:
# RX_USED TX_USED SUM_USED BILL_USED IFACE_NOW
refresh_usage() {
  local iface counters rx tx cur_cycle interface_changed=0
  if ! iface=$(get_iface); then
    err "没有找到可监控的网络接口"
    log "counter read failed: no interface"
    return 1
  fi
  IFACE_NOW="$iface"
  if ! counters=$(read_counters "$iface"); then
    err "读取网卡计数器失败: $iface"
    log "counter read failed: iface=$iface"
    return 1
  fi
  read -r rx tx <<<"$counters"

  load_state || return 1
  cur_cycle=$(current_cycle_id)
  [ -n "$cur_cycle" ] || {
    err "无法计算当前流量周期"
    log "cycle calculation failed"
    return 1
  }

  if [ -z "$CYCLE_ID" ] || [ "$CYCLE_ID" != "$cur_cycle" ]; then
    CYCLE_ID="$cur_cycle"
    STATE_IFACE="$iface"
    BASE_RX=$rx
    BASE_TX=$tx
    LAST_RX=$rx
    LAST_TX=$tx
    ACC_RX=0
    ACC_TX=0
    OFFSET_RX=0
    OFFSET_TX=0
    save_state 0 || return 1
  elif [ -z "$STATE_IFACE" ]; then
    STATE_IFACE="$iface"
  elif [ "$STATE_IFACE" != "$iface" ]; then
    ACC_RX=$(awk -v a="$ACC_RX" -v l="$LAST_RX" -v b="$BASE_RX" 'BEGIN{v=l-b; if(v<0)v=0; printf "%.0f", a+v}')
    ACC_TX=$(awk -v a="$ACC_TX" -v l="$LAST_TX" -v b="$BASE_TX" 'BEGIN{v=l-b; if(v<0)v=0; printf "%.0f", a+v}')
    STATE_IFACE="$iface"
    BASE_RX=$rx
    BASE_TX=$tx
    LAST_RX=$rx
    LAST_TX=$tx
    interface_changed=1
    log "monitor interface changed to $iface"
  fi

  # counter reboot / wrap: current < last
  if [ "$interface_changed" -eq 0 ] && [ "$(awk -v a="$rx" -v b="$LAST_RX" 'BEGIN{print (a+0 < b+0) ? 1 : 0}')" -eq 1 ]; then
    ACC_RX=$(awk -v a="$ACC_RX" -v l="$LAST_RX" -v b="$BASE_RX" 'BEGIN{v=l-b; if(v<0)v=0; printf "%.0f", a+v}')
    BASE_RX=0
  fi
  if [ "$interface_changed" -eq 0 ] && [ "$(awk -v a="$tx" -v b="$LAST_TX" 'BEGIN{print (a+0 < b+0) ? 1 : 0}')" -eq 1 ]; then
    ACC_TX=$(awk -v a="$ACC_TX" -v l="$LAST_TX" -v b="$BASE_TX" 'BEGIN{v=l-b; if(v<0)v=0; printf "%.0f", a+v}')
    BASE_TX=0
  fi

  LAST_RX=$rx
  LAST_TX=$tx
  save_state || return 1

  RAW_RX_USED=$(awk -v a="$ACC_RX" -v r="$rx" -v b="$BASE_RX" 'BEGIN{v=a+(r-b); if(v<0)v=0; printf "%.0f", v}')
  RAW_TX_USED=$(awk -v a="$ACC_TX" -v t="$tx" -v b="$BASE_TX" 'BEGIN{v=a+(t-b); if(v<0)v=0; printf "%.0f", v}')
  RX_USED=$(awk -v r="$RAW_RX_USED" -v o="$OFFSET_RX" 'BEGIN{v=r+o; if(v<0)v=0; printf "%.0f", v}')
  TX_USED=$(awk -v t="$RAW_TX_USED" -v o="$OFFSET_TX" 'BEGIN{v=t+o; if(v<0)v=0; printf "%.0f", v}')
  SUM_USED=$(awk -v r="$RX_USED" -v t="$TX_USED" 'BEGIN{printf "%.0f", r+t}')
  BILL_USED=$(compute_metric_value "$METRIC" "$RX_USED" "$TX_USED")
}

calibrate_usage() {
  local direction="$1" target_text="$2" target raw offset rc=0
  if ! target=$(parse_size "$target_text"); then
    err "流量格式无效: $target_text"
    return 1
  fi
  case "$direction" in
    up|tx) direction=up ;;
    down|rx) direction=down ;;
    *) err "校准方向只支持 up 或 down"; return 1 ;;
  esac

  acquire_lock || return 1
  if ! refresh_usage; then
    release_lock
    return 1
  fi
  if [ "$direction" = "up" ]; then
    raw=$RAW_TX_USED
    offset=$(awk -v t="$target" -v r="$raw" 'BEGIN{printf "%.0f", t-r}')
    OFFSET_TX=$offset
    TX_USED=$target
  else
    raw=$RAW_RX_USED
    offset=$(awk -v t="$target" -v r="$raw" 'BEGIN{printf "%.0f", t-r}')
    OFFSET_RX=$offset
    RX_USED=$target
  fi
  SUM_USED=$(awk -v r="$RX_USED" -v t="$TX_USED" 'BEGIN{printf "%.0f", r+t}')
  BILL_USED=$(compute_metric_value "$METRIC" "$RX_USED" "$TX_USED")
  save_state || rc=1
  release_lock
  [ "$rc" -eq 0 ] || return 1
  log "usage calibrated direction=$direction target=$target cycle=$CYCLE_ID"
  ok "已校准本周期${direction}: $(bytes_to_human "$target")"
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
MENU_KEY="m"
EOF
}

write_default_config() {
  ensure_dirs || return 1
  if [ ! -f "$VTM_CONFIG" ]; then
    default_config_body >"$VTM_CONFIG"
    # set instance default
    local hn
    hn=$(hostname 2>/dev/null || echo "vps")
    sed -i "s/^INSTANCE_NAME=\"\"/INSTANCE_NAME=\"$hn\"/" "$VTM_CONFIG" 2>/dev/null || true
    ok "已生成默认配置: $VTM_CONFIG"
  fi
  chmod 600 "$VTM_CONFIG" 2>/dev/null || true
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
    val="${val//\\\\/\\}"
  elif [[ "$val" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$val"
}

load_config() {
  RULE_LINES=()
  CMD_MAP=()
  write_default_config || return 1

  INSTANCE_NAME="$(hostname 2>/dev/null || echo vps)"
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
  ADDRESS_STOP_CMD="/root/address/app/ops/stop.sh"
  DRY_RUN=0
  CHECK_INTERVAL_MIN=5
  MENU_KEY="m"

  local line key val name
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    case "$key" in
      INSTANCE_NAME|INTERFACE|METRIC|RESET_DAY|TIMEZONE|QUOTA|TG_ENABLED|TG_BOT_TOKEN|TG_CHAT_ID|TG_ENDPOINT|MAIL_ENABLED|MAIL_HOST|MAIL_PORT|MAIL_USE_SSL|MAIL_USER|MAIL_PASS|MAIL_FROM|MAIL_TO|SHUTDOWN_ENABLED|SHUTDOWN_CMD|SHUTDOWN_DELAY|ADDRESS_STOP_CMD|DRY_RUN|CHECK_INTERVAL_MIN|MENU_KEY)
        val=$(conf_parse_value "$line")
        printf -v "$key" '%s' "$val"
        ;;
    esac
  done <"$VTM_CONFIG"

  case "$METRIC" in up|tx|upload|out|down|rx|download|in|sum|total|min|max) ;; *) METRIC=up ;; esac
  [[ "$RESET_DAY" =~ ^[0-9]+$ ]] && [ "$RESET_DAY" -ge 1 ] && [ "$RESET_DAY" -le 28 ] || RESET_DAY=1
  [[ "$MAIL_PORT" =~ ^[0-9]+$ ]] || MAIL_PORT=465
  [[ "$SHUTDOWN_DELAY" =~ ^[0-9]+$ ]] || SHUTDOWN_DELAY=30
  [[ "$CHECK_INTERVAL_MIN" =~ ^[0-9]+$ ]] && [ "$CHECK_INTERVAL_MIN" -ge 1 ] || CHECK_INTERVAL_MIN=5
  [[ "$TG_ENABLED" =~ ^[01]$ ]] || TG_ENABLED=0
  [[ "$MAIL_ENABLED" =~ ^[01]$ ]] || MAIL_ENABLED=0
  [[ "$MAIL_USE_SSL" =~ ^[01]$ ]] || MAIL_USE_SSL=1
  [[ "$SHUTDOWN_ENABLED" =~ ^[01]$ ]] || SHUTDOWN_ENABLED=1
  [[ "$DRY_RUN" =~ ^[01]$ ]] || DRY_RUN=0

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
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  ensure_dirs || return 1
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
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$VTM_CONFIG"
  chmod 600 "$VTM_CONFIG" 2>/dev/null || true
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
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$VTM_CONFIG"
  chmod 600 "$VTM_CONFIG" 2>/dev/null || true
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
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$VTM_CONFIG"
  chmod 600 "$VTM_CONFIG" 2>/dev/null || true
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
  text=$(printf '%s\n%s' "$title" "$body")
  url="${TG_ENDPOINT:-https://api.telegram.org/bot}${TG_BOT_TOKEN}/sendMessage"
  resp=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    "$url" 9>&- 2>&1) || {
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
    if cerr=$(curl "${curl_args[@]}" 9>&- 2>&1); then
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
    } | sendmail -t 9>&- 2>>"$VTM_LOG"; then
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
  local configured=0 failed=0
  local lines=()

  if [ "$TG_ENABLED" = "1" ]; then
    configured=$((configured + 1))
    if notify_telegram "$title" "$body"; then
      lines+=("Telegram: ok")
    else
      lines+=("Telegram: fail")
      failed=$((failed + 1))
    fi
  fi
  if [ "$MAIL_ENABLED" = "1" ]; then
    configured=$((configured + 1))
    if notify_email "$title" "$body"; then
      lines+=("Email: ok")
    else
      lines+=("Email: fail")
      failed=$((failed + 1))
    fi
  fi

  if [ "$configured" -eq 0 ]; then
    warn "未启用任何通知通道"
    log "notify skipped: no channel"
    return 1
  fi

  local l
  for l in "${lines[@]}"; do
    echo "  $l"
    log "notify $l | $title"
  done
  [ "$failed" -eq 0 ]
}

format_status_text() {
  local qbytes="" qh="(未设配额)" pct="n/a"
  if [ -n "$QUOTA" ]; then
    if qbytes=$(parse_size "$QUOTA"); then
      qh=$(bytes_to_human "$qbytes")
      pct=$(pct_of "$BILL_USED" "$qbytes")
    else
      qh="配置无效"
    fi
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

build_status_text() {
  local rc=0
  acquire_lock || return 1
  refresh_usage || rc=1
  release_lock
  [ "$rc" -eq 0 ] || return 1
  format_status_text
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
  bash -c "$cmd" 9>&-
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
  bash -c "$SHUTDOWN_CMD" 9>&-
}

execute_actions() {
  local actions_csv="$1" rule_name="$2" detail="$3"
  local title body
  title="⚠️ 流量阈值触发: ${rule_name}"
  body=$(printf '%s\n规则: %s\n详情: %s\n' "$(format_status_text)" "$rule_name" "$detail")

  local a
  IFS=',' read -ra _acts <<<"$actions_csv"
  if [ "$DRY_RUN" = "1" ]; then
    warn "[dry-run] 发送通知: $title"
    log "dry-run notify $rule_name"
  elif ! send_notify "$title" "$body"; then
    warn "通知未全部送达，本轮不执行后续动作"
    log "rule $rule_name blocked by notification failure"
    return 1
  fi

  for a in "${_acts[@]}"; do
    a=$(echo "$a" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$a" in
      notify) ;;
      stop_address|stop-address)
        do_stop_address || return 1
        ;;
      shutdown)
        do_shutdown || return 1
        ;;
      run:*)
        run_named_cmd "${a#run:}" || return 1
        ;;
      "") ;;
      *)
        warn "未知动作: $a"
        log "unknown action $a in rule $rule_name"
        return 1
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
  bash "$cmd" 9>&-
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
  load_config || return 1
  acquire_lock || return 1
  if ! refresh_usage; then
    release_lock
    return 1
  fi
  local line name th m acts th_bytes used
  local triggered=0 rc=0 rule_key
  local -A seen_rule_keys=()
  for line in "${RULE_LINES[@]}"; do
    IFS='|' read -r name th m acts <<<"$line"
    name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    th=$(echo "$th" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    m=$(echo "${m:-$METRIC}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    acts=$(echo "$acts" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$name" ] && continue
    if [[ ! "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      err "规则名称无效: $name"
      log "invalid rule name=$name"
      rc=1
      continue
    fi
    rule_key=${name//[^A-Za-z0-9_]/_}
    if [ -n "${seen_rule_keys[$rule_key]:-}" ]; then
      err "规则名称冲突: $name"
      log "duplicate rule state key=$rule_key name=$name"
      rc=1
      continue
    fi
    seen_rule_keys[$rule_key]=1
    case "$m" in
      up|tx|upload|out|down|rx|download|in|sum|total|min|max) ;;
      *)
        err "规则计量方向无效: $name ($m)"
        log "invalid metric rule=$name value=$m"
        rc=1
        continue
        ;;
    esac
    if ! th_bytes=$(parse_size "$th") || [ "$th_bytes" = "0" ]; then
      err "规则阈值无效: $name ($th)"
      log "invalid threshold rule=$name value=$th"
      rc=1
      continue
    fi
    used=$(compute_metric_value "$m" "$RX_USED" "$TX_USED")
    if [ "$(awk -v u="$used" -v t="$th_bytes" 'BEGIN{print (u+0 >= t+0) ? 1 : 0}')" -eq 1 ]; then
      if is_fired "$name"; then
        log "rule $name already fired this cycle"
        continue
      fi
      info "触发规则: $name ($(bytes_to_human "$used") >= $th)"
      log "trigger $name used=$used threshold=$th_bytes"
      if execute_actions "$acts" "$name" "$(metric_label "$m") $(bytes_to_human "$used") >= $th"; then
        if [ "$DRY_RUN" != "1" ]; then
          mark_fired "$name" || rc=1
        fi
      else
        rc=1
      fi
      triggered=1
    fi
  done
  if [ "$triggered" -eq 0 ]; then
    log "check ok bill=$(bytes_to_human "$BILL_USED") cycle=$CYCLE_ID"
  fi
  release_lock
  return "$rc"
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
    if [ "$(readlink -f "$src" 2>/dev/null || echo "$src")" != "$(readlink -f "$VTM_SCRIPT_PATH" 2>/dev/null || echo "$VTM_SCRIPT_PATH")" ]; then
      cp -f "$src" "$VTM_SCRIPT_PATH"
    fi
  elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
    # bash <(curl ...) 场景：从 /dev/fd 落盘
    cat "${BASH_SOURCE[0]}" >"$VTM_SCRIPT_PATH"
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
    install_bin_entry
  fi
  load_config 2>/dev/null || true
  setup_shell_shortcut "${MENU_KEY:-m}"
  ok "已安装到 $VTM_ROOT"
  echo "  脚本: $VTM_SCRIPT_PATH"
  echo "  配置: $VTM_CONFIG"
  echo "  状态: $VTM_STATE"
  echo "  命令: vtm  /  快捷键: ${MENU_KEY:-m}"
}

# 把脚本复制为 /usr/local/bin/vtm 实体文件（kejilion 同款，避免软链自复制）
install_bin_entry() {
  is_root || return 1
  [ -f "$VTM_SCRIPT_PATH" ] || return 1
  rm -f "$VTM_BIN_LINK"
  cp -f "$VTM_SCRIPT_PATH" "$VTM_BIN_LINK"
  chmod +x "$VTM_BIN_LINK"
  ln -sfn "$VTM_BIN_LINK" /usr/bin/vtm 2>/dev/null || true
}

# 快捷键安装方式对齐 kejilion「k」：
#   /usr/local/bin/<key> 可执行文件 + /usr/bin/<key> 软链
# 不依赖 alias / source bashrc，任意 shell 立即可用
remove_old_shortcuts() {
  local old="$1"
  # 清理曾写过的 bashrc alias 块
  local f
  for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
    [ -f "$f" ] || continue
    if grep -q 'vps-traffic-monitor shortcut' "$f" 2>/dev/null; then
      local tmp
      tmp=$(mktemp)
      awk '
        /# >>> vps-traffic-monitor shortcut >>>/ {skip=1; next}
        /# <<< vps-traffic-monitor shortcut <<</ {skip=0; next}
        !skip {print}
      ' "$f" >"$tmp"
      mv -f "$tmp" "$f"
    fi
    sed -i "/^alias ${old}=/d" "$f" 2>/dev/null || true
  done
  # 清理指向本程序的旧命令名软链（保留 vtm 主入口）
  if [ -n "$old" ] && [ "$old" != "vtm" ]; then
    for f in "/usr/local/bin/$old" "/usr/bin/$old"; do
      if [ -L "$f" ]; then
        local tgt
        tgt=$(readlink -f "$f" 2>/dev/null || true)
        case "$tgt" in
          "$VTM_SCRIPT_PATH"|"$VTM_BIN_LINK"|*/vps-traffic-monitor.sh) rm -f "$f" ;;
        esac
      elif [ -f "$f" ] && grep -q 'VTM_NAME="vps-traffic-monitor"' "$f" 2>/dev/null; then
        rm -f "$f"
      fi
    done
  fi
}

setup_shell_shortcut() {
  local key="${1:-m}"
  local old="${MENU_KEY:-m}"
  if ! [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    err "快捷键只能是字母开头，例如 m / vtm / mon"
    return 1
  fi
  if [ "$(id -u)" -ne 0 ]; then
    err "设置 PATH 快捷键需要 root（写入 /usr/local/bin）"
    return 1
  fi

  ensure_dirs
  if [ ! -f "$VTM_SCRIPT_PATH" ]; then
    local src
    src=$(resolve_self_source)
    if [ -n "$src" ] && [ -f "$src" ]; then
      cp -f "$src" "$VTM_SCRIPT_PATH"
    elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
      cat "${BASH_SOURCE[0]}" >"$VTM_SCRIPT_PATH"
    fi
  fi
  chmod +x "$VTM_SCRIPT_PATH" 2>/dev/null || true
  install_bin_entry

  if [ -n "$old" ] && [ "$old" != "$key" ]; then
    remove_old_shortcuts "$old"
  fi
  remove_old_shortcuts "$key"

  # 与 kejilion 相同：/usr/local/bin/m + /usr/bin/m
  if [ "$key" != "vtm" ]; then
    ln -sfn "$VTM_BIN_LINK" "/usr/local/bin/$key"
    ln -sfn "$VTM_BIN_LINK" "/usr/bin/$key" 2>/dev/null || true
  fi

  set_config_kv MENU_KEY "$key"
  MENU_KEY="$key"
  hash -r 2>/dev/null || true
  ok "快捷键已安装: 直接输入 ${key} 回车（等同 kejilion 的 k）"
  echo "  /usr/local/bin/${key}  ->  $VTM_BIN_LINK"
  if command -v "$key" >/dev/null 2>&1; then
    echo "  检测: $(command -v "$key")"
  else
    warn "当前 shell 未刷新 PATH，执行 hash -r 或重开终端"
  fi
  log "shortcut PATH set to $key"
  return 0
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
    install_bin_entry
    load_config 2>/dev/null || true
    local key="${MENU_KEY:-m}"
    if [ "$key" != "vtm" ]; then
      ln -sfn "$VTM_BIN_LINK" "/usr/local/bin/$key"
      ln -sfn "$VTM_BIN_LINK" "/usr/bin/$key" 2>/dev/null || true
    fi
  fi
  ok "脚本已更新 → v${new_ver:-?}  ($VTM_SCRIPT_PATH)"
  log "script updated to v${new_ver:-?} from $VTM_REPO_RAW"

  local self
  self=$(resolve_self_source)
  if [ -n "$self" ] && [ "$(readlink -f "$self" 2>/dev/null || echo "$self")" = "$(readlink -f "$VTM_SCRIPT_PATH" 2>/dev/null || echo "$VTM_SCRIPT_PATH")" ]; then
    info "正在用新版本重新启动菜单..."
    exec bash "$VTM_SCRIPT_PATH" --menu
  fi
  info "下次运行: ${MENU_KEY:-m}  或  vtm"
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
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$VTM_SCRIPT_PATH --check
Nice=10
UMask=0077
EOF

  cat >"$VTM_UNIT_DIR/$VTM_TIMER" <<EOF
[Unit]
Description=VPS Traffic Monitor periodic check

[Timer]
OnBootSec=2min
OnUnitInactiveSec=${mins}min
AccuracySec=30s
Unit=$VTM_SERVICE

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload || return 1
  systemctl enable "$VTM_TIMER" || return 1
  systemctl restart "$VTM_TIMER" || return 1
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
  local usage_ok=1
  if acquire_lock; then
    refresh_usage || usage_ok=0
    release_lock
  else
    usage_ok=0
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
  echo -e "主机: $(hostname 2>/dev/null)  网卡: ${IFACE_NOW:-?}  本月周期: ${CYCLE_ID:-?}"
  echo -e "快捷键: 输入 ${gl_lv}${MENU_KEY:-m}${gl_bai} 回车（PATH 命令，类似 kejilion 的 k）"
  echo "------------------------"
  echo -e "${gl_kjlan}【本月流量】${gl_bai}"
  if [ "$usage_ok" -eq 1 ]; then
    echo "  上行: $(bytes_to_human "${TX_USED:-0}")"
    echo "  下行: $(bytes_to_human "${RX_USED:-0}")"
    echo "  合计: $(bytes_to_human "${SUM_USED:-0}")"
  else
    echo -e "  ${gl_hong}读取失败，请检查 INTERFACE 和日志${gl_bai}"
  fi
  echo "------------------------"
  echo -e "${gl_kjlan}【通知】${gl_bai} Telegram:${tg_s}  邮件:${mail_s}"
  echo -e "${gl_kjlan}【后台监控】${gl_bai} ${timer_s}"
  echo "------------------------"
  echo -e "${gl_kjlan}【规则】${gl_bai}  达到阈值 → 一定通知；可选再停 address / 关机"
  if [ "${#RULE_LINES[@]}" -eq 0 ]; then
    echo -e "  ${gl_hui}(还没有规则，选 1 添加)${gl_bai}"
  else
    local line name th m acts flag used thb i=1
    for line in "${RULE_LINES[@]}"; do
      IFS='|' read -r name th m acts <<<"$line"
      m=${m:-up}
      if [ "$usage_ok" -ne 1 ]; then
        echo -e "  ${i}. ${name}  $(metric_label "$m") ≥ ${th}  → $(actions_label "$acts")  ${gl_hong}[数据错误]${gl_bai}"
        i=$((i + 1))
        continue
      fi
      used=$(compute_metric_value "$m" "${RX_USED:-0}" "${TX_USED:-0}")
      if ! thb=$(parse_size "$th"); then
        echo -e "  ${i}. ${name}  ${gl_hong}阈值无效: ${th}${gl_bai}"
        i=$((i + 1))
        continue
      fi
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
  echo -e "${gl_lv}1.${gl_bai} 添加规则"
  echo -e "${gl_lv}2.${gl_bai} 删除规则"
  echo -e "${gl_lv}3.${gl_bai} 通知设置（Telegram / 邮件）"
  echo -e "${gl_lv}4.${gl_bai} 后台监控开关（开机自动检查）"
  echo -e "${gl_lv}5.${gl_bai} 改快捷键（当前: ${MENU_KEY:-m}）"
  echo -e "${gl_lv}6.${gl_bai} 更新脚本"
  echo -e "${gl_lv}7.${gl_bai} 校准本周期已用流量"
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

  local name dir m th th_bytes act_stop act_off acts
  read -r -p "1) 规则名称 (如 stop-at-6.5t): " name
  name=$(echo "$name" | tr -d '[:space:]')
  if [[ ! "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    err "名称仅支持字母、数字、点、下划线和连字符"
    press_any
    return 1
  fi
  local existing existing_name existing_key name_key
  name_key=${name//[^A-Za-z0-9_]/_}
  for existing in "${RULE_LINES[@]}"; do
    existing_name=${existing%%|*}
    existing_key=${existing_name//[^A-Za-z0-9_]/_}
    if [ "$existing_key" = "$name_key" ]; then
      err "规则名称与现有规则冲突: $existing_name"
      press_any
      return 1
    fi
  done

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
  if ! th_bytes=$(parse_size "$th") || [ "$th_bytes" = "0" ]; then err "阈值格式无效"; press_any; return 1; fi

  echo ""
  echo "4) 额外动作（通知一定会发）"
  read -r -p "   达到后停止 address 服务? [y/N]: " act_stop
  read -r -p "   达到后关机? [y/N]: " act_off

  acts="notify"
  if is_yes "$act_stop"; then
    acts="${acts},stop_address"
  fi
  if is_yes "$act_off"; then
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

menu_calibrate_usage() {
  load_config || return 1
  clear 2>/dev/null || true
  echo -e "${gl_kjlan}校准本周期已用流量${gl_bai}"
  echo "------------------------"
  build_status_text || { press_any; return 1; }
  echo "------------------------"
  echo "1. 上行（Oracle 出站）"
  echo "2. 下行"
  echo "0. 返回"
  local choice direction value
  read -r -p "请选择: " choice
  case "$choice" in
    1) direction=up ;;
    2) direction=down ;;
    0|"") return ;;
    *) err "无效选择"; press_any; return 1 ;;
  esac
  read -r -p "输入控制台显示的本周期已用流量 (如 4.2T): " value
  if [ -z "$value" ] || ! parse_size "$value" >/dev/null; then
    err "流量格式无效"
    press_any
    return 1
  fi
  if confirm_yes "确认校准 $(metric_label "$direction") 为 $value?"; then
    calibrate_usage "$direction" "$value"
  fi
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
        if test_telegram "VPS 流量监控 · Telegram 测试"; then
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
        if test_email "VPS 流量监控 · 邮件测试"; then
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
        if [ "$any" -eq 1 ]; then ok "测试结束"; else err "没有可用通道"; fi
        press_any
        ;;
      6) set_config_kv TG_ENABLED 0; ok "已关闭 Telegram"; press_any ;;
      7) set_config_kv MAIL_ENABLED 0; ok "已关闭邮件"; press_any ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_background() {
  load_config
  clear 2>/dev/null || true
  echo -e "${gl_kjlan}后台监控${gl_bai}"
  echo "------------------------"
  echo "说明: 开启后系统会每隔几分钟自动检查流量和规则，"
  echo "      不用一直开着本菜单。关掉就不再自动检查。"
  echo "当前: $(timer_status_line)"
  echo "------------------------"
  echo "1. 开启后台监控"
  echo "2. 关闭后台监控"
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

menu_change_shortcut() {
  load_config
  clear 2>/dev/null || true
  echo -e "${gl_kjlan}改快捷键${gl_bai}"
  echo "------------------------"
  echo "现在: 输入 ${MENU_KEY:-m} 回车 → 打开本菜单"
  echo "实现方式: 安装到 /usr/local/bin/（与 kejilion 的 k 相同）"
  echo "默认 m，可改成 mon 等"
  if command -v "${MENU_KEY:-m}" >/dev/null 2>&1; then
    echo "检测: $(command -v "${MENU_KEY:-m}")"
  else
    echo -e "${gl_huang}检测: 当前未在 PATH 中找到 ${MENU_KEY:-m}${gl_bai}"
  fi
  echo "------------------------"
  local key
  read -r -p "新快捷键 [m]: " key
  key=${key:-m}
  setup_shell_shortcut "$key"
  press_any
}

ensure_shortcut_ready() {
  load_config
  local key="${MENU_KEY:-m}"
  if is_root && [ -f "$VTM_SCRIPT_PATH" ]; then
    # 实体文件缺失或与安装目录脚本不一致时重装
    if [ ! -f "$VTM_BIN_LINK" ] || [ -L "$VTM_BIN_LINK" ] \
      || ! cmp -s "$VTM_SCRIPT_PATH" "$VTM_BIN_LINK" 2>/dev/null; then
      install_bin_entry || true
    fi
  fi
  if ! command -v "$key" >/dev/null 2>&1; then
    setup_shell_shortcut "$key" || true
  elif [ ! -e "/usr/local/bin/$key" ] && [ "$key" != "vtm" ]; then
    setup_shell_shortcut "$key" || true
  fi
}

main_menu() {
  ensure_dirs
  write_default_config
  load_config
  ensure_shortcut_ready
  while true; do
    show_dashboard
    local c
    read -r -p "请输入数字: " c
    case "$c" in
      1) wizard_add_rule ;;
      2) wizard_delete_rule ;;
      3) menu_notify ;;
      4) menu_background ;;
      5) menu_change_shortcut ;;
      6)
        if confirm_yes "从 GitHub 更新脚本（保留本机配置）?"; then
          update_script
        fi
        press_any
        ;;
      7) menu_calibrate_usage ;;
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
  $0 --set-used up|down SIZE  校准本周期已用流量
  $0 --help

一键运行:
  bash <(curl -fsSL ${VTM_REPO_RAW})
EOF
}

main() {
  ensure_dirs || exit 1
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --check)
      check_rules
      exit $?
      ;;
    --status)
      load_config || exit 1
      build_status_text
      exit $?
      ;;
    --test-notify)
      load_config || exit 1
      local body
      body=$(build_status_text) || exit 1
      send_notify "VPS Traffic Monitor · 通知测试" "$body"
      exit $?
      ;;
    --test-telegram)
      load_config || exit 1
      test_telegram
      exit $?
      ;;
    --test-email)
      load_config || exit 1
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
    --set-used)
      load_config || exit 1
      calibrate_usage "${2:-}" "${3:-}"
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
