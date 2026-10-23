# Halo Mobile — iOS

| Path | What |
|---|---|
| `HaloShareKit/` | SwiftPM package: the HaloShare (LocalSend v2) peer — server, client, discovery — plus `halosharecli`. 56 tests. |
| `HaloMobile/` | The SwiftUI app (Share / Inbox / Settings). Generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). |

Contract: [`docs/HALOSHARE_PROTOCOL.md`](../docs/HALOSHARE_PROTOCOL.md) · Requirements: [`docs/specs/F-049-F-050-mobile-requirements.md`](../docs/specs/F-049-F-050-mobile-requirements.md)

## Test the library

```bash
cd ios/HaloShareKit && swift test          # 56 tests — loopback, raw sockets, curl, discovery
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

(Xcode 27's minimum simulator deployment target is iOS 15; the app targets 16.)

## Drive the app against a Mac peer

The simulator shares the Mac's network, so `127.0.0.1` reaches the app and the app can reach the Mac.

```bash
CLI=ios/HaloShareKit/.build/debug/halosharecli

# Mac → phone: raises the consent sheet in the app; nothing is written until you tap Accept.
$CLI send --to 127.0.0.1:53317 some-file.bin

# Phone → Mac: start a receiver, then in the app: Add by address "127.0.0.1:53318",
# select it, tap "Send 5 MB test" (Debug builds only).
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
- Not yet: Share Extension, the system file-picker flow has not been driven in the simulator (the Debug "send test file" button exercises the same send path), and no physical-device or official-LocalSend testing.
