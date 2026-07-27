#!/bin/sh
set -eu

# Diagnostic dump for a Pi Zero with NO built-in wifi: wifi + ethernet are both
# USB dongles hanging off a hub. Unlike wifi-brcm-diag.sh (built-in brcmfmac
# chip), we don't assume a specific driver here — capture lsusb + whatever
# kernel modules/drivers actually bound, so the right driver can be identified
# first.

OUT="/root/wifi-usb-diag-$(date +%Y%m%d-%H%M%S).log"

{
  echo "=== Date ==="
  date

  echo
  echo "=== USB topology (hub + dongles) ==="
  command -v lsusb >/dev/null 2>&1 && lsusb || echo "lsusb not available"
  command -v lsusb >/dev/null 2>&1 && lsusb -t || true

  echo
  echo "=== Interfaces ==="
  ip -brief link show || true
  ip link show || true
  ls -l /sys/class/net || true

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
  command -v rfkill >/dev/null 2>&1 && rfkill list || echo "rfkill not available"

  echo
  echo "=== Loaded USB net/wifi driver modules ==="
  lsmod | egrep -i 'usbnet|cdc_ether|cdc_ncm|asix|smsc95xx|r8152|rtl8|rtl87|r871x|8192|8188|8814|8821|ath9k_htc|mt76|mt7601u|mt7663u|zd1211|carl9170|rndis' || echo "none of the common USB net/wifi drivers matched (check lsmod full output below)"
  echo "--- full lsmod ---"
  lsmod || true

  echo
  echo "=== dmesg (USB + wifi/net relevant) ==="
  dmesg -T | egrep -i 'usb|wlan|wifi|cfg80211|mac80211|firmware|link is|carrier|eth|rndis|asix|smsc|r8152' | tail -n 300 || true

  echo
  echo "=== Current regulatory domain ==="
  iw reg get || true

  echo
  echo "=== iw dev (all wireless interfaces) ==="
  iw dev || true

  echo
  echo "=== iwconfig (signal/retries/beacon) ==="
  command -v iwconfig >/dev/null 2>&1 && iwconfig || echo "iwconfig not available"

  echo
  echo "=== NetworkManager device/connection state ==="
  command -v nmcli >/dev/null 2>&1 && nmcli device status || echo "nmcli not available"
  command -v nmcli >/dev/null 2>&1 && nmcli connection show || true

  echo
  echo "=== recent wpa_supplicant/NetworkManager journal (last 3h) ==="
  command -v journalctl >/dev/null 2>&1 && journalctl -u wpa_supplicant -u NetworkManager --no-pager --since "-3 hours" || echo "journalctl not available"

  echo
  echo "=== ethtool on wired USB dongle interface(s), if present ==="
  for ifc in /sys/class/net/*; do
    name=$(basename "$ifc")
    case "$name" in
      lo|wlan*) continue ;;
    esac
    if command -v ethtool >/dev/null 2>&1; then
      echo "-- ethtool $name --"
      ethtool "$name" || true
    fi
  done
} >"$OUT" 2>&1

echo "Saved: $OUT"

