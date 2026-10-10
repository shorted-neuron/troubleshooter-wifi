# Wifi Troubleshooting — general findings (all Pi models)

Findings that held on more than one kind of Pi, plus the measurement method used to get
them. Model-specific logs:

- `wifi-troubleshooting-rpi4-5.md` — Pi 4 / Pi 5 with built-in wifi (CYW43455 class).
- `wifi-troubleshooting-pi-zero2w.md` — Zero 2W series (BCM43430 class). Living log.
- `wifi-troubleshooting-pi-zero-usb.md` — any Pi using a USB wifi dongle.

Hosts, SSIDs and addresses are placeholders (`pi-4-1`, `wifi-A`, ...). Where a number comes
from one unit only, the model file says which.

## How the measurements were taken

- **Link loss:** `ping -D -O -n -i 1 -I wlan0 <gateway>` for 25-30 minutes. `-D` stamps each
  reply with epoch time so loss can be lined up with scan warnings and AP-side logs;
  `-I wlan0` keeps ethernet out of the result. Clocks on client and AP must be in sync (check
  chrony; a Pi that boots with an old image time steps forward once NTP arrives).
- **Runtime-only changes, restored by a trap.** Anything that changes behavior (bgscan
  interval, driver retry limit, band pin) is applied without touching the saved profile and
  restored on exit. ABA order (change, restore, change) because links drift over time.
- **Keep a second path to the box.** A test that can drop `wlan0` needs ethernet (or another
  reachable path), or the control session dies with the test. Pause the monitor cron
  entry for the test and restore it from a trap, otherwise the monitor may bounce wifi mid-run.
- **Capture on the client** (`tcpdump -i wlan0 -n -e -s 0 -w file`, installed with apt) to
  see which frames reach the host. Compare DHCP replies against *broadcast* frames from other
  hosts (ARP requests): broadcasts arriving while unicast replies do not separates "all
  downlink is dead" from "unicast downlink only".
- **AP-side counters** (station dump: tx retries, tx failed, signal, power-save bit) are
  useful per association, but sample at 1-2 s; a 6 s sampler is too coarse for 20 s cycles.
  Counters are cumulative since association. Do not compare `tx failed` across different
  drivers or radios; use it against the same client's other band.
- **Counters read from the client** (`rx_dropped` in `/sys/class/net/wlan0/statistics`) are
  cumulative since boot. A large number there says nothing about a test unless it grows
  during the test window.
- `/proc/uptime` is monotonic; a wrong wall clock does not make `uptime` wrong.

## NetworkManager / wpa_supplicant behavior

- **Background scan.** NM passes wpa_supplicant `bgscan simple:30:-65:300` when it sees two or
  more BSSIDs for the SSID, and `simple:30:-70:86400` for one. It is computed only when the
  connection is activated. Below the threshold (-65 dBm) the short interval (30 s) applies.
  On weak chipsets each scan costs seconds of loss (see the USB file). Taking the second band
  or second AP away changes this value only at the next activation.
- **Band pin** (`802-11-wireless.band` = `bg`/`a`). With a pin, NM only considers that band.
  Without one it picks the strongest BSS, which is usually the 5 GHz one even when 5 GHz is
  the worse link for that client. Falling back to the other band after 5 GHz fails took from
  about 2 minutes to more than 5 minutes in tests; do not rely on it.
