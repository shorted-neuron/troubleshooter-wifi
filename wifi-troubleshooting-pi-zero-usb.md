# Wifi Troubleshooting — Pi Zero (no built-in wifi, USB hub + wifi/eth dongles)

Distinct from `wifi-troubleshooting-pi-zero2w.md`: this unit is an original Pi Zero
(armv6l) with **no onboard wifi/BLE chip**. A USB hub is attached (Terminus 7-port),
carrying a USB wifi dongle and a USB ethernet dongle. Different hardware/driver stack
entirely — none of the `brcmfmac`/`roamoff` findings from the Zero 2W doc apply here.

## Environment (this unit — call it `pi-zero-usb-1`)

- Board: Raspberry Pi Zero (armv6l), imaged via `rpi-imager`.
- USB hub: Terminus Technology 7-port hub (`1a40:0201`).
- Wifi dongle: TRENDnet TEW-648UBM, Realtek RTL8188CUS chipset, driver `rtl8192cu`.
- Ethernet dongle: TP-Link UE300, Realtek RTL8153 chipset, driver `r8152`.
- Network stack: NetworkManager (no netplan wifi config was ever rendered — see below).

## Session 1 findings (2026-07-28)

### Issue 1 — wifi was never configured (not a recurrence of any known bug)

`nmcli connection show` only listed the wired connection — **no wifi profile existed
at all**. `iwconfig` showed `ESSID:off/any`, `Not-Associated`. Netplan's two
`90-NM-<uuid>.yaml` render-back files were both empty (0 bytes). No
`/etc/NetworkManager/system-connections/*.nmconnection` for wifi, no
`wpa_supplicant.conf`. Conclusion: this was a fresh `rpi-imager` image where only
ethernet was set up during imaging; wifi was simply never configured, not a
disconnect/reconnect bug like the Zero 2W's brcmfmac issue.

### Issue 2 — `rtl8192cu` scan wedged after boot

Before any wifi profile existed, `nmcli device wifi list ifname wlan0` returned an
empty table (no APs at all, including ones known to be in range), and `iw dev wlan0
scan` hung indefinitely with **no corresponding dmesg activity** — i.e. the driver
never even logged an attempt. `rfkill` showed unblocked, `ip link` showed the
interface administratively up. This looks like a wedged firmware/driver state on the
`rtl8192cu` chip (known to be somewhat flaky), not an RF or config issue.

**Fix**: reload the driver module:

```sh
ip link set wlan0 down
rmmod rtl8192cu
modprobe rtl8192cu
ip link set wlan0 up
```

After reload, `iw dev wlan0 scan` immediately returned full results (multiple
neighboring APs visible, good signal levels on the target SSID). This is the wifi
analog of `retry-wifi.sh`'s module-reload approach for the built-in brcmfmac case —
worth adding a `rtl8192cu`-aware variant of that script if this recurs.

### Fix applied

```sh
nmcli device wifi connect "<SSID>" password "<PSK>" ifname wlan0
```

Associated cleanly (WPA-PSK, no FT/802.11r involved — this AP doesn't advertise it,
unlike the `blue` AP noted in the Zero 2W doc), got a DHCP lease, and stayed connected
through a short monitoring window. Credentials were applied directly via `nmcli` on
the device only — never written to any file in this repo.

## If it recurs

1. Check `nmcli connection show` first — confirm a wifi profile still exists (rule
   out it being deleted/reset again).
2. If `nmcli device wifi list` comes back empty or `iw dev wlan0 scan` hangs, try the
   `rmmod rtl8192cu && modprobe rtl8192cu` reload above before assuming an RF/AP
   problem.
3. Watch for USB power issues on the hub — dmesg during boot showed a `usb 1-1.6`
   (unrelated HID receiver on the same hub) reset/reconnect a few seconds after the
   wifi dongle's firmware load; if wifi or ethernet dongles start dropping in tandem
   with USB resets, suspect hub power budget, not driver/firmware.
4. If wifi drops in a loop reminiscent of the Zero 2W bug (`CTRL-EVENT-DISCONNECTED`,
   `ASSOC-REJECT`), note this chipset has no `roamoff` module param — that fix does
   not apply here. Look for `rtl8192cu`/`rtlwifi`-specific power-save or roaming
   options instead.

## Related scripts (this dir)

- `wifi-usb-diag.sh` — driver-agnostic diagnostic dump for USB wifi/ethernet dongle
  setups (lsusb, interface→driver mapping, USB/net dmesg, NM state, ethtool). Use this
  instead of `wifi-brcm-diag.sh` (which assumes the built-in `brcmfmac` chip) on any
  Pi with no onboard wifi.

