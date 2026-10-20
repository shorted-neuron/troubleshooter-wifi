# TODO

- CI: GitHub Actions checks on pull requests and pushes to `main`
  - Syntax: `sh -n` and `dash -n` on every script
  - Lint: `shellcheck --shell=sh` and `checkbashisms -f` on every script
  - Tests: move the stub-`vcgencmd`/`dmesg` harness for `check_throttle`, `decode_throttled` and `secs_since_last_reboot` into the repo and run it
  - Privacy scan: fail on IPs, MACs, hostnames and SSIDs in changed files
