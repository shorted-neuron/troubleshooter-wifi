#!/bin/sh
set -eu

# Diagnostic dump for a Pi Zero with NO built-in wifi: wifi + ethernet are both
# USB dongles hanging off a hub. Unlike wifi-brcm-diag.sh (built-in brcmfmac
# chip), we don't assume a specific driver here — capture lsusb + whatever
# kernel modules/drivers actually bound, so the right driver can be identified
# first.
#
# Tool availability is checked up front. A missing tool is reported once in the
# "Tool availability" section and its section is skipped. A tool that IS
# installed but fails keeps its stderr and exit code in the log — failures are
# never reported as "not available".

STAMP=$(date +%Y%m%d-%H%M%S)
NOTES=""

if [ "$(id -u)" -eq 0 ]; then
  OUT="/root/wifi-usb-diag-$STAMP.log"
else
  OUT="${TMPDIR:-/tmp}/wifi-usb-diag-$STAMP.log"
  NOTES="WARNING: not running as root; output is limited (dmesg may be restricted, rfkill/journalctl/iw may fail or show less). Re-run with sudo for a full dump. Writing log to $OUT instead of /root."
  echo "$NOTES" >&2
fi

have() { command -v "$1" >/dev/null 2>&1; }  # boolean check only

# run a command; keep its stdout+stderr in the log, note a nonzero exit, never abort
run() {
  "$@" || echo "[exit $? from: $*]"
}

# skip note for a missing tool
missing() { echo "$1 not installed, skipping"; }

{
  echo "=== Date ==="
  date
  [ -z "$NOTES" ] || echo "$NOTES"

  echo
  echo "=== Tool availability ==="
  for t in lsusb ip iw iwconfig rfkill nmcli netplan ethtool journalctl dmesg lsmod; do
    if have "$t"; then echo "$t: present"; else echo "$t: MISSING"; fi
  done

  echo
  echo "=== USB topology (hub + dongles) ==="
  if have lsusb; then
    run lsusb
    run lsusb -t
  else
    missing lsusb
  fi

  echo
  echo "=== Interfaces ==="
  if have ip; then
    run ip -brief link show
    run ip link show
  else
    missing ip
  fi
  run ls -l /sys/class/net

  echo
  echo "=== Interface -> USB device mapping ==="
  for ifc in /sys/class/net/*; do
    name=$(basename "$ifc")
    [ "$name" = "lo" ] && continue
    driver_path="$ifc/device/driver"
    if [ -e "$driver_path" ]; then
      echo "$name driver: $(basename "$(readlink -f "$driver_path")")"
    else
      echo "$name driver: (no driver link found)"
    fi
  done

  echo
  echo "=== rfkill ==="
  if have rfkill; then run rfkill list; else missing rfkill; fi

  echo
  echo "=== Loaded USB net/wifi driver modules ==="
  if have lsmod; then
    # grep exit 1 just means "no match"; real errors still land in the log via stderr
    if ! lsmod | grep -Ei 'usbnet|cdc_ether|cdc_ncm|asix|smsc95xx|r8152|rtl8|rtl87|r871x|8192|8188|8814|8821|ath9k_htc|mt76|mt7601u|mt7663u|zd1211|carl9170|rndis'; then
      echo "none of the common USB net/wifi drivers matched (check lsmod full output below)"
    fi
    echo "--- full lsmod ---"
    run lsmod
  else
    missing lsmod
  fi

  echo
  echo "=== dmesg (USB + wifi/net relevant) ==="
  if have dmesg; then
    # no pipe-masked exit status: capture first so a dmesg failure (e.g.
    # dmesg_restrict as non-root) is reported with its real error and not
    # run through the filter
    if dmesg_out=$(dmesg -T 2>&1); then
      printf '%s\n' "$dmesg_out" | grep -Ei 'usb|wlan|wifi|cfg80211|mac80211|firmware|link is|carrier|eth|rndis|asix|smsc|r8152' | tail -n 300 || true
    else
      echo "[exit $? from: dmesg -T] $dmesg_out"
    fi
  else
    missing dmesg
  fi

  echo
  echo "=== Current regulatory domain ==="
  if have iw; then run iw reg get; else missing iw; fi

  echo
  echo "=== iw dev (all wireless interfaces) ==="
  if have iw; then run iw dev; else missing iw; fi

  echo
  echo "=== iwconfig (signal/retries/beacon) ==="
  if have iwconfig; then run iwconfig; else missing iwconfig; fi

  echo
  echo "=== NetworkManager device/connection state ==="
  if have nmcli; then
    run nmcli device status
    run nmcli connection show
  else
    missing nmcli
  fi

  echo
  echo "=== netplan (file listing only: configs can hold PSKs, so contents are not dumped) ==="
  if have netplan; then
    run ls -l /etc/netplan /run/netplan
  else
    missing netplan
  fi

  echo
  echo "=== recent wpa_supplicant/NetworkManager journal (last 3h) ==="
  if have journalctl; then
    run journalctl -u wpa_supplicant -u NetworkManager --no-pager --since "-3 hours"
  else
    missing journalctl
  fi

  echo
  echo "=== ethtool on wired USB dongle interface(s), if present ==="
  if have ethtool; then
    for ifc in /sys/class/net/*; do
      name=$(basename "$ifc")
      case "$name" in
        lo|wlan*) continue ;;
      esac
      echo "-- ethtool $name --"
      run ethtool "$name"
    done
  else
    missing ethtool
  fi
} >"$OUT" 2>&1

echo "Saved: $OUT"
