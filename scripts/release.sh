#!/usr/bin/env bash
# Build, sign, notarize and package a flatlink release.
#
#   scripts/release.sh 0.1.0
#
# Produces dist/flatlink-<version>-macos.zip (a universal, Developer ID signed and
# notarized binary plus LICENSE) and its .sha256. Publishing — the tag, the GitHub
# release and the Homebrew formula — is printed at the end, not done here.
#
# Environment:
#   DEVELOPER_DIR    Xcode to build with (default: /Applications/Xcode.app — never a beta)
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
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "tag v$VERSION already exists"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  ids=$(security find-identity -v -p codesigning | grep -c '"Developer ID Application' || true)
  [[ "$ids" == 1 ]] || fail "found $ids Developer ID Application identities; set SIGN_IDENTITY"
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep '"Developer ID Application' | sed 's/.*"\(.*\)"/\1/')
fi
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "no usable notarytool profile '$NOTARY_PROFILE'"
echo "▸ flatlink $VERSION — $(xcrun swift --version 2>&1 | head -1 | sed 's/.*Apple Swift version \([^ ]*\).*/Swift \1/'), $SIGN_IDENTITY"

echo "▸ test"
swift test 2>&1 | tail -1

echo "▸ build (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
BIN=.build/apple/Products/Release/flatlink
[[ "$(lipo -archs "$BIN")" == *arm64* && "$(lipo -archs "$BIN")" == *x86_64* ]] || fail "binary is not universal"

STAGE="dist/flatlink-$VERSION"
ZIP="dist/flatlink-$VERSION-macos.zip"
rm -rf "$STAGE" "$ZIP" "$ZIP.sha256"
mkdir -p "$STAGE"
cp "$BIN" "$STAGE/flatlink"
cp LICENSE "$STAGE/"
[[ "$("$STAGE/flatlink" --version)" == "flatlink $VERSION" ]] || fail "built binary reports the wrong version"

echo "▸ sign"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE/flatlink"
codesign --verify --strict --verbose=2 "$STAGE/flatlink" 2>&1 | tail -1
# Match captured output: `cmd | grep -q` fails under pipefail when grep exits early (SIGPIPE).
sig=$(codesign -dv "$STAGE/flatlink" 2>&1)
grep -q 'flags=.*runtime' <<<"$sig" || fail "hardened runtime flag missing"

echo "▸ notarize (a bare binary can't be stapled; Gatekeeper checks the ticket online)"
ditto -c -k --keepParent "$STAGE" "$ZIP"
out=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
grep -E '^\s*(id|status):' <<<"$out" | sed 's/^ */  /'
grep -q 'status: Accepted' <<<"$out" || fail "notarization was not accepted; see 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE'"

shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

cat <<EOF

✓ $ZIP is signed and notarized. To publish:
  git tag -a v$VERSION -m "flatlink $VERSION" && git push origin v$VERSION
  gh release create v$VERSION "$ZIP" "$ZIP.sha256" --title "flatlink $VERSION" --notes "…"
  then update url + sha256 in tsvb/homebrew-tap Formula/flatlink.rb
EOF
