#!/bin/sh
# install.sh -- install auto-fix-wifi.sh from a cloned checkout of this repo.
#
#   ./install.sh                install or upgrade. Keeps your existing
#                               /etc/auto-fix-wifi.conf and fills in any
#                               settings it doesn't have yet.
#   ./install.sh --reconfigure  same, and also re-discovers the hardware/
#                               network values (wifi iface, gateway, DNS
#                               server, driver module) -- use after swapping
#                               a dongle or moving the Pi to another network.
#                               Policy settings you edited (check URL,
#                               retries, reboot limits...) are kept.
set -eu

usage() {
  echo "usage: $0 [--reconfigure]" >&2
}

BOOT_ARGS=""
case "${1:-}" in
  "") ;;
  --reconfigure) BOOT_ARGS="--rediscover" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "too many arguments" >&2; usage; exit 2
fi

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/local/sbin/auto-fix-wifi.sh
CRON=/etc/cron.d/auto-fix-wifi
LOGROTATE=/etc/logrotate.d/auto-fix-wifi
CONF=/etc/auto-fix-wifi.conf

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
else
  echo "This installer needs sudo. Run 'sudo -v' first, or re-run as root." >&2
  exit 1
fi

echo "Installing $BIN"
$SUDO install -m 0755 "$SRC_DIR/auto-fix-wifi.sh" "$BIN"

echo "Installing $CRON (every 10 minutes)"
$SUDO install -m 0644 "$SRC_DIR/auto-fix-wifi.cron" "$CRON"

echo "Installing $LOGROTATE"
$SUDO install -m 0644 "$SRC_DIR/auto-fix-wifi.logrotate" "$LOGROTATE"

if ! command -v dig >/dev/null 2>&1; then
  echo "WARNING: dig not found. Without it the DNS check can't be bound to the wifi" >&2
  echo "interface and falls back to the system resolver (could answer over eth0)." >&2
  echo "Install it: sudo apt install dnsutils  (bind9-dnsutils on newer releases)" >&2
fi

if [ -n "$BOOT_ARGS" ]; then
  echo "Reconfiguring: re-discovering iface/gateway/DNS/driver, filling in any missing settings..."
else
  echo "Running bootstrap (discovers iface/gateway/DNS/driver on first install; fills in any missing settings)..."
fi
# shellcheck disable=SC2086  # BOOT_ARGS is intentionally unquoted (empty or one flag)
$SUDO "$BIN" $BOOT_ARGS || true
echo "What the bootstrap changed: grep 'bootstrap:' /var/log/auto-fix-wifi/detail.log | tail"

# Validate HTTP_CHECK_URL now: the default assumes internet access, which an
# isolated network doesn't have. A bad target is only an advisory in the
# monitor (no fix/reboot), but it's better caught here than in syslog later.
conf_val() {
  [ -f "$CONF" ] || return 0
  # same literal-read semantics as auto-fix-wifi.sh's conf_get: one pair of
  # surrounding quotes and trailing CR/whitespace stripped
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
HTTP_URL=$(conf_val HTTP_CHECK_URL)
WIFI_IF=$(conf_val WIFI_IFACE)
if [ -z "$HTTP_URL" ]; then
  echo "HTTP check: disabled (HTTP_CHECK_URL is empty)."
elif ! command -v curl >/dev/null 2>&1; then
  echo "WARNING: curl not found; the HTTP check can't run and can't be validated." >&2
else
  echo "Testing HTTP_CHECK_URL ($HTTP_URL) via ${WIFI_IF:-default route}..."
  # same semantics as the monitor: any HTTP response counts, no redirect following
  if code=$(curl ${WIFI_IF:+--interface "$WIFI_IF"} -g -sS --max-time 10 -o /dev/null -w '%{http_code}' "$HTTP_URL"); then
    echo "  OK (HTTP status $code)"
  else
    echo "WARNING: HTTP_CHECK_URL is not reachable from this network (curl error above)." >&2
    echo "  The monitor will log a warning on every run (it won't reload drivers or reboot for this)." >&2
    echo "  Set HTTP_CHECK_URL in $CONF to something reachable here, or leave it empty to skip." >&2
  fi
fi

echo
echo "Done. Config file: $CONF"
echo "Review/edit it (check targets, retry counts, reboot threshold), e.g.:"
echo "  sudo \${EDITOR:-nano} $CONF"
echo "Logs: /var/log/auto-fix-wifi/{detail.log,actions.log}"
echo "After swapping hardware or changing networks, re-run '$0 --reconfigure'."

