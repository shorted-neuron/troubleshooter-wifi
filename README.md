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
