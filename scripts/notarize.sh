#!/bin/bash
# Sends the signed app to Apple's notary service and staples the ticket to it, then builds the release disk
# image (the drag-to-Applications window in docs/design/dmg), signs, notarizes and staples that too. Writes
# Face-ID-Unlock-<version>.dmg and Face-ID-Unlock.dmg (the same file; the website's Download links to
# releases/latest/download/Face-ID-Unlock.dmg). Run after scripts/build-app.sh, on a Mac whose keychain holds a
# notarytool profile for the signing team; FACEID_NOTARY_PROFILE names it. dmgbuild runs through uv.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-$PWD/.build/Face ID Unlock.app}"
profile="${FACEID_NOTARY_PROFILE:?set FACEID_NOTARY_PROFILE to your notarytool keychain profile}"
identity="${FACEID_SIGNING_IDENTITY:-Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)}"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

notarize() {
    local status
    status="$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json |
        plutil -extract status raw -)"
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization of $1 finished with status: $status. See: xcrun notarytool log <id> --keychain-profile $profile" >&2
        exit 1
    fi
}

# The app: Apple checks a zip of it; the ticket is stapled to the app itself.
ditto -c -k --keepParent "$app" "$work/submit.zip"
notarize "$work/submit.zip"
xcrun stapler staple "$app"
spctl --assess --type exec "$app"

# The disk image people download.
dmg="$PWD/.build/Face-ID-Unlock-$version.dmg"
rm -f "$dmg"
uv run --quiet --with dmgbuild dmgbuild -s docs/design/dmg/dmg-settings.py -D app="$app" "Face ID Unlock" "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature "$dmg"
cp "$dmg" "$PWD/.build/Face-ID-Unlock.dmg"
printf '%s\n' "$dmg" "$PWD/.build/Face-ID-Unlock.dmg"
