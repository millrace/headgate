#!/usr/bin/env bash
#
# Release headgate at the current HEAD: push main, create + push an annotated
# tag, and wait for the "headgate zip" CI (which builds & attaches headgate.zip).
#
#   tools/release.sh <X.Y.Z> [tag message]
#
# Commit your change first (e.g. with tools/commit.sh). Review this script once,
# then approve `tools/release.sh` to skip the per-step prompts.
set -euo pipefail

VER="${1:?usage: tools/release.sh X.Y.Z [message]}"
TAG="v$VER"
MSG="${2:-$TAG}"
REPO="millrace/headgate"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> push main + tag $TAG"
git -C "$ROOT" push origin main
git -C "$ROOT" tag -a "$TAG" -m "$MSG"
git -C "$ROOT" push origin "$TAG"

echo "==> waiting for 'headgate zip' CI…"
sleep 6
RID="$(gh run list -R "$REPO" --workflow 'headgate zip' -L1 --json databaseId -q '.[0].databaseId')"
gh run watch "$RID" -R "$REPO" --exit-status

echo "==> released $TAG"
gh release view "$TAG" -R "$REPO" --json assets -q '.assets[] | .name + "  " + (.size|tostring)' 2>/dev/null || true
