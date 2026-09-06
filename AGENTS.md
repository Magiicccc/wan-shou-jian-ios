# iPhone App

- This directory is an independent, original iOS source package for public source hosting.
- Keep official artwork, private device logs, personal records, credentials, and generated build products outside source control.
- Use SwiftUI and CoreBluetooth. Keep wire encoding independent from platform transport.
- Use Chinese interface copy and preserve the black/silver design direction.
- Every physical write follows an explicit user connection and action; preview launches must avoid Bluetooth and microphone permission requests.
- Keep device-response structure checks, cryptographic authenticity, and observed physical light behavior distinct.
- Run XCTest and simulator UI checks in the macOS CI before delivering an IPA.
