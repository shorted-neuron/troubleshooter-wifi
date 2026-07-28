#!/bin/sh
# auto-fix-wifi.sh
#
# Consolidated always-on wifi health check + auto-recovery, meant to run from
# root's cron every ~10 minutes (see auto-fix-wifi.cron for an example entry).
# Replaces manual use of wifi-brcm-diag.sh / wifi-usb-diag.sh / retry-wifi.sh
# for ongoing monitoring; those scripts remain useful for one-shot manual
# diagnosis. Works with either the built-in brcmfmac chip (Pi Zero 2W) or a
# USB wifi dongle (e.g. rtl8192cu) since it discovers the driver name rather
# than hardcoding it.
#
# Design summary:
# Design summary:
#   - First run (or any run where config is incomplete) auto-bootstraps
#     /etc/auto-fix-wifi.conf: wifi interface, gateway IP, DNS server
#     (defaults to the system resolver from /etc/resolv.conf, freely
#     override-able), wifi driver module name, check targets, timings.
#     Re-run with --rediscover to force re-bootstrapping (e.g. after
#     swapping dongles).
#   - Each cycle: ping gateway (bound to wifi iface) + DNS lookup (against
#     the configured DNS server) + HTTP(S) check (bound to wifi iface where
#     possible, redirects never followed -- any response status counts as
#     "up", useful when the check target is a restrictive network's own
#     gateway IP rather than a real internet endpoint). All three must pass.
#   - On failure: wait 10s, retry the whole battery, up to RETRY_COUNT times.
#   - If still failing: try a scoped wifi-only fix (disconnect + reload wifi
#     driver module + reconnect). If that doesn't recover it, escalate to a
#     full fix (stop NetworkManager, reload module, start NetworkManager).
#   - If the fix doesn't recover connectivity, increment a persistent
#     consecutive-failure counter; after REBOOT_THRESHOLD consecutive failed
#     fix cycles, reboot as a last resort.
#   - Detailed step-by-step output goes to a log file (for pulling the SD
#     card later). High-level pass/fail goes to syslog every run. Any
#     restart/reload/reboot action is logged loudly to syslog (warning/err/
#     crit) AND to a dedicated actions log file.
#
# Must run as root (module unload/reload, nmcli, systemctl, reboot).

set -eu

# cron's default PATH is minimal (often just /usr/bin:/bin) and won't find
# modprobe/rmmod/ip/iw/nmcli/systemctl, which typically live in /sbin or
# /usr/sbin. Force a full PATH regardless of invocation context.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

CONF="/etc/auto-fix-wifi.conf"
STATE_DIR="/var/lib/auto-fix-wifi"
FAIL_COUNT_FILE="$STATE_DIR/consecutive_fix_failures"
LOG_DIR="/var/log/auto-fix-wifi"
DETAIL_LOG="$LOG_DIR/detail.log"
ACTIONS_LOG="$LOG_DIR/actions.log"
LOCKFILE="/var/run/auto-fix-wifi.lock"
TAG="auto-fix-wifi"

REDISCOVER=0
if [ "${1:-}" = "--rediscover" ]; then
  REDISCOVER=1
fi

# ---------------------------------------------------------------------------
# logging helpers
# ---------------------------------------------------------------------------

now() { date -Is; }

log_detail() {
  # $1 = message
  printf '%s %s\n' "$(now)" "$1" >>"$DETAIL_LOG"
}

log_syslog() {
  # $1 = priority (info|warning|err|crit), $2 = message
  logger -t "$TAG" -p "daemon.$1" "$2" || true
}

log_action() {
  # A restart/reload/reboot action: log loudly everywhere.
  # $1 = priority (warning|err|crit), $2 = message
  printf '%s [%s] %s\n' "$(now)" "$1" "$2" >>"$ACTIONS_LOG"
  log_detail "ACTION [$1]: $2"
  log_syslog "$1" "ACTION: $2"
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$LOG_DIR"
}

# ---------------------------------------------------------------------------
# config: load, or bootstrap missing pieces
# ---------------------------------------------------------------------------

