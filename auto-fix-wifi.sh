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
#     gateway IP rather than a real internet endpoint).
#   - Ping and DNS are the link-level checks: either failing is a failure.
#     HTTP failing alone (ping + DNS fine) is only a warning -- a driver
#     reload can't fix an upstream/firewall problem, and reload loops drop
#     the client from the AP every cycle. HTTP_CHECK_URL empty = skip HTTP.
#   - On failure: wait 10s, retry the whole battery, up to RETRY_COUNT times.
#   - If still failing: try a scoped wifi-only fix (disconnect + reload wifi
#     driver module + reconnect). If that doesn't recover it, escalate to a
#     full fix (stop NetworkManager, reload module, start NetworkManager).
#   - If the fix doesn't recover connectivity, increment a persistent
#     consecutive-failure counter; after REBOOT_THRESHOLD consecutive failed
#     fix cycles, reboot as a last resort -- at most MAX_REBOOTS_PER_DAY
#     times per 24h (default 4) and never sooner than MIN_REBOOT_INTERVAL
#     after the previous one (default 60m; accepts e.g. 90s, 60m, 1h, 1d,
#     any case; a bare number is minutes). Otherwise it only logs (a reboot
#     that doesn't fix anything must not repeat forever).
#   - Every run compares the configured GATEWAY_IP with the live default
#     route on the wifi iface and warns on mismatch (stale config after
#     moving networks). It never rewrites the config on its own; use
#     --rediscover.
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
REBOOT_TIMES_FILE="$STATE_DIR/reboot_epochs"
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
  # with query strings) survive intact. The conf is read literally, NOT
  # sourced by a shell, so quoting/escaping isn't interpreted: tolerate the
  # natural KEY="value" / KEY='value' style by stripping one pair of matching
  # surrounding quotes, plus trailing CR/whitespace (stray quotes, CRLF line
  # endings and trailing spaces all make curl reject the URL).
  [ -f "$CONF" ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 {
      v = $0; sub(/^[^=]*=/, "", v)
      gsub(/\r/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (length(v) >= 2) {
        f = substr(v, 1, 1); l = substr(v, length(v))
        if ((f == "\"" && l == "\"") || (f == "\047" && l == "\047")) v = substr(v, 2, length(v) - 2)
      }
      print v; exit
    }' "$CONF"
}

conf_has() {
  # $1 = key; true if "key=" line exists in $CONF, even with an empty value
  [ -f "$CONF" ] && grep -q "^$1=" "$CONF"
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
  # device/driver -> /sys/bus/<bus>/drivers/<driver name>. The driver name
  # usually equals the module name but isn't guaranteed to; the driver dir's
  # "module" symlink -> /sys/module/<modname> is exact, when present (absent
  # for built-in drivers), so prefer it and fall back to the driver name.
  drv_path="/sys/class/net/$1/device/driver"
  if [ -e "$drv_path" ]; then
    drv_dir=$(readlink -f "$drv_path")
    if [ -L "$drv_dir/module" ]; then
      basename "$(readlink -f "$drv_dir/module")"
    else
      basename "$drv_dir"
    fi
  else
    echo ""
  fi
}

conf_refresh() {
  # $1 = key, $2 = freshly discovered value. On --rediscover, never replace a
  # working value with an empty result (e.g. link down while rediscovering).
  old=$(conf_get "$1")
  if [ -z "$2" ] && [ -n "$old" ]; then
    log_detail "bootstrap: WARNING could not rediscover $1 (nothing found); keeping $old"
    return 0
  fi
  conf_set "$1" "$2"
  log_detail "bootstrap: $1=$2"
}

conf_default() {
  # $1 = key, $2 = default. Fills in a missing/empty key; never overwrites a
  # value. Logged, so a --reconfigure shows exactly which params it added.
  [ -z "$(conf_get "$1")" ] || return 0
  conf_set "$1" "$2"
  log_detail "bootstrap: added missing default $1=$2"
}

bootstrap_config_if_needed() {
  ensure_dirs
  if [ ! -f "$CONF" ]; then
    cat >"$CONF" <<'EOF'
# auto-fix-wifi.conf -- plain KEY=value, read literally (NOT sourced by a shell):
# no escaping or variable expansion. Write values bare, e.g.
#   HTTP_CHECK_URL=https://example.invalid/path?a=1&b=2
# One pair of surrounding quotes is tolerated and stripped. Empty HTTP_CHECK_URL
# skips the HTTP check.
EOF
  fi

  cur_iface=$(conf_get WIFI_IFACE)
  if [ "$REDISCOVER" = "1" ] || [ -z "$cur_iface" ]; then
    cur_iface=$(discover_wifi_iface)
    conf_set WIFI_IFACE "$cur_iface"
    log_detail "bootstrap: WIFI_IFACE=$cur_iface"
  fi

  if [ "$REDISCOVER" = "1" ] || [ -z "$(conf_get GATEWAY_IP)" ]; then
    conf_refresh GATEWAY_IP "$(discover_gateway "$cur_iface")"
  fi

  if [ "$REDISCOVER" = "1" ] || [ -z "$(conf_get DNS_SERVER)" ]; then
    conf_refresh DNS_SERVER "$(discover_dns_server "$cur_iface")"
  fi

  if [ "$REDISCOVER" = "1" ] || [ -z "$(conf_get WIFI_DRIVER)" ]; then
    conf_refresh WIFI_DRIVER "$(discover_wifi_driver "$cur_iface")"
  fi

  # Fixed defaults, only set if absent/empty (never overwritten by
  # --rediscover, these aren't hardware-discovered, they're policy). This runs
  # on every start, so a conf from an older version gets any newly added
  # settings filled in automatically.
  conf_default DNS_CHECK_NAME "example.com"
  # HTTP_CHECK_URL: only defaulted when the key is absent. An existing empty
  # value means "skip the HTTP check" (isolated networks with no internet and
  # no reachable local web endpoint). The default assumes internet access --
  # set it to something reachable on this network segment.
  if ! conf_has HTTP_CHECK_URL; then
    conf_set HTTP_CHECK_URL "https://api.ipify.org/"   # keep in sync with install.sh
    log_detail "bootstrap: added missing default HTTP_CHECK_URL"
  fi
  conf_default RETRY_COUNT "3"
  conf_default RETRY_WAIT "10"
  conf_default PING_TIMEOUT "2"
  conf_default HTTP_TIMEOUT "5"
  conf_default MODULE_RELOAD_WAIT "5"
  conf_default IFACE_WAIT_MAX "15"
  conf_default REBOOT_THRESHOLD "5"
  conf_default MAX_REBOOTS_PER_DAY "4"
  conf_default MIN_REBOOT_INTERVAL "60m"
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
  # Built-in default applies even if the key is missing/empty/non-numeric in
  # the conf (e.g. a conf hand-edited or created before this setting existed).
  MAX_REBOOTS_PER_DAY=$(conf_get MAX_REBOOTS_PER_DAY)
  case "$MAX_REBOOTS_PER_DAY" in
    ''|*[!0-9]*) MAX_REBOOTS_PER_DAY=4 ;;
  esac
  MIN_REBOOT_INTERVAL=$(conf_get MIN_REBOOT_INTERVAL)
  if [ -z "$MIN_REBOOT_INTERVAL" ]; then
    MIN_REBOOT_INTERVAL=60m
  elif ! parse_duration "$MIN_REBOOT_INTERVAL" >/dev/null; then
    log_syslog warning "invalid MIN_REBOOT_INTERVAL '$MIN_REBOOT_INTERVAL' in $CONF (use e.g. 90s, 60m, 1h, 1d); using 60m"
    log_detail "WARNING: invalid MIN_REBOOT_INTERVAL '$MIN_REBOOT_INTERVAL'; using 60m"
    MIN_REBOOT_INTERVAL=60m
  fi
  MIN_REBOOT_INTERVAL_SECS=$(parse_duration "$MIN_REBOOT_INTERVAL")
}

