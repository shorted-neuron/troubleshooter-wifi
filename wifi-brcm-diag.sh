#!/bin/sh
set -eu

OUT="/root/wifi-brcmf-diag-$(date +%Y%m%d-%H%M%S).log"

{
  echo "=== Date ==="
  date

  echo
  echo "=== Interfaces ==="
  ip link show || true
  ls -l /sys/class/net || true

  echo
  echo "=== rfkill ==="
  command -v rfkill >/dev/null 2>&1 && rfkill list || true

  echo
  echo "=== Module state ==="
  lsmod | egrep -i 'brcmfmac|brcmutil|cfg80211|mac80211|brcm' || true

  echo
  echo "=== dmesg (Wi-Fi relevant) ==="
  dmesg -T | egrep -i 'brcmfmac|brcmf_sdio|dongle|sdio|firmware|wl0|cfg80211|mac80211|wlan|rfkill|mmc1' | tail -n 300 || true

  echo
  echo "=== Current regulatory domain ==="
  iw reg get || true

  echo
  echo "=== iwconfig (signal/retries/beacon) ==="
  command -v iwconfig >/dev/null 2>&1 && iwconfig || true

  echo
  echo "=== brcmfmac roamoff param ==="
  cat /sys/module/brcmfmac/parameters/roamoff || echo "roamoff param not present"
} >"$OUT" 2>&1

echo "Saved: $OUT"

