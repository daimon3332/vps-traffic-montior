#!/bin/bash

set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$TEST_DIR/.." && pwd)
TEST_TMP="$TEST_DIR/.tmp/$$"
PASS=0
FAIL=0

cleanup() {
  case "$TEST_TMP" in
    "$TEST_DIR"/.tmp/*) rm -rf -- "$TEST_TMP" ;;
  esac
}
trap cleanup EXIT

# shellcheck source=../vps-traffic-monitor.sh
source "$PROJECT_DIR/vps-traffic-monitor.sh"

acquire_lock() {
  VTM_LOCK_HELD=1
}

release_lock() {
  VTM_LOCK_HELD=0
}

pass() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s: %s\n' "$1" "$2"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name" "expected=$expected actual=$actual"
  fi
}

assert_true() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name" "command failed: $*"
  fi
}

assert_false() {
  local name="$1"
  shift
  if "$@"; then
    fail "$name" "command unexpectedly succeeded: $*"
  else
    pass "$name"
  fi
}

reset_fixture() {
  mkdir -p "$TEST_TMP/root" "$TEST_TMP/state" "$TEST_TMP/log" \
    "$TEST_TMP/net/eth0/statistics" "$TEST_TMP/net/eth1/statistics"
  VTM_ROOT="$TEST_TMP/root"
  VTM_CONFIG="$VTM_ROOT/config.conf"
  VTM_STATE_DIR="$TEST_TMP/state"
  VTM_STATE="$VTM_STATE_DIR/state"
  VTM_LOCK="$VTM_STATE_DIR/lock"
  VTM_LOG="$TEST_TMP/log/monitor.log"
  VTM_SYS_CLASS_NET="$TEST_TMP/net"
  cat >"$VTM_CONFIG" <<'EOF'
INSTANCE_NAME="test-vps"
INTERFACE="eth0"
METRIC="up"
RESET_DAY=1
TIMEZONE="UTC"
QUOTA="10T"
TG_ENABLED=0
MAIL_ENABLED=0
DRY_RUN=0
EOF
  set_counters eth0 1000 2000
  set_counters eth1 500 700
  rm -f "$VTM_STATE"
  load_config
}

set_counters() {
  local iface="$1" rx="$2" tx="$3"
  printf '%s\n' "$rx" >"$VTM_SYS_CLASS_NET/$iface/statistics/rx_bytes"
  printf '%s\n' "$tx" >"$VTM_SYS_CLASS_NET/$iface/statistics/tx_bytes"
}

reset_fixture

assert_eq "parse binary size" "7146825580544" "$(parse_size 6.5T)"
assert_false "reject invalid size" parse_size "6x"

legacy_cycle=$(current_cycle_id)
cat >"$VTM_STATE" <<EOF
CYCLE_ID='$legacy_cycle'
STATE_IFACE='eth0'
BASE_RX=1000
BASE_TX=2000
LAST_RX=1000
LAST_TX=2000
ACC_RX=1.5e+03
ACC_TX=2.5e+03
EOF
load_state
assert_eq "legacy scientific rx state" "1500" "$ACC_RX"
assert_eq "legacy scientific tx state" "2500" "$ACC_TX"
rm -f "$VTM_STATE"

refresh_usage
assert_eq "first sample rx baseline" "0" "$RX_USED"
assert_eq "first sample tx baseline" "0" "$TX_USED"
assert_eq "state stores interface" "eth0" "$STATE_IFACE"

set_counters eth0 1300 2600
refresh_usage
assert_eq "rx growth" "300" "$RX_USED"
assert_eq "tx growth" "600" "$TX_USED"

set_counters eth0 50 70
refresh_usage
assert_eq "rx survives counter reset" "350" "$RX_USED"
assert_eq "tx survives counter reset" "670" "$TX_USED"

calibrate_usage up 2K >/dev/null
assert_eq "calibration sets total" "2048" "$TX_USED"
set_counters eth0 50 170
refresh_usage
assert_eq "growth continues after calibration" "2148" "$TX_USED"

INTERFACE=eth1
refresh_usage
assert_eq "interface switch preserves rx" "350" "$RX_USED"
assert_eq "interface switch preserves tx" "2148" "$TX_USED"
set_counters eth1 550 800
refresh_usage
assert_eq "new interface rx growth" "400" "$RX_USED"
assert_eq "new interface tx growth" "2248" "$TX_USED"

CYCLE_ID="1999-01"
OFFSET_RX=99
OFFSET_TX=99
save_state
mark_fired cycle-rule
refresh_usage
assert_eq "new cycle resets rx" "0" "$RX_USED"
assert_eq "new cycle resets tx" "0" "$TX_USED"
assert_false "new cycle clears fired rules" is_fired cycle-rule

state_before=$(cksum <"$VTM_STATE")
INTERFACE=missing0
assert_false "missing interface fails" refresh_usage
state_after=$(cksum <"$VTM_STATE")
assert_eq "missing interface keeps state" "$state_before" "$state_after"

marker="$TEST_TMP/config-executed"
cat >"$VTM_CONFIG" <<EOF
INSTANCE_NAME='\$(touch "$marker")'
INTERFACE="eth0"
METRIC="up"
RESET_DAY=1
TIMEZONE="UTC"
EOF
load_config
assert_false "config values are not executed" test -e "$marker"
secret='a\b"c'
set_config_kv MAIL_PASS "$secret"
load_config
assert_eq "config escaping round trip" "$secret" "$MAIL_PASS"

reset_fixture
cat >>"$VTM_CONFIG" <<'EOF'
TG_ENABLED=1
TG_BOT_TOKEN="TOKEN"
TG_CHAT_ID="CHAT"
MAIL_ENABLED=1
MAIL_HOST="smtp.test"
MAIL_FROM="from@test"
MAIL_TO="to@test"
RULE_1="critical|1B|up|notify,stop_address"
EOF
load_config
refresh_usage
set_counters eth0 1000 2002

NOTIFY_RESULT=1
MAIL_RESULT=0
ACTION_CALLS=0
notify_telegram() {
  return "$NOTIFY_RESULT"
}
notify_email() {
  return "$MAIL_RESULT"
}
do_stop_address() {
  ACTION_CALLS=$((ACTION_CALLS + 1))
  return 0
}

assert_false "notification failure fails check" check_rules
assert_eq "notification failure blocks action" "0" "$ACTION_CALLS"
assert_false "notification failure remains retryable" is_fired critical

NOTIFY_RESULT=0
assert_true "successful retry completes check" check_rules
assert_eq "successful retry runs action" "1" "$ACTION_CALLS"
assert_true "successful workflow marks fired" is_fired critical

cat >>"$VTM_CONFIG" <<'EOF'
DRY_RUN=1
RULE_2="dry-run-rule|1B|up|notify"
EOF
load_config
assert_true "dry run check succeeds" check_rules
assert_false "dry run does not mark fired" is_fired dry-run-rule

printf '%s tests passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
