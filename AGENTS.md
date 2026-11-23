# Repository guidance

## Project and compatibility

DynBQ is experimental, firmware-specific Broadcom DHD/Runner backup-queue
software. Releases contain source, a shell controller, and helpers. They do not
contain a compiled kernel module or a firmware build toolchain.

The recorded historical hardware baseline is ASUS GT-BE19000AI with
Asuswrt-Merlin `3006.102.8_2` and Linux `4.19.294`. This is not a compatibility
certificate for the current release or another firmware. The module must match
the exact firmware ABI, including Broadcom's private driver interfaces.

The current radio mapping is `wl0` = 2.4 GHz, `wl1` = 5 GHz, and `wl2` = 6 GHz.
Preserve the Runner/HBQD capability checks, independent radio state, 2.4 GHz
HIGH-state cap, and bounded temporary logging when making unrelated changes.
Changes to these behaviors need corresponding implementation, tests, and
documentation; source tests cannot establish hardware compatibility.

## Source map

- `src/dynbq.c` and `src/Makefile`: kernel shim and external-module build target.
- `scripts/dynbq-controller.sh`: production policy, Runner checks, queue writes,
  and process lifecycle.
- `tests/state_machine.py`: behavioral scenarios executing the production shell
  policy block, without loading a module or accessing a router.
- `scripts/check.sh`: shared local and CI verification entry point.
- `scripts/update-router-macos.sh`: controller-only updater for an existing
  validated installation.
- `scripts/update-router-v3.2-macos.sh`: retained compatibility wrapper.
- `scripts/router-cleanup.sh`: legacy migration that changes NVRAM/startup hooks
  and removes extra files from the DynBQ installation directory.
- `scripts/package-release.sh`: committed-source packaging and checksums.
- `docs/verified-observations.md`: historical hardware evidence.

## Local verification

Run from the repository root with POSIX shell, Bash, and Python 3 available:

```sh
sh scripts/check.sh
git diff --check
```

For a focused policy run:

```sh
python3 tests/state_machine.py
```

The tests execute the actual shell policy. Keep that link to production code;
do not replace it with a separately maintained policy implementation.

Repository-scoped verification uses these offline checks. The controller,
updater, load-observation helper, and legacy cleanup helper perform device
actions and are not local test commands. For device work requested by the task,
preserve unrelated configuration and record the exact model, firmware, module
build, source commit, and observations separately from CI results.

## Kernel build boundary

`src/Makefile` supplies an external-module target. A build needs the exact
configured firmware tree, compiler, generated headers, and module symbols;
ordinary host kernel headers are not a substitute. The build invocation form
is documented in the [README](README.md#kernel-module-build). A successful
compile alone does not validate Broadcom driver compatibility.

## Documentation and maintenance

- Keep `VERSION`, the controller's version, README archive examples, and
  `CHANGELOG.md` aligned when changing the release version.
- Preserve the old updater entry point and existing user-facing paths unless
  the task includes a reviewed migration.
- Keep `/tmp` logging bounded. The normal updater does not install startup
  persistence or invoke the legacy cleanup helper.
- Preserve the kernel shim's GPL-2.0-only notice. The current `LICENSE` explicitly
  names the kernel shim; do not turn that wording into an unsupported license
  claim for all supporting files.
- Describe historical observations as historical. Do not advertise universal
  router support, measured speed gains, or device acceptance from offline tests.

## Release packaging

On Linux, after committing the intended source:

```sh
bash scripts/package-release.sh
```

The script archives `HEAD`, rejects tracked uncommitted changes, and writes the
source archive and checksum under `dist/`. It does not bundle a built `.ko`.

The current release process uses the manual **Release source preview** workflow
with an existing version tag matching `VERSION` and a reviewed commit contained
in `main`. Existing tags are not moved or reused. Source releases remain
experimental prereleases under the documented validation scope; see
[release maintenance](docs/releases.md).
