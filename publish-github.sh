#!/bin/bash
set -euo pipefail

OWNER="${OWNER:-Eabusham2}"
REPO="${REPO:-asuswrt-dynbq-v3}"
VISIBILITY="${VISIBILITY:-public}"
VERSION="v3.2.0"
DESCRIPTION="Experimental DynBQ controller for ASUS GT-BE19000AI on Asuswrt-Merlin: dynamic Broadcom Runner backup queues (64/128/192), strict three-band hysteresis, and safe HBQD/offload preservation."
TOPICS=(asuswrt-merlin asus-router broadcom wifi-7 networking router queue-management latency gt-be19000ai dynamic-queue broadcom-runner)

command -v gh >/dev/null 2>&1 || { echo "gh CLI is required: brew install gh"; exit 1; }
gh auth status >/dev/null

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -b main
  USER_ID="$(gh api user --jq .id)"
  git config user.name "$OWNER"
  git config user.email "${USER_ID}+${OWNER}@users.noreply.github.com"
  git add .
  git commit -m "Initial DynBQ release"
else
  git branch -M main
fi

if gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
  echo "Remote repo already exists: $OWNER/$REPO"
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$OWNER/$REPO.git"
else
  gh repo create "$OWNER/$REPO" --"$VISIBILITY" --source=. --remote=origin --description "$DESCRIPTION"
fi

gh repo edit "$OWNER/$REPO" --description "$DESCRIPTION"
for topic in "${TOPICS[@]}"; do
  gh repo edit "$OWNER/$REPO" --add-topic "$topic"
done

if ! git rev-parse "$VERSION" >/dev/null 2>&1; then
  git tag -a "$VERSION" -m "DynBQ V3.2 strict three-band hysteresis release"
fi

git push -u origin main
git push origin "$VERSION"

echo "Published: https://github.com/$OWNER/$REPO"
