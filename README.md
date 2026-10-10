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

**Goal:** keep a wifi interface operational over time, not instantly.
- A host that is offline for a few minutes is fine (the Pis here run without the network)
- The point is that it comes back on its own when its driver, dongle or NetworkManager do not
- So the monitor is patient: retries, a recheck, and a settle wait after each fix step before it calls a fix failed

Each run: pings the gateway, does a DNS lookup, and does an HTTP(S) check. Ping and
HTTP are bound to the wifi interface; the DNS lookup only uses its address. Ping and DNS are the link-level checks; if
either fails, it waits 10s and retries the whole battery, up to 3 times. Each
attempt is more than one packet: up to `PING_COUNT` pings (default 3, 1 s apart,
stops at the first reply) and `dig` with `DNS_TRIES` (default 2), because a lossy
link fails a single-packet check fairly often. If every attempt failed it waits
`RECHECK_WAIT` seconds (default 45, `0` = off) and checks once more, since a USB
dongle's background wifi scan can swallow a whole round of retries. Only if that
also fails does it try a scoped wifi-only fix (disconnect + reload the wifi
driver module + reconnect) before escalating to a full fix (stop
NetworkManager, reload the module, start NetworkManager). If the fix doesn't
recover connectivity for 5 consecutive cron cycles (configurable; about 100 minutes at 20-minute pacing), it reboots
as a last resort, at most 4 times per 24h (`MAX_REBOOTS_PER_DAY`) and never sooner than `MIN_REBOOT_INTERVAL` (default `60m`; accepts e.g. `90s`, `60m`, `1h`, `1d`, any case; a bare number is minutes) after the previous one. Both defaults apply even if absent from the conf. Otherwise it only logs, and re-checks each run.

After each fix step it does not check once and give up: it polls the whole battery for up to
`FIX_SETTLE_WAIT` seconds (default 90, `0` = one immediate check), because a reconnect after a driver
reload can take a minute or two (a failed WPA3 attempt first, then the fallback profile). A link that
returns fast adds no delay. With the defaults a run that goes through every stage takes about 7
minutes at worst (attempts ~1 min, recheck ~1 min, wifi-only fix up to ~2.5 min, full fix up to
~2.5 min), well under the 20-minute cron interval; if you raise `RETRY_COUNT`, `RECHECK_WAIT` or
`FIX_SETTLE_WAIT`, keep the total below the interval (a slow run never overlaps the next one, it
just delays it).

On a host with a second NIC on the same subnet, the DNS lookup can be answered over that NIC even
when wifi is down; ping and HTTP are interface-bound and still fail the check. Wifi-only hosts are
unaffected.

An HTTP-only failure (ping + DNS fine) is just a warning in syslog — no driver
reload, no reboot. Set `HTTP_CHECK_URL` in `/etc/auto-fix-wifi.conf` to
something reachable from the network the Pi is on (the default, `https://api.ipify.org/`,
assumes internet access; isolated VLANs have none), or leave it empty to skip the HTTP check.
Each run also warns if the configured `GATEWAY_IP` differs from the live
default route (stale config after moving networks); fix with `auto-fix-wifi.sh --reconfigure`.

**First run auto-bootstraps** `/etc/auto-fix-wifi.conf` — discovers the wifi
interface, gateway IP, DNS server, and wifi driver module name, and fills in
sane defaults for check targets/timings. Every start also fills in any setting
missing from the conf (e.g. ones added by a newer version) without touching
existing values; what it added is logged as `bootstrap:` lines in `detail.log`.
Run `auto-fix-wifi.sh --reconfigure` (`--rediscover` is an alias; `./install.sh
--reconfigure` runs the same thing) to force re-discovery of hardware-specific
values (e.g. after swapping a USB dongle). Rediscovery never replaces a working
value with an empty result (link down).
Policy settings (check targets, retry counts, reboot threshold) can be hand-
edited in the conf file afterwards and won't be overwritten. The conf is plain
`KEY=value`, read literally (not sourced by a shell): write values bare, e.g.
`HTTP_CHECK_URL=https://example.invalid/path?a=1&b=2`, with no backslash escaping.
One pair of surrounding quotes and trailing whitespace/CR are tolerated and stripped.
If the HTTP check fails with `curl: (3) URL rejected: Port number was not a decimal
number` or `Malformed input to a URL function`, look for stray quotes, a backslash or
trailing characters in `HTTP_CHECK_URL` (`cat -A /etc/auto-fix-wifi.conf` shows them).