conf_get() {
  # $1 = key; prints value from $CONF if present, else empty.
  # Strips only the first "key=" prefix so values containing "=" (e.g. URLs
  # with query strings) survive intact.
  [ -f "$CONF" ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$CONF"
}

conf_set() {
  # $1 = key, $2 = value; append or update in $CONF
  [ -f "$CONF" ] || : >"$CONF"
  if grep -q "^$1=" "$CONF" 2>/dev/null; then
    # in-place update (portable-ish sed -i)
    sed -i "s#^$1=.*#$1=$2#" "$CONF"
  else
    printf '%s=%s\n' "$1" "$2" >>"$CONF"
  fi
}

discover_wifi_iface() {
  iface=$(command -v iw >/dev/null 2>&1 && iw dev 2>/dev/null | awk '/Interface/{print $2; exit}') || true
  if [ -z "${iface:-}" ]; then
    for c in /sys/class/net/wlan*; do
      [ -e "$c" ] || continue
      iface=$(basename "$c")
      break
    done
  fi
  echo "${iface:-wlan0}"
}

discover_gateway() {
  # $1 = wifi iface
  # "ip route show dev <iface>" omits the "dev <iface>" token, so the "via"
  # field position shifts depending on other route flags present (proto,
  # src, metric, ...) -- search for the token after "via" rather than
  # assuming a fixed field index.
  gw=$(ip route show dev "$1" 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}') || true
  if [ -z "${gw:-}" ]; then
    gw=$(nmcli -g IP4.GATEWAY device show "$1" 2>/dev/null | head -1) || true
  fi
  if [ -z "${gw:-}" ]; then
    # last resort: whatever route on this iface specifically shows as default
    gw=$(ip route show default 2>/dev/null | awk -v ifc="$1" '{for(i=1;i<=NF;i++){if($i=="dev" && $(i+1)==ifc){for(j=1;j<=NF;j++) if($j=="via") print $(j+1); exit}}}') || true
  fi
  echo "${gw:-}"
}

discover_dns_server() {
  # $1 = wifi iface
  # "The system resolver" means /etc/resolv.conf's nameserver -- that's the
  # literal, authoritative answer to "what DNS server does this box use"
  # regardless of which interface currently owns the default route. Fall
  # back to nmcli/resolvectl only if resolv.conf is somehow unusable.
  dns=""
  if [ -f /etc/resolv.conf ]; then
    dns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf) || true
  fi
  if [ -z "${dns:-}" ] && command -v resolvectl >/dev/null 2>&1; then
    dns=$(resolvectl dns "$1" 2>/dev/null | awk '{print $NF}') || true
  fi
  if [ -z "${dns:-}" ]; then
    dns=$(nmcli -g IP4.DNS device show "$1" 2>/dev/null | head -1) || true
  fi
  echo "${dns:-}"
}

discover_wifi_driver() {
  # $1 = wifi iface
  drv_path="/sys/class/net/$1/device/driver"
  if [ -e "$drv_path" ]; then
    basename "$(readlink -f "$drv_path")"
  else
    echo ""
  fi
}

bootstrap_config_if_needed() {
  ensure_dirs
  [ -f "$CONF" ] || : >"$CONF"

  cur_iface=$(conf_get WIFI_IFACE)
  if [ "$REDISCOVER" = "1" ] || [ -z "$cur_iface" ]; then
    cur_iface=$(discover_wifi_iface)
    conf_set WIFI_IFACE "$cur_iface"
    log_detail "bootstrap: WIFI_IFACE=$cur_iface"
  fi

  cur_gw=$(conf_get GATEWAY_IP)
  if [ "$REDISCOVER" = "1" ] || [ -z "$cur_gw" ]; then
    cur_gw=$(discover_gateway "$cur_iface")
    conf_set GATEWAY_IP "$cur_gw"
    log_detail "bootstrap: GATEWAY_IP=$cur_gw"
  fi

  cur_dns=$(conf_get DNS_SERVER)
  if [ "$REDISCOVER" = "1" ] || [ -z "$cur_dns" ]; then
    cur_dns=$(discover_dns_server "$cur_iface")
    conf_set DNS_SERVER "$cur_dns"
    log_detail "bootstrap: DNS_SERVER=$cur_dns"
  fi

  cur_drv=$(conf_get WIFI_DRIVER)
  if [ "$REDISCOVER" = "1" ] || [ -z "$cur_drv" ]; then
    cur_drv=$(discover_wifi_driver "$cur_iface")
    conf_set WIFI_DRIVER "$cur_drv"
    log_detail "bootstrap: WIFI_DRIVER=$cur_drv"
  fi

  # Fixed defaults, only set if absent (never overwritten by --rediscover,
  # these aren't hardware-discovered, they're policy).
  [ -n "$(conf_get DNS_CHECK_NAME)" ]   || conf_set DNS_CHECK_NAME "example.com"
  [ -n "$(conf_get HTTP_CHECK_URL)" ]   || conf_set HTTP_CHECK_URL "https://detectportal.firefox.com/success.txt"
  [ -n "$(conf_get RETRY_COUNT)" ]      || conf_set RETRY_COUNT "3"
  [ -n "$(conf_get RETRY_WAIT)" ]       || conf_set RETRY_WAIT "10"
  [ -n "$(conf_get PING_TIMEOUT)" ]     || conf_set PING_TIMEOUT "2"
  [ -n "$(conf_get HTTP_TIMEOUT)" ]     || conf_set HTTP_TIMEOUT "5"
  [ -n "$(conf_get MODULE_RELOAD_WAIT)" ] || conf_set MODULE_RELOAD_WAIT "5"
  [ -n "$(conf_get IFACE_WAIT_MAX)" ]   || conf_set IFACE_WAIT_MAX "15"
  [ -n "$(conf_get REBOOT_THRESHOLD)" ] || conf_set REBOOT_THRESHOLD "5"
}

