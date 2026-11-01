#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A shipping app always contains the local models; it never downloads one at runtime.
for model in SFace MiniFASNet; do
    if [[ ! -d "Resources/$model.mlpackage" ]]; then
        echo "Missing Resources/$model.mlpackage. See README.md for model preparation." >&2
        exit 1
    fi
done
swift build -c release
app="$PWD/.build/Face ID Unlock.app"
staging="$(mktemp -d "$PWD/.build/app-stage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
staged_app="$staging/Face ID Unlock.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp .build/release/FaceIDUnlock "$staged_app/Contents/MacOS/FaceIDUnlock"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp -R Resources/ThirdParty "$staged_app/Contents/Resources/ThirdParty"
# App and menu-bar icons; their sources and generators are in docs/design/icon.
cp Resources/AppIcon.icns Resources/MenuBarIcon.pdf "$staged_app/Contents/Resources/"
for model in SFace MiniFASNet; do
    xcrun coremlcompiler compile "Resources/$model.mlpackage" "$staged_app/Contents/Resources"
    [[ -d "$staged_app/Contents/Resources/$model.mlmodelc" ]]
done
identity="${FACEID_SIGNING_IDENTITY:-Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)}"
codesign --force --options runtime --timestamp --sign "$identity" --entitlements Resources/FaceIDUnlock.entitlements "$staged_app"
codesign --verify --strict "$staged_app"
rm -rf "$app"
mv "$staged_app" "$app"
printf '%s\n' "$app"
