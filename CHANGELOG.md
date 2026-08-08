## 3.2.0 - 2026-08-08

- Remove dead host BA/retry setter probing from the production controller (those setters are empirically unwritable on this firmware), shrinking the persistent controller while retaining native Runner `ba256cfg:1`.
- Add explicit three-band traffic hysteresis: very-low -> 64, normal -> 128, very-high clean -> 192.
- MID -> LOW now requires <=1000 TX posts/sec for 6 consecutive 2-second samples, unless a real BQ drop or sustained feeder pressure forces LOW sooner.
- LOW -> MID requires >=2500 TX posts/sec for 2 consecutive samples, preventing idle-state flapping.
- HIGH entry remains intentionally strict at >=30000 TX posts/sec for 6 consecutive samples with outstanding <=64 and zero feeder-full/BQ-drop signals.
- Remove the redundant per-window 95% completion-ratio gate after the first real run reached 52,994 TX posts/sec without entering HIGH; cumulative outstanding <=64 already verifies completions keep pace and avoids false negatives caused by completion timing lag.
- HIGH hold uses >=20000 TX posts/sec; 3 failed hold samples drop HIGH -> MID.
- 3 consecutive very-low samples while HIGH drop directly HIGH -> LOW.
- Add transition reasons and sample sequence numbers to runtime stats/logs.
- Add `scripts/update-router-v3.2-macos.sh` for validated no-reboot deployment with automatic controller rollback on failure.
- Extend the macOS load test to verify both HIGH entry and automatic downshift.

## 3.1.1 - 2026-08-08

- Add `scripts/test-high-macos.sh` to empirically verify automatic `128 -> 192 -> 128` behavior under real Wi-Fi load.
- Document the 30,000 TX-posts/sec, 6-sample HIGH trigger used by V3.1.
- Improve the HIGH diagnostic after the first real run reached 52,994 TX posts/sec without entering HIGH: the test now reports per-guard failures and maximum consecutive `high_ok=1` streak instead of only peak PPS.
- No router runtime-policy changes from 3.1.0 yet; threshold tuning is deferred until the diagnostic identifies the actual limiting guard.

# Changelog

## v3.1.0 — 2026-08-07

- Finalized safe production architecture: native HBQD + Runner offload + DynBQ 64/128/192.
- Removed runnable experimental CoDel/HBQD override scripts.
- Added bounded tmpfs-only logging (32 KiB max, 120-line trim, reset on start).
- Added router development-artifact cleanup helper.
- Documented unsupported host BA/rate setters on the tested impl105 firmware.
- Added state-machine regression tests and GitHub Actions syntax checks.
- Added GitHub publishing helper with description, topics and release tag.