load_config() {
  WIFI_IFACE=$(conf_get WIFI_IFACE)
  GATEWAY_IP=$(conf_get GATEWAY_IP)
  DNS_SERVER=$(conf_get DNS_SERVER)
  WIFI_DRIVER=$(conf_get WIFI_DRIVER)
  DNS_CHECK_NAME=$(conf_get DNS_CHECK_NAME)
  HTTP_CHECK_URL=$(conf_get HTTP_CHECK_URL)
  RETRY_COUNT=$(conf_get RETRY_COUNT)
  RETRY_WAIT=$(conf_get RETRY_WAIT)
  PING_TIMEOUT=$(conf_get PING_TIMEOUT)
  HTTP_TIMEOUT=$(conf_get HTTP_TIMEOUT)
  MODULE_RELOAD_WAIT=$(conf_get MODULE_RELOAD_WAIT)
  IFACE_WAIT_MAX=$(conf_get IFACE_WAIT_MAX)
  REBOOT_THRESHOLD=$(conf_get REBOOT_THRESHOLD)
}

# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------

check_ping() {
  if [ -z "$GATEWAY_IP" ]; then
    log_detail "ping check: skipped, no GATEWAY_IP configured"
    return 1
  fi
  if ping -I "$WIFI_IFACE" -c 1 -W "$PING_TIMEOUT" "$GATEWAY_IP" >>"$DETAIL_LOG" 2>&1; then
    log_detail "ping check: OK ($GATEWAY_IP via $WIFI_IFACE)"
    return 0
  else
    log_detail "ping check: FAILED ($GATEWAY_IP via $WIFI_IFACE)"
    return 1
  fi
}

check_dns() {
  if command -v dig >/dev/null 2>&1; then
    src_ip=$(ip -4 -o addr show "$WIFI_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "${src_ip:-}" ] && [ -n "$DNS_SERVER" ]; then
      if dig -b "$src_ip" "@$DNS_SERVER" +time=3 +tries=1 +short "$DNS_CHECK_NAME" >>"$DETAIL_LOG" 2>&1; then
        log_detail "dns check: OK (dig @$DNS_SERVER $DNS_CHECK_NAME via $WIFI_IFACE src $src_ip)"
        return 0
      else
        log_detail "dns check: FAILED (dig @$DNS_SERVER $DNS_CHECK_NAME via $WIFI_IFACE src $src_ip)"
        return 1
      fi
    fi
  fi
  # Fallback: system resolver, NOT guaranteed to go out $WIFI_IFACE if
  # another interface (e.g. eth0) is also up with a default route.
  log_detail "dns check: falling back to system resolver (getent) -- not interface-bound, dig unavailable or no wifi IP yet"
  if getent hosts "$DNS_CHECK_NAME" >>"$DETAIL_LOG" 2>&1; then
    log_detail "dns check: OK (getent $DNS_CHECK_NAME)"
    return 0
  else
    log_detail "dns check: FAILED (getent $DNS_CHECK_NAME)"
    return 1
  fi
}

check_http() {
  if ! command -v curl >/dev/null 2>&1; then
    log_detail "http check: skipped, curl not installed"
    return 1
  fi
  # Deliberately no -f (accept any HTTP response status, including
  # redirects/401/403/etc -- we only care that *something* answered) and no
  # -L (never follow a redirect). This matters on networks with strict
  # filtering where only a local endpoint (e.g. the AP's own admin/gateway
  # IP) is configured as the check target: a 301 from the gateway's web UI
  # still proves the HTTP path works, and following it could send us
  # somewhere unexpected. curl only returns nonzero here on a real
  # transport-level failure (refused/timeout/DNS failure), not on the HTTP
  # status code.
  # (the "if" here is deliberate -- with `set -e`, a bare
  # `http_code=$(cmd)` assignment would abort the script on curl's nonzero
  # exit instead of letting us handle it)
  if http_code=$(curl --interface "$WIFI_IFACE" -sS --max-time "$HTTP_TIMEOUT" \
      -o /dev/null -w '%{http_code}' "$HTTP_CHECK_URL" 2>>"$DETAIL_LOG"); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ -n "$http_code" ]; then
    log_detail "http check: OK ($HTTP_CHECK_URL via $WIFI_IFACE, status=$http_code, redirects not followed)"
    return 0
  else
    log_detail "http check: FAILED ($HTTP_CHECK_URL via $WIFI_IFACE, curl_rc=$rc status=${http_code:-none})"
    return 1
  fi
}

