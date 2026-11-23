# DynBQ contributor context

Follow the canonical [repository guidance](../AGENTS.md).

- This is experimental Broadcom DHD/Runner queue-control source for
  firmware-specific development, not a prebuilt router package.
- The historical baseline is ASUS GT-BE19000AI, Asuswrt-Merlin `3006.102.8_2`,
  Linux `4.19.294`. It does not certify the current release or another firmware;
  every kernel module needs the exact firmware ABI and driver validation.
- Run `sh scripts/check.sh` and `git diff --check` from the repository root.
  The check script requires POSIX shell, Bash, and Python 3 and uses no router.
- `tests/state_machine.py` executes the production shell policy. Keep tests tied
  to that implementation and preserve unrelated capability and ownership checks.
- The updater and cleanup scripts perform device actions; they are not offline
  test commands. Treat device results separately from source/CI evidence.
- Preserve the old updater wrapper and keep release version references aligned.
  Source releases contain no compiled `.ko`; do not infer hardware performance
  or compatibility from a passing test suite.
