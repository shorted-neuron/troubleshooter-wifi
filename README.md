troubleshooter-wifi
===================

Scripts to help troubleshoot Wi-Fi issues on Raspberry Pi devices.

If stuck with a headless Pi that fell off wifi, try this one-liner if you can get access:

```bash
journalctl -u wpa_supplicant -u NetworkManager --no-pager --since "-3 hours" \
  | grep -E "CTRL-EVENT-DISCONNECTED|ASSOC-REJECT|no-secrets" ; \
  uptime ; \
  nmcli device status ; \
  date ; \
  iwconfig ; \
  echo -n "roamoff param is: " ; \
  cat /sys/module/brcmfmac/parameters/roamoff  
```

Then proceed to the [wifi-troubleshooting-pi-zero2w.md](wifi-troubleshooting-pi-zero2w.md) doc for next steps or AI help.

If the Pi has **no built-in wifi** (USB wifi/ethernet dongles via a hub instead), use
`wifi-usb-diag.sh` instead of `wifi-brcm-diag.sh` — it doesn't assume the `brcmfmac`
chip and instead captures `lsusb`, interface-to-driver mapping, and USB-relevant
`dmesg`. See [wifi-troubleshooting-pi-zero-usb.md](wifi-troubleshooting-pi-zero-usb.md)
for that device class.

## auto-fix-wifi.sh — always-on monitor + auto-recovery

`auto-fix-wifi.sh` is a driver-agnostic (works with either `brcmfmac` or a USB
dongle like `rtl8192cu`) always-on wifi health check, meant to run from root's
cron periodically. It supersedes manually running the diag/retry scripts for
*ongoing* monitoring; those scripts remain useful for one-shot manual digging.

Each run: pings the gateway, does a DNS lookup, and does an HTTPS check — all
bound to the wifi interface where possible so a working `eth0` on dual-NIC
boxes can't mask a dead wifi link. If any check fails, it waits 10s and
retries the whole battery, up to 3 times. If it's still down, it tries a
scoped wifi-only fix (disconnect + reload the wifi driver module + reconnect)
before escalating to a full fix (stop NetworkManager, reload the module,
start NetworkManager). If the fix doesn't recover connectivity for 5
consecutive cron cycles (configurable), it reboots as a last resort.

**First run auto-bootstraps** `/etc/auto-fix-wifi.conf` — discovers the wifi
interface, gateway IP, DNS server, and wifi driver module name, and fills in
sane defaults for check targets/timings. Re-run with `--rediscover` to force
re-discovery of hardware-specific values (e.g. after swapping a USB dongle).
Policy settings (check targets, retry counts, reboot threshold) can be hand-
edited in the conf file afterwards and won't be overwritten.

**Install:**

```bash
sudo cp auto-fix-wifi.sh /usr/local/sbin/auto-fix-wifi.sh
sudo chmod +x /usr/local/sbin/auto-fix-wifi.sh
sudo cp auto-fix-wifi.cron /etc/cron.d/auto-fix-wifi
sudo cp auto-fix-wifi.logrotate /etc/logrotate.d/auto-fix-wifi
```

**Logs:**

- `/var/log/auto-fix-wifi/detail.log` — full step-by-step output of every
  check, every run (for pulling off the SD card later).
- High-level pass/fail is logged to syslog every run (`logger -t auto-fix-wifi`).
- Any restart/reload/reboot action is logged loudly to syslog
  (`warning`/`err`/`crit`) **and** to `/var/log/auto-fix-wifi/actions.log`, so
  you can `tail -f` just that file to see intervention history at a glance.

**Reading the detail log — a useful diagnostic pattern:** ping (gateway) and
DNS checks are inherently weak signals on their own — the gateway is LAN-local
by definition, and the discovered DNS server may itself be reachable purely
over LAN routing even when the network's WAN/internet uplink is down (seen in
practice on a dual-subnet box: DNS resolved fine over wifi because the
resolver was reachable LAN-side, but the HTTPS check correctly failed because
wifi's subnet had no working internet route). If you see `ping check: OK` and
`dns check: OK` but `http check: FAILED` repeatedly, that's a strong hint the
problem is upstream (the AP/router isn't routing this client to the internet
— client isolation, a guest/IoT VLAN with no WAN uplink, or an ISP gateway
requiring device approval) rather than anything fixable by reloading the
wifi driver on the Pi itself.

