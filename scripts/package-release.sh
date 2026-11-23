#!/bin/bash
# Archive only committed source; a firmware-specific kernel module is not bundled.
set -euo pipefail
cd "$(dirname "$0")/.."
git diff --quiet
git diff --cached --quiet
VERSION="$(git show HEAD:VERSION | tr -d '\r\n')"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: VERSION must contain a semantic version" >&2
  exit 1
}
NAME="asuswrt-dynbq-v3-$VERSION-source"
mkdir -p dist
git archive --format=tar --prefix="$NAME/" HEAD | gzip -n >"dist/$NAME.tar.gz"
(
  cd dist
  sha256sum "$NAME.tar.gz" >"$NAME.sha256"
  sha256sum -c "$NAME.sha256"
)
echo "Source archive: dist/$NAME.tar.gz"
