#!/bin/sh
# install.sh -- install auto-fix-wifi.sh from a cloned checkout of this repo.
set -eu

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

echo "Running first-time bootstrap (discovers iface/gateway/DNS/driver)..."
$SUDO "$BIN" || true

# Validate HTTP_CHECK_URL now: the default assumes internet access, which an
# isolated network doesn't have. A bad target is only an advisory in the
# monitor (no fix/reboot), but it's better caught here than in syslog later.
conf_val() {
  [ -f "$CONF" ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$CONF"
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
  if code=$(curl ${WIFI_IF:+--interface "$WIFI_IF"} -sS --max-time 10 -o /dev/null -w '%{http_code}' "$HTTP_URL"); then
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
echo "Re-run '$BIN --rediscover' after swapping hardware (e.g. a new dongle)."

