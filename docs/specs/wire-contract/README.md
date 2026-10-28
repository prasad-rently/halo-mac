# Wire contract fixture (H-20)

`phone-nodes.v1.json` — every node kind the Android phone writes to the user's Realtime Database
(`devices`, SIM `lines`, SMS `messages`, `clipboard` item), captured from the real Kotlin writers.

* Swift (`HaloTests`): decodes every `node` the way the desktop does and must produce `expect`.
* Kotlin (`android/halocloud/.../WireContractTest.kt`): re-runs the real writers over the fixture's scenario and
  requires every `node` to match (field names, value types, and the plaintext behind each `*Enc` field), and the
  fixture to open under its documented key.
* Ciphertext is randomly nonced: never compare `*Enc` bytes.
* **Additive fields:** since H-21b a line node also carries `lineVersion` and `updatedAt` (the phone bumps them only
  when the label / carrier / own number change). The Kotlin test allows exactly those two extras on `lines` and
  asserts them separately; fold them into this file once both sides have merged (regenerate in BOTH languages in
  the same change).
