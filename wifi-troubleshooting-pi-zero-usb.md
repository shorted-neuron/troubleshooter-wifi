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
unlike the `wifi-A` AP noted in the Zero 2W doc), got a DHCP lease, and stayed connected
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

## Lossy link and background-scan outages (Pi Model B, `rt2800usb` dongle, 2026-10)

Device `pi-model-b-1`: Raspberry Pi Model B (armv6l, no onboard wifi) with a
Ralink/Samsung `rt2800usb` 802.11abgn USB dongle, NetworkManager, AP `wifi-A` on
2.4 GHz channel 11. Signal was a strong -47 to -52 dBm throughout. A second Pi on
the same gateway with built-in `brcmfmac` wifi (`pi-builtin-1`) was the control and lost
0 of about 5000 pings over the same windows.

**Symptom:** `auto-fix-wifi.sh` occasionally bounced the wifi, once costing a 2m13s
outage, although the AP saw a healthy client. The AP's own log showed a client-side
disconnect with no deauth and no timeout, i.e. the monitor itself caused it.

**Measurements** (1 Hz ping to the gateway bound to `wlan0`, plus AP-side station
counters recorded in parallel, 25-30 minute runs):

| Run | Change | Lost | Notes |
|---|---|---|---|
| 1 | baseline (a display service running) | 14.1% | scan windows 34% lost, outside 11.4% |
| 2 | display service stopped | 7.7% | outside scans 5.5% |
| 3 | dongle on a USB extension cable | 9.3% | outside scans 6.1% |
| 4 | background scanning set to 3600 s (runtime only) | 8.5% | no scans; longest burst 3 pings |
| 5 | driver retry limit 2 -> 7/4 (ABA, runtime only) | 8.7% / 7.7% / 14.5% | no effect; the link drifts over time |

**Findings**
- NetworkManager hands wpa_supplicant `bgscan simple:30:-65:300` when it sees more than one BSSID
  for the SSID (here a 2.4 GHz and a 5 GHz BSS). At good signal that is a background scan
  every 300 s; with the scan itself (~22 s) the cadence was 322 s.
- Each scan is a 25-30 s window in which a third to half of the pings are lost, and the
  kernel logs a `mac80211` `ieee80211_calc_hw_conf_chan` warning when the scan *completes*
  (it is a widely reported warning on this scan path, not specific to this device). The AP
  sees the client toggle its power-save bit only around scans.
- The monitor's three retries span about 35 s, so all of them can land inside one scan and
  look like a dead link. Of three failing runs one morning, two overlapped a scan completion
(one of them led to a bounce); the other two recovered on their own by the third retry.
- Scans are only part of the loss: with scans off, 6-9% of pings were still lost, with
  replies often ~120 ms late. Hardware looked healthy (no under-voltage, no USB errors,
  USB at 480 Mb/s, 48 degC). Stopping the display service and the extension cable each
  roughly halved the baseline loss; the driver retry limit made no difference.
- The AP's retry counters did not separate this device from the control, so they
  are a poor indicator of a client's problem.

**What changed in the monitor**
- A recheck `RECHECK_WAIT` (default 45 s) after all retries fail, before any fix.
- Each attempt sends up to `PING_COUNT` pings (default 3) and `dig` uses `DNS_TRIES`
  (default 2).
A bounce does not cure baseline loss and costs minutes of outage, so false triggers are
worth avoiding. Options not taken: locking to one BSSID (stops failover to another AP),
changing bands (the 5 GHz BSS is weaker at the install location), cabling.

## Offline after an AP security change — cause confirmed (2026-10-07/08)

Resolved. The `rt2800usb` Pi above (`pi-model-b-1`), a Pi 2 Model B with the same dongle
(`pi-2-1`) and a Pi Model B+ with an `rtl8192cu` dongle (`pi-b-plus-1`) all dropped off wifi when the
AP's `wifi-A` SSID went `sae-mixed`, and stayed off (one of them was rebooted four times by the monitor,
then hit its daily cap). Cause: the NM profile held the wifi password as a 64-hex key (Imager boot seed),
which cannot be used for SAE, while NM offered SAE and wpa_supplicant preferred it. Fix: store the
password as text. Full chain, checks and the hardware table: `wifi-troubleshooting-general.md`
(section "WPA3 / SAE").

Dongle-specific notes from the incident:
- Both `rt2800usb` and `rtl8192cu` complete SAE once the text password is stored.
- `rtl8192cu` scan wedge recurred on `pi-b-plus-1` after its profile was fixed (`iw dev wlan0 scan`
  hung, then 0 BSSes). The module reload above cured it (26 networks right after). The monitor's
  own driver reload would also have done it.
- `pi-b-plus-1` and `pi-2-1` had no `auto-fix-wifi.sh` before; installed with `install.sh` once they
  were back (driver autodiscovered as `rtl8192cu` / `rt2800usb`).

## Related scripts (this dir)

- `wifi-usb-diag.sh` — driver-agnostic diagnostic dump for USB wifi/ethernet dongle
  setups (lsusb, interface→driver mapping, USB/net dmesg, NM state, ethtool). Use this
  instead of `wifi-brcm-diag.sh` (which assumes the built-in `brcmfmac` chip) on any
  Pi with no onboard wifi.


