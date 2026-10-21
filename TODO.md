# TODO

- CI: GitHub Actions checks on pull requests and pushes to `main`
  - Syntax: `sh -n` and `dash -n` on every script
  - Lint: `shellcheck --shell=sh` and `checkbashisms -f` on every script
  - Tests: move the stub-`vcgencmd`/`dmesg` harness for `check_throttle`, `decode_throttled` and `secs_since_last_reboot` into the repo and run it
  - Tests: `install.sh` schedule cases with stubbed paths: fresh install, keep on upgrade, `--cron-step` with a fitting and a non-fitting offset, bad step, bad offset, legacy `*/N` and `N-59/N` (`*/15`, `3-59/15`, `5-59/10`, `auto`)
  - Privacy scan: fail on IPs, MACs, hostnames and SSIDs in changed files
