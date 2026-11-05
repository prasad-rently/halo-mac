# Halo Mobile — iOS

| Path | What |
|---|---|
| `HaloShareKit/` | SwiftPM package: the HaloShare (LocalSend v2) peer — server, client, discovery — plus `halosharecli`; and `HaloShareStaging`, the Share Extension's network-free half. |
| `HaloMobile/` | The SwiftUI app (Share / Inbox / Settings), the `HaloShareExtension` share-sheet target and `HaloMobileTests`. Generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) — after a merge, re-run `xcodegen generate` instead of hand-merging the `.xcodeproj`. |

Contract: [`docs/HALOSHARE_PROTOCOL.md`](../docs/HALOSHARE_PROTOCOL.md) · Requirements: [`docs/specs/F-049-F-050-mobile-requirements.md`](../docs/specs/F-049-F-050-mobile-requirements.md)

## Test the library

```bash
cd ios/HaloShareKit && swift test          # 77 Kit tests + 27 staging tests — loopback, raw sockets, curl, discovery, permission/peer/background policy
swift build && .build/debug/halosharecli --help
```

## Build the app (simulator)

```bash
cd ios/HaloMobile
xcodegen generate                           # only needed after editing project.yml
xcodebuild -project HaloMobile.xcodeproj -scheme HaloMobile \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

App Group (`group.com.halo.mobile`) note: an **unsigned** build (`CODE_SIGNING_ALLOWED=NO`) compiles and runs, but carries no entitlements, so the Share Extension has nowhere to hand items over — Settings shows "Share from other apps: Unavailable". To exercise the extension in the Simulator build ad-hoc signed:
`… CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build`.

App-level tests (hosted in the Simulator): `xcodebuild test -scheme HaloMobile -destination 'platform=iOS Simulator,name=iPhone Air' CODE_SIGNING_ALLOWED=NO`.

(Xcode 27's minimum simulator deployment target is iOS 15; the app targets 16.)

## Drive the app against a Mac peer

The simulator shares the Mac's network, so `127.0.0.1` reaches the app and the app can reach the Mac.

```bash
CLI=ios/HaloShareKit/.build/debug/halosharecli

# Mac → phone: raises the consent sheet in the app; nothing is written until you tap Accept.
$CLI send --to 127.0.0.1:53317 some-file.bin

# Phone → Mac: start a receiver, then in the app: Add by address "127.0.0.1:53318",
# select it, tap "5 MB test" (Debug builds only) — that lines the file up; tap Send in the sheet.
$CLI receive --dir /tmp/rx --port 53318
```

## Cross-implementation test against the real desktop server

```bash
(cd ios/HaloShareKit && swift build)
TEST_RUNNER_HALO_SHARE_CLI=$PWD/ios/HaloShareKit/.build/debug/halosharecli \
  xcodebuild test -project Halo.xcodeproj -scheme HaloTests -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -only-testing:HaloTests/HaloShareInteropTests
```

## Limits worth knowing

- **No multicast on iOS** (restricted entitlement). Discovery is an HTTP /24 scan plus manual address; an iPhone is found by others only through *their* scan.
- **No background receive on iOS.** The server listens while the app is active and stops when it isn't.
- **Plain HTTP**, matching what Halo desktop serves (requirements MD1) — a stated trade-off awaiting the owner's decision.
- **Receiving works while Halo is open.** Leaving the app mid-transfer asks iOS for a short grace period (`beginTask`); if it runs out, one generic local notification says to reopen Halo. Nothing resumes — a transfer interrupted this way is sent again from the start.
- **Share Extension** (Photos/Files/Safari/…): copies items into the App Group, never touches the network, never sends. The app picks the batch up on foreground, opens the send sheet, and sends only after a device is chosen and Send is tapped. Caps: 25 items, 2 GiB per item, 4 GiB per batch, 1 MiB text; batches expire after 24 h.
- **Local Network permission** is probed with an `NWBrowser` on `_halosharecheck._tcp` (listed in `NSBonjourServices`); denial shows a card with an Open-Settings button. The probe browses for nothing real.
- Not yet: physical-device and official-LocalSend testing; the extension has only been driven from Simulator Photos (not third-party apps); iCloud-placeholder files from the picker are not coordinated/downloaded; the Local-Network *denied* state is unit-tested but cannot be produced in the Simulator.
