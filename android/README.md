# Halo Mobile — Android

| Module | What |
|---|---|
| `haloshare/` | Pure Kotlin/JVM: the HaloShare (LocalSend v2) peer — server, client, discovery. **No Android dependency**, so its 58 tests run on the JVM in seconds. |
| `halocloud/` | Pure Kotlin/JVM: the cloud contract — crypto (byte-parity with the Mac), pairing payload, a REST Realtime Database client (auth, refresh, streaming), the **SMS sync engine** and the **clipboard sync engine**. No Android dependency, so all of it is unit-tested on the JVM. |
| `app/` | The Compose app (Share / SMS / Clipboard / Files / Settings) over `:haloshare` and `:halocloud`. Supplies what only Android can: the SMS provider, SIM list, WorkManager, the accessibility service, the Keystore. |
| `tools/` | Development aids for driving the cloud features on an emulator with no Firebase project (below). Not shipped. |

Contract: [`docs/HALOSHARE_PROTOCOL.md`](../docs/HALOSHARE_PROTOCOL.md) · Requirements: [`docs/specs/F-049-F-050-mobile-requirements.md`](../docs/specs/F-049-F-050-mobile-requirements.md)

```bash
cd android
./gradlew :haloshare:test                  # 58 tests (loopback, raw sockets, curl, stall/cancel, discovery)
./gradlew :halocloud:test                  # crypto parity vectors + RTDB client (real HTTP + SSE vs a loopback server) + SMS + clipboard engines
./gradlew :app:assembleDebug               # app/build/outputs/apk/debug/app-debug.apk

# Cross-implementation (Kotlin ⇄ Swift): build the Swift CLI first.
(cd ../ios/HaloShareKit && swift build)
HALO_SHARE_CLI=$PWD/../ios/HaloShareKit/.build/debug/halosharecli ./gradlew :haloshare:test
```

Needs JDK 17 and `ANDROID_HOME`. Gradle 8.14.4, AGP 8.13.2, Kotlin 2.4.20.

## Drive the app against a Mac peer (emulator)

```bash
emulator -avd <name> -no-window &          # use `emulator -list-avds` for the name
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n app.halo.mobile/.MainActivity

# Mac → phone: forward the emulator's port, send from the Swift CLI, tap Accept.
adb forward tcp:54317 tcp:53317
../ios/HaloShareKit/.build/debug/halosharecli send --to 127.0.0.1:54317 some-file.bin
adb shell ls /sdcard/Android/data/app.halo.mobile/files/Received/

# Phone → Mac: run a receiver; in the app add "10.0.2.2:53318" (the emulator's name for the host),
# select it and tap "Send 5 MB test" (debug builds).
../ios/HaloShareKit/.build/debug/halosharecli receive --dir /tmp/rx --port 53318
```

## Cloud features: SMS + clipboard (F-044 / F-045 / F-049)

1. On the Mac: **Messages → Connect Firebase** (your own project), then **Cloud settings → Pair a phone → Show pairing code**.
2. On the phone: **SMS** or **Clipboard** tab → scan the QR or paste the code → type the encryption passphrase.
   The passphrase is not stored; the key derived from it is kept sealed by the Android Keystore.
3. **SMS**: allow SMS access, switch sync on. First sync covers 90 days; new messages follow within seconds
   (broadcast → 1.2 s delay → WorkManager), with a 15-minute safety net. Per-SIM toggles, sender allow/deny list,
   delete-mirroring.
4. **Clipboard**: switch sync on. *Send clipboard now* and the share-sheet target *Send to Mac (Halo)* work on every
   Android version. Fully automatic capture needs the accessibility service (Settings → Accessibility → Halo).

### Driving it on an emulator without Firebase

```bash
python3 tools/fake-firebase.py 9199 &                    # stands in for Google's auth + the Realtime Database
CODE=$(node tools/cloud-peek.mjs pair 9199 "Correct-Horse-Battery-Staple-9")
adb shell am start -n app.halo.mobile/.MainActivity --es pairingCode "$CODE"    # debug builds only
# enter the passphrase in the app, grant SMS, switch sync on, then:
adb emu sms send VM-HDFCBK "Your OTP is 482913"          # a live message
node tools/cloud-peek.mjs dump 9199 "Correct-Horse-Battery-Staple-9"           # decrypts what the phone uploaded
node tools/cloud-peek.mjs clip 9199 "Correct-Horse-Battery-Staple-9" "from the mac"
```

`cloud-peek.mjs` implements `docs/specs/crypto-parity.md` with Node's own crypto, so a successful decrypt is a third
implementation agreeing with the Kotlin one. A debug build accepts a database at `http://10.0.2.2:<port>` and sends
its auth calls there; a release build refuses anything that is not https and only ever sends credentials to Google.

## Limits worth knowing

- **Cloud features have not run against a real Firebase project or a physical phone** — only the stand-in above and an
  emulator. The wire format is the desktop's, read from its source, but the live round-trip with the shipped Mac app is
  still a manual check (`docs/MANUAL_TEST_PLAN.md`).
- **Automatic clipboard capture is unverified.** The accessibility service binds and runs on the emulator; whether a given
  phone's OEM build lets it read the clipboard in the background (Android 10+) can only be learned on that phone.
- **Remote clipboard items arrive only while Halo's process is alive** (the accessibility service keeps it so; otherwise
  open the app). There is no foreground service yet.
- **Delete-mirroring is tested on the JVM, not on a device** — a shell cannot delete from the SMS provider on a Play-Store emulator image.
- Not built: expenditure parsing on the phone (F-048 mobile), SMS notifications on the phone, iOS cloud features.

- **Receives only while the app is visible.** A foreground service for background receive (MR-OS-2) is not built.
- **No multicast yet** (MR-DI-4): discovery is an HTTP /24 scan plus manual address.
- **Plain HTTP**, cleartext allowed app-wide (`network_security_config.xml`) — requirements MD1, awaiting the owner's decision.
- **Compose is pinned** to the BOM that matches AGP 8.13 / API 36. Move AGP, compileSdk and Compose together.
- Not built: Sharesheet target. Not verified: the system file picker, a physical device, the official LocalSend app.
