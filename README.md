# Asuswrt DynBQ V3

Experimental dynamic Broadcom DHD/Runner backup-queue control for the **ASUS GT-BE19000AI** on **Asuswrt-Merlin 3006.102.8_2 / Linux 4.19.294**.

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

| State | Backup queue | Purpose |
|---|---:|---|
| LOW | 64 | sustained pressure / real BQ drop |
| MID | 128 | sticky normal baseline |
| HIGH | 192 | sustained clean high packet load |

Transitions in V3.1:

- MID → LOW: 4 consecutive pressure samples, or any real Runner BQ drop
- LOW → MID: 3 clean samples
- MID → HIGH: 6 sustained clean high-load samples
- HIGH → MID: 3 non-high samples or ordinary pressure
- HIGH → LOW: real BQ drop

HIGH uses DHD/Runner `dhd_tx_post_packets` and `dhd_tx_complete_packets`, not Linux interface byte counters that may be bypassed by hardware offload.

## Files

- `src/dynbq.c` — GPL kernel shim exposing `/proc/dynbq`
- `src/Makefile` — external module Makefile
- `scripts/dynbq-controller.sh` — production V3.1 controller
- `scripts/router-cleanup.sh` — removes development leftovers and normalizes persistence
- `tests/state_machine.py` — state-machine regression checks
- `publish-github.sh` — creates/publishes the GitHub repository, description, topics and `v3.1.0` tag

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

V3.1 therefore leaves those controls untouched and retains Broadcom's native internal BA/rate-selection behavior. Runner-level `ba256cfg:1` remains available independently.

## License

The kernel shim is GPL-2.0-only. See `LICENSE`.


## Empirical HIGH=192 test

On a macOS Wi-Fi client, run `scripts/test-high-macos.sh`. It uses `networkQuality -s -v`, watches the router's DHD/Runner signals, and reports PASS only after observing an automatic `128 -> 192 -> 128` transition.

V3.1 HIGH requires at least 30,000 TX posts/sec for 6 consecutive 2-second samples, `outstanding <= 64`, zero feeder-full/BQ-drop events, and at least 95% TX completions.