- **NM's "secrets" wording is unreliable.** `Connection activation failed: Secrets were
  required, but not provided` and `has security, but secrets are required` (followed by
  `secrets exist. No new secrets needed.`) appear in nearly every activation log and say nothing
  about the password. Two different causes were seen behind it:
  - Weak 5 GHz: the association timed out (`association took too long`), NM moved to need-auth,
    and a headless `sudo nmcli` has no secret agent. The password was fine (a Pi 4, see the
    rpi4-5 file).
  - A saved key in the wrong form for SAE (below): wpa_supplicant aborts locally with
    `SAE: No password available`, and NM only reports `association took too long` /
    `ssid-not-found`. The real message is visible only in wpa_supplicant's DEBUG output.
  Rule: do not trust NM's wording; raise the supplicant log level (below) and read its lines.
- **DHCP timeout** is 45 s. A link that associates but cannot deliver DHCP replies produces a
  disconnect/re-associate cycle of about 46 s ("client-initiated disassoc" in the AP log).
  `ipv4.dhcp-timeout` can be raised temporarily for a test; restore it afterwards.
- **`ASSOC-REJECT status_code=16`** from one BSS followed by a successful join of the other
  BSS was seen repeatedly while 802.11r was partly configured on the AP (below).
  On brcmfmac the status code and the BSSID in the driver's connect event are unreliable (a rejected SAE
  association showed `status_code=16` and the other band's BSSID while the AP actually answered status 1
  on the intended BSS); check the AP log or a capture before drawing conclusions from them.
- `bgscan simple: Failed to enable signal strength monitoring` is logged on every connect
  (both bands, both outcomes) on at least the Pi 4. It does not distinguish good from bad
  connections.
- Auto-connect gives up after `connection.autoconnect-retries` (default 4) failed activations;
  the device then stays down until something re-activates it. This is a candidate for a
  client that vanishes after an AP-side change and does not return.

## Weak 5 GHz: unicast fails, broadcast works

Seen on a Pi 4 (see the rpi4-5 file for the run). Symptoms at a spot with -63 to -77 dBm on
5 GHz (the same Pi was fine at about -57 dBm on 2.4 GHz):

- Authentication and association complete, the 4-way handshake sometimes needs a second try.
- The AP sees the client's DHCP broadcasts and the router answers, but the client never
  receives the OFFER/ACK: in a client capture there is no DHCP reply for 60-70 s, while
  broadcast ARP from other hosts arrives normally.
- AP-side: about two thirds of the AP's unicast frames to the client got no 802.11 ACK in the
  first 30 s after association (a healthy client: 0.1-0.4 % failed). The power-save bit was
  never set, so the client was not asleep.
- The monitor sees `ping`/`dns` failures only after DHCP fails; NM falls back to the other
  band on its own after a few minutes, then everything is fine, which looks intermittent.

Moving the same Pi next to the AP (5 GHz about -50 dBm) removed the whole pattern: DHCP in
under 6 s, 40 of 40 gateway probes answered, 0 of 47 AP frames failed in the first 30 s.
Things that did **not** change the result at the weak spot: `bgscan` off, power save
explicitly off, regulatory-domain changes (the brcmfmac PHY is self-managed, `country 99`).

Rule of thumb from this fleet (softened after a second Pi 4): a weak 5 GHz signal at the AP
(-63 dBm or worse) makes the first seconds-to-minutes after a 5 GHz association unreliable. The
AP's unicast frames fail at a high rate then and recover as traffic flows. How bad it gets is
unit-specific, not a fixed threshold:

| Device (Pi 4, same firmware) | AP-side 5 GHz signal | AP->client frames failed |
|---|---|---|
| `pi-4-1` (failing spot) | -63 to -77 dBm | 2/3 in the first 30 s, 26 % over the test, DHCP never completed for ~70 s |
| `pi-4-2` (stable for 15 h) | -69 to -77 dBm, average -71 | about 11 % in the first minutes after association, then about 2 %; 2.5 % over 15 h, 0 % loss on a 30-ping test |

Other clients, AP-side counters (cumulative since association, all at or stronger than -52 dBm
unless noted), for scale: a Zero 2W with built-in brcmfmac (`pi-zero-2`) loses a steady 9 % of AP
frames, before and after the AP change, not front-loaded; a Pi 2 with an `mt7601u` dongle (`pi-2-2`)
a steady 4.5 %; a dongle Pi at -77 dBm on 2.4 GHz lost 0.04 %; a Pi 5 at -43 dBm lost 0 %. Per-device
loss at a given signal varies by an order of magnitude, so judge each device by its own counters.

So signal alone does not predict the problem; `pi-4-2` may cope better because of its placement,
antenna or lighter traffic. Practical guidance: if a client's first connection after a band change
is slow or DHCP stalls, pin it to 2.4 GHz and look at the AP-side failed/retry counters for that
client right after association (not only the long-run average). Check the client's own `iw dev
wlan0 link` signal *and* the AP's view; the two can differ by 20 dB on dongles.

## A client can stay "connected" to an AP that has forgotten it (2026-10)

After the AP's 5 GHz radio was reloaded, a Pi 5 (`pi-5-1`) kept showing `wpa_state=COMPLETED` for
about 54 minutes while the AP no longer had it associated. wpa_supplicant logged no disconnect at
all. The first sign was NetworkManager's DHCP lease renewal at the next T1 boundary: no reply for
45 s, `ip-config-unavailable`, a local disconnect, rescan, rejoin within 8 s. Another Pi 4 on the
same BSS noticed within three minutes, so it is not universal. A likely cause (unproven) is that the
association uses protected management frames, so the unprotected "you are not associated" frame the
AP sends after a restart is ignored.

Consequences: the supplicant state is not proof of connectivity; only an end-to-end check is. This is
the case the `auto-fix-wifi.sh` ping check exists for: with it installed the outage would have been
cut to about one cron cycle. Without a monitor, a client can be offline for as long as the lease
interval.

## AP-side changes that affect clients

- Removing 802.11r from a SSID that clients were already joined to: clients with profiles that
  list `FT-PSK`/`FT-SAE` fall back to the plain PSK or SAE paths; those worked once reconnected.
- Switching a band to `sae-mixed` (WPA2-PSK and SAE both accepted): wpa_supplicant 2.10 clients
  that try SAE against an AP set to H2E-only can fail to join where PSK would have worked.
  One client (USB dongle, see the USB file) disappeared at the moment of such a change and had
  not returned hours later. Cause not established.
- Do the AP change when a console or ethernet path exists to the client; headless Pis with only
  wifi cannot be repaired remotely.

## Monitor script (`auto-fix-wifi.sh`) lessons

Recorded in detail in the Zero 2W file and the USB file; the short version:

- Failure of a layer-7 check alone (HTTP) must never trigger a reboot: it only logs a warning.
- A recheck after the retries, and several probes per attempt, avoid fixes triggered by a
  single scan window or a lost packet.
- A fix (bounce, module reload, reboot) does not cure a bad radio link; it costs minutes of
  outage. Compare `actions.log` counts per day before and after a change to judge it.
- Module reload must unload dependent modules first (`brcmfmac_cyw`, `brcmfmac_wcc`).
- A Pi with no wifi interface (wired-only, or a failed or unplugged dongle)
  - An older script version assumed `wlan0`, found it missing, and ran the fix path
    (NM restarts, module reloads) against hardware that was not there
  - The current script stays idle: every mode says so and exits 0, with no fix or reboot, and
    picks the interface up by itself when one appears
  - An interface that was configured and then went missing is still a failure on purpose,
    because the fix path can bring a dropped dongle back; to retire wifi on a host, remove the
    cron entry
- Run times
  - `install.sh` gives each host its own minute offset in the 20-minute schedule (derived from
    the machine-id, or `--cron-offset N`), so a fleet does not retry and bounce wifi in lockstep
    after an AP or router blip
  - When correlating logs across hosts, allow a window of about 20 minutes instead of one minute
- Block test of the monitor on real hosts (the AP denied three clients at once; each ran its own cron minute)
  - Every stage showed up in the logs: attempts, recheck, wifi-only bounce, full NM + driver reload, failed-cycle counter
  - End of the chain
    - Reboot at the threshold on one Pi (reboot count recorded, counter reset)
    - "NOT rebooting" at the cap on the others, with `MAX_REBOOTS_PER_DAY=0` (a safe way to test the last stage)
  - After the AP released them, recovery took minutes, not seconds
    - wpa_supplicant backs off after repeated failures (the SSID is disabled for 10 to 20 s per failure, growing), so reconnecting took about 4 to 5 minutes
    - NetworkManager had also given up autoconnect on one Pi and tried nothing for 7 minutes; the monitor's fix cycle revived it
    - This is acceptable by design: the goal is a wifi interface that comes back eventually, not instantly
  - A fix cycle can start just as an outage ends, and a reconnect after a driver reload is slow
    - On a Pi with the SAE trial profile it takes about 75 to 100 s (the SAE attempt fails first, then the PSK fallback, then the hook returns to SAE)
    - Seen: the post-fix check ran before the reconnect finished and counted a failed cycle (3/2) although the link was back about a minute later
    - Fix: `FIX_SETTLE_WAIT` (default 90 s) polls the checks after each fix step instead of checking once
- Interface cases tested on real hardware (a Pi with a USB dongle)
  - No interface configured, driver unloaded: idle message, exit 0, no actions
  - Driver loaded again: picked up on the next run (`bootstrap: WIFI_IFACE=wlan0`), checks pass
  - Interface configured but driver unloaded: failure path, the wifi-only fix reloads the driver and recovers

## WPA3 / SAE: why some clients vanished after the AP went `sae-mixed` (2026-10)

**What the terms mean.**
- WPA2-PSK (what these Pis use): the password becomes a key; anyone who records the connection
  handshake can guess passwords offline, and a leaked password also decrypts older recordings.
- WPA3-SAE: a password-authenticated key exchange. Guessing needs one interaction with the AP per
  try, recordings stay unreadable after a later leak, and it requires protected management frames.
- `sae-mixed` (transition mode): the AP accepts both WPA2-PSK and SAE clients. It migrates clients
  without cutting anyone off, but the weakest allowed mode still sets the network's strength; the
  real gain comes from SAE-only, or from putting WPA2-only clients on their own SSID.

**Symptom.** Right after the AP's SSID changed to `sae-mixed` (and 802.11r was removed), three Pis
with USB dongles lost wifi and never came back: the monitor rebooted one four times, then hit its
daily cap and logged `needs human attention`. An over-the-air monitor heard only probe requests
from them for hours, with no Authentication frames at all. The AP's own log showed a disconnect at
the moment of the change and nothing after. Each dmesg showed one last AP-side reject
(`denied association (code=43)`, invalid AKM) as the FT-PSK key type disappeared from the BSS.

**Root cause (confirmed on all three, AP behaved correctly).**
1. The wifi password was saved in the NM profile as a **64-character hex key**, not as text. The
   source is the Raspberry Pi Imager customization: it writes the pre-hashed key into
   `/boot/firmware/network-config` (cloud-init seed), cloud-init renders it into netplan, and NM
   builds the profile from that.
2. A 64-hex key is enough for WPA2-PSK but cannot be used for SAE, which needs the text password.
3. NM builds the supplicant's key-management list from what the supplicant reports for that
   interface. On the dongle Pis it includes `SAE FT-SAE`, and wpa_supplicant prefers SAE whenever the
   BSS offers it. Before the AP change the BSS offered only PSK, so it worked.
4. wpa_supplicant 2.10 then logs `Using SAE auth_alg` ... `SAE: No password available`, drops the BSS
   on its ignore list (`CTRL-EVENT-SSID-TEMP-DISABLED reason=CONN_FAILED`) and never transmits an
   Authentication frame. The NM auto-connect then repeats about every 26 s.

**How to check a Pi (no secrets printed).**
- `nmcli -s -g 802-11-wireless-security.psk connection show <profile> | tr -d '\n' | wc -c` prints
  the length: 64 (and only hex digits) means the hashed form, 8-63 means text.
- Which key types NM offers: journal line `Config: added 'key_mgmt' value '...'` — look for `SAE`.
- What the supplicant can do on that interface: `busctl --system get-property fi.w1.wpa_supplicant1
  <iface path> fi.w1.wpa_supplicant1.Interface Capabilities` and look for `sae` under `KeyMgmt`.
- Why a join fails: `wpa_cli -i wlan0 log_level DEBUG`, trigger one activation, read the lines
  (`Using SAE auth_alg`, `SAE: No password available`); put the level back to `INFO` afterwards.
  The debug output also dumps neighbors' SSIDs/BSSIDs: filter before sharing or committing.

**Fix.** Store the password as text in the profile. The hashed key can be verified against the
typed password before replacing it (`wpa_passphrase <ssid>` of the typed text must equal the stored
hex), so a typo cannot overwrite a working key. After the change the dongle Pis join with
`key_mgmt=SAE`: the 2.4 GHz BSS's SAE exchange takes about 90 ms, tested on `rt2800usb` (two Pis)
and `rtl8192cu`. `pmf=disable` in the profile does **not** remove SAE from the list and does not help.
Pitfalls hit while doing this:
- `nmcli connection edit` echoes the commands it reads, including `set wifi-sec.psk <password>`.
  A script that logs the editor's output leaks the password into the log. Filter that line before
  logging or printing (the repo does not ship such a script; the one used here was a one-off).
- Reading the stored key back immediately after the save once returned an empty value (the
  profile was being regenerated by netplan); read it again after a few seconds before concluding.
- The Imager seed on the boot partition still contains the hashed form. cloud-init normally applies
  network config only for a new instance, so a reboot keeps the fix; a reflash brings the hex back.
  For new images, set the wifi password as text after first boot, or use a profile that carries it
  as text.

**Which hardware can use SAE here** (what the supplicant reports for the interface, read with
`busctl` as above):

| Device | Wifi hardware | `sae` in supplicant KeyMgmt | Result |
|---|---|---|---|
| `pi-model-b-1` | Pi Model B, `rt2800usb` dongle | yes | SAE works after text password |
| `pi-2-1` | Pi 2 Model B, `rt2800usb` dongle | yes | SAE works after text password |
| `pi-b-plus-1` | Pi Model B+, `rtl8192cu` dongle | yes | SAE works after text password |
| `pi-4-1` | Pi 4, built-in brcmfmac | not offered by NM | WPA2-PSK in use (text password); SAE works if forced, see below |
| `pi-zero-1` | Zero 2W, built-in brcmfmac | not offered by NM | WPA2-PSK in use, joins a WPA2-only SSID; same chip family as `pi-zero-2`, whose forced SAE fails (below) |
| `pi-zero-2` | Zero 2W, built-in brcmfmac | not offered by NM | WPA2-PSK in use (text password); survived the AP change; **forced SAE fails**: no SAE exchange, authentication times out |
| `pi-zero-3` | Pi Zero, `rtl8192cu` dongle | yes | already on SAE with a text password; survived the AP change |
| `pi-2-2` | Pi 2 Model B, `mt7601u` dongle | yes | already on SAE with a text password; survived the AP change |
| `pi-4-2` | Pi 4, built-in brcmfmac | not offered by NM | WPA2-PSK in use (text password); stable on 5 GHz; forced SAE works with `sae_pwe=1` (tested, 2.4 GHz) |
| `pi-5-1` | Pi 5, built-in brcmfmac | not offered by NM | WPA2-PSK in use (text password), 5 GHz; forced SAE with `sae_pwe=1` **works on 5 GHz** (connected in 6 s, `key_mgmt=SAE`, 0 % loss) but failed twice on 2.4 GHz; see the Pi 4/5 file and the silent-association note |

**Table heading note.** "Offered by NM" means wpa_supplicant lists `sae` in the interface's `KeyMgmt`
capabilities. That is yes for the dongle Pis (their drivers run SAE through mac80211). For the
built-in brcmfmac Pis it is no, so NetworkManager never adds `SAE` to a `wpa-psk` profile and they stay on
WPA2-PSK even though the SSID is `sae-mixed`.

**brcmfmac can still do SAE, if told to (tested on a Pi 4; it does NOT work on the Zero 2W, see below).** `iw phy` says "Device supports SAE
with AUTHENTICATE command" and the kernel hands SAE to userspace (external auth). With a cloned
temporary profile forced to `key-mgmt=sae` on the 2.4 GHz BSS:
1. wpa_supplicant 2.10 ran the SAE exchange (commit and confirm both with status 0) but derived the
   password element the old way (hunting-and-pecking), while the association request advertised
   support for the newer hash-to-element (H2E) method.
2. hostapd with `sae_pwe=2` (H&P and H2E both allowed) has an anti-downgrade check and refused the
   association: `SAE: <mac> indicates support for SAE H2E, but did not use it`, response status 1
   ("Unspecified failure"). The client's own log showed `ASSOC-REJECT status_code=16` and a different
   BSSID in that event; that status and BSSID are not reliable on brcmfmac, trust AP-side logs/captures.
3. With the supplicant's global `sae_pwe` set to 1 at runtime (`wpa_cli -i wlan0 set sae_pwe 1`) it
   derived the element via H2E ("Derive PT", "Derive PWE from PT"), the AP accepted, NM reported the
   device connected with `key_mgmt=SAE`, and 5 of 5 gateway pings were answered.
So the AP setting `sae_pwe=2` is correct; no AP change is needed. The dongle Pis never hit this
because their normal SME path uses H2E automatically. `wpa_cli set sae_pwe` is runtime-only (lost when
the supplicant interface is recreated); a persistent setup (boot service + NetworkManager dispatcher hook
+ a second SAE profile with the PSK profile as fallback) was built and tested on one Pi 4, on both
bands, across reboot, radio toggle and NM restart; see `wifi-troubleshooting-rpi4-5.md`. The Pi 5 works on 5 GHz but failed twice on 2.4 GHz (below, Pi 4/5 file).

**The Zero 2W cannot do SAE (tested).** The same forced-`key-mgmt=sae` test with `sae_pwe=1` on a Zero 2W
(BCM43430/1, firmware 7.45.96 dated 2023-06-14, kernel 6.18) never started an SAE exchange: the supplicant
used the plain `CONNECT` command with the SAE key type (`Auth Type 4`, `akm=00-0f-ac:8`), no external-auth
event arrived, and 10 s later `Authentication with <bssid> timed out`; NetworkManager failed the activation
and the self-reverting test restored the PSK profile. `iw phy` on that chip prints the same "SAE with
AUTHENTICATE command" line as the Pi 4, so that line says nothing about whether SAE really works.
Treat Zero 2W (and any chip with this firmware) as WPA2-only.

**Implication for migrating to SAE-only.** The dongle Pis can do it once their password is stored as
text. A Pi 4 (CYW43455-class) can too, but only with an explicit `key-mgmt=sae` profile plus `sae_pwe=1` in the
supplicant, a client-side change per Pi (the trial setup in the Pi 4/5 file); without it they belong on
a WPA2-only SSID (or stay on `sae-mixed`, where they keep joining with WPA2-PSK). Do not change the AP's
`sae_pwe` to suit them: `0` (H&P only) removes the downgrade check, `1` (H2E only) would reject
H&P-only clients.

**Same incident, other findings.**
- A wedged `rtl8192cu` scan (0 networks, `iw scan` hangs) recurred on one Pi right after the
  profile fix. Reloading the module cures it (see the USB file); do not conclude from "0 BSSes" that
  SAE failed.
- A client's own `iw` signal and the AP's station reading for it differ by 20+ dB on the dongle Pis
  (antenna and scale); compare like with like.
- The monitor's behavior was correct throughout: bounded reboots, then `needs human attention`.
  Fix actions cannot repair a profile problem, so it keeps logging until the profile is fixed.
- `pkill -f <pattern>` inside `sudo sh -c '...'` matches its own shell (the pattern is on its own
  command line); use `pgrep -x`/a script file or a PID.
