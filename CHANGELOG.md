## 3.1.1 - 2026-08-08

- Add `scripts/test-high-macos.sh` to empirically verify automatic `128 -> 192 -> 128` behavior under real Wi-Fi load.
- Document the 30,000 TX-posts/sec, 6-sample HIGH trigger used by V3.1.
- No router runtime-policy changes from 3.1.0.

# Changelog

## v3.1.0 — 2026-08-07

- Finalized safe production architecture: native HBQD + Runner offload + DynBQ 64/128/192.
- Removed runnable experimental CoDel/HBQD override scripts.
- Added bounded tmpfs-only logging (32 KiB max, 120-line trim, reset on start).
- Added router development-artifact cleanup helper.
- Documented unsupported host BA/rate setters on the tested impl105 firmware.
- Added state-machine regression tests and GitHub Actions syntax checks.
- Added GitHub publishing helper with description, topics and release tag.
