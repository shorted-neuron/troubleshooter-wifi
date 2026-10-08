# Wifi Troubleshooting — Pi 4 / Pi 5 (built-in wifi, brcmfmac CYW43455 class)

Model-specific log. General method and NM behavior: `wifi-troubleshooting-general.md`.
Only the Pi 4 has been measured so far; no Pi 5 data yet, so everything below is Pi 4
(`pi-4-1`) unless stated otherwise.

## Environment (`pi-4-1`)

- Raspberry Pi 4 Model B Rev 1.5, Raspberry Pi OS 13 (trixie), kernel 6.18 (rpt-rpi-v8).
- Chip/firmware: `BCM4345/6`, firmware 7.45.265 (2023-08-29), driver `brcmfmac`.
- NetworkManager 1.52, wpa_supplicant 2.10, netplan-rendered profile.
- Dual band SSID `wifi-A` (separate 2.4 GHz and 5 GHz BSSes, same PSK). Profile originally
  pinned to 2.4 GHz (`802-11-wireless.band = bg`) because of 802.11r problems.
- `iw` and `wpa_cli` are in `/usr/sbin`: not in a normal user's `PATH`, found under `sudo`.

## 5 GHz at the usual location: unicast to the Pi fails (2026-10)

Question: can the 2.4 GHz band pin be removed, so the Pi can use 5 GHz after an AP-side
change removed 802.11r?

**Run 1 (pin removed, activation at the usual spot, console access only).** The Pi chose
5 GHz, associated, and had no connectivity; the supplicant looped scanning/associating,
and NM ended with `Connection activation failed: Secrets were required, but not provided`
(a side effect of the timed-out association, not a missing PSK; see general file). It was back
on 2.4 GHz only after the pin was restored at the console. The AP logged its authentication
replies not being ACKed by the Pi at about -74 dBm.

**Run 2 (pin removed, unattended).** 5 GHz associated and finished the handshake in under a
second, but DHCP never completed (45 s), the activation failed, repeated four times; one of the
5 GHz BSS also answered `ASSOC-REJECT status_code=16` once or twice. NM landed on 2.4 GHz
after about 2 minutes, and moved back to 5 GHz a few minutes later. No `auto-fix-wifi.sh`
action ran in that window.

**Run 3 (controlled, forced 5 GHz, `eth0` for access, wlan0 captured).**

- Association 5 GHz about -68 to -71 dBm at the client.
- The Pi's capture holds 11 DHCP requests over the first 69 s after association and **no DHCP
  reply until +69 s**; the router logged an OFFER/ACK for each request. Broadcast ARP from other hosts
  arrived the whole time. So unicast downlink to the Pi failed, broadcast downlink did not.
- AP side (station recorder): `tx failed` 9 of 15, 13 of 19, 15 of 27 frames in the first
  30 s (healthy clients 0.1-0.4 %). An over-the-air capture showed the AP re-sending the
  EAPOL M1 about 1 s later (first one unanswered) and DHCP replies flagged retry.
- Manual-address gateway ping during the window: 4 of 10 answered, 0.5-2 s late; after the
  first DHCP reply (+69 s) traffic flowed.

**Run 4 (A/B, six forced re-associations with `bgscan` on/off, power save explicitly off).**
All six cycles: gateway ARP never resolved (`Destination Host Unreachable`) for the few
seconds each cycle ran, in both bgscan states. Not a clean test (ping stopped after ~3 s),
but nothing improved.

**Run 5 (same procedure, Pi moved next to the main AP, 5 GHz about -50 to -54 dBm).** Clean:
NM activated in 6 s with a DHCP lease, 40 of 40 probes (one per 0.5 s) answered, the AP saw
0 retries and 0 failed in the first 30 s (47 frames) and nothing afterwards. 2.4 GHz at that
spot: -34 dBm.

**Conclusion.** The failure follows 5 GHz signal at the Pi's usual spot, about 15-20 dB
below the working one, not the AP, router, DHCP, power save, `bgscan` or regulatory domain.
Not shown: why the loss is nearly total instead of a slow link. No kernel/firmware message
pointed to a cause (the journal only had `brcmf_cfg80211_scan: Scanning suppressed:
status (4)` while the supplicant retried scans during association).

**Decision for `pi-4-1`:** keep the 2.4 GHz pin at the usual location (2.4 GHz about
-53 to -62 dBm there, stable). Un-pinning is only reasonable if the Pi is installed where its 5 GHz
signal at the AP is clearly better than about -63 dBm.

## Earlier monitor activity on this Pi (before the recheck change)

The tail of `actions.log` (2026-10-04) shows five wifi-only bounces, each after three failed
checks: three recovered at once, two escalated to the full NM + module reload
and did not recover (consecutive failed fix cycles 1/5). Cause was not investigated at the
time; the check changes of PR 4 (recheck, multi-probe) address false triggers, and the count
per day is the number to compare.

## SAE / WPA3 on this chip

wpa_supplicant 2.10 on this Pi does not list `sae` in its per-interface KeyMgmt capabilities (the
dongle Pis do), so NM never offers SAE and the profile joins with `WPA2-PSK-SHA256` even though the
AP is `sae-mixed`. This Pi was unaffected by the Imager-hashed-key problem (its saved password is
text) and by the AP change. `iw phy` says "Device supports SAE with AUTHENTICATE command", so the chip
claims support; the supplicant simply does not enable it here. A fleet with an SAE-only SSID needs
a WPA2-only SSID for this Pi. Details and the capability table: `wifi-troubleshooting-general.md`.

## Open items

- No Pi 5 measurements. Expect the same `CYW43455` class radio but confirm before reusing
  the 2.4 GHz rule of thumb.
- Check whether a second Pi 4 at a weaker or better spot shows the same -63 dBm cliff.
