# Wifi Troubleshooting — Pi 4 / Pi 5 (built-in wifi, brcmfmac CYW43455 class)

Model-specific log. General method and NM behavior: `wifi-troubleshooting-general.md`.
The Pi 4 (`pi-4-1`, `pi-4-2`) has been measured in detail; one Pi 5 (`pi-5-1`) has only been
surveyed (below). Everything else is Pi 4 (`pi-4-1`) unless stated otherwise.

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

**Conclusion.** The failure follows the 5 GHz link at the Pi's usual spot (AP-side -63 to -77 dBm,
about 15-20 dB below the working one), not the AP, router, DHCP, power save, `bgscan` or regulatory
domain. A second Pi 4 (`pi-4-2`, same firmware) at a similar AP-side level (about -71 dBm average)
stayed connected for 15 h with 2.5 % of AP frames failed, so signal strength alone is not the whole
explanation (see the table in the general file).
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
dongle Pis do), so NM never offers SAE and the profile joins with `WPA2-PSK-SHA256` even though the AP is
`sae-mixed`. This Pi was unaffected by the Imager-hashed-key problem (its saved password is text) and by
the AP change.

SAE does work on this chip when forced (tested on `pi-4-2`, 2.4 GHz BSS, temporary cloned profile with
`key-mgmt=sae`): the kernel hands SAE to userspace, wpa_supplicant 2.10 completes the exchange, but by
default derives the password element with hunting-and-pecking while the association advertises H2E. The
AP (`sae_pwe=2`) then refuses the association with status 1 ("indicates support for SAE H2E, but did not
use it"). Setting the supplicant's `sae_pwe` to 1 at runtime fixed it: SAE connected, `key_mgmt=SAE`, 0 %
loss over a short ping test. A persistent setup (boot service, dispatcher hook, second profile) is described below and was tested on
one Pi 4. Cross-model background: `wifi-troubleshooting-general.md`.

## SAE on this chip: persistent setup (trial on one Pi 4, 2026-10)

Goal: let a brcmfmac Pi use WPA3-SAE against an `sae-mixed` SSID (names below are placeholders: PSK
profile `wifi-A`, SAE profile `wifi-A-sae`, interface `wlan0`). Three parts:

1. **`wpa-sae-pwe.service`** (boot): runs `wpa-sae-pwe.sh`, which sets the supplicant's global
   `sae_pwe` to 1 as soon as the `wlan0` interface exists. `wpa_cli set` is runtime-only, so this has to
   be repeated whenever the supplicant interface is recreated.
2. **NetworkManager dispatcher hook** `90-sae-pwe`: re-applies `sae_pwe=1` on every `wlan0` state change,
   and when the PSK fallback profile comes up it asks NM to try the SAE profile again (once after a 5 s
   delay; at most 3 failed tries per boot and 3600 s apart; a try that ends with the SAE profile up resets
   the counters). Overrides go in `/etc/default/sae-trial` (`SAE_PROFILE`, `MAX_TRIES`, `MIN_INTERVAL`).
3. **A second profile** `wifi-A-sae`: a clone of the PSK profile with `key-mgmt=sae` and a higher
   autoconnect priority. The PSK profile stays as the automatic fallback, so a failed SAE attempt can
   never leave the Pi offline. `nmcli connection clone` copies the saved password inside NetworkManager;
   it is never printed or typed.

**Install** (as root, with ethernet available as a safety net):

```sh
# 1) the setter script
cat > /usr/local/sbin/wpa-sae-pwe.sh <<'EOS'
#!/bin/sh
# Set sae_pwe=1 on the wpa_supplicant interface (global param, runtime only, lost when the
# interface is recreated). "once": single attempt (dispatcher); default: wait up to 2 min.
IF=${1:-wlan0}; MODE=${2:-wait}; i=0
while [ "$i" -lt 60 ]; do
  if [ "$(wpa_cli -i "$IF" set sae_pwe 1 2>/dev/null | head -1)" = OK ]; then
    logger -t wpa-sae-pwe "sae_pwe=1 set on $IF"; exit 0
  fi
  [ "$MODE" = once ] && exit 0
  i=$((i+1)); sleep 2
done
logger -t wpa-sae-pwe "could not set sae_pwe on $IF (no supplicant interface after 120 s)"; exit 1
EOS
chmod 755 /usr/local/sbin/wpa-sae-pwe.sh

# 2) the boot service
cat > /etc/systemd/system/wpa-sae-pwe.service <<'EOS'
[Unit]
Description=Set wpa_supplicant sae_pwe=1 for SAE on brcmfmac
After=NetworkManager.service wpa_supplicant.service
Wants=NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wpa-sae-pwe.sh wlan0

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload && systemctl enable --now wpa-sae-pwe.service

# 3) the dispatcher hook (root-owned, mode 755)
cat > /etc/NetworkManager/dispatcher.d/90-sae-pwe <<'EOS'
#!/bin/sh
# NetworkManager dispatcher hook (trial): keep wpa_supplicant's sae_pwe=1 on wlan0 and move a
# fallback PSK connection back to the SAE profile.
#  - every wlan0 event: re-apply sae_pwe=1 (it is lost whenever the supplicant interface is recreated)
#  - "up" of a connection other than $SAE_PROFILE while $SAE_PROFILE exists: try $SAE_PROFILE once
#    (after a short delay), at most MAX_TRIES tries per boot and MIN_INTERVAL seconds apart. A try
#    that ends with $SAE_PROFILE up resets the counters, so only failures use up tries.
# SAE_HOOK_DRYRUN=1 only logs what it would do.
[ "$1" = wlan0 ] || exit 0
SAE_PROFILE=wifi-A-sae; MAX_TRIES=3; MIN_INTERVAL=3600; STATE=/run/sae-trial-state
[ -r /etc/default/sae-trial ] && . /etc/default/sae-trial
lg() { logger -t sae-hook "$*"; }
case "$2" in pre-up|up|down|dhcp4-change) /usr/local/sbin/wpa-sae-pwe.sh wlan0 once ;; esac
[ "$2" = up ] || exit 0
if [ "${CONNECTION_ID:-}" = "$SAE_PROFILE" ]; then rm -f "$STATE"; exit 0; fi
nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$SAE_PROFILE" || exit 0
now=$(date +%s); count=0; last=0
[ -r "$STATE" ] && read -r count last < "$STATE"
if [ "$count" -ge "$MAX_TRIES" ]; then lg "fallback '${CONNECTION_ID:-?}' is up; not retrying $SAE_PROFILE ($count tries used)"; exit 0; fi
if [ $((now - last)) -lt "$MIN_INTERVAL" ]; then lg "fallback '${CONNECTION_ID:-?}' is up; last try $((now - last)) s ago (< $MIN_INTERVAL), not retrying"; exit 0; fi
echo "$((count + 1)) $now" > "$STATE"
lg "fallback '${CONNECTION_ID:-?}' is up: trying $SAE_PROFILE (try $((count + 1))/$MAX_TRIES)"
[ "${SAE_HOOK_DRYRUN:-0}" = 1 ] && { lg "dry run: would run nmcli connection up $SAE_PROFILE"; exit 0; }
systemd-run --no-block --quiet --description="retry $SAE_PROFILE" sh -c "sleep 5; nmcli connection up $SAE_PROFILE" >/dev/null 2>&1 || lg "systemd-run failed"
exit 0
EOS
chown root:root /etc/NetworkManager/dispatcher.d/90-sae-pwe && chmod 755 /etc/NetworkManager/dispatcher.d/90-sae-pwe

# 4) the SAE profile next to the existing PSK profile
nmcli connection clone wifi-A wifi-A-sae
nmcli connection modify wifi-A-sae 802-11-wireless-security.key-mgmt sae \
      connection.autoconnect yes connection.autoconnect-priority 10
```

**Remove:** `systemctl disable --now wpa-sae-pwe.service`; delete the service file, the hook, the setter
script and `/etc/default/sae-trial`; `systemctl daemon-reload`; `nmcli connection delete wifi-A-sae`.

**Results on a Pi 4** (`pi-4-2`; ethernet kept plugged in; the auto-fix cron entry was paused during tests):

| Test | Result |
|---|---|
| Activate the SAE profile by hand, 2.4 GHz BSS | connected, `key_mgmt=SAE`, 0 % loss over 6 pings |
| Same, forced onto the 5 GHz BSS (-76 dBm client-side, -70 dBm AP-side) | connected in about 22 s, H2E exchange, `key_mgmt=SAE`; AP log `auth_alg=sae`, no downgrade message; 2 of the first 9 AP frames failed (the usual mild front-loading); SAE and the 4-way handshake finished within 0.02 s, but DHCP took 15 s to hand out a lease (the weak-5 GHz early-association unicast problem from the general file, not SAE) |
| Reboot | SAE profile connected at the first attempt (the service set `sae_pwe` about 1 s before NM started the activation); no fallback |
| Wifi radio off/on (interface recreated, `sae_pwe` back to 0) | first SAE attempt fails and times out (about 75 s), NM falls back to PSK, the hook sets `sae_pwe=1` and retries: SAE again after 102 s |
| `systemctl restart NetworkManager` | same chain, SAE again after 86 s |
| With the setting missing | AP log shows `SAE: <mac> indicates support for SAE H2E, but did not use it` and an Assoc Response status 1; with the setting present it does not |

**Limits.** After the interface is recreated the Pi runs on the PSK fallback for roughly 1.5 to 2
minutes before it moves back to SAE, because the failed first attempt has to time out. The monitor's
driver reload creates the same situation. The persistent setup itself was only run on one Pi 4; the Pi 5 was tested with the temporary-profile test only (below). The Zero 2W cannot use it (its firmware does not do SAE, see the general file). The hook's retry cap means a client where SAE does not work stays on the PSK profile after 3 tries.

## Pi 5 (`pi-5-1`) survey (2026-10)

Raspberry Pi 5 Model B Rev 1.1, Raspberry Pi OS 13 (trixie), up 9 weeks, built-in brcmfmac with the
same firmware string as the Pi 4s (`01-b677b91b`), NetworkManager 1.52, wpa_supplicant 2.10. It joins the
5 GHz BSS at about -55 dBm client-side (AP-side -43 dBm) with `WPA2-PSK-SHA256` and a text password, and
the supplicant does not list `sae` (same as the Pi 4). The AP saw 0 failed frames out of about 7.5 k
over 16 hours, so no 5 GHz problem here. One incident: after the AP's radio reload this Pi stayed
"connected" for about 54 minutes while the AP had forgotten it; see "A client can stay connected to
an AP that has forgotten it" in `wifi-troubleshooting-general.md`. The monitor was installed afterwards.

**Forced-SAE tests on the Pi 5** (temporary cloned profile with `key-mgmt=sae`, supplicant `sae_pwe=1`
set at runtime, self-reverting; the Pi is wifi-only):

| Run | Band | Result |
|---|---|---|
| 1 | 2.4 GHz BSS | external auth started, H2E commit sent (status 126) and answered by the AP, then `Frame command failed: ret=-110` (the next management frame was not sent), `Authentication ... timed out`; activation failed |
| 2 | 2.4 GHz BSS | external auth started, then a connect event with `status=16` and no SAE commit/confirm logged; activation failed |
| 3 | 5 GHz BSS | full SAE exchange (commit 126 / confirm 0), `SAE completed`, `key_mgmt=SAE`, connected in about 6 s, 5 of 5 pings |

So SAE works on this Pi on the band it normally uses and failed both times on 2.4 GHz; the AP saw the
first commit but no confirm or association on 2.4 GHz. Cause not determined (a frame-transmit timeout on
2.4 GHz after coming from a 5 GHz association; n=2 on 2.4 GHz, n=1 on 5 GHz). The persistent setup above
was not installed here.

## Open items

- Only one Pi 5, and only surveyed, not stress-tested; its behavior at a weak 5 GHz spot is unknown.
- Check whether a second Pi 4 at a weaker or better spot shows the same -63 dBm cliff.