parse_duration() {
  # $1 = duration like 90s, 60m, 1h, 1d (any case); bare number = minutes.
  # Prints seconds, returns 1 (printing nothing) if unparseable.
  d=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$d" in
    *[!0-9smhd]*|''|[smhd]*|*[smhd]?*) return 1 ;;
  esac
  case "$d" in
    *s) n=${d%s}; mult=1 ;;
    *m) n=${d%m}; mult=60 ;;
    *h) n=${d%h}; mult=3600 ;;
    *d) n=${d%d}; mult=86400 ;;
    *)  n=$d;     mult=60 ;;
  esac
  [ -n "$n" ] || return 1
  echo $((n * mult))
}

warn_if_gateway_stale() {
  # Compare configured gateway to the live default route on the wifi iface.
  # Warn only: auto-rewriting config could mask a real routing problem.
  live_gw=$(discover_gateway "$WIFI_IFACE")
  if [ -n "$live_gw" ] && [ "$live_gw" != "$GATEWAY_IP" ]; then
    log_syslog warning "configured GATEWAY_IP ($GATEWAY_IP) differs from live default route on $WIFI_IFACE ($live_gw); config may be stale, run auto-fix-wifi.sh --rediscover"
    log_detail "WARNING: configured GATEWAY_IP=$GATEWAY_IP differs from live gateway $live_gw on $WIFI_IFACE (stale config? --rediscover)"
  fi
}

# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------

# Per-check results from the last run_cycle: ok | FAIL | skipped
PING_RES=""
DNS_RES=""
HTTP_RES=""

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
    src_ip=$(ip -4 -o addr show "$WIFI_IFACE" 2>>"$DETAIL_LOG" | awk '{print $4}' | cut -d/ -f1 | head -1) || true
    if [ -z "${src_ip:-}" ]; then
      # no IPv4 on the wifi iface IS a wifi failure; don't fall back to the
      # system resolver, which could answer over eth0 and look healthy
      log_detail "dns check: FAILED ($WIFI_IFACE has no IPv4 address)"
      return 1
    fi
    if [ -n "$DNS_SERVER" ]; then
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
  # another interface (e.g. eth0) is also up with a default route. Only
  # reached when dig is missing or DNS_SERVER is empty. The ping check is
  # interface-bound and still covers the link itself.
  log_detail "dns check: WARNING falling back to system resolver (getent), NOT interface-bound: dig not installed (install dnsutils/bind9-dnsutils) or DNS_SERVER empty"
  if getent hosts "$DNS_CHECK_NAME" >>"$DETAIL_LOG" 2>&1; then
    log_detail "dns check: OK (getent $DNS_CHECK_NAME)"
    return 0
  else
    log_detail "dns check: FAILED (getent $DNS_CHECK_NAME)"
    return 1
  fi
}

