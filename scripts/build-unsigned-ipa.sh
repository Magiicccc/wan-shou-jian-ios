#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
DEVICE_MAC_SHA256="${LIGHTSTICK_MAC_SHA256:-}"
if [[ -n "$DEVICE_MAC_SHA256" && ! "$DEVICE_MAC_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  printf '%s\n' 'LIGHTSTICK_MAC_SHA256 must contain exactly 64 hexadecimal characters.' >&2
  exit 2
fi
swift scripts/make-icon.swift
xcodegen generate
xcodebuild -project WanShouJian.xcodeproj -scheme WanShouJian \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" "LIGHTSTICK_MAC_SHA256=$DEVICE_MAC_SHA256" build
APP_PATH="$ROOT_DIR/build/device/Build/Products/Debug-iphoneos/WanShouJian.app"
test -f "$APP_PATH/WanShouJian"
test -f "$APP_PATH/Assets.car"
mkdir -p build
PACKAGE_DIR="$(mktemp -d "$ROOT_DIR/build/package.XXXXXX")"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
mkdir "$PACKAGE_DIR/Payload"
ditto "$APP_PATH" "$PACKAGE_DIR/Payload/WanShouJian.app"
rm -f "$ROOT_DIR/build/WanShouJian-unsigned.ipa"
cd "$PACKAGE_DIR"
/usr/bin/zip -qry "$ROOT_DIR/build/WanShouJian-unsigned.ipa" Payload
cd "$ROOT_DIR"
shasum -a 256 build/WanShouJian-unsigned.ipa > build/sha256.txt
