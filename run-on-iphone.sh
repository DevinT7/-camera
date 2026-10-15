#!/bin/bash
# Usage: ./run-on-iphone.sh <device-identifier>   (from: xcrun devicectl list devices)
set -e
DEVICE="${1:?pass the device identifier from: xcrun devicectl list devices}"
cd "$(dirname "$0")"
# xcodebuild wants the hardware UDID, devicectl uses the CoreDevice identifier; map one to the other.
TMP=$(mktemp)
xcrun devicectl list devices --json-output "$TMP" >/dev/null 2>&1
UDID=$(python3 -I - "$TMP" "$DEVICE" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["identifier"] == sys.argv[2] or d["hardwareProperties"].get("udid") == sys.argv[2]:
        print(d["hardwareProperties"]["udid"]); break
PY
)
rm -f "$TMP"
[ -n "$UDID" ] || { echo "Device not found"; exit 1; }
xcodegen generate >/dev/null
xcodebuild -project NotBoringCamera.xcodeproj -scheme NotBoringCamera -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build -allowProvisioningUpdates build
APP=build/Build/Products/Debug-iphoneos/NotBoringCamera.app
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing com.devin.camera.notboring
