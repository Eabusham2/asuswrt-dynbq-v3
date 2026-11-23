# Asuswrt DynBQ v3

DynBQ adjusts Broadcom DHD/Runner backup queues according to each radio's traffic and queue-pressure counters. It is **experimental, firmware-specific router software**. The current source release is **3.3.1**.

The controller uses queue sizes 64, 128, and 192 on 5/6 GHz, and 64 or 128 on 2.4 GHz. It preserves Runner offload and HBQD rather than changing those capabilities.

## Compatibility and release contents

The project's recorded hardware baseline is an **ASUS GT-BE19000AI running Asuswrt-Merlin 3006.102.8_2 / Linux 4.19.294**. That historical observation does not establish compatibility with another model, firmware build, or kernel ABI. See [historical observations](docs/verified-observations.md).

[Releases](https://github.com/Eabusham2/asuswrt-dynbq-v3/releases) provide an experimental **source archive and SHA-256 checksum**. The archive includes the controller, kernel-module source, documentation, helpers, and tests. It does **not** include a compiled `dynbq.ko`, the Broadcom firmware tree, or a complete build toolchain.

Before running DynBQ, you need:

- A kernel module compiled and validated against the **exact firmware and kernel ABI** on the router. A matching kernel version string alone is insufficient.
- The firmware's `dhd` command and a working `/jffs/bin/bdmf_shell` with access to Runner counters.
- The radio mapping expected by this controller: `wl0` = 2.4 GHz, `wl1` = 5 GHz, `wl2` = 6 GHz.
- SSH administrator access, writable JFFS storage, and BusyBox shell utilities.
- An independently verified Runner baseline on all three radios: `txoffl:1`, `rxoffl:1`, `bkupq:1`, `hbqd:1`, `dynbkupq:1`, `codel:0`, `ba256cfg:1`.

The source is intended for firmware developers and existing validated installations. There is no universal first-install script. Do not load a module built for another firmware.

## Get the source

Download the versioned source archive and matching `.sha256` file from the release page. Verify the archive before extracting it:

```bash
# Linux
sha256sum -c asuswrt-dynbq-v3-3.3.1-source.sha256

# macOS
shasum -a 256 -c asuswrt-dynbq-v3-3.3.1-source.sha256
```

You can also clone the repository and select a release tag:

```bash
git clone https://github.com/Eabusham2/asuswrt-dynbq-v3.git
cd asuswrt-dynbq-v3
git checkout v3.3.1
```

### Kernel-module build

`src/Makefile` defines the external-module target for `src/dynbq.c`. Build it inside a configured, matching firmware build environment with the correct compiler, generated headers, and module symbols. For an environment that supports external module builds, the invocation has this form:

```bash
make -C "$KERNEL_BUILD" M="$PWD/src" \
  ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" modules
```

Set those variables from the firmware's own build configuration. This repository does not supply or validate that environment. A successful compile alone does not prove that the module's calls into Broadcom's Runner driver are compatible.

The expected installation layout is:

```text
/jffs/dynbq/dynbq.ko
/jffs/dynbq/dynbq-controller.sh
```

The module provides `/proc/dynbq`. It resolves the firmware's `dhd_runner_notify` symbol and accepts only the three queue sizes used by the controller. Validate the module and Runner behavior on the intended firmware before enabling the controller or adding boot persistence.

## Update an existing installation

The updater replaces the **controller only**. It requires an existing controller and a firmware-matched module at the paths above. It does not build, replace, or certify the module, flash firmware, or reboot the router.

From macOS, set your own SSH connection values, then run the updater from the source directory:

```bash
export ROUTER="router.example"   # Replace with your router's hostname or IP
export RUSER="router-admin"      # Replace with its SSH administrator username
bash scripts/update-router-macos.sh
```

Both variables are required; the helpers contain no personal login or network defaults. SSH uses your normal key/password authentication and host-key verification.

The updater transfers the controller over plain SSH, checks its byte count and BusyBox shell syntax, checks the version and Runner baseline, and rolls back the controller if its startup or post-update health check fails. The old `scripts/update-router-v3.2-macos.sh` path remains a compatibility entry point to the same updater.

Firmware upgrades require a fresh module compatibility review before reusing this updater.

## Use the controller

On a router with a validated installation:

```sh
/jffs/dynbq/dynbq-controller.sh start
/jffs/dynbq/dynbq-controller.sh status
/jffs/dynbq/dynbq-controller.sh stop
```

`start` avoids launching another controller when one is already running. `status` prints each radio's target, live counters, Runner capabilities, and recent transitions. `stop` attempts to restore MID=128 on all radios and removes the controller's runtime files. If Runner access has failed, independently verify the queue state rather than relying only on the stop message.

Startup persistence is not installed by the updater. If you add a call to an existing Merlin startup hook, preserve its other commands and first validate manual start/stop on the exact firmware. This release has no new reboot-persistence hardware certification.

## Current queue policy

Each radio keeps its own state and consecutive-sample counters. Samples are taken approximately every two seconds; command execution and unavailable Runner statistics can make wall-clock intervals longer.

| Radio | LOW | MID | HIGH | LOW → MID traffic threshold |
|---|---:|---:|---:|---:|
| `wl0` — 2.4 GHz | 64 | 128 | Disabled | ≥12,000 TX posts/sec |
| `wl1` — 5 GHz | 64 | 128 | 192 | ≥4,000 TX posts/sec |
| `wl2` — 6 GHz | 64 | 128 | 192 | ≥4,000 TX posts/sec |

| Transition | Requirement |
|---|---|
| MID → LOW, idle | ≤2,000 TX posts/sec for 8 consecutive samples; no BQ drops |
| MID → LOW, pressure | Feeder-full delta ≥512 for 9 consecutive non-HIGH-eligible samples |
| LOW → MID | The radio's recovery threshold for 9 consecutive samples; no BQ drops |
| MID → HIGH, 5/6 GHz | ≥30,000 TX posts/sec for 12 consecutive samples, outstanding ≤2,048, and no BQ drops |
| HIGH hold, 5/6 GHz | ≥20,000 TX posts/sec, outstanding ≤2,048, and no BQ drops |
| HIGH → MID | 4 consecutive failed HIGH-hold samples |
| HIGH → LOW, idle | 4 consecutive idle samples |
| MID/HIGH → LOW, BQ drop | Immediate on a real Runner BQ-drop delta for an allowed state |

The 2.4 GHz radio never enters HIGH. A stale HIGH state there returns to MID. During genuine heavy traffic, feeder-full signals alone do not block HIGH on 5/6 GHz. The controller writes a flowring when its target changes or when it first sees the flowring.

## Logs and diagnostics

Runtime state is kept under `/tmp`, including `/tmp/dynbq.log`, per-radio `.stats` files, the PID file, and flowring target caches. The controller checks the log size at 32 KiB and trims it to the most recent 120 lines. It resets the log on start and removes it on stop. `/tmp` data also disappears at reboot; no persistent JFFS log or cron job is required.

For an optional macOS Wi-Fi load observation:

```bash
ROUTER="router.example" RUSER="router-admin" bash scripts/test-high-macos.sh
```

This runs macOS `networkQuality`, observes all three radios, and reports transitions. It creates real network load and may not sustain enough traffic to enter HIGH. A partial result is not a hardware certification; 2.4 GHz cannot produce a HIGH transition by design. Offline CI does not run this helper.

If startup fails, check the firmware-matched module, `/proc/dynbq`, `bdmf_shell`, all three Runner capability lines, and the recent log before retrying. Do not disable HBQD to make a failed precheck pass.

### Legacy migration helper

`scripts/router-cleanup.sh` is retained for installations containing this project's earlier experimental setup. **It is not a routine install or update step.** It unsets four legacy NVRAM keys, replaces marked DynBQ startup blocks, and removes every file or directory in `/jffs/dynbq` except `dynbq.ko` and `dynbq-controller.sh`. Review the script and back up any files or hook content you need before using it. Normal controller updates do not invoke it.

## Development and releases

Run offline checks from the repository root:

```bash
sh scripts/check.sh
```

CI checks shell syntax, version consistency, and behavioral scenarios that execute the actual controller's policy block. Coverage includes all three radios, dwell thresholds, emergency drops, heavy-load feeder pressure, the outstanding ceiling, and radio independence. These checks do not load the kernel module or verify physical router behavior.

See [release maintenance](docs/releases.md) for the manual, versioned source-release workflow. Repository changes and documentation pushes do not publish a release automatically.

## License

[GPL-2.0-only](LICENSE).