run_cycle() {
  # Whole battery; all three must pass. Logs each sub-check regardless.
  ok=1
  check_ping || ok=0
  check_dns  || ok=0
  check_http || ok=0
  [ "$ok" = "1" ]
}

# ---------------------------------------------------------------------------
# fix actions
# ---------------------------------------------------------------------------

wait_for_iface() {
  i=0
  while [ "$i" -lt "$IFACE_WAIT_MAX" ]; do
    [ -d "/sys/class/net/$WIFI_IFACE" ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

reload_wifi_module() {
  if [ -z "$WIFI_DRIVER" ]; then
    log_detail "module reload: skipped, WIFI_DRIVER unknown"
    return 1
  fi
  log_detail "module reload: modprobe -r $WIFI_DRIVER"
  # a couple of passes, like retry-wifi.sh -- dependent modules may take a
  # moment to free up.
  n=0
  while [ "$n" -lt 3 ]; do
    if ! lsmod | grep -q "^${WIFI_DRIVER}\b"; then
      break
    fi
    modprobe -r "$WIFI_DRIVER" >>"$DETAIL_LOG" 2>&1 || true
    n=$((n + 1))
    sleep 1
  done
  sleep "$MODULE_RELOAD_WAIT"
  log_detail "module reload: modprobe $WIFI_DRIVER"
  modprobe "$WIFI_DRIVER" >>"$DETAIL_LOG" 2>&1
  wait_for_iface
}

fix_wifi_only_bounce() {
  log_action warning "checks failed $RETRY_COUNT times; attempting scoped wifi-only fix (disconnect + reload $WIFI_DRIVER + reconnect) on $WIFI_IFACE"
  nmcli device disconnect "$WIFI_IFACE" >>"$DETAIL_LOG" 2>&1 || true
  reload_wifi_module || true
  ip link set "$WIFI_IFACE" up >>"$DETAIL_LOG" 2>&1 || true
  nmcli device connect "$WIFI_IFACE" >>"$DETAIL_LOG" 2>&1 || true
  sleep 5
}

fix_full_reload() {
  log_action err "wifi-only bounce did not recover connectivity; escalating to full fix: stop NetworkManager, reload $WIFI_DRIVER, start NetworkManager"
  systemctl stop NetworkManager >>"$DETAIL_LOG" 2>&1 || true
  reload_wifi_module || true
  systemctl start NetworkManager >>"$DETAIL_LOG" 2>&1 || true
  sleep 10
}

read_fail_count() {
  [ -f "$FAIL_COUNT_FILE" ] && cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0
}

write_fail_count() {
  echo "$1" >"$FAIL_COUNT_FILE"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

ensure_dirs

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log_detail "another instance is still running; exiting"
  exit 0
fi

bootstrap_config_if_needed
load_config

log_detail "=== run start (WIFI_IFACE=$WIFI_IFACE GATEWAY_IP=$GATEWAY_IP DNS_SERVER=$DNS_SERVER WIFI_DRIVER=$WIFI_DRIVER) ==="

attempt=1
passed=0
while [ "$attempt" -le "$RETRY_COUNT" ]; do
  log_detail "check cycle attempt $attempt/$RETRY_COUNT"
  if run_cycle; then
    passed=1
    break
  fi
  if [ "$attempt" -lt "$RETRY_COUNT" ]; then
    sleep "$RETRY_WAIT"
  fi
  attempt=$((attempt + 1))
done

if [ "$passed" = "1" ]; then
  log_syslog info "check OK ($WIFI_IFACE): ping/dns/http all passed (attempt $attempt/$RETRY_COUNT)"
  write_fail_count 0
  exit 0
fi

log_syslog warning "check FAILED ($WIFI_IFACE): ping/dns/http did not all pass after $RETRY_COUNT attempts; attempting fix"

fix_wifi_only_bounce
if run_cycle; then
  log_action warning "recovered via scoped wifi-only bounce on $WIFI_IFACE"
  write_fail_count 0
  exit 0
fi

fix_full_reload
if run_cycle; then
  log_action err "recovered via full NetworkManager + module reload on $WIFI_IFACE (wifi-only bounce was insufficient)"
  write_fail_count 0
  exit 0
fi

fail_count=$(read_fail_count)
fail_count=$((fail_count + 1))
write_fail_count "$fail_count"
log_action err "fix did not recover connectivity; consecutive failed fix cycles: $fail_count/$REBOOT_THRESHOLD"

if [ "$fail_count" -ge "$REBOOT_THRESHOLD" ]; then
  log_action crit "reached $REBOOT_THRESHOLD consecutive failed fix cycles; rebooting as last resort"
  write_fail_count 0
  reboot
fi

exit 1








