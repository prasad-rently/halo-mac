# Wire contract fixture (H-20)

`phone-nodes.v1.json` — every node kind the Android phone writes to the user's Realtime Database
(`devices`, SIM `lines`, SMS `messages`, sent-SMS `sent`, `clipboard` item), captured from the real Kotlin writers.

* Swift (`HaloTests`): decodes every `node` the way the desktop does and must produce `expect`.
* Kotlin (`android/halocloud/.../WireContractTest.kt`): re-runs the real writers over the fixture's scenario and
  requires every `node` to match (field names, value types, and the plaintext behind each `*Enc` field), and the
  fixture to open under its documented key.
* Ciphertext is randomly nonced: never compare `*Enc` bytes.
* **Additive fields:** since H-21b a line node also carries `lineVersion` and `updatedAt` (the phone bumps them only
  when the label / carrier / own number change). The Kotlin test allows exactly those two extras on `lines` and
  asserts them separately; fold them into this file once both sides have merged (regenerate in BOTH languages in
  the same change).
* **Sent messages (`sent`):** the phone's opt-in "Also sync messages I send" writes the user's own outgoing SMS to
  `sms/{uid}/{deviceId}/sent/{smsId}_{dateMs}` — a sibling of `messages`, deliberately not a `type: 2` row inside it. A desktop
  build that predates this observes `messages` only and never looks at `sent`, so an old Mac cannot show (or notify for) the
  user's own text as something they received. The node shape is the message node's with `type` 2 and `addressEnc` = the
  recipient; its `threadKey` equals the one an inbox row from the same contact on the same line gets. Both suites consume the
  `sent` entry (the Kotlin writer produces it; Swift decodes it with `direction == sent`). No Realtime Database rule change:
  `sms/$uid` already grants the owner read/write below it, and the desktop never queries `sent` by `date`.
