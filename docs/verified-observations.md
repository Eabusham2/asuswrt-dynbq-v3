# Verified observations

## Working final state

On the tested GT-BE19000AI / Merlin 3006.102.8_2 build:

```text
txoffl:1
rxoffl:1
bkupq:1
hbqd:1
dynbkupq:1
codel:0
ba256cfg:1
```

`/proc/dynbq` is present and a single V3 controller process is expected.

## Dynamic BQ

Manual live Runner writes were verified for backup queue sizes 64, 128 and 192, including restore to 128. Earlier automatic control also demonstrated real 128 → 64 → 128 transitions under BE feeder pressure.

## HBQD / CoDel incompatibility discovered during testing

Setting `dol1_cap_hbqd_override=0` / `dol2_cap_hbqd_override=0` did **not** merely turn off runtime HBQD. It advertised the capability as unsupported while the dongle still required it. Broadcom then force-disabled TX/RX Runner offload, producing an all-zero offload capability state.

Therefore V3.1 never applies HBQD capability overrides and intentionally keeps CoDel disabled on this firmware.

## Host BA/rate controls

Capability-safe same-value readback probes showed the tested firmware does not expose writable host setters for `ampdu_ba_wsize`, `ampdu_mpdu`, or BE per-TID regular-rate retry. Those are skipped rather than guessed.

## Logging

Production logging is tmpfs-only and bounded. No persistent JFFS logs are part of the project.
