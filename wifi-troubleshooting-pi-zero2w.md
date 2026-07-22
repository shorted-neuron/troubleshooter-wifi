# Wifi Troubleshooting — Pi Zero 2W (brcmfmac self-disconnect bug)

Applies to both affected Pi Zero 2W units (same chip/firmware/symptom). Diagnosed on
`pi-zero-1`; fix should be applied to the second unit too once confirmed stable.

## Problem

Pi Zero 2W units randomly lose wifi and stay disconnected for hours, no error visible
to the user. Started as "raspi-config wifi config gives generic error" — that's a
red herring, see below. Real bug is a driver-level self-disconnect loop.

## Environment

- Chip: Broadcom BCM43438 combo wifi/BLE, driver `brcmfmac`, firmware `es7` (2023-06-14,
  currently latest available via `firmware-brcm80211` package — no update path exists).
- Network stack: NetworkManager, config rendered via **netplan** (not classic
  wpa_supplicant/dhcpcd). This is why raspi-config's wifi tool fails with a generic
  error — it assumes it owns wpa_supplicant/dhcpcd directly, but NM+netplan owns
  `wlan0` here. Use `nmcli`/netplan yaml directly instead of raspi-config for wifi changes.

## Netplan/NM quirks (reference, not bugs)

- `/etc/netplan/90-NM-<uuid>.yaml` filenames are **auto-generated** by NM's netplan
  render-back mechanism — it re-serializes live NM connection state into netplan yaml
  on every `netplan generate`/`apply`. Hand-authoring a clean yaml file only survives
  until the next apply; it always converges to the ugly uuid filename once NM owns it.
  Not preventable without switching that interface's renderer away from NetworkManager.
- Use `nmcli connection show` for the **readable name** (e.g. `netplan-wlan0-black`),
  not the backing yaml filename, when identifying connections.
- To change SSID/AP on this box: edit/add netplan yaml (`wifis: wlan0: access-points:`)
  or `nmcli connection modify <uuid> wifi.ssid ... wifi-sec.psk ...`, then
  `netplan generate && netplan apply`. Test risky changes with `netplan try
  --timeout=<secs>` first — auto-reverts on timeout regardless of session state, but
  note: if the interface under test is your only path to the box (no ethernet on Zero
  2W), your control session dies with it; confirmation requires a second reachable path
  (e.g. a laptop already on the target network) or acceptance that it'll roll back
  even if the test actually succeeded.

## Root cause (confirmed via journalctl, see log excerpts already captured this session)

Recurring loop, every ~3–11 min:

1. `wpa_supplicant: CTRL-EVENT-DISCONNECTED ... reason=0 locally_generated=1` —
   **client-initiated** disconnect, not an AP-side kick.
2. Reassociation attempts hit `CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00
   status_code=16` — zeroed BSSID = **driver-synthesized timeout**, not a real
   rejection frame from the AP.
3. wpa_supplicant backs off (`SSID-TEMP-DISABLED duration=10/20`), NM's 45s
   activation timeout trips (`link timed out`), auto-retries.
4. Eventually one failure gets misclassified as a bad password →
   `Activation: (wifi) asking for new secrets` → `state change: config -> failed
   (reason 'no-secrets')`. NM **stops auto-retrying**, waits for a human to supply
   new secrets. Headless Pi = stuck disconnected indefinitely. This is the "silent
   multi-hour outage" symptom.

### Ruled out

- Powersave: already disabled globally by Raspberry Pi OS default
  (`/etc/NetworkManager/conf.d/default-wifi-powersave-off.conf`). Confirmed via
  `nmcli`: `802-11-wireless.powersave: 0 (default)`.
- Weak signal: `-58 dBm` via `iw dev wlan0 link` — strong, not marginal.
- Stale firmware: `firmware-brcm80211` already at latest available version.
- FT-PSK: `blue` (a different AP, since replaced) threw a hard
  `FT: Invalid key management type (2)` error early on; `black` doesn't show that
  exact error, but shares the same disconnect signature. NM always offers FT-PSK
  opportunistically for any `wpa-psk` connection when the AP advertises 802.11r,
  regardless of nmcli config — not something easily disabled client-side. If the fix
  below doesn't hold, test disabling 802.11r/Fast-Transition on the router's admin
  UI as the next lead.

## Fix applied

```bash
cat > /etc/modprobe.d/brcmfmac.conf <<'EOF'
options brcmfmac roamoff=1
EOF
reboot
```

Disables `brcmfmac`'s own roam/link-health decision engine — the thing generating the
self-initiated `reason=0` disconnects. Verify it's active after boot:

```bash
cat /sys/module/brcmfmac/parameters/roamoff   # should print Y or 1
```

**Status as of last check**: applied, confirmed `roamoff=1` active, clean for the
monitoring window so far (started `Wed Jul 22 2026 ~15:03 MDT`). Not yet
long-enough-confirmed to declare fixed — original outage cycle hit every 3–11 min, so
give it hours before trusting it.

## Monitoring one-liner

Run every few hours until confident:

```bash
journalctl -u wpa_supplicant -u NetworkManager --no-pager --since "-3 hours" \
  | grep -E "CTRL-EVENT-DISCONNECTED|ASSOC-REJECT|no-secrets"
uptime
nmcli device status
date
iwconfig
echo -n "roamoff param is: "; cat /sys/module/brcmfmac/parameters/roamoff
```

Empty grep output = good. Any `CTRL-EVENT-DISCONNECTED`/`ASSOC-REJECT`/`no-secrets`
hits = recurrence, go to next steps below.

## If it recurs

1. Re-verify `roamoff` param is still `1` (rules out it silently reverting).
2. Test disabling 802.11r/Fast-Transition on the router's admin UI for "wifi-A" (see
   FT note above — likely next-best lead).
3. Apply same `roamoff=1` fix to the second Zero 2W unit for comparison — if one
   unit stays stable and the other doesn't under otherwise-identical config, that
   points to a per-unit hardware/antenna variance rather than a pure driver bug.
4. Consider `iw dev wlan0 station dump` at time of any future disconnect (retry
   counts, signal) to catch a live RF/interference contribution, if any.

## Known script bug — `retry-wifi.sh`

Original module-unload list referenced `brcmfmac_wcc`, but this system loads
`brcmfmac_cyw` (Cypress-manufactured chip variant shim). Since the wrong name never
matched, `modprobe -r brcmfmac` failed silently every time (dependent module still
loaded), meaning the script's unload/reload loop was likely a no-op — whatever
temporary relief it provided came from the `systemctl stop/start NetworkManager`
bookending it, not any actual driver/firmware reset.

**Fixed** in this session — script now unloads both `brcmfmac_cyw` and `brcmfmac_wcc`
(covers either chip variant across kernel/board revisions).

## Related scripts (this dir)

- `wifi-brcm-diag.sh` — one-shot diagnostic dump (interfaces, rfkill, modules,
  filtered dmesg, regdomain). Enhanced this session to also capture `iwconfig` output
  and the `roamoff` param state.
- `retry-wifi.sh` — nukes and reloads brcmfmac module stack + bounces NetworkManager.
  Useful as a manual recovery hammer if the box gets stuck again before `roamoff`
  fully proves out. Module-name bug fixed (see above).

