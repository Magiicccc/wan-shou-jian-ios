#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
python3 scripts/test_select_simulator.py
python3 scripts/test_configure_ipa.py
swift scripts/make-icon.swift
xcodegen generate
SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 scripts/select-simulator.py)"
test -n "$SIMULATOR_ID"
mkdir -p build
if [[ -e build/Tests.xcresult ]]; then
  mv build/Tests.xcresult "build/Tests-$(date +%s).xcresult"
fi
TEST_STATUS=0
xcodebuild -project WanShouJian.xcodeproj -scheme WanShouJian \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/tests -resultBundlePath build/Tests.xcresult \
  CODE_SIGNING_ALLOWED=NO test || TEST_STATUS=$?
if [[ -d build/Tests.xcresult ]]; then
  xcrun xcresulttool export attachments --path build/Tests.xcresult --output-path build/test-attachments || printf '%s\n' 'Attachment export unavailable; the full result bundle is retained.'
fi
if [[ "$TEST_STATUS" -ne 0 ]]; then
  exit "$TEST_STATUS"
fi
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl status_bar "$SIMULATOR_ID" override --time 9:41 --batteryState charged --batteryLevel 100
xcrun simctl install "$SIMULATOR_ID" build/tests/Build/Products/Debug-iphonesimulator/WanShouJian.app
xcrun simctl launch "$SIMULATOR_ID" com.magiicccc.wanshoujian --preview
sleep 3
xcrun simctl io "$SIMULATOR_ID" screenshot build/iphone-preview.png
xcrun simctl terminate "$SIMULATOR_ID" com.magiicccc.wanshoujian
