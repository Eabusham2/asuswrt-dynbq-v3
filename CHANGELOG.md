## 3.2.2 - 2026-08-08

- Make LOW slightly easier: MID -> LOW now uses <=2000 TX posts/sec for 3 consecutive 2-second samples (~6 s).
- LOW -> MID now uses >=4000 TX posts/sec for one sample (~2 s).
- Keep HIGH entry at >=30000 TX posts/sec for 4 consecutive samples (~8 s) with outstanding <=2048 and zero real BQ drops.
- Stop treating feeder-full pressure as a HIGH blocker during true very-high throughput; feeder-full can be large during healthy heavy traffic.
- Keep real Runner BQ drops as immediate LOW and keep HIGH easy to leave when load ends.
- Empirically proved the complete automatic cycle on wl1 under real Wi-Fi load: 64 -> 128 -> 192 -> 128 -> 64.
- Proof run reached 63,497 TX posts/sec, max outstanding 1,900, 6 consecutive HIGH_OK samples, 7 consecutive HIGH_HOLD samples, and zero BQ drops.
- wl2 independently remained at 64 because it carried no heavy test traffic, confirming per-radio independence.
- Runner remained healthy throughout: txoffl:1, rxoffl:1, bkupq:1, hbqd:1, dynbkupq:1, codel:0, ba256cfg:1.

## 3.2.1 - 2026-08-08

- Make LOW easier/faster: MID -> LOW now uses <=1500 TX posts/sec for 4 consecutive 2-second samples (~8 s).
- Make recovery from LOW quicker: LOW -> MID now uses >=3000 TX posts/sec for one clean sample (~2 s).
- Keep HIGH very selective at >=30000 TX posts/sec, but reduce entry from 6 to 4 consecutive samples (~8 s).
- Raise HIGH outstanding safety ceiling from 64 to 2048 after a real V3.2 run reached 56,140 pps with outstanding=1,562 while remaining healthy.
- Treat feeder-full as HIGH-blocking pressure only at the existing severe threshold (`full_delta >= 512`), instead of any nonzero feeder-full count.
- HIGH -> MID now needs only 2 failed hold samples (~4 s); HIGH -> LOW needs only 2 consecutive low samples (~4 s).
- Keep real Runner BQ drop as an immediate LOW transition.
- Add `pressure=` to runtime stats.
- Expand state-machine regression tests so wl1 and wl2 each prove MID->LOW, LOW->MID, MID->HIGH, HIGH->MID, HIGH->LOW, and independent behavior.
- Update the macOS empirical test to report severe-pressure samples separately from harmless nonzero feeder-full counts.

## 3.2.0 - 2026-08-08

- Remove dead host BA/retry setter probing from the production controller (those setters are empirically unwritable on this firmware), shrinking the persistent controller while retaining native Runner `ba256cfg:1`.
- Add explicit three-band traffic hysteresis: very-low -> 64, normal -> 128, very-high clean -> 192.
- MID -> LOW requires <=1000 TX posts/sec for 6 consecutive 2-second samples, unless a real BQ drop or sustained feeder pressure forces LOW sooner.
- LOW -> MID requires >=2500 TX posts/sec for 2 consecutive samples.
- HIGH entry requires >=30000 TX posts/sec for 6 consecutive samples with outstanding <=64 and zero feeder-full/BQ-drop signals.
- Remove the redundant per-window 95% completion-ratio gate after the first real run reached 52,994 TX posts/sec without entering HIGH.
- HIGH hold uses >=20000 TX posts/sec; 3 failed hold samples drop HIGH -> MID.
- 3 consecutive very-low samples while HIGH drop directly HIGH -> LOW.
- Add transition reasons and sample sequence numbers to runtime stats/logs.
- Add `scripts/update-router-v3.2-macos.sh` for validated no-reboot deployment with automatic controller rollback on failure.
- Fix the macOS updater for Asuswrt SSH servers without SFTP; plain SSH streaming is used instead.
- Extend the macOS load test to verify both HIGH entry and automatic downshift.

## 3.1.1 - 2026-08-08

- Add `scripts/test-high-macos.sh` to empirically verify automatic `128 -> 192 -> 128` behavior under real Wi-Fi load.
- Document the 30,000 TX-posts/sec, 6-sample HIGH trigger used by V3.1.
- Improve the HIGH diagnostic after the first real run reached 52,994 TX posts/sec without entering HIGH.

## v3.1.0 - 2026-08-07

- Finalized safe production architecture: native HBQD + Runner offload + DynBQ 64/128/192.
- Removed runnable experimental CoDel/HBQD override scripts.
- Added bounded tmpfs-only logging (32 KiB max, 120-line trim, reset on start).
- Added router development-artifact cleanup helper.
- Documented unsupported host BA/rate setters on the tested impl105 firmware.
- Added state-machine regression tests and GitHub Actions syntax checks.