**Install:**

```bash
./install.sh                          # needs sudo; installs script + cron + logrotate
./install.sh --reconfigure            # same, plus re-discover iface/gateway/DNS/driver
./install.sh --http-url https://example.invalid/   # implies --reconfigure, no prompt
./install.sh --http-url none          # ...and skip the HTTP check
./install.sh --cron-offset 3          # run at minutes 3, 23, 43 (0-19, or auto)
```

`install.sh` only installs files; all configuration lives in `auto-fix-wifi.sh`, and
the installer delegates to it, so running these by hand does the same thing:

| Command | Does |
|---|---|
| `auto-fix-wifi.sh` | the monitor (what cron runs) |
| `auto-fix-wifi.sh --reconfigure` | re-discover iface/gateway/DNS/driver, fill in missing settings, ask for the HTTP check URL, then one check-only pass. Never fixes or reboots. `--rediscover` is an alias |
| `auto-fix-wifi.sh --reconfigure --http-url URL\|none` | same without the prompt; works without a terminal (ssh, scripts) |
| `auto-fix-wifi.sh --check` | one check-only pass: prints ping/dns/http results, never fixes or reboots |

The installer exits with the delegated script's status (0 ok, 2 bad arguments such as
an invalid `--http-url`, 1 a ping/DNS check failed, 3 another instance was running);
the files are installed in every case.

The cron schedule is every 20 minutes at a per-host minute offset, so a fleet does not
run (and bounce wifi after an AP or router blip) all in the same minute.
- Fresh install: the offset is derived from the host (`/etc/machine-id`), so it is
  stable across reinstalls
- Upgrade: the schedule already in `/etc/cron.d/auto-fix-wifi` is kept
- `--cron-offset N` (0-19) sets it explicitly; `--cron-offset auto` applies the derived one
  to an existing install

On a host with no wifi interface at all (wired-only, or a dongle that is not plugged in)
every mode says so and exits 0: no checks, no fix, no reboot. It looks again on every run
and starts monitoring by itself once an interface appears. An interface that was
configured and has since gone missing is still treated as a failure, since the fix path
can bring a dropped dongle back; to retire wifi on a host, remove its cron entry.

On a fresh install (no conf yet) the installer runs `--reconfigure`; a plain
`./install.sh` over an existing conf is an upgrade: it keeps your conf, fills in any
new settings (logged as `bootstrap:` lines) and runs `--check`.

The **HTTP check URL** prompt defaults to `https://api.ipify.org/`. Press Enter to
accept, type a new `http(s)://` URL, or type `none` to skip the HTTP check (isolated
networks with no internet and no reachable local endpoint). On `--reconfigure` the
default shown is the URL already in the conf, or `https://api.ipify.org/` if there is
none (or it was empty). The prompt only runs on a terminal; without one, or without
`--http-url`, the conf is left as is and a note says so. The check-only pass at the end
shows the results and warns if the URL isn't reachable or `dig` is missing.

`--reconfigure` rewrites only the discovered values (`WIFI_IFACE`, `GATEWAY_IP`,
`DNS_SERVER`, `WIFI_DRIVER`), so a hand-edited `DNS_SERVER` is replaced too; other
settings such as the reboot limits are kept.

Then review `/etc/auto-fix-wifi.conf` (especially `HTTP_CHECK_URL`). Install `dig`
too (`sudo apt install dnsutils`, or `bind9-dnsutils`): it lets the DNS check bind to
the wifi interface. Without it the check falls back to the system resolver, which on
a dual-NIC box may answer over `eth0`.

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

