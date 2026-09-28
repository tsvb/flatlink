#!/usr/bin/env bash
# Build, sign, notarize, package and tag a flatlink release: the command and the app.
#
#   scripts/release.sh 1.1.0
#
# Produces, each with its .sha256:
#   dist/flatlink-<version>-macos.zip      the command: a universal, Developer ID signed and
#                                          notarized binary plus LICENSE
#   dist/flatlink-app-<version>-macos.zip  Flatlink.app, universal, signed, notarized and stapled
# and tags the commit they were built from as v<version>. Publishing — pushing the tag, the
# GitHub release and the Homebrew casks — is printed at the end, not done here.
#
# Environment:
#   DEVELOPER_DIR    Xcode to build with (default: /Applications/Xcode.app — never a beta).
#                    It must be the version in .xcode-version, which CI builds with too.
#                    XcodeGen, likewise, must be the version in .xcodegen-version.
#   SIGN_IDENTITY    codesign identity (default: the one "Developer ID Application" identity)
#   NOTARY_PROFILE   notarytool keychain profile (default: PhotoDropNotary, the Developer ID
#                    credentials this Mac keeps for all its apps, stored once with
#                    xcrun notarytool store-credentials)
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
grep -q "^        MARKETING_VERSION: \"$VERSION\"$" App/project.yml \
  || fail "App/project.yml does not say MARKETING_VERSION $VERSION"
command -v xcodegen >/dev/null || fail "XcodeGen is needed to build the app: brew install xcodegen"
xcodegen=$(xcodegen --version)
[[ "$xcodegen" == "Version: $(<.xcodegen-version)" ]] \
  || fail "XcodeGen is ${xcodegen#Version: }, but .xcodegen-version says $(<.xcodegen-version), which CI builds with"
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
# The app tried below is quit too, if the script stops while it is open.
pid=""
trap 'if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$WORK"' EXIT

# Runs a step, showing its last line — or all of its output when it fails.
step() {
  local log="$WORK/$1.log"
  shift
  "$@" >"$log" 2>&1 || { cat "$log" >&2; fail "failed: $*"; }
  grep -v '^[[:space:]]*$' "$log" | tail -1
}

echo "▸ test"
step test xcrun swift test --scratch-path "$WORK/build"

echo "▸ build (arm64 + x86_64)"
# Xcode 27 records the deployment target (14.0) as the SDK version of whatever it builds from a Swift
# package, with swift build or xcodebuild alike; an Xcode project target, like the app, records the
# SDK it was built with. It links against the current SDK all the same: only that number differs.
step build xcrun swift build -c release --arch arm64 --arch x86_64 --scratch-path "$WORK/build" -Xswiftc -warnings-as-errors
# Where it lands moved in Xcode 27 (apple/ became out/), so it is asked for, not assumed.
BIN="$(xcrun swift build -c release --arch arm64 --arch x86_64 --scratch-path "$WORK/build" --show-bin-path)/flatlink"
[[ "$(lipo -archs "$BIN")" == *arm64* && "$(lipo -archs "$BIN")" == *x86_64* ]] || fail "binary is not universal"

echo "▸ build the app (arm64 + x86_64)"
# Unsigned here, and signed below like the command, with the one identity and the same checks.
(cd App && xcodegen generate --quiet) || fail "xcodegen failed"
step app-build xcodebuild -project App/Flatlink.xcodeproj -scheme Flatlink -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/app" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGNING_ALLOWED=NO build
APP="$WORK/stage/Flatlink.app"
mkdir -p "$WORK/stage"
ditto "$WORK/app/Build/Products/Release/Flatlink.app" "$APP"
archs=$(lipo -archs "$APP/Contents/MacOS/Flatlink")
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "the app is not universal: $archs"
[[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")" == "$VERSION" ]] \
  || fail "the app's Info.plist does not say version $VERSION"
[[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")" == "$VERSION" ]] \
  || fail "the app's Info.plist does not say build $VERSION"
# One signature covers the bundle only while there is nothing nested in it to sign first.
[[ ! -e "$APP/Contents/Frameworks" && ! -e "$APP/Contents/PlugIns" ]] || fail "the app embeds code; sign it too"

STAGE="dist/flatlink-$VERSION"
NAME="flatlink-$VERSION-macos.zip"
ZIP="dist/$NAME"
rm -rf "$STAGE" "$ZIP" "$ZIP.sha256"
mkdir -p "$STAGE"
cp "$BIN" "$STAGE/flatlink"
cp LICENSE "$STAGE/"

