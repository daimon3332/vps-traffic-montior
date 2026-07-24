#!/bin/bash
# VPS Traffic Monitor — multi-server bandwidth guard with numeric TUI
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/master/vps-traffic-monitor.sh)
#   ./vps-traffic-monitor.sh
#   ./vps-traffic-monitor.sh --check
sh_v="1.0.0"

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
VTM_REPO_RAW="${VTM_REPO_RAW:-https://raw.githubusercontent.com/daimon3332/vps-traffic-montior/master/vps-traffic-monitor.sh}"
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
DRY_RUN=0
CHECK_INTERVAL_MIN=5

# rules / commands stored as parallel arrays
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
# 多机通用：每台机器一份 config.conf

INSTANCE_NAME=""
INTERFACE=""
METRIC="up"
RESET_DAY=1
TIMEZONE="Asia/Shanghai"
QUOTA="10T"

# 规则格式: name|threshold|metric|actions
# actions 逗号分隔: notify  run:命令名  shutdown
# 示例（Oracle 出站）:
# RULE_1="stop-app|6.5T|up|notify,run:stop_heavy_app"
# RULE_2="poweroff|8T|up|notify,shutdown"

# 命名命令（通用，按机器修改）
# CMD_stop_heavy_app="/root/address/app/ops/stop.sh"

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
  grep -E '^(INSTANCE_NAME|INTERFACE|METRIC|RESET_DAY|TIMEZONE|QUOTA|TG_|MAIL_|SHUTDOWN_|DRY_RUN|CHECK_INTERVAL)' \
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

notify_telegram() {
  local title="$1" body="$2"
  [ "$TG_ENABLED" = "1" ] || return 1
  [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || return 1
  local text
  text=$(printf '<b>%s</b>\n%s' "$title" "$body")
  local url="${TG_ENDPOINT}${TG_BOT_TOKEN}/sendMessage"
  local resp
  resp=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    "$url" 2>&1) || {
    log "telegram fail: $resp"
    return 1
  }
  echo "$resp" | grep -q '"ok":true' || echo "$resp" | grep -q '"ok": true' || {
    log "telegram bad resp: $resp"
    return 1
  }
  return 0
}

