#!/usr/bin/env bash
set -euo pipefail

# Builds dist and creates a release tag for it WITHOUT committing dist to
# the current branch. The build output is committed into a one-off commit
# on top of the current HEAD, tagged, and only the tag is pushed. The
# local branch is then reset back to its original state, so dist never
# lives on master history - it only exists under the tag.

DRY_RUN=false
TAG_ARG=""
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then
    DRY_RUN=true
  else
    TAG_ARG="$arg"
  fi
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash your changes first." >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
CURRENT_COMMIT="$(git rev-parse HEAD)"

if [[ -n "$TAG_ARG" ]]; then
  TAG="$TAG_ARG"
else
  VERSION="$(node -p "require('./package.json').version")"
  TAG="v${VERSION}"
fi

tag_exists() {
  git rev-parse -q --verify "refs/tags/$1" >/dev/null \
    || git ls-remote --exit-code --tags origin "$1" >/dev/null 2>&1
}

if tag_exists "${TAG}"; then
  echo "Tag ${TAG} already exists (locally or on origin)." >&2
  echo "Last 3 tags:" >&2
  git tag --sort=-creatordate | head -3 >&2
  exit 1
fi

echo "==> Building dist"
pnpm run build

echo "==> Copying plugin files to root (prepare)"
npm run prepare

echo "==> Committing build artifacts locally (will not be pushed to ${CURRENT_BRANCH})"
git add -f dist plugin/dist android ios CapacitorGoogleMaps.podspec README.md
git commit --quiet -m "chore: build dist for ${TAG}"

echo ""

if $DRY_RUN; then
  echo ""
  echo "Dry run: not creating tag or pushing. Restoring ${CURRENT_BRANCH}."
  git reset --hard "${CURRENT_COMMIT}"
  exit 0
fi

echo ""
read -rp "Create and push tag ${TAG}? [Y/n] " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "Aborted. Restoring ${CURRENT_BRANCH}."
  git reset --hard "${CURRENT_COMMIT}"
  exit 1
fi

echo "==> Tagging ${TAG}"
# git tag -a "${TAG}" -m "${TAG}"

echo "==> Pushing tag ${TAG} (branch ${CURRENT_BRANCH} is not pushed)"
# git push origin "${TAG}"

echo "==> Restoring ${CURRENT_BRANCH} to its original state (build commit stays only under the tag)"
git reset --hard "${CURRENT_COMMIT}"

echo ""
echo "Done"
