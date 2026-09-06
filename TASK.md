# iOS First Build

## Goal
Create a sideloadable iPhone app for manual connection, solid color, brightness, and light-off testing on the owner's original lightstick.

## Context
The Windows workspace contains independently reconstructed TypeScript protocol vectors and a physically confirmed green-light transaction. Reuse the earlier reader project's macOS CI packaging approach while keeping its project unchanged.

## Constraints
The user approved a public original-source repository on 2026-09-06. Publish this directory only. Official artwork and private observations remain local. iOS 17 is the initial deployment target. Background music analysis and fox animation are later milestones. The initial app releases its BLE session when backgrounded.

## Verification
XCTest covers byte encoding, CRC32, brightness conversion, queues, and session cancellation. Simulator UI runs with --preview and uses zero physical Bluetooth activity. An unsigned device IPA is built separately and installed by the owner with Sideloadly. Physical color and brightness remain user-confirmed checks.

## Outputs
Original Swift sources, XcodeGen configuration, cloud build workflow, test results, simulator screenshots, and WanShouJian-unsigned.ipa. Record the actual CI status and artifact hash after the build.
