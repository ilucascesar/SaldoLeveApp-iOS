#!/bin/bash
set -euo pipefail
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$IOS_ROOT"
mkdir -p build/previews
testStatus=0
xcodebuild -project SaldoLeve.xcodeproj -scheme SaldoLeve -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Simulator ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build > build/simulator.log 2>&1 || { grep -n -A 8 -B 3 -E 'error:|unable to type-check' build/simulator.log || true; tail -n 30 build/simulator.log; exit 1; }
# Select a device/runtime pair already installed on this runner. New runtimes
# can exclude older device types, so choosing each independently can fail.
PROFILE=$(xcrun simctl list devices available -j | python3 -c '
import json,re,sys
profiles=[]
for runtime,devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime: continue
    version=tuple(map(int,re.findall(r"\d+",runtime.split(".iOS-")[1])))
    if version[0]<27: continue
    for device in devices:
        kind=device.get("deviceTypeIdentifier","")
        if ".iPhone-" in kind:
            profiles.append((kind.endswith(".iPhone-17"),version,runtime,kind))
if not profiles: sys.exit("An installed iPhone simulator with iOS 27 or later is required.")
chosen=max(profiles)
print(chosen[2]+"|"+chosen[3])')
RUNTIME="${PROFILE%%|*}"
DEVICE_TYPE="${PROFILE#*|}"
echo "Widget validation simulator: $RUNTIME / $DEVICE_TYPE"
DEVICE=$(xcrun simctl create SaldoLeve-Preview "$DEVICE_TYPE" "$RUNTIME")
trap 'xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true; xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$DEVICE" build/Simulator/Build/Products/Debug-iphonesimulator/SaldoLeve.app
for SCREEN in list drawer editor calendar dashboard expenses notifications menu layout focus widgets columns4 habits birthdays remote search; do
  xcrun simctl launch --terminate-running-process "$DEVICE" br.com.ilucascesar.saldoleve --ui-preview "--preview-$SCREEN"
  sleep 3
  xcrun simctl io "$DEVICE" screenshot "build/previews/$SCREEN.png"
done

# Widget links must reach the native screen through the scene lifecycle.
xcrun simctl launch --terminate-running-process "$DEVICE" br.com.ilucascesar.saldoleve --ui-preview
sleep 3
xcrun simctl openurl "$DEVICE" 'saldoleve://focus'
sleep 2
xcrun simctl io "$DEVICE" screenshot 'build/previews/widget-open-focus.png'

xcodebuild -project SaldoLeve.xcodeproj -scheme SaldoLeve -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build/Simulator \
  -parallel-testing-enabled NO -only-testing:SaldoLeveUITests \
  -resultBundlePath build/Interactions.xcresult CODE_SIGNING_ALLOWED=NO test > build/interactions.log 2>&1 || { testStatus=$?; tail -n 150 build/interactions.log; }
grep -E 'Test Case|Executed |5000 tasks' build/interactions.log || true

# Export screenshot attachments when supported by this Xcode version.
if xcrun xcresulttool export attachments --path build/Interactions.xcresult --output-path build/attachments > build/attachments.log 2>&1; then
  python3 - <<'PY'
from pathlib import Path
import shutil
for index, image in enumerate(Path('build/attachments').rglob('*.png')):
    shutil.copyfile(image, Path('build/previews') / ('interaction-' + str(index) + '.png'))
PY
fi
exit "$testStatus"