notify_email() {
  local title="$1" body="$2"
  [ "$MAIL_ENABLED" = "1" ] || return 1
  [ -n "$MAIL_HOST" ] && [ -n "$MAIL_FROM" ] && [ -n "$MAIL_TO" ] || return 1

  # Prefer curl SMTP
  if command -v curl >/dev/null 2>&1; then
    local proto="smtp"
    local url
    if [ "$MAIL_USE_SSL" = "1" ] && [ "$MAIL_PORT" = "465" ]; then
      url="smtps://${MAIL_HOST}:${MAIL_PORT}"
    elif [ "$MAIL_USE_SSL" = "1" ]; then
      url="smtp://${MAIL_HOST}:${MAIL_PORT}"
    else
      url="smtp://${MAIL_HOST}:${MAIL_PORT}"
    fi
    local mailfile
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

    local curl_args=( -fsSL --connect-timeout 15 --max-time 60
      --url "$url"
      --mail-from "$MAIL_FROM"
      --upload-file "$mailfile"
    )
    # multiple --mail-rcpt
    local rcpt
    IFS=',' read -ra _rcpts <<<"$MAIL_TO"
    for rcpt in "${_rcpts[@]}"; do
      rcpt=$(echo "$rcpt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$rcpt" ] && curl_args+=( --mail-rcpt "$rcpt" )
    done
    if [ -n "$MAIL_USER" ]; then
      curl_args+=( --user "${MAIL_USER}:${MAIL_PASS}" )
    fi
    if [ "$MAIL_USE_SSL" = "1" ] && [ "$MAIL_PORT" != "465" ]; then
      curl_args+=( --ssl-reqd )
    fi

    if curl "${curl_args[@]}" 2>>"$VTM_LOG"; then
      rm -f "$mailfile"
      return 0
    fi
    rm -f "$mailfile"
    log "email curl smtp failed"
  fi

  # fallback: sendmail
  if command -v sendmail >/dev/null 2>&1; then
    {
      echo "From: ${MAIL_FROM}"
      echo "To: ${MAIL_TO}"
      echo "Subject: ${title}"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | sendmail -t 2>>"$VTM_LOG" && return 0
  fi
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
      shutdown)
        # ensure notify even if not in list for shutdown safety
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
    if ! curl -fsSL --connect-timeout 15 --max-time 120 "$VTM_REPO_RAW" -o "$VTM_SCRIPT_PATH"; then
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

  local tg_s mail_s cmd_s sd_s mon_s timer_s
  if [ "$TG_ENABLED" = "1" ] && [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    tg_s="已配置 chat=$(mask_secret "$TG_CHAT_ID")"
  else
    tg_s="未配置"
  fi
  if [ "$MAIL_ENABLED" = "1" ] && [ -n "$MAIL_HOST" ] && [ -n "$MAIL_TO" ]; then
    mail_s="已配置 ${MAIL_TO}"
  else
    mail_s="未配置"
  fi
  if [ "${#CMD_MAP[@]}" -gt 0 ]; then
    cmd_s="已配置 ${#CMD_MAP[@]} 个: $(echo "${!CMD_MAP[@]}" | tr ' ' ',')"
  else
    cmd_s="未配置"
  fi
  if [ "$SHUTDOWN_ENABLED" = "1" ]; then
    sd_s="启用 delay=${SHUTDOWN_DELAY}s"
  else
    sd_s="未启用"
  fi
  mon_s="规则 ${#RULE_LINES[@]} 条 | dry_run=${DRY_RUN}"
  timer_s=$(timer_status_line)

  clear 2>/dev/null || true
  echo -e "${gl_kjlan}VPS Traffic Monitor${gl_bai}  v${sh_v}"
  echo -e "实例: ${gl_lv}${INSTANCE_NAME}${gl_bai}  主机: $(hostname 2>/dev/null)  网卡: ${IFACE_NOW:-?}"
  echo "------------------------"
  echo -e "${gl_kjlan}【流量状态】${gl_bai}"
  echo "  计量: $(metric_label "$METRIC") | 周期: ${CYCLE_ID:-?} | 重置日: ${RESET_DAY} | TZ: ${TIMEZONE}"
  echo "  上行: $(bytes_to_human "${TX_USED:-0}") | 下行: $(bytes_to_human "${RX_USED:-0}") | 合计: $(bytes_to_human "${SUM_USED:-0}")"
  echo "  计费用量: $(bytes_to_human "${BILL_USED:-0}") / ${qh} (${pct}%)"
  if [ "$DRY_RUN" = "1" ]; then
    echo -e "  ${gl_huang}当前为 DRY-RUN 模式（不执行真实动作）${gl_bai}"
  fi
  echo "------------------------"
  echo -e "${gl_kjlan}【已配置服务】${gl_bai}"
  echo -e "  $( [ ${#RULE_LINES[@]} -gt 0 ] && service_mark 1 || service_mark 0 ) 流量监控     ${mon_s}"
  echo -e "  $( [ "$tg_s" != "未配置" ] && service_mark 1 || service_mark 0 ) Telegram     ${tg_s}"
  echo -e "  $( [ "$mail_s" != "未配置" ] && service_mark 1 || service_mark 0 ) 邮件通知     ${mail_s}"
  echo -e "  $( [ "$cmd_s" != "未配置" ] && service_mark 1 || service_mark 0 ) 自定义命令   ${cmd_s}"
  echo -e "  $( [ "$SHUTDOWN_ENABLED" = "1" ] && service_mark 1 || service_mark 0 ) 关机动作     ${sd_s}"
  echo -e "  $( [ "$timer_s" = "已安装" ] && service_mark 1 || service_mark 0 ) 定时任务     ${timer_s} (每 ${CHECK_INTERVAL_MIN} 分钟)"
  echo "------------------------"
  echo -e "${gl_kjlan}【规则】${gl_bai}"
  if [ "${#RULE_LINES[@]}" -eq 0 ]; then
    echo -e "  ${gl_hui}(无规则，请到 [4] 添加)${gl_bai}"
  else
    local line name th m acts flag used thb
    for line in "${RULE_LINES[@]}"; do
      IFS='|' read -r name th m acts <<<"$line"
      m=${m:-$METRIC}
      used=$(compute_metric_value "$m" "${RX_USED:-0}" "${TX_USED:-0}")
      thb=$(parse_size "$th")
      if is_fired "$name"; then
        flag="${gl_huang}[已触发]${gl_bai}"
      elif [ "$(awk -v u="$used" -v t="$thb" 'BEGIN{print (u+0>=t+0)?1:0}')" -eq 1 ]; then
        flag="${gl_hong}[应触发]${gl_bai}"
      else
        flag="${gl_hui}[待触发]${gl_bai}"
      fi
      echo -e "  · ${th} $(metric_label "$m") → ${acts}  ${flag}"
    done
  fi
  echo "------------------------"
  echo -e "${gl_lv}1.${gl_bai} 刷新总览"
  echo -e "${gl_lv}2.${gl_bai} 立即检查流量 / 执行规则"
  echo -e "${gl_lv}3.${gl_bai} 通知设置 (Telegram / 邮件)"
  echo -e "${gl_lv}4.${gl_bai} 规则管理"
  echo -e "${gl_lv}5.${gl_bai} 命令与动作"
  echo -e "${gl_lv}6.${gl_bai} 实例与计费设置"
  echo -e "${gl_lv}7.${gl_bai} 测试通知"
  echo -e "${gl_lv}8.${gl_bai} 安装 / 卸载定时任务"
  echo -e "${gl_lv}9.${gl_bai} 高级 (dry-run / 重置周期 / 安装脚本)"
  echo -e "${gl_lv}0.${gl_bai} 退出"
  echo "------------------------"
}

# ── menus ──────────────────────────────────────────────────────────
menu_notify() {
  while true; do
    load_config
    clear 2>/dev/null || true
    echo -e "${gl_kjlan}通知设置${gl_bai}"
    echo "------------------------"
    echo "Telegram: enabled=${TG_ENABLED} token=$( [ -n "$TG_BOT_TOKEN" ] && mask_secret "$TG_BOT_TOKEN" || echo 空 ) chat=$( [ -n "$TG_CHAT_ID" ] && mask_secret "$TG_CHAT_ID" || echo 空 )"
    echo "Email: enabled=${MAIL_ENABLED} host=${MAIL_HOST:-空} to=${MAIL_TO:-空} port=${MAIL_PORT}"
    echo "------------------------"
    echo "1. 配置 Telegram"
    echo "2. 开关 Telegram"
    echo "3. 配置邮件"
    echo "4. 开关邮件"
    echo "0. 返回"
    echo "------------------------"
    local c
    read -r -p "请输入数字: " c
    case "$c" in
      1)
        local t id ep
        read -r -p "Bot Token (回车保留): " t
        read -r -p "Chat ID (回车保留): " id
        read -r -p "API Endpoint (回车保留默认): " ep
        [ -n "$t" ] && set_config_kv TG_BOT_TOKEN "$t"
        [ -n "$id" ] && set_config_kv TG_CHAT_ID "$id"
        [ -n "$ep" ] && set_config_kv TG_ENDPOINT "$ep"
        set_config_kv TG_ENABLED 1
        ok "已保存 Telegram"
        press_any
        ;;
      2)
        load_config
        if [ "$TG_ENABLED" = "1" ]; then set_config_kv TG_ENABLED 0; ok "已关闭 Telegram"
        else set_config_kv TG_ENABLED 1; ok "已开启 Telegram"; fi
        press_any
        ;;
      3)
        local h p u pw fr to ssl
        read -r -p "SMTP Host: " h
        read -r -p "SMTP Port [465]: " p
        p=${p:-465}
        read -r -p "Username: " u
        read -r -p "Password: " pw
        read -r -p "From: " fr
        read -r -p "To (逗号分隔多个): " to
        read -r -p "Use SSL 1/0 [1]: " ssl
        ssl=${ssl:-1}
        [ -n "$h" ] && set_config_kv MAIL_HOST "$h"
        set_config_kv MAIL_PORT "$p"
        [ -n "$u" ] && set_config_kv MAIL_USER "$u"
        [ -n "$pw" ] && set_config_kv MAIL_PASS "$pw"
        [ -n "$fr" ] && set_config_kv MAIL_FROM "$fr"
        [ -n "$to" ] && set_config_kv MAIL_TO "$to"
        set_config_kv MAIL_USE_SSL "$ssl"
        set_config_kv MAIL_ENABLED 1
        ok "已保存邮件"
        press_any
        ;;
      4)
        load_config
        if [ "$MAIL_ENABLED" = "1" ]; then set_config_kv MAIL_ENABLED 0; ok "已关闭邮件"
        else set_config_kv MAIL_ENABLED 1; ok "已开启邮件"; fi
        press_any
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_rules() {
  while true; do
    load_config
    clear 2>/dev/null || true
    echo -e "${gl_kjlan}规则管理${gl_bai}"
    echo "------------------------"
    local i=1 line
    if [ "${#RULE_LINES[@]}" -eq 0 ]; then
      echo "(无规则)"
    else
      for line in "${RULE_LINES[@]}"; do
        echo "  $i) $line"
        i=$((i + 1))
      done
    fi
    echo "------------------------"
    echo "1. 添加规则"
    echo "2. 删除规则"
    echo "3. 清空全部规则"
    echo "0. 返回"
    echo "------------------------"
    local c
    read -r -p "请输入数字: " c
    case "$c" in
      1)
        local n th m ac
        echo "格式示例: name=stop-app threshold=6.5T metric=up actions=notify,run:stop_heavy_app"
        read -r -p "规则名: " n
        read -r -p "阈值 (如 6.5T): " th
        read -r -p "计量 up/down/sum [up]: " m
        m=${m:-up}
        read -r -p "动作 (notify,run:xxx,shutdown): " ac
        ac=${ac:-notify}
        if [ -z "$n" ] || [ -z "$th" ]; then
          err "名称和阈值必填"
        else
          RULE_LINES+=("${n}|${th}|${m}|${ac}")
          save_rules
          ok "已添加"
        fi
        press_any
        ;;
      2)
        local idx
        read -r -p "删除序号: " idx
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#RULE_LINES[@]}" ]; then
          local new=()
          local j=1
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
        ;;
      3)
        if confirm_YES "输入 YES 清空全部规则"; then
          RULE_LINES=()
          save_rules
          ok "已清空"
        fi
        press_any
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_commands() {
  while true; do
    load_config
    clear 2>/dev/null || true
    echo -e "${gl_kjlan}命令与动作${gl_bai}"
    echo "------------------------"
    echo "命名命令 (规则里用 run:名称 调用):"
    if [ "${#CMD_MAP[@]}" -eq 0 ]; then
      echo "  (无)"
    else
      local n
      for n in "${!CMD_MAP[@]}"; do
        echo "  $n = ${CMD_MAP[$n]}"
      done
    fi
    echo "------------------------"
    echo "关机: enabled=${SHUTDOWN_ENABLED} delay=${SHUTDOWN_DELAY}s"
    echo "  cmd: ${SHUTDOWN_CMD}"
    echo "------------------------"
    echo "1. 添加/修改命名命令"
    echo "2. 删除命名命令"
    echo "3. 设置关机参数"
    echo "4. 开关关机动作"
    echo "5. 手动执行命名命令"
    echo "0. 返回"
    echo "------------------------"
    local c
    read -r -p "请输入数字: " c
    case "$c" in
      1)
        local name path
        read -r -p "命令名 (如 stop_heavy_app): " name
        read -r -p "执行内容 (shell): " path
        if [ -n "$name" ] && [ -n "$path" ]; then
          save_cmd "$name" "$path"
          ok "已保存 CMD_${name}"
        else
          err "不能为空"
        fi
        press_any
        ;;
      2)
        local name
        read -r -p "要删除的命令名: " name
        delete_cmd "$name"
        ok "已删除"
        press_any
        ;;
      3)
        local d cmd
        read -r -p "关机延迟秒数 [${SHUTDOWN_DELAY}]: " d
        read -r -p "关机命令 [${SHUTDOWN_CMD}]: " cmd
        [ -n "$d" ] && set_config_kv SHUTDOWN_DELAY "$d"
        [ -n "$cmd" ] && set_config_kv SHUTDOWN_CMD "$cmd"
        ok "已保存"
        press_any
        ;;
      4)
        load_config
        if [ "$SHUTDOWN_ENABLED" = "1" ]; then set_config_kv SHUTDOWN_ENABLED 0; ok "已禁用关机"
        else set_config_kv SHUTDOWN_ENABLED 1; ok "已启用关机"; fi
        press_any
        ;;
      5)
        local name
        read -r -p "命令名: " name
        load_config
        run_named_cmd "$name"
        press_any
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_billing() {
  load_config
  clear 2>/dev/null || true
  echo -e "${gl_kjlan}实例与计费设置${gl_bai}"
  echo "------------------------"
  echo "当前:"
  echo "  INSTANCE_NAME=$INSTANCE_NAME"
  echo "  INTERFACE=${INTERFACE:-自动}"
  echo "  METRIC=$METRIC"
  echo "  RESET_DAY=$RESET_DAY"
  echo "  TIMEZONE=$TIMEZONE"
  echo "  QUOTA=$QUOTA"
  echo "  CHECK_INTERVAL_MIN=$CHECK_INTERVAL_MIN"
  echo "------------------------"
  local v
  read -r -p "实例名 (回车保留): " v; [ -n "$v" ] && set_config_kv INSTANCE_NAME "$v"
  read -r -p "网卡 (空=自动, 输入 auto 清空手动): " v
  if [ "$v" = "auto" ]; then set_config_kv INTERFACE ""
  elif [ -n "$v" ]; then set_config_kv INTERFACE "$v"; fi
  read -r -p "计量 up/down/sum/max/min (回车保留): " v; [ -n "$v" ] && set_config_kv METRIC "$v"
  read -r -p "月重置日 1-28 (回车保留): " v; [ -n "$v" ] && set_config_kv RESET_DAY "$v"
  read -r -p "时区 (回车保留): " v; [ -n "$v" ] && set_config_kv TIMEZONE "$v"
  read -r -p "配额 如 10T (回车保留): " v; [ -n "$v" ] && set_config_kv QUOTA "$v"
  read -r -p "检查间隔分钟 (回车保留): " v; [ -n "$v" ] && set_config_kv CHECK_INTERVAL_MIN "$v"
  ok "已保存（若改了检查间隔，请到菜单 8 重装 timer）"
  press_any
}

