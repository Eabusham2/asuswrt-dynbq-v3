# Asuswrt DynBQ V3

Experimental dynamic Broadcom DHD/Runner backup-queue control for the **ASUS GT-BE19000AI** on **Asuswrt-Merlin 3006.102.8_2 / Linux 4.19.294**. Current policy version: **V3.2.2**.

> This is model/firmware-specific research code. Rebuild and revalidate the kernel module for any different firmware/kernel ABI.

## Supported architecture

The tested router/dongle requires **HBQD** for Runner offload. The safe production architecture is:

- Runner TX/RX offload: **ON**
- backup queue + dynamic backup queue: **ON**
- HBQD: **ON**
- Runner BA256 capability: **ON**
- Runner CoDel: **OFF**
- DynBQ BE queue: **64 / 128 / 192**

## V3.2.2 state machine

Each production radio (`wl1` and `wl2`) runs the same state machine **independently** from its own DHD/Runner counters.

| State | Queue | Meaning |
|---|---:|---|
| LOW | 64 | low sustained traffic or real queue pressure |
| MID | 128 | normal/default |
| HIGH | 192 | sustained very-high traffic |

Transitions:

- **MID -> LOW:** <= **2000 TX posts/sec** for **3 consecutive 2-second samples** (~6 s)
- **MID -> LOW pressure:** any real Runner BQ drop immediately, or sustained feeder pressure during non-high traffic
- **LOW -> MID:** >= **4000 TX posts/sec** for **1 sample** (~2 s)
- **MID -> HIGH:** >= **30000 TX posts/sec** for **4 consecutive samples** (~8 s), outstanding <= **2048**, no real BQ drop
- **HIGH hold:** >= **20000 TX posts/sec**, outstanding <=2048, no real BQ drop
- **HIGH -> MID:** 2 consecutive failed HIGH-hold samples (~4 s)
- **HIGH -> LOW:** any real BQ drop immediately, or sustained very-low traffic after load collapses

Feeder-full by itself does **not** block HIGH during genuine >=30k pps heavy traffic. Real testing showed feeder-full can be large while the Runner remains healthy and BQ drops stay at zero.

This intentionally makes **LOW easy to reach**, **MID quick to recover when traffic starts**, **HIGH hard to enter**, and **HIGH easy to leave**.

## Empirical proof

V3.2.2 completed the full automatic cycle on the loaded radio under a real macOS `networkQuality` run:

```text
64 -> 128 -> 192 -> 128 -> 64
```

Observed on `wl1`:

- max TX-post rate: **63,497 pps**
- max outstanding: **1,900**
- max HIGH_OK streak: **6 samples**
- max HIGH_HOLD streak: **7 samples**
- BQ drops: **0**

The transition log showed:

```text
64 -> 128  low_cleared
128 -> 192 very_high
192 -> 128 high_cleared
128 -> 64  very_low
```

`wl2` stayed at 64 because it carried no heavy test traffic, confirming the radios operate independently.

Runner capabilities remained healthy throughout: `txoffl:1`, `rxoffl:1`, `bkupq:1`, `hbqd:1`, `dynbkupq:1`, `codel:0`, `ba256cfg:1`.

## Files

- `src/dynbq.c` — GPL kernel shim exposing `/proc/dynbq`
- `scripts/dynbq-controller.sh` — production controller
- `scripts/update-router-v3.2-macos.sh` — no-reboot updater with rollback
- `scripts/test-high-macos.sh` — empirical 64/128/192 test
- `scripts/router-cleanup.sh` — removes development leftovers
- `tests/state_machine.py` — regression tests for **wl1 and wl2**, including independent up/down transitions

## Storage/logging

Persistent router storage remains only:

```text
/jffs/dynbq/dynbq.ko
/jffs/dynbq/dynbq-controller.sh
```

Runtime state/logging is under `/tmp`. `/tmp/dynbq.log` is capped at **32 KiB**, trimmed to the newest 120 lines, reset when the controller starts, and disappears on reboot. No DynBQ cron job or persistent JFFS log is required.

## Updating the router

From a Mac clone of the repo:

```bash
cd ~/Downloads/asuswrt-dynbq-v3
git pull --ff-only
bash scripts/update-router-v3.2-macos.sh
```

The updater uses plain SSH streaming (no SFTP/scp requirement), BusyBox `ash -n`, Runner health checks, exact policy checks, and automatic rollback if the new controller fails.

## Testing all three bands

```bash
bash scripts/test-high-macos.sh
```

The test watches deduplicated per-radio samples, generates a real Wi-Fi load with `networkQuality`, then verifies up/down transitions and cooldown. A radio that carries no test traffic should stay LOW; that is expected because radios are independent.

## Known limitations

The tested impl105 firmware does not expose writable host controls for `ampdu_ba_wsize`, `ampdu_mpdu`, or `ampdu_rr_retry_limit_tid` for BE TIDs 0/3. DynBQ leaves them untouched and keeps Broadcom's native rate/BA behavior. Runner-level `ba256cfg:1` remains active independently.

## License

The kernel shim is GPL-2.0-only. See `LICENSE`.
