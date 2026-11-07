#!/usr/bin/env bash
# Seeds the loopback stand-in for a Simulator walkthrough: the REAL Kotlin engines publish 5 SMS (2 SIM lines)
# and a clipboard item, and a pairing code for the stand-in is printed. NOT real Firebase.
#   ./scripts/demo-standin.sh [port]       -> leaves the stand-in running; prints the pairing code; Ctrl-C stops it
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/../../.." && pwd)"
port="${1:-19400}"
export HALO_E2E_PORT="$port" HALO_E2E_PASSPHRASE="demo passphrase 123" HALO_E2E_ITERATIONS=100000 HALO_E2E_DEMO=1 HALO_E2E_MODE=publish
export HALO_E2E_SALT_B64="$(printf '\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10' | base64)"
python3 "$repo/android/tools/fake-firebase.py" "$port" >/dev/null 2>&1 & srv=$!
kt="$repo/android/halocloud/src/test/kotlin/app/halo/cloud/IosInteropE2E.kt"
trap 'kill $srv 2>/dev/null; rm -f "$kt"' EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$port/_dump" >/dev/null && break; sleep 0.1; done
cp "$here/kotlin/IosInteropE2E.kt" "$kt"
(cd "$repo/android" && ./gradlew :halocloud:test --offline --rerun-tasks --tests 'app.halo.cloud.IosInteropE2E' -q)
python3 - "$port" "$HALO_E2E_SALT_B64" <<'PY'
import sys, json, base64, hashlib
port, salt = sys.argv[1], sys.argv[2]
cfg = dict(apiKey="any", projectID="p", googleAppID="a", gcmSenderID="g", databaseURL=f"http://127.0.0.1:{port}")
auth = dict(email="me@halo.test", password="halo-test-password")
fields = [cfg["apiKey"], cfg["projectID"], cfg["googleAppID"], cfg["gcmSenderID"], cfg["databaseURL"], "", auth["email"], auth["password"], salt, "2", "100000"]
chk = hashlib.sha256("|".join(fields).encode()).hexdigest()
p = dict(firebaseConfig=cfg, auth=auth, saltBase64=salt, schema=2, iterations=100000, checksum=chk)
code = base64.b64encode(json.dumps(p).encode()).decode()
open("/tmp/halo-demo-pairing-code.txt", "w").write(code)
print("stand-in on 127.0.0.1:%s  passphrase: demo passphrase 123" % port)
print("pairing code written to /tmp/halo-demo-pairing-code.txt")
PY
echo "running; Ctrl-C to stop"; wait $srv
