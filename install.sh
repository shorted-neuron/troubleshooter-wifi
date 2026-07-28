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

echo "Running first-time bootstrap (discovers iface/gateway/DNS/driver)..."
$SUDO "$BIN" || true

echo
echo "Done. Config file: $CONF"
echo "Review/edit it (check targets, retry counts, reboot threshold), e.g.:"
echo "  sudo \${EDITOR:-nano} $CONF"
echo "Logs: /var/log/auto-fix-wifi/{detail.log,actions.log}"
echo "Re-run '$BIN --rediscover' after swapping hardware (e.g. a new dongle)."

