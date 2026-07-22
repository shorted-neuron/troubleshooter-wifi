# AGENTS.md

## Project

Shell scripts for diagnosing/recovering Wi-Fi on Raspberry Pi devices
(brcmfmac driver issues). Target systems: headless Pi, NetworkManager + netplan,
POSIX `sh` (not bash-specific unless noted).

## Scope of changes

- Scripts must remain POSIX `sh` compatible (`#!/bin/sh`, `set -eu`) unless a
  script already declares otherwise.
- Preserve `set -eu` and `|| true` guards on diagnostic commands — scripts must
  not abort mid-run just because one diagnostic command is unavailable.  
- Unless doing a boolean check, do not throw away STDERR - if something is 
  missing, args wrong for target environment, or a command fails, the user 
  should see it in the logs.
- Keep output redirected to timestamped log files as the existing scripts do.
- Do not add hardcoded SSIDs, PSKs, hostnames, IPs, MAC addresses, or other
  device/network-identifying values into scripts, docs, or examples. Use
  placeholders (e.g. `wifi-A`, `pi-zero-1`).

## Privacy/secrets scan (required before finishing any task)

This repo is public. Before completing any task, scan all changed and newly
added files for:

- Credentials, tokens, API keys, passwords, PSKs.
- Hostnames, real device names, SSIDs, BSSIDs/MACs, IP addresses.
- Personal names/initials, usernames, home network identifiers.
- Anything under `.idea/` that isn't already excluded by `.idea/.gitignore`
  (e.g. datasource credentials, workspace state).

Redact/generalize anything found. Report findings to the user even if no
action is taken.

## Validation

- No test suite. Validate shell scripts with `sh -n <script>` (syntax check)
  after edits.
- If modifying module-unload/reload logic, verify module names referenced
  (`brcmfmac_cyw` vs `brcmfmac_wcc`) aren't reintroducing the fixed bug
  described in `wifi-troubleshooting-pi-zero2w.md`.

## Docs

- `wifi-troubleshooting-pi-zero2w.md` is a living diagnostic log, not static
  docs — append new findings under relevant sections rather than rewriting
  history.
- Update `README.md` only for user-facing usage changes.

