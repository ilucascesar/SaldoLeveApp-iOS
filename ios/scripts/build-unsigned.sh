#!/bin/bash
# Run on macOS with Xcode. No signing account, certificate or provisioning profile.
set -euo pipefail
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$IOS_ROOT/build"
cd "$IOS_ROOT"

xcodebuild -version
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
if [ "${SDK_VERSION%%.*}" -lt 27 ]; then
  echo 'The extra-large portrait widget requires Xcode 27 and the iOS 27 SDK or later.'
  exit 1
fi
plutil -lint SaldoLeve/Info.plist SaldoLeve/Settings.bundle/Root.plist SaldoLeveWidgets/Info.plist SaldoLeve/PrivacyInfo.xcprivacy SaldoLeve.xcodeproj/project.pbxproj
mkdir -p "$BUILD_ROOT"
swiftc SaldoLeve/SiteAddress.swift SaldoLeve/NativeNotificationPreferences.swift SaldoLeve/NativeLayoutPreferences.swift SaldoLeve/NativeModels.swift SaldoLeve/NativeTaskMerge.swift SaldoLeve/NativeTaskIndex.swift SaldoLeve/NativeFinanceModels.swift SaldoLeve/NativePlatformModels.swift SaldoLeve/NativeInstallmentDraft.swift SaldoLeveWidgets/WidgetModels.swift Tests/main.swift -o "$BUILD_ROOT/address-tests"
"$BUILD_ROOT/address-tests"
swiftc -parse-as-library SaldoLeve/NativeNotificationPreferences.swift SaldoLeve/NativeModels.swift SaldoLeve/NativeTaskMerge.swift SaldoLeve/NativeTaskIndex.swift Tests/sync.swift -o "$BUILD_ROOT/sync-tests"
"$BUILD_ROOT/sync-tests"
swiftc -O SaldoLeve/NativeNotificationPreferences.swift SaldoLeve/NativeModels.swift SaldoLeve/NativeTaskMerge.swift SaldoLeve/NativeTaskIndex.swift Tests/performance.swift -o "$BUILD_ROOT/performance-tests"
"$BUILD_ROOT/performance-tests"

# generic/platform=iOS + iphoneos + arm64 is essential. Simulator binaries cannot
# be installed by AltStore. Build directly; -exportArchive would demand signing.
xcodebuild \
  -project SaldoLeve.xcodeproj \
  -scheme SaldoLeve \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  build

APP="$BUILD_ROOT/DerivedData/Build/Products/Release-iphoneos/SaldoLeve.app"
test -x "$APP/SaldoLeve"
test -f "$APP/config.json"
test -f "$APP/PrivacyInfo.xcprivacy"
test -f "$APP/Settings.bundle/Root.plist"
test -x "$APP/PlugIns/SaldoLeveWidgets.appex/SaldoLeveWidgets"
test -f "$APP/PlugIns/SaldoLeveWidgets.appex/config.json"
/usr/bin/lipo "$APP/PlugIns/SaldoLeveWidgets.appex/SaldoLeveWidgets" -verify_arch arm64
if test -f "$APP/NativeBridge.js"; then echo 'Unexpected legacy WebView bridge in native app'; exit 1; fi
/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$APP/Info.plist" | /usr/bin/grep -qx 'iPhoneOS'
/usr/bin/lipo "$APP/SaldoLeve" -verify_arch arm64

STAGE="$(mktemp -d "$BUILD_ROOT/ipa.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/SaldoLeve.app"
(cd "$STAGE" && /usr/bin/zip -qry "$STAGE/SaldoLeve-unsigned.ipa" Payload)
/usr/bin/unzip -t "$STAGE/SaldoLeve-unsigned.ipa"
mv -f "$STAGE/SaldoLeve-unsigned.ipa" "$BUILD_ROOT/SaldoLeve-unsigned.ipa"
echo "IPA para o AltStore: $BUILD_ROOT/SaldoLeve-unsigned.ipa"
