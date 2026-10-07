#!/bin/sh
# install.sh -- install auto-fix-wifi.sh from a cloned checkout of this repo.
#
#   ./install.sh                install or upgrade. Keeps your existing
#                               /etc/auto-fix-wifi.conf and fills in any
#                               settings it doesn't have yet. On a fresh
#                               install (no conf yet) it configures via
#                               'auto-fix-wifi.sh --reconfigure', which asks
#                               which URL the HTTP check should use.
#   ./install.sh --reconfigure  same, and always runs the reconfigure: re-
#                               discovers the wifi iface, gateway, DNS server
#                               and driver module, and asks for the HTTP check
#                               URL again (default: the current one). Use
#                               after swapping a dongle or moving the Pi to
#                               another network. Other settings you edited
#                               (retries, reboot limits...) are kept.
#   ./install.sh --http-url URL|none
#                               implies --reconfigure and sets the HTTP check
#                               URL without prompting ("none" skips the HTTP
#                               check). Works without a terminal.
#
# All configuration logic lives in auto-fix-wifi.sh (--reconfigure, --check,
# --http-url); this script only installs files and delegates, so running
# '/usr/local/sbin/auto-fix-wifi.sh --reconfigure' by hand does the same thing.
# Neither mode runs the monitor's fix/reboot path: they end with a check-only
# pass that prints the ping/dns/http results.
#
# Exit status: 0 on success. If the delegated auto-fix-wifi.sh exits nonzero,
# this script finishes its output and exits with that same status (2 = bad
# arguments such as an invalid --http-url, 1 = a link-level check failed,
# anything else = unexpected failure). The files are installed in every case.
set -eu

usage() {
  echo "usage: $0 [--reconfigure] [--http-url URL|none]" >&2
}

RECONFIGURE=0
HTTP_URL_ARG=""
HTTP_URL_ARG_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reconfigure) RECONFIGURE=1 ;;
    --http-url)
      [ "$#" -ge 2 ] || { echo "--http-url needs a value" >&2; usage; exit 2; }
      HTTP_URL_ARG="$2"; HTTP_URL_ARG_SET=1; RECONFIGURE=1; shift ;;
    --http-url=*) HTTP_URL_ARG="${1#--http-url=}"; HTTP_URL_ARG_SET=1; RECONFIGURE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

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

# no conf yet = fresh install: configure it the same way --reconfigure does
if ! $SUDO test -f "$CONF"; then
  RECONFIGURE=1
fi

echo "Installing $BIN"
$SUDO install -m 0755 "$SRC_DIR/auto-fix-wifi.sh" "$BIN"

echo "Installing $CRON (every 10 minutes)"
$SUDO install -m 0644 "$SRC_DIR/auto-fix-wifi.cron" "$CRON"

echo "Installing $LOGROTATE"
$SUDO install -m 0644 "$SRC_DIR/auto-fix-wifi.logrotate" "$LOGROTATE"

if [ "$RECONFIGURE" = "1" ]; then
  echo "Configuring: $BIN --reconfigure"
  set -- --reconfigure
  if [ "$HTTP_URL_ARG_SET" = "1" ]; then
    set -- --reconfigure --http-url "$HTTP_URL_ARG"
  fi
else
  echo "Upgrading: $BIN --check (keeps your conf, fills in any missing settings)"
  set -- --check
fi
# the files above are installed either way; keep the delegated exit status so
# automation can tell a rejected --http-url or a failing check from success
rc=0
$SUDO "$BIN" "$@" || rc=$?
if [ "$rc" != "0" ]; then
  echo "NOTE: $BIN exited $rc (see above); the files are installed." >&2
fi
echo "What the bootstrap changed: grep 'bootstrap:' /var/log/auto-fix-wifi/detail.log | tail"

echo
echo "Done. Config file: $CONF"
echo "Review/edit it (check targets, retry counts, reboot limits), e.g.:"
echo "  sudo \${EDITOR:-nano} $CONF"
echo "Logs: /var/log/auto-fix-wifi/{detail.log,actions.log}"
echo "After swapping hardware or changing networks, re-run '$0 --reconfigure'."
exit "$rc"
