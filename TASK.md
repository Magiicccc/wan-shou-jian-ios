# iOS Home Rhythm Upgrade

2026-09-09 / 0.3.3: Test user-requested MediaRemote pause on a personally sideloaded iPhone. Dynamically resolve MRMediaRemoteSendCommand and send Pause (1) on explicit rhythm stop / external-stage pause. Preserve lifecycle-only pauses, local accompaniment, audio routing and BLE behavior. Distinguish symbol availability, submission result and physical playback acceptance. Simulator/preview skips native commands. Verify unit/UI checks in macOS CI and package the existing private fox locally. Device acceptance: play NetEase on this iPhone, pause from the app, check actual music and BLE state, then repeat with an A2DP speaker. No automatic remote play or shortcut dependency.

2026-09-09 / 0.3.2: Preserve an explicitly selected BLE connection while opening Settings or a music app. Recover karaoke input after route changes without ending BLE intent. Add an external-music stage for NetEase playback with built-in-mic capture, bounded recovery, monotonic elapsed time, and evidence-scoped practice scoring / AI review. Keep raw audio ephemeral and private fox assets local. Verify policy/lifecycle/scoring tests and simulator UI, build in macOS CI, then package the existing private fox for Sideloadly. Physical acceptance covers sword-first/speaker-second, app switching, microphone permission denial, interruption, and external playback with the owner's phone/speaker.

2026-09-09: Integrate the owner's refined 3D fox in home, immersive and karaoke views. Private mobile USDZ and matching fallback renders are injected locally. Baked appearance uses a marked model hierarchy; legacy resources keep their existing lighting. Keep audio/BLE logic unchanged. Build 0.3.1 (5), run CI, and preserve prior IPA files.

## Goal
Create a sideloadable iPhone app that listens to music played at home, produces smooth colors and breathing, and continues an explicitly started audio/BLE session in the background. Provide a restrained silver/blue fox visualizer, an immersive screen, device management, and settings.

## Context
The Windows workspace contains independently reconstructed TypeScript protocol vectors and a physically confirmed green-light transaction. Reuse the earlier reader project's macOS CI packaging approach while keeping its project unchanged.

## Constraints
The user approved a public original-source repository on 2026-09-06. Publish this directory only. Official artwork, derived private imagery, and private observations remain local. iOS 17 is the initial deployment target. Use audio and bluetooth-central background modes for user-started sessions, explicit stop, bounded reconnect, and interruption recovery. Seat binding, concerts, ticketing, and venue-wide control are outside this home-use scope. Cold audio-service reset requires a new user start.

## Verification
XCTest covers byte encoding, CRC32, brightness conversion, bounded queues, audio features, silence and transient cases, deterministic color/breathing, lifecycle cancellation, settings, and reconnect intent. Simulator UI runs with --preview and uses synthetic audio with zero microphone or physical Bluetooth activity. An unsigned device IPA is built separately, configured locally, and installed by the owner with Sideloadly. Lock-screen operation, actual audio routes, physical colors, and 30/60-minute stability remain device verification steps.

## Outputs
Original Swift sources, XcodeGen configuration, cloud build workflow, test results, simulator screenshots, and WanShouJian-unsigned.ipa. Public packages use an abstract music visualization; private fox PNGs are added with configure-ipa.py --visual-assets on the owner's machine before signing. Record actual CI results and package hashes separately from physical-device observations.
