# Halo Mobile — Android

| Module | What |
|---|---|
| `haloshare/` | Pure Kotlin/JVM: the HaloShare (LocalSend v2) peer — server, client, discovery. **No Android dependency**, so its 58 tests run on the JVM in seconds. |
| `app/` | The Compose app (Share / Inbox / Settings) over `:haloshare`. |

Contract: [`docs/HALOSHARE_PROTOCOL.md`](../docs/HALOSHARE_PROTOCOL.md) · Requirements: [`docs/specs/F-049-F-050-mobile-requirements.md`](../docs/specs/F-049-F-050-mobile-requirements.md)

```bash
cd android
./gradlew :haloshare:test                  # 58 tests (loopback, raw sockets, curl, stall/cancel, discovery)
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

## Limits worth knowing

- **Receives only while the app is visible.** A foreground service for background receive (MR-OS-2) is not built.
- **No multicast yet** (MR-DI-4): discovery is an HTTP /24 scan plus manual address.
- **Plain HTTP**, cleartext allowed app-wide (`network_security_config.xml`) — requirements MD1, awaiting the owner's decision.
- **Compose is pinned** to the BOM that matches AGP 8.13 / API 36. Move AGP, compileSdk and Compose together.
- Not built: Sharesheet target. Not verified: the system file picker, a physical device, the official LocalSend app.