echo "▸ sign"
# Named like the app, rather than after the file: that is how Gatekeeper and the notary service know it.
codesign --force --options runtime --timestamp --identifier com.tsvb.flatlink --sign "$SIGN_IDENTITY" "$STAGE/flatlink"
step verify codesign --verify --strict --verbose=2 "$STAGE/flatlink"
# Match captured output: `cmd | grep -q` fails under pipefail when grep exits early (SIGPIPE).
sig=$(codesign -dv "$STAGE/flatlink" 2>&1)
grep -q 'flags=.*runtime' <<<"$sig" || fail "hardened runtime flag missing"
grep -q '^Identifier=com.tsvb.flatlink$' <<<"$sig" || fail "the binary is not signed as com.tsvb.flatlink"

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

echo "▸ sign the app"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
step app-verify codesign --verify --deep --strict --verbose=2 "$APP"
sig=$(codesign -dv "$APP" 2>&1)
grep -q 'flags=.*runtime' <<<"$sig" || fail "the app: hardened runtime flag missing"

echo "▸ try the signed app"
# It opens its window for a moment. -pairs gives it an empty list for this launch only (the
# argument domain), so it never watches or updates the folders saved on this Mac.
"$APP/Contents/MacOS/Flatlink" -pairs '<5b5d>' >"$WORK/app-run.log" 2>&1 &
pid=$!
sleep 4
kill -0 "$pid" 2>/dev/null || { cat "$WORK/app-run.log" >&2; fail "the signed app quit within 4 seconds of starting"; }
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=""

# Submits a zip for notarization, and fails unless it is accepted.
notarize() {
  local out
  out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) \
    || { echo "$out" >&2; fail "notarytool failed"; }
  grep -E '^\s*(id|status):' <<<"$out" | sed 's/^ */  /' | awk '!seen[$0]++'
  grep -q 'status: Accepted' <<<"$out" \
    || { echo "$out" >&2; fail "notarization was not accepted; see 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE'"; }
}

# From inside dist/, so that `shasum -c` works on the two files wherever they are downloaded to.
checksum() {
  (cd dist && shasum -a 256 "$1" | tee "$1.sha256") >&2
  local sha
  sha=$(<"dist/$1.sha256")
  echo "${sha%% *}"
}

echo "▸ notarize the command (a bare binary can't be stapled; Gatekeeper checks the ticket online)"
# Zipped under another name until it is accepted, so dist/ never holds a release that isn't one.
# No resource forks or extended attributes: they would unzip as ._ files.
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$WORK/$NAME"
notarize "$WORK/$NAME"
mv "$WORK/$NAME" "$ZIP"
SHA=$(checksum "$NAME")

echo "▸ wait for Gatekeeper to find the command's ticket"
# A bare binary can't carry its ticket, so Gatekeeper looks it up online by its cdhash. Right after
# notarization it can still find none, and a download in that window is refused ("Apple could not
# verify…"): measured for 1.1.0, some five minutes although the ticket service already had it.
# So the release is not called ready until a downloaded copy — quarantined, as a browser leaves it —
# is accepted here. spctl only assesses it: nothing is run, so no dialog appears.
for ((try = 1; ; try++)); do
  probe="$WORK/gatekeeper-$try"
  cp "$STAGE/flatlink" "$probe"
  xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");release.sh;" "$probe"
  verdict=$(spctl --assess --type install -vv "$probe" 2>&1 || true)
  grep -q 'source=Notarized Developer ID' <<<"$verdict" && { echo "  accepted after $(( (try - 1) / 2 )) min"; break; }
  (( try < 40 )) || { echo "$verdict" >&2; fail "Gatekeeper still refuses the command after 20 minutes; not tagged"; }
  sleep 30
done

echo "▸ notarize and staple the app"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$WORK/app-submit.zip"
notarize "$WORK/app-submit.zip"
step staple xcrun stapler staple "$APP"
step staple-validate xcrun stapler validate "$APP"
gatekeeper=$(spctl --assess --type execute -vv "$APP" 2>&1) || { echo "$gatekeeper" >&2; fail "Gatekeeper rejects the app"; }
grep -q 'source=Notarized Developer ID' <<<"$gatekeeper" || { echo "$gatekeeper" >&2; fail "the app is not seen as notarized"; }
APP_NAME="flatlink-app-$VERSION-macos.zip"
APP_ZIP="dist/$APP_NAME"
rm -f "$APP_ZIP" "$APP_ZIP.sha256"
# The stapled app, zipped only now that it is one.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$APP_ZIP"
APP_SHA=$(checksum "$APP_NAME")

[[ "$(git rev-parse HEAD)" == "$COMMIT" && -z "$(git status --porcelain)" ]] \
  || fail "the repository changed during the build; v$VERSION was not tagged"
git tag -a "v$VERSION" -m "flatlink $VERSION" "$COMMIT"

cat <<EOF2

✓ $ZIP and $APP_ZIP are signed and notarized, and ${COMMIT:0:7} is tagged v$VERSION.
  flatlink      sha256 $SHA
  flatlink-app  sha256 $APP_SHA
To publish (tag, GitHub release and Homebrew casks), write the release notes to a file and run:
  scripts/publish.sh $VERSION <notes.md>
EOF2
