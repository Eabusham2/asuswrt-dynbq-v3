# DynBQ for Asuswrt-Merlin — experimental Broadcom Runner queue control

DynBQ is an **experimental Broadcom DHD/Runner backup-queue controller** developed on the **ASUS GT-BE19000AI with Asuswrt-Merlin**. It adjusts each radio's queue using traffic and queue-pressure counters. The current source release is **3.3.1**.

The source is intended for firmware developers and existing validated installations. Releases include a shell controller and Linux kernel-module source; a module built and validated for the router's **exact firmware** is required. No prebuilt module or universal installer is supplied.

The controller uses queue sizes 64, 128, and 192 on 5/6 GHz, and 64 or 128 on 2.4 GHz. It preserves Runner offload and HBQD rather than changing those capabilities.

[Source releases](https://github.com/Eabusham2/asuswrt-dynbq-v3/releases) · [Compatibility](#compatibility-and-release-contents) · [FAQ](#frequently-asked-questions) · [Report a problem](#report-a-problem)

## Compatibility and release contents

The project's recorded hardware baseline is an **ASUS GT-BE19000AI running Asuswrt-Merlin 3006.102.8_2 / Linux 4.19.294**. That historical observation does not establish compatibility with another model, firmware build, or kernel ABI. See [historical observations](docs/verified-observations.md).

[Releases](https://github.com/Eabusham2/asuswrt-dynbq-v3/releases) provide an experimental **source archive and SHA-256 checksum**. The archive includes the controller, kernel-module source, documentation, helpers, and tests. It does **not** include a compiled `dynbq.ko`, the Broadcom firmware tree, or a complete build toolchain.

Before running DynBQ, you need:

- A kernel module compiled and validated against the **exact firmware and kernel ABI** on the router. A matching kernel version string alone is insufficient.
- The firmware's `dhd` command and a working `/jffs/bin/bdmf_shell` with access to Runner counters.
- The radio mapping expected by this controller: `wl0` = 2.4 GHz, `wl1` = 5 GHz, `wl2` = 6 GHz.
- SSH administrator access, writable JFFS storage, and BusyBox shell utilities.
- An independently verified Runner baseline on all three radios: `txoffl:1`, `rxoffl:1`, `bkupq:1`, `hbqd:1`, `dynbkupq:1`, `codel:0`, `ba256cfg:1`.

Do not load a module built for another firmware.

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

Contributor and coding-assistant guidance lives in [AGENTS.md](AGENTS.md).

## Frequently asked questions

### Which routers and firmware versions can run DynBQ?

The recorded historical baseline is GT-BE19000AI with Merlin `3006.102.8_2` and Linux `4.19.294`. It does not certify the current release, another model, or later firmware. A matching kernel version string alone is insufficient; see the [compatibility requirements](#compatibility-and-release-contents).

### Where can I download a compiled dynbq.ko?

The [source releases](https://github.com/Eabusham2/asuswrt-dynbq-v3/releases) do not include one. Building requires the exact firmware's configured build tree, compiler, generated headers, and module symbols. The [module-build section](#kernel-module-build) explains that boundary; the controller updater requires an already validated module.

### Why does 2.4 GHz never enter HIGH?

The current policy caps `wl0` at MID=128 and uses a higher traffic threshold to leave LOW. Only `wl1` and `wl2` can reach HIGH=192. This is an intentional [per-radio policy](#current-queue-policy), not evidence that the controller has stopped working.

### Will DynBQ improve my internet speed or latency?

No general performance improvement is established by this source release. Offline tests verify queue-selection behavior, while [historical observations](docs/verified-observations.md) describe earlier queue transitions on one setup. The [load-observation helper](#logs-and-diagnostics) reports behavior without certifying a throughput or latency benefit.

### Does the updater flash firmware or reboot the router?

It replaces the controller in an existing installation and retains the current module. It does not flash firmware, reboot, or install startup persistence. Review the [update instructions](#update-an-existing-installation); a firmware change requires fresh module compatibility validation.

### Can I test the project without a router?

Yes. With POSIX shell, Bash, and Python 3 available, run `sh scripts/check.sh` from the repository root. These [offline checks](#development-and-releases) exercise the production policy with synthetic counters and do not load a kernel module or contact a router.

## Report a problem

[Open an issue](https://github.com/Eabusham2/asuswrt-dynbq-v3/issues) with the following information:

- Source tag or commit, controller version, and whether the problem occurs during build, update, startup, or an active session.
- Router model, full firmware version, kernel version, and the build source/toolchain used for `dynbq.ko`.
- Expected behavior, observed behavior, affected radio, and the shortest steps that reproduce it.
- Relevant output from the [status command](#use-the-controller) and the nearby transition or error lines; review shared logs for private information first.
- For an offline failure, the exact command and output from `sh scripts/check.sh`.

Keep hardware observations separate from local test results. A compiler error or policy-test failure can be reported without installing the module or changing router settings.

## Related independent projects

- [FlowCache Doctor](https://github.com/Eabusham2/asuswrt-merlin-flowcache-doctor) — Asuswrt-Merlin diagnostics and targeted FlowCache recovery.
- [Router VPN](https://github.com/Eabusham2/router-vpn) — a self-hosted VPN/proxy platform with native client applications.
- [AdGuard Home Block Page](https://github.com/Eabusham2/adguard-home-blockpage) — an HTTP explanation page for domains blocked by AdGuard Home.

These projects have their own installation and compatibility requirements. DynBQ has no dependency on them.

## License

The kernel shim is licensed under [GPL-2.0-only](LICENSE); see its [source notice](src/dynbq.c).

## Search keywords (ignore)

`dynbq`, `asus-router`, `asuswrt-merlin`, `gt-be19000ai`, `broadcom`, `broadcom-dhd`,
`broadcom-runner`, `backup-queue`, `dynamic-queue`, `queue-management`, `per-radio-policy`, `flowring`,
`hbqd`, `runner-offload`, `wireless-networking`, `2-4-ghz`, `5-ghz`, `6-ghz`,
`embedded-linux`, `linux-kernel-module`, `firmware-development`, `exact-firmware-abi`, `experimental`, `source-only`,
`busybox`, `posix-shell`, `bash`, `ssh`, `jffs`, `hysteresis`,
`queue-pressure`, `traffic-counters`, `state-machine`, `offline-tests`, `controller-updater`, `sha256-checksums`
