#!/usr/bin/env bash
# Build, sign, notarize, package and tag a flatlink release.
#
#   scripts/release.sh 0.1.0
#
# Produces dist/flatlink-<version>-macos.zip (a universal, Developer ID signed and
# notarized binary plus LICENSE) and its .sha256, and tags the commit it was built
# from as v<version>. Publishing — pushing the tag, the GitHub release and the
# Homebrew cask — is printed at the end, not done here.
#
# Environment:
#   DEVELOPER_DIR    Xcode to build with (default: /Applications/Xcode.app — never a beta).
#                    It must be the version in .xcode-version, which CI builds with too.
#   SIGN_IDENTITY    codesign identity (default: the one "Developer ID Application" identity)
#   NOTARY_PROFILE   notarytool keychain profile (default: PhotoDropNotary)
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 0.1.0}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NOTARY_PROFILE="${NOTARY_PROFILE:-PhotoDropNotary}"
cd "$(dirname "$0")/.."

fail() { echo "✗ $*" >&2; exit 1; }

# Preflight: everything that can fail cheaply fails before the build.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be X.Y.Z, got '$VERSION'"
grep -q "^let version = \"$VERSION\"$" Sources/flatlink/main.swift \
  || fail "Sources/flatlink/main.swift does not say version $VERSION"
xcode=$(xcodebuild -version)
[[ "${xcode%%$'\n'*}" == "Xcode $(<.xcode-version)" ]] \
  || fail "building with ${xcode%%$'\n'*}, but .xcode-version says $(<.xcode-version)"
arch -x86_64 /usr/bin/true 2>/dev/null \
  || fail "Rosetta is needed to run the Intel half of the binary: softwareupdate --install-rosetta"

# The release is built from what is on GitHub, so that the tag names the source of the binary.
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
COMMIT=$(git rev-parse HEAD)
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "tag v$VERSION already exists"
remote=$(git ls-remote origin refs/heads/main "refs/tags/v$VERSION") || fail "can't reach origin"
grep -q "^$COMMIT	refs/heads/main$" <<<"$remote" \
  || fail "HEAD (${COMMIT:0:7}) is not what main on origin points at; push it first"
! grep -q "refs/tags/v$VERSION$" <<<"$remote" || fail "tag v$VERSION already exists on origin"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  ids=$(security find-identity -v -p codesigning | grep -c '"Developer ID Application' || true)
  [[ "$ids" == 1 ]] || fail "found $ids Developer ID Application identities; set SIGN_IDENTITY"
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep '"Developer ID Application' | sed 's/.*"\(.*\)"/\1/')
fi
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "no usable notarytool profile '$NOTARY_PROFILE'"
[[ "$(xcrun swift --version 2>&1)" =~ Swift\ version\ ([^ ]+) ]] || fail "can't tell the Swift version"
echo "▸ flatlink $VERSION from ${COMMIT:0:7} — ${xcode%%$'\n'*}, Swift ${BASH_REMATCH[1]}, $SIGN_IDENTITY"

# Everything is built from scratch in a folder of its own, so nothing stale gets into a release.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Runs a step, showing its last line — or all of its output when it fails.
step() {
  local log="$WORK/$1.log"
  shift
  "$@" >"$log" 2>&1 || { cat "$log" >&2; fail "failed: $*"; }
  tail -1 "$log"
}

echo "▸ test"
step test xcrun swift test --scratch-path "$WORK/build"

echo "▸ build (arm64 + x86_64)"
step build xcrun swift build -c release --arch arm64 --arch x86_64 --scratch-path "$WORK/build" -Xswiftc -warnings-as-errors
# Where it lands moved in Xcode 27 (apple/ became out/), so it is asked for, not assumed.
BIN="$(xcrun swift build -c release --arch arm64 --arch x86_64 --scratch-path "$WORK/build" --show-bin-path)/flatlink"
[[ "$(lipo -archs "$BIN")" == *arm64* && "$(lipo -archs "$BIN")" == *x86_64* ]] || fail "binary is not universal"

STAGE="dist/flatlink-$VERSION"
NAME="flatlink-$VERSION-macos.zip"
ZIP="dist/$NAME"
rm -rf "$STAGE" "$ZIP" "$ZIP.sha256"
mkdir -p "$STAGE"
cp "$BIN" "$STAGE/flatlink"
cp LICENSE "$STAGE/"

echo "▸ sign"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE/flatlink"
step verify codesign --verify --strict --verbose=2 "$STAGE/flatlink"
# Match captured output: `cmd | grep -q` fails under pipefail when grep exits early (SIGPIPE).
sig=$(codesign -dv "$STAGE/flatlink" 2>&1)
grep -q 'flags=.*runtime' <<<"$sig" || fail "hardened runtime flag missing"

echo "▸ try both halves of the signed binary"
for half in arm64 x86_64; do
  [[ "$(arch "-$half" "$STAGE/flatlink" --version)" == "flatlink $VERSION" ]] \
    || fail "$half: the binary reports the wrong version"
  mkdir -p "$WORK/$half/src/day"
  touch "$WORK/$half/src/day/A.DNG" "$WORK/$half/src/day/A.JPG" "$WORK/$half/src/B.jpg"
  step "try-$half" arch "-$half" "$STAGE/flatlink" --skip-paired-jpegs "$WORK/$half/src" "$WORK/$half/flat"
  links=$(find "$WORK/$half/flat" -type l)
  [[ "$(wc -l <<<"$links" | tr -d ' ')" == 2 ]] || fail "$half: expected 2 links, got: $links"
done

echo "▸ notarize (a bare binary can't be stapled; Gatekeeper checks the ticket online)"
# Zipped under another name until it is accepted, so dist/ never holds a release that isn't one.
# No resource forks or extended attributes: they would unzip as ._ files.
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$WORK/$NAME"
out=$(xcrun notarytool submit "$WORK/$NAME" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) \
  || { echo "$out" >&2; fail "notarytool failed"; }
grep -E '^\s*(id|status):' <<<"$out" | sed 's/^ */  /'
grep -q 'status: Accepted' <<<"$out" \
  || { echo "$out" >&2; fail "notarization was not accepted; see 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE'"; }
mv "$WORK/$NAME" "$ZIP"

# From inside dist/, so that `shasum -c` works on the two files wherever they are downloaded to.
(cd dist && shasum -a 256 "$NAME" | tee "$NAME.sha256")
SHA=$(<"$ZIP.sha256")
SHA=${SHA%% *}

[[ "$(git rev-parse HEAD)" == "$COMMIT" && -z "$(git status --porcelain)" ]] \
  || fail "the repository changed during the build; v$VERSION was not tagged"
git tag -a "v$VERSION" -m "flatlink $VERSION" "$COMMIT"

cat <<EOF2

✓ $ZIP is signed and notarized, and ${COMMIT:0:7} is tagged v$VERSION. To publish:
  git push origin v$VERSION
  gh release create v$VERSION "$ZIP" "$ZIP.sha256" --title "flatlink $VERSION" --notes "…"
  then in tsvb/homebrew-tap Casks/flatlink.rb (a cask, not a formula: an unbottled formula
  needs current Command Line Tools to install, a cask never does) set
    version "$VERSION"
    sha256 "$SHA"
EOF2
