# Wire contract fixture (H-20)

`phone-nodes.v1.json` — every node kind the Android phone writes to the user's Realtime Database
(`devices`, SIM `lines`, SMS `messages`, `clipboard` item), **produced by the Kotlin engines**
(`android/halocloud/src/test/kotlin/app/halo/cloud/WireContractTest.kt`).

* Kotlin: the test runs the real engines and requires their output to equal this file (field names, value types,
  and the plaintext behind every `*Enc` field).
* Swift (desktop, `HaloTests`): decode this file with the production readers (`SMSSyncClient`, `ClipboardSyncEnvelope`,
  `CryptoService`) using the `crypto` block (passphrase / salt / iterations) to open the `*Enc` fields; the expected
  plaintexts are in `decrypted`. Ciphertext is randomly nonced, so never compare it byte for byte.
* Line nodes carry `lineVersion` + `updatedAt` (H-21): the desktop re-reads a line when either changes.

Regenerate only for an intended contract change, and update the Swift side in the same release:
`HALO_WIRE_CONTRACT_WRITE=1 ./gradlew :halocloud:test --tests '*WireContractTest*'` (from `android/`).
