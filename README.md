# Asuswrt DynBQ V3

Experimental dynamic Broadcom DHD/Runner backup-queue control for the **ASUS GT-BE19000AI** on **Asuswrt-Merlin 3006.102.8_2 / Linux 4.19.294**. Current policy version: **V3.2.0**.

> This is a model/firmware-specific research project. Do not load its kernel module on a different kernel/firmware build without rebuilding and validating against that exact ABI.

## Final supported architecture

The tested router/dongle requires **HBQD** for Runner offload. Disabling HBQD capability causes Broadcom to force-disable TX/RX offload, so the final design deliberately keeps native HBQD and leaves Runner CoDel disabled.

- Runner TX offload: **ON**
- Runner RX offload: **ON**
- backup queue: **ON**
- dynamic backup queue: **ON**
- HBQD: **ON**
- BA256 Runner capability: **ON**
- Runner CoDel: **OFF**
- DynBQ dynamic BE queue: **64 / 128 / 192**

## State machine

V3.2 uses deliberately separated traffic bands and hysteresis so the queue grows only for sustained very-high load and shrinks only when traffic is genuinely very low or the Runner reports queue pressure.

| State | Backup queue | Purpose |
|---|---:|---|
| LOW | 64 | very-low sustained load, real BQ drop, or sustained severe feeder pressure |
| MID | 128 | sticky normal/default baseline |
| HIGH | 192 | sustained very-high clean hardware-offloaded load |

Transitions in V3.2:

- MID -> LOW (idle): <= **1000 TX posts/sec** for **6 consecutive 2-second samples** (~12 s)
- MID -> LOW (pressure): any real Runner BQ drop immediately, or >=512 feeder-full events for 4 consecutive samples
- LOW -> MID: >= **2500 TX posts/sec** for **2 consecutive samples** (~4 s), with no pressure/drop
- MID -> HIGH: >= **30000 TX posts/sec** for **6 consecutive samples** (~12 s), outstanding <=64, no feeder-full event, no BQ drop
- HIGH hold: >= **20000 TX posts/sec** with the same clean queue conditions
- HIGH -> MID: 3 consecutive failed HIGH-hold samples (~6 s), or feeder pressure immediately
- HIGH -> LOW: any real BQ drop immediately, or <=1000 TX posts/sec for 3 consecutive samples (~6 s)

This gives the intended hysteresis: **64 only when very low/bad, 128 for ordinary traffic, and 192 only when very high and clean**.

HIGH uses DHD/Runner `dhd_tx_post_packets`, `dhd_tx_complete_packets`, and cumulative outstanding work, not Linux interface byte counters that hardware offload may bypass. The previous per-window 95% completion-ratio gate was removed in V3.2 because `outstanding <= 64` already establishes that completions are keeping pace while avoiding false failures from completion-timing lag.

## Files

- `src/dynbq.c` — GPL kernel shim exposing `/proc/dynbq`
- `src/Makefile` — external module Makefile
- `scripts/dynbq-controller.sh` — production V3.2 controller
- `scripts/router-cleanup.sh` — removes development leftovers and normalizes persistence
- `scripts/update-router-v3.2-macos.sh` — validated no-reboot V3.2 deployment with rollback
- `scripts/test-high-macos.sh` — empirical three-band HIGH/downshift test
- `tests/state_machine.py` — state-machine regression checks
- `publish-github.sh` — creates/publishes the GitHub repository, description, topics and `v3.2.0` tag

## Storage and logging

Persistent router storage is intentionally only:

```text
/jffs/dynbq/dynbq.ko
/jffs/dynbq/dynbq-controller.sh
```

All controller state/logging lives under `/tmp` (RAM/tmpfs). The controller log:

- is reset on each controller start;
- is capped at **32 KiB**;
- is trimmed to the latest **120 lines** when it reaches the cap;
- disappears on reboot with the rest of `/tmp`.

No DynBQ cron job is required. No persistent log file is written to JFFS.

## Installation notes

The included kernel source must be built against the matching Asuswrt-Merlin/Broadcom kernel tree/config. The prebuilt module from one firmware build must not be assumed compatible with another.

The normal Merlin boot hook is:

```sh
# DYNBQ BEGIN
(sleep 25; /jffs/dynbq/dynbq-controller.sh start) &
# DYNBQ END
```

`/jffs/scripts/services-start` must be executable and begin with `#!/bin/sh`.

## Final cleanup

On the router:

```sh
/jffs/dynbq/dynbq-controller.sh status
```

For a development-artifact sweep, copy/run `scripts/router-cleanup.sh`. It preserves unrelated `services-start` content and keeps only the two production DynBQ files.

## Known limitations

The tested impl105 firmware does not expose writable host controls for:

- `ampdu_ba_wsize`
- `ampdu_mpdu`
- `ampdu_rr_retry_limit_tid` for BE TIDs 0/3

V3.2 therefore leaves those controls untouched and retains Broadcom's native internal BA/rate-selection behavior. Runner-level `ba256cfg:1` remains available independently.

## License

The kernel shim is GPL-2.0-only. See `LICENSE`.

## Empirical three-band test

On a macOS Wi-Fi client, run `scripts/test-high-macos.sh`. It uses `networkQuality -s -v`, watches deduplicated controller samples, proves HIGH entry only after the strict very-high streak, then verifies HIGH automatically downshifts after load ends. During the cooldown it also reports whether the radio accumulated enough <=1000 pps samples to select LOW=64.
