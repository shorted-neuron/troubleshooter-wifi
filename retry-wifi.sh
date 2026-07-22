#!/bin/sh
set -eu

log="retry-wifi-$(date +%Y%m%d-%H%M%S).log"

{
  echo "=== retry start: $(date -Is) ==="

  echo
  echo "== current interfaces =="
  ip link show || true
  echo "== /sys/class/net =="
  ls -l /sys/class/net || true

  echo
  echo "== current rfkill =="
  command -v rfkill >/dev/null 2>&1 && rfkill list || true

  echo "== stop NetworkManager =="
  systemctl stop NetworkManager
  echo
  echo "== unload modules (if loaded) =="
  # Order matters a bit: brcmfmac depends on cfg80211/mac80211/brcmfmac_wcc|brcmfmac_cyw
  # (the shim module name varies by chip vendor variant -- Cypress vs original Broadcom
  # manufacture -- include both so this works regardless of which one this board loads;
  # verify actually-loaded name via `lsmod | grep brcmfmac` before relying on this list)
  # loop 5 times so that we wind up unloading no matter what
  for n in 1 2 3 4 5 ; do
  for m in brcmfmac_cyw brcmfmac_wcc brcmfmac brcmutil cfg80211 mac80211; do
    if lsmod | grep -q "^${m}\b"; then
      echo "rmmod $m"
      modprobe -r "$m" || true
    else
      echo module $m not in list on try $n
    fi
  done
  echo try $n done
  done

  # uncomment for an interactive prompt...
  # read -p "ready to restart?  if not press Ctrl-C" junk

  echo
  echo "== reload modules =="
  modprobe brcmutil
  modprobe cfg80211
  modprobe mac80211
  modprobe brcmfmac

  echo
  echo "== wait for wlan0 (up to ~15s) =="
  i=0
  while [ $i -lt 15 ]; do
    if [ -d /sys/class/net/wlan0 ]; then
      echo wlan0 seems to be available
      break
    fi
    i=$((i+1))
    sleep 1
  done

  sleep 10
  echo "== start NetworkManager =="
  systemctl start NetworkManager
  echo
  sleep 10
  echo
  echo "== interfaces after reload =="
  ip link show || true
  ls -l /sys/class/net || true

  echo
  echo "== bring wlan0 up (if present) =="
  if ip link show wlan0 >/dev/null 2>&1; then
    ip link set wlan0 up || true
    iw dev wlan0 info || true
  else
    echo "wlan0 not present; dumping last brcmfmac-related dmesg lines:"
    dmesg -T | egrep -i 'brcmfmac|brcmf_sdio|dongle|sdio|firmware|wl0|cfg80211|mac80211|wlan|mmc1' | tail -n 120 || true
  fi

  echo
  echo "=== retry end: $(date -Is) ==="

} 2>&1 | tee "$log"

echo "Saved: $log"
echo "Run: cat $log"

