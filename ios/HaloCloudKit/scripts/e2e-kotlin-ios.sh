#!/usr/bin/env bash
# HaloCloudKit <-> real Kotlin engines, end to end, through the loopback stand-in (NOT real Firebase).
#   1. Kotlin SmsSyncEngine + ClipboardSyncEngine publish   -> Swift package reads + decrypts
#   2. Swift package publishes a clipboard item              -> Kotlin ClipboardSyncEngine.observe() decodes it
# Needs: python3, JDK 17, the Gradle offline cache, Xcode's swift (/usr/bin/swift).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
port="${PORT:-19311}"
export HALO_E2E_PORT="$port"
export HALO_E2E_PASSPHRASE="e2e interop passphrase 1"
export HALO_E2E_SALT_B64="$(printf '\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10' | base64)"
export HALO_E2E_ITERATIONS=100000
export HALO_E2E_EXPECT_FILE="$(mktemp)"
kt="$repo/android/halocloud/src/test/kotlin/app/halo/cloud/IosInteropE2E.kt"

python3 "$repo/android/tools/fake-firebase.py" "$port" >/dev/null 2>&1 & srv=$!
cleanup() { kill "$srv" 2>/dev/null || true; rm -f "$kt" "$HALO_E2E_EXPECT_FILE"; }
trap cleanup EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$port/_dump" >/dev/null && break; sleep 0.1; done

cp "$here/kotlin/IosInteropE2E.kt" "$kt"
gradle() { (cd "$repo/android" && ./gradlew :halocloud:test --offline --rerun-tasks --tests 'app.halo.cloud.IosInteropE2E' -q); }

echo "== 1. Kotlin writes (real SmsSyncEngine / ClipboardSyncEngine) =="
HALO_E2E_MODE=publish gradle
echo "== 1b. Swift reads + decrypts =="
(cd "$here/.." && HALO_E2E_MODE=read /usr/bin/swift test --filter InteropE2ETests/testSwiftReadsWhatTheKotlinEnginesWrote)
echo "== 2. Swift writes =="
(cd "$here/.." && HALO_E2E_MODE=write /usr/bin/swift test --filter InteropE2ETests/testSwiftPublishesAClipboardItemForKotlin)
echo "== 2b. Kotlin ClipboardSyncEngine decodes the iOS item =="
HALO_E2E_MODE=verify gradle
echo "E2E OK"
