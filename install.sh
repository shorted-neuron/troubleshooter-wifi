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
#   ./install.sh --cron-offset N|auto
#                               minute offset (0 to step-1) of the cron schedule:
#                               N-59/step. "auto" derives it from this host: the last
#                               byte of the wifi MAC (else eth0's) modulo the step, so
#                               the fleet does not all run in the same minute.
#                               Default: "auto", except that an upgrade keeps the
#                               schedule already installed.
#   ./install.sh --cron-step N  minutes between runs: 1 2 3 4 5 6 10 12 15 20 30
#                               (default 20). Without --cron-offset, an installed
#                               offset that fits the new step is kept.
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
  echo "usage: $0 [--reconfigure] [--http-url URL|none] [--cron-offset N|auto] [--cron-step N]" >&2
}

RECONFIGURE=0
HTTP_URL_ARG=""
HTTP_URL_ARG_SET=0
CRON_OFFSET=""      # auto or 0-19 (empty = not given)
CRON_OFFSET_SET=0
CRON_STEP=""        # minutes between runs (empty = not given)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reconfigure) RECONFIGURE=1 ;;
    --http-url)
      [ "$#" -ge 2 ] || { echo "--http-url needs a value" >&2; usage; exit 2; }
      HTTP_URL_ARG="$2"; HTTP_URL_ARG_SET=1; RECONFIGURE=1; shift ;;
    --http-url=*) HTTP_URL_ARG="${1#--http-url=}"; HTTP_URL_ARG_SET=1; RECONFIGURE=1 ;;
    --cron-offset)
      [ "$#" -ge 2 ] || { echo "--cron-offset needs a value" >&2; usage; exit 2; }
      CRON_OFFSET="$2"; CRON_OFFSET_SET=1; shift ;;
    --cron-offset=*) CRON_OFFSET="${1#--cron-offset=}"; CRON_OFFSET_SET=1 ;;
    --cron-step)
      [ "$#" -ge 2 ] || { echo "--cron-step needs a value" >&2; usage; exit 2; }
      CRON_STEP="$2"; shift ;;
    --cron-step=*) CRON_STEP="${1#--cron-step=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [ "$CRON_OFFSET_SET" = "1" ]; then
  case "$CRON_OFFSET" in
    auto|[0-9]|[1-5][0-9]) ;;
    *) echo "--cron-offset must be a number 0-59 or auto" >&2; usage; exit 2 ;;
  esac
fi
case "$CRON_STEP" in
  ""|1|2|3|4|5|6|10|12|15|20|30) ;;
  *) echo "--cron-step must be one of 1 2 3 4 5 6 10 12 15 20 30" >&2; usage; exit 2 ;;
esac

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

# Minute field of the cron schedule (N-59/step). A per-host offset keeps the whole fleet
# from running (and bouncing wifi after an AP blip) in the same minute. "auto" is
# the last byte of the wifi MAC (else eth0's) modulo the step: stable per hardware and
# easy to predict from an inventory. Without a usable MAC it falls back to a
# checksum of the machine-id (hostname if missing).
host_offset() {
  step=$1
  mac=""
  for d in /sys/class/net/wlan* /sys/class/net/eth0; do
    [ -r "$d/address" ] || continue
    mac=$(cat "$d/address" 2>/dev/null) || continue
    break
  done
  last=${mac##*:}
  case "$last" in
    [0-9a-fA-F][0-9a-fA-F]) echo $(( 0x$last % step )); return 0 ;;
  esac
  n=$(printf '%s' "$(cat /etc/machine-id 2>/dev/null || hostname)" | cksum | cut -d' ' -f1)
  echo $((n % step))
}
existing_sched=""
if $SUDO test -f "$CRON"; then
  # $1 is awk's field, not a shell variable
  # shellcheck disable=SC2016
  existing_sched=$($SUDO awk '!/^[[:space:]]*#/ && NF { print $1; exit }' "$CRON" || true)
fi
# the installed schedule, if it has the N-59/step (or */step) shape
ex_off=""; ex_step=""
if printf '%s' "$existing_sched" | grep -Eq '^(\*|[0-9]+-59)/[0-9]+$'; then
  ex_step=${existing_sched##*/}
  ex_off=${existing_sched%%[-/]*}
  [ "$ex_off" != "*" ] || ex_off=0
fi
step=${CRON_STEP:-${ex_step:-20}}
if [ -n "$CRON_OFFSET" ]; then
  off=$CRON_OFFSET
  [ "$off" != "auto" ] || off=$(host_offset "$step")
elif [ -n "$ex_off" ] && [ "$ex_off" -lt "$step" ]; then
  off=$ex_off                    # upgrade: the installed offset stays
else
  off=$(host_offset "$step")     # fresh install, or an offset that no longer fits
fi
if [ "$off" -ge "$step" ]; then
  echo "--cron-offset $off does not fit a $step-minute step (0-$((step - 1)))" >&2
  usage; exit 2
fi
SCHED="$off-59/$step"
echo "Installing $BIN"
$SUDO install -m 0755 "$SRC_DIR/auto-fix-wifi.sh" "$BIN"

cron_tmp=$(mktemp)
trap 'rm -f "$cron_tmp"' EXIT
sed "s|^\*/20 |$SCHED |" "$SRC_DIR/auto-fix-wifi.cron" >"$cron_tmp"
echo "Installing $CRON (every $step minutes, minute field: $SCHED)"
$SUDO install -m 0644 "$cron_tmp" "$CRON"

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
