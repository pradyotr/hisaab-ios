#!/usr/bin/env bash
# Builds build/Hisaab.ipa. Runs on macOS only (GitHub Actions runner). Needs Xcode + XcodeGen.
#
# The .ipa is ad-hoc signed ("-"), which is NOT installable as-is. Its only purpose is to embed the
# entitlements (App Group) so Sideloadly / AltStore can read them and re-sign with your Apple ID.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
xcodegen generate

xcodebuild \
  -project Hisaab.xcodeproj \
  -scheme Hisaab \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee build/xcodebuild.log | grep -E "error:|warning: .*Hisaab|BUILD (SUCCEEDED|FAILED)" || true

# grep/tee hide xcodebuild's exit code, so check the result explicitly.
APP="build/DerivedData/Build/Products/Release-iphoneos/Hisaab.app"
APPEX="$APP/PlugIns/HisaabWidget.appex"
if [ ! -d "$APP" ] || ! grep -q "BUILD SUCCEEDED" build/xcodebuild.log; then
  echo "Build failed. Full log: build/xcodebuild.log"
  exit 1
fi
if [ ! -d "$APPEX" ]; then
  echo "Widget extension missing from $APP/PlugIns"
  exit 1
fi

# Sign the inner bundle first, then the outer one.
codesign --force --sign - --entitlements Widget/HisaabWidget.entitlements "$APPEX"
codesign --force --sign - --entitlements App/Hisaab.entitlements "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q application-groups \
  || { echo "App Group entitlement not embedded"; exit 1; }

rm -rf build/Payload build/Hisaab.ipa
mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && zip -qry Hisaab.ipa Payload)
echo "Built build/Hisaab.ipa ($(du -h build/Hisaab.ipa | cut -f1))"
