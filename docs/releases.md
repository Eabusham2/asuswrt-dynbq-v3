# Release maintenance

DynBQ releases are experimental source distributions. The repository does not currently build or publish a firmware-specific kernel module. Keep the public release marked as a prerelease until hardware compatibility and deployment have been independently established for the advertised target.

## Prepare a release

1. Update `VERSION`, the controller's `VERSION` field, the README's current version and archive examples, and `CHANGELOG.md` together.
2. Run `sh scripts/check.sh`. Review the source and deployment changes, including the retained legacy helper paths.
3. Commit the intended changes and push them to `main`. Confirm the `lint` workflow succeeds for that commit.
4. Create a new, immutable version tag on that reviewed commit. Do not move or reuse an existing release tag.
5. Run **Release source preview** from GitHub Actions with the existing tag, for example `v3.3.1`.

The release workflow verifies the tag's version and that its commit is contained in `main`, reruns the offline checks, and creates an archive directly from the tagged Git tree. It publishes a source `.tar.gz` and a separate SHA-256 checksum file. Existing releases are not overwritten by the workflow.

## Inspect a package locally

On Linux, after committing the intended source:

```bash
bash scripts/package-release.sh
tar -tzf dist/asuswrt-dynbq-v3-3.3.1-source.tar.gz
```

The packager rejects tracked uncommitted changes. The archive contains committed repository files, including documentation and tests; ignored build outputs and local files are excluded. No prebuilt `.ko` is part of this distribution.

## Verification limits

The state-machine tests run the production shell policy with synthetic counters. They verify policy behavior rather than a separately maintained Python model. Syntax and policy checks cannot certify the module ABI, Broadcom driver interactions, actual queue-size readback, throughput, SIGHUP behavior on a router, or reboot persistence. Record any hardware verification separately with the exact model, firmware, module build, and source commit.

## Retired tooling

The previous `publish-github.sh` was a one-time repository bootstrap script with a fixed `v3.2.1` tag. It renamed the current branch and changed repository metadata, so it has been replaced by the manual release workflow. Its only executable reference was the old syntax job. The public `update-router-v3.2-macos.sh` path remains available and forwards to `update-router-macos.sh`.