check_http() {
  if [ -z "$HTTP_CHECK_URL" ]; then
    log_detail "http check: skipped, HTTP_CHECK_URL empty"
    return 2
  fi
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
  if http_code=$(curl --interface "$WIFI_IFACE" -g -sS --max-time "$HTTP_TIMEOUT" \
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
  # Whole battery, every sub-check logged regardless. Ping + DNS are the
  # link-level checks and must pass; HTTP failing alone is only a warning
  # (see header). Sets PING_RES/DNS_RES/HTTP_RES for the caller's log lines.
  # (if/else rather than `check || rc=$?`: keeps set -e from tripping)
  ok=1
  if check_ping; then PING_RES=ok; else PING_RES=FAIL; ok=0; fi
  if check_dns;  then DNS_RES=ok;  else DNS_RES=FAIL;  ok=0; fi
  if check_http; then
    HTTP_RES=ok
  else
    if [ "$?" = "2" ]; then HTTP_RES=skipped; else HTTP_RES=FAIL; fi
  fi
  [ "$ok" = "1" ]
}

results() { echo "ping=$PING_RES dns=$DNS_RES http=$HTTP_RES"; }

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
  # modprobe -r refuses to unload a module that other modules still use. On
  # brcmfmac the vendor shim (brcmfmac_cyw or brcmfmac_wcc, whichever this
  # board loads) depends on it, so unloading only "brcmfmac" fails every
  # time -- the exact no-op bug documented in wifi-troubleshooting-pi-zero2w.md.
  # Read the dependents from lsmod's "Used by" column and unload them first
  # rather than hardcoding vendor module names.
  deps=$(lsmod | awk -v m="$WIFI_DRIVER" '$1 == m { print $4 }' | tr ',' ' ') || true
  log_detail "module reload: $WIFI_DRIVER dependents: ${deps:-none}"
  # a couple of passes, like retry-wifi.sh -- dependent modules may take a
  # moment to free up.
  n=0
  while [ "$n" -lt 3 ]; do
    if ! lsmod | grep -q "^${WIFI_DRIVER}\b"; then
      break
    fi
    for d in $deps; do
      [ "$d" = "-" ] && continue
      log_detail "module reload: modprobe -r $d"
      modprobe -r "$d" >>"$DETAIL_LOG" 2>&1 || true
    done
    log_detail "module reload: modprobe -r $WIFI_DRIVER"
    modprobe -r "$WIFI_DRIVER" >>"$DETAIL_LOG" 2>&1 || true
    n=$((n + 1))
    sleep 1
  done
  if lsmod | grep -q "^${WIFI_DRIVER}\b"; then
    log_detail "module reload: WARNING $WIFI_DRIVER still loaded after unload attempts (still in use?)"
  fi
  sleep "$MODULE_RELOAD_WAIT"
  log_detail "module reload: modprobe $WIFI_DRIVER"
  modprobe "$WIFI_DRIVER" >>"$DETAIL_LOG" 2>&1
  # dependents normally come back via device match; load any that don't,
  # best effort (a no-op if already loaded).
  for d in $deps; do
    [ "$d" = "-" ] && continue
    modprobe "$d" >>"$DETAIL_LOG" 2>&1 || true
  done
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

reboots_last_24h() {
  # Prints how many reboots this script initiated in the last 24h; prunes older
  # entries from $REBOOT_TIMES_FILE.
  [ -f "$REBOOT_TIMES_FILE" ] || { echo 0; return 0; }
  cutoff=$(( $(date +%s) - 86400 ))
  awk -v c="$cutoff" '$1 >= c' "$REBOOT_TIMES_FILE" >"$REBOOT_TIMES_FILE.tmp" || true
  mv "$REBOOT_TIMES_FILE.tmp" "$REBOOT_TIMES_FILE"
  wc -l <"$REBOOT_TIMES_FILE" | tr -d ' '
}

last_reboot_epoch() {
  # Prints epoch of the most recent reboot this script initiated, 0 if none.
  if [ -s "$REBOOT_TIMES_FILE" ]; then
    tail -n 1 "$REBOOT_TIMES_FILE"
  else
    echo 0
  fi
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

warn_if_gateway_stale

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
  if [ "$HTTP_RES" = "FAIL" ]; then
    # link is fine, only the HTTP target failed: warn, do NOT touch the driver
    log_syslog warning "check OK with warning ($WIFI_IFACE): $(results) -- link-level checks pass, HTTP target ($HTTP_CHECK_URL) failing; not attempting a fix (check HTTP_CHECK_URL is reachable from this network)"
  else
    log_syslog info "check OK ($WIFI_IFACE): $(results) (attempt $attempt/$RETRY_COUNT)"
  fi
  write_fail_count 0
  exit 0
fi

log_syslog warning "check FAILED ($WIFI_IFACE): $(results) after $RETRY_COUNT attempts; attempting fix"

fix_wifi_only_bounce
if run_cycle; then
  log_action warning "recovered via scoped wifi-only bounce on $WIFI_IFACE ($(results))"
  write_fail_count 0
  exit 0
fi

fix_full_reload
if run_cycle; then
  log_action err "recovered via full NetworkManager + module reload on $WIFI_IFACE (wifi-only bounce was insufficient; $(results))"
  write_fail_count 0
  exit 0
fi

fail_count=$(read_fail_count)
fail_count=$((fail_count + 1))
write_fail_count "$fail_count"
log_action err "fix did not recover connectivity ($(results)); consecutive failed fix cycles: $fail_count/$REBOOT_THRESHOLD"

if [ "$fail_count" -ge "$REBOOT_THRESHOLD" ]; then
  recent=$(reboots_last_24h)
  if [ "$recent" -ge "$MAX_REBOOTS_PER_DAY" ]; then
    # a reboot that didn't help last time won't help now; stop and just log
    log_action crit "reached $REBOOT_THRESHOLD consecutive failed fix cycles ($(results)) but already rebooted $recent times in the last 24h (max $MAX_REBOOTS_PER_DAY); NOT rebooting, needs human attention"
  elif since=$(( $(date +%s) - $(last_reboot_epoch) )); [ "$since" -lt "$MIN_REBOOT_INTERVAL_SECS" ]; then
    # fail counter stays at/above threshold, so the next run re-evaluates
    log_action crit "reached $REBOOT_THRESHOLD consecutive failed fix cycles ($(results)) but last reboot was ${since}s ago (MIN_REBOOT_INTERVAL=$MIN_REBOOT_INTERVAL); NOT rebooting yet, $((MIN_REBOOT_INTERVAL_SECS - since))s to go"
  else
    log_action crit "reached $REBOOT_THRESHOLD consecutive failed fix cycles ($(results)); rebooting as last resort (reboot $((recent + 1))/$MAX_REBOOTS_PER_DAY in 24h)"
    date +%s >>"$REBOOT_TIMES_FILE"
    write_fail_count 0
    reboot
  fi
fi

exit 1