menu_timer() {
  while true; do
    clear 2>/dev/null || true
    echo -e "${gl_kjlan}定时任务${gl_bai}"
    echo "------------------------"
    echo "状态: $(timer_status_line)"
    if systemctl list-timers "$VTM_TIMER" --no-pager 2>/dev/null | head -5; then
      :
    fi
    echo "------------------------"
    echo "1. 安装/更新 systemd timer"
    echo "2. 卸载 timer"
    echo "3. 查看最近日志"
    echo "0. 返回"
    echo "------------------------"
    local c
    read -r -p "请输入数字: " c
    case "$c" in
      1) install_timer; press_any ;;
      2) uninstall_timer; press_any ;;
      3)
        journalctl -u "$VTM_SERVICE" -n 30 --no-pager 2>/dev/null || tail -n 30 "$VTM_LOG" 2>/dev/null || echo "无日志"
        press_any
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_advanced() {
  while true; do
    load_config
    clear 2>/dev/null || true
    echo -e "${gl_kjlan}高级${gl_bai}"
    echo "------------------------"
    echo "DRY_RUN=${DRY_RUN}"
    echo "配置: $VTM_CONFIG"
    echo "状态: $VTM_STATE"
    echo "日志: $VTM_LOG"
    echo "------------------------"
    echo "1. 切换 dry-run"
    echo "2. 重置当前计费周期 (清零用量基准)"
    echo "3. 安装脚本到本机 ($VTM_ROOT)"
    echo "4. 应用 Oracle 出站示例规则 (6.5T停服/8T关机)"
    echo "5. 查看 state 文件"
    echo "0. 返回"
    echo "------------------------"
    local c
    read -r -p "请输入数字: " c
    case "$c" in
      1)
        if [ "$DRY_RUN" = "1" ]; then set_config_kv DRY_RUN 0; ok "dry-run 关闭"
        else set_config_kv DRY_RUN 1; ok "dry-run 开启"; fi
        press_any
        ;;
      2)
        if confirm_YES "输入 YES 重置周期基准"; then
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
          ok "已重置"
        fi
        press_any
        ;;
      3) install_local; press_any ;;
      4)
        if confirm_yes "写入示例规则与 address 停服命令?"; then
          set_config_kv METRIC up
          set_config_kv QUOTA 10T
          set_config_kv "CMD_stop_heavy_app" "/root/address/app/ops/stop.sh"
          RULE_LINES=(
            "stop-app|6.5T|up|notify,run:stop_heavy_app"
            "poweroff|8T|up|notify,shutdown"
          )
          save_rules
          ok "已写入 Oracle 示例（请再配置通知）"
        fi
        press_any
        ;;
      5)
        cat "$VTM_STATE" 2>/dev/null || echo "无 state"
        press_any
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
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
      3) menu_notify ;;
      4) menu_rules ;;
      5) menu_commands ;;
      6) menu_billing ;;
      7)
        load_config
        send_notify "VPS Traffic Monitor 测试" "$(build_status_text)" \
          && ok "测试完成" || err "测试失败（检查通道配置）"
        press_any
        ;;
      8) menu_timer ;;
      9) menu_advanced ;;
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
  $0 --test-notify  发送测试通知
  $0 --install      安装脚本到 $VTM_ROOT
  $0 --install-timer 安装 systemd timer
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
      send_notify "VPS Traffic Monitor 测试" "$(build_status_text)"
      exit $?
      ;;
    --install)
      install_local
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
