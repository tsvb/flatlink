#!/usr/bin/env bash
# Publish a release that scripts/release.sh built and tagged: push the tag, create the GitHub release
# with its zips, and point the Homebrew casks in tsvb/homebrew-tap at them.
#
#   scripts/publish.sh 1.1.2 notes.md
#
# Asks once before anything leaves this Mac. With DRY_RUN=1 it checks everything, and updates the
# casks in a scratch copy of the tap, but pushes and publishes nothing.
set -euo pipefail

VERSION="${1:?usage: scripts/publish.sh <version> <notes.md>}"
NOTES="${2:?usage: scripts/publish.sh <version> <notes.md>}"
DRY_RUN="${DRY_RUN:-}"
TAP="tsvb/homebrew-tap"
cd "$(dirname "$0")/.."

fail() { echo "✗ $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be X.Y.Z, got '$VERSION'"
[[ -s "$NOTES" ]] || fail "no release notes in '$NOTES'"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "v$VERSION isn't tagged; run scripts/release.sh $VERSION first"

# The zips release.sh made, as its checksums recorded them.
ZIP="flatlink-$VERSION-macos.zip"
APP_ZIP="flatlink-app-$VERSION-macos.zip"
for zip in "$ZIP" "$APP_ZIP"; do
  [[ -f "dist/$zip" && -f "dist/$zip.sha256" ]] || fail "dist/$zip or its .sha256 is missing"
  (cd dist && shasum -a 256 -c --status "$zip.sha256") || fail "dist/$zip doesn't match its .sha256"
done
SHA=$(cut -d ' ' -f 1 "dist/$ZIP.sha256")
APP_SHA=$(cut -d ' ' -f 1 "dist/$APP_ZIP.sha256")

if [[ -z "$DRY_RUN" ]]; then
  ! gh release view "v$VERSION" >/dev/null 2>&1 || fail "the release v$VERSION already exists on GitHub"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The casks, updated in a copy of the tap and checked before anything is published.
gh repo clone "$TAP" "$WORK/tap" -- --quiet
for cask in flatlink flatlink-app; do
  file="$WORK/tap/Casks/$cask.rb"
  [[ -f "$file" ]] || fail "$TAP has no Casks/$cask.rb"
  sha=$([[ "$cask" == flatlink ]] && echo "$SHA" || echo "$APP_SHA")
  sed -i '' -E -e "s/^  version \"[^\"]*\"$/  version \"$VERSION\"/" -e "s/^  sha256 \"[^\"]*\"$/  sha256 \"$sha\"/" "$file"
  if ! grep -q "^  version \"$VERSION\"$" "$file" || ! grep -q "^  sha256 \"$sha\"$" "$file"; then
    fail "couldn't set the version and sha256 in Casks/$cask.rb"
  fi
done
brew style "$WORK/tap/Casks/flatlink.rb" "$WORK/tap/Casks/flatlink-app.rb" >/dev/null \
  || fail "brew style finds fault with the updated casks"
git -C "$WORK/tap" --no-pager diff --stat

if [[ -n "$DRY_RUN" ]]; then
  echo "✓ dry run: v$VERSION, both zips and the casks check out; nothing was pushed or published"
  exit 0
fi

read -r -p "Publish flatlink $VERSION: push v$VERSION, create the GitHub release and update $TAP? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || fail "not published"

echo "▸ push the tag"
git push origin "v$VERSION"

echo "▸ create the release"
gh release create "v$VERSION" "dist/$ZIP" "dist/$ZIP.sha256" "dist/$APP_ZIP" "dist/$APP_ZIP.sha256" \
  --title "flatlink $VERSION" --notes-file "$NOTES"

echo "▸ check what GitHub serves"
gh release download "v$VERSION" --pattern '*.zip' --dir "$WORK/served"
(cd "$WORK/served" && shasum -a 256 -c --status <(cat "$OLDPWD/dist/$ZIP.sha256" "$OLDPWD/dist/$APP_ZIP.sha256")) \
  || fail "the zips GitHub serves don't match; the casks were not updated"

echo "▸ update the casks"
git -C "$WORK/tap" commit --quiet -am "flatlink $VERSION"
git -C "$WORK/tap" push --quiet origin HEAD

echo "▸ check that Homebrew installs it"
brew update --quiet >/dev/null
brew fetch --cask --force tsvb/tap/flatlink tsvb/tap/flatlink-app >/dev/null \
  || fail "Homebrew can't fetch the new casks; check $TAP"

echo "✓ flatlink $VERSION is published: brew upgrade --cask flatlink flatlink-app"
