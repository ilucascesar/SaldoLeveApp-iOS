#!/bin/bash
set -euo pipefail
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$IOS_ROOT"
mkdir -p build/previews
testStatus=0
testSelection=(-only-testing:SaldoLeveUITests)
if [ -n "${UI_TEST_FILTER:-}" ] && [ "$UI_TEST_FILTER" != all ]; then
  testSelection=()
  for TEST in $UI_TEST_FILTER; do
    [[ "$TEST" =~ ^test[A-Za-z0-9]+$ ]] || { echo 'Invalid UI test name'; exit 1; }
    testSelection+=("-only-testing:SaldoLeveUITests/InteractionTests/$TEST")
  done
fi
simctl() {
  echo "Simulator command: $*" >&2
  python3 - "$@" <<'PY'
import os, subprocess, sys
try:
    result = subprocess.run(['xcrun', 'simctl', *sys.argv[1:]], timeout=int(os.environ.get('SL_SIMCTL_TIMEOUT', '180')))
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit('Simulator command timed out: ' + ' '.join(sys.argv[1:]))
PY
}
xcodebuild -project SaldoLeve.xcodeproj -scheme SaldoLeve -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Simulator ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build > build/simulator.log 2>&1 || { grep -n -A 8 -B 3 -E 'error:|unable to type-check' build/simulator.log || true; tail -n 30 build/simulator.log; exit 1; }
# Select a device/runtime pair already installed on this runner. New runtimes
# can exclude older device types, so choosing each independently can fail.
PROFILE=$(simctl list devices available -j | python3 -c '
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
DEVICE=$(simctl create SaldoLeve-Preview "$DEVICE_TYPE" "$RUNTIME")
trap 'SL_SIMCTL_TIMEOUT=20 simctl shutdown "$DEVICE" >/dev/null 2>&1 || true; SL_SIMCTL_TIMEOUT=20 simctl delete "$DEVICE" >/dev/null 2>&1 || true' EXIT
simctl boot "$DEVICE"
SL_SIMCTL_TIMEOUT=240 simctl bootstatus "$DEVICE" -b
if [ -z "${UI_TEST_FILTER:-}" ] || [ "$UI_TEST_FILTER" = all ]; then
SL_SIMCTL_TIMEOUT=20 simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100 || echo 'Skipping cosmetic status bar override.'
simctl install "$DEVICE" build/Simulator/Build/Products/Debug-iphonesimulator/SaldoLeve.app
for SCREEN in ${PREVIEW_SCREENS:-list widgets focus}; do
  simctl launch --terminate-running-process "$DEVICE" br.com.ilucascesar.saldoleve --ui-preview "--preview-$SCREEN"
  sleep 3
  simctl io "$DEVICE" screenshot "build/previews/$SCREEN.png"
done

# Widget links must reach the native screen through the scene lifecycle.
simctl launch --terminate-running-process "$DEVICE" br.com.ilucascesar.saldoleve --ui-preview
sleep 3
simctl openurl "$DEVICE" 'saldoleve://focus'
sleep 2
simctl io "$DEVICE" screenshot 'build/previews/widget-open-focus.png'
fi

xcodebuild -project SaldoLeve.xcodeproj -scheme SaldoLeve -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build/Simulator \
  -parallel-testing-enabled NO "${testSelection[@]}" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath build/Interactions.xcresult ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test 2>&1 | tee build/interactions.log || { testStatus=$?; tail -n 150 build/interactions.log; }
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
