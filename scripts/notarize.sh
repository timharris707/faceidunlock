#!/bin/bash
# Sends the signed app to Apple's notary service, staples the ticket to it, and writes the release zips:
# Face-ID-Unlock-<version>.zip and Face-ID-Unlock.zip (the same file; the website's Download links to
# releases/latest/download/Face-ID-Unlock.zip). Run after scripts/build-app.sh, on a Mac whose keychain
# holds a notarytool profile for the signing team; FACEID_NOTARY_PROFILE names it.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-$PWD/.build/Face ID Unlock.app}"
profile="${FACEID_NOTARY_PROFILE:?set FACEID_NOTARY_PROFILE to your notarytool keychain profile}"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ditto -c -k --keepParent "$app" "$work/submit.zip"
status="$(xcrun notarytool submit "$work/submit.zip" --keychain-profile "$profile" --wait --output-format json |
    plutil -extract status raw -)"
if [[ "$status" != "Accepted" ]]; then
    echo "Notarization finished with status: $status. See: xcrun notarytool log <id> --keychain-profile $profile" >&2
    exit 1
fi
xcrun stapler staple "$app"
spctl --assess --type exec "$app"

zip="$PWD/.build/Face-ID-Unlock-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
cp "$zip" "$PWD/.build/Face-ID-Unlock.zip"
printf '%s\n' "$zip" "$PWD/.build/Face-ID-Unlock.zip"
