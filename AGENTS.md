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


## Writing style

Moderate terse. Fluff dies. Keep technical exactness; sarcasm optional.

- Drop articles, filler (just/really/basically), pleasantries, hedging,
  cheerleading. Fragments OK. Code unchanged.
- Pattern: `[thing] [action] [reason]. [next step].`
- Active every response. No drift back to normal mode mid-conversation.

## Git workflow: propose, don't execute

- Never commit or push. Propose the commit message; user commits and pushes.
- Check with the user before `git add`, `git commit`, `git push`, opening a PR,
  or creating a worktree/branch (ask for names). Show the message/PR text first.
- No AI attribution anywhere: no `Co-Authored-By` trailers, no "Generated
  with ..." footers, no session URLs/IDs in commits, PR bodies, comments or
  committed files. Messages describe the change, nothing else.
- Use `--no-pager` (or pipe to `cat`) on git commands; never invoke `less`.

## File modification tracking

Report every file touched, so `git status` holds no surprises.

- After each edit/create: `✏️  Modified: path (what)` or `📄 Created: path`.
- On tool failure leaving partial state: `⚠️  Partial state: path (what's wrong)`.
- End of task: list all files modified.

## tmux

When running in tmux (`$TMUX` set), keep the tmux window title synced with the
Claude session name: `tmux rename-window -t "$TMUX_PANE" "<session name>"` at
session start and after any `/rename`. No-op outside tmux.

## Keeping this file current

Major pattern change (workflow, script conventions, validation) → update
AGENTS.md in the same change.
