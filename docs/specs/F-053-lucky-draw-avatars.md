# F-053 — Lucky Draw Avatars (NFeat-130)

> **Status:** 🔧 **Emoji / photo / monogram avatars are merged in `release/v2.5` (PR #54; not clicked through, 60 fps never measured on screen).** **v2.6 completion (non-art) is built on PR #57 (unmerged; head `c700dfc`, independently reviewed) and hardening on PR #60 (unmerged):** hero travel, hub last winner, storage readout + per-roster clear, CSV avatar column, wheel signposts — **hero flight, name reveal, Reduce-Motion cross-fade and 60 fps have NOT been seen on a screen** (V-8). **Not built:** animated emoji, caricatures (no art; ⛔ ART → v2.7), "give everyone a character". Owner decisions on art source and file deletion recorded 2026-10-27.
> **Extends:** F-051 Lucky Draw Spinner Wheel · **Raised:** 2026-10-27 · **Effort estimate:** ~8–10 d desktop (incl. 1.5 d of spikes)
> **Reserved pbxproj ID block:** `8225`–`8244` (claimed in `CLAUDE.md`)

---

## 0. The request, as received, and how it was read

> *"Add image or avatar to lucky draw participants — character emoji, animated emojis, real photos,
> preloaded caricature etc. — round outline and character phase inside. Try to add it over the spin
> wheel and popups on win, that makes it look much better."*

| Phrase | Reading used here | If wrong |
|---|---|---|
| "round outline and character phase inside" | A **circular avatar with a ring outline, and a character (a face, an emoji, or the person's initials) inside it.** "Phase" is read as "face". | Only §5.1 FR-A6 (monogram fallback) and the ring style in §8 change. |
| "animated emojis" | Emoji that **move** (a looping animation). Apple's emoji are static glyphs — there is no system API for animated emoji — so this needs a **bundled animation pack**. | See §3 D5 and the licensing risk in §12. |
| "preloaded caricature" | A **bundled set of cartoon-face avatars** a user can pick from. It is *not* "turn my photo into a caricature" — that needs an ML model Halo does not have (§12 R3 treats it as an optional spike). | Moves from P2 to a separate feature. |
| "over the spin wheel and popups on win" | The avatar appears **on the wheel's segments**, in the **winner popup**, in the **multi-draw winners strip** and in the **Already-drawn log**. | — |

---

## 1. Summary

Today every entry on the wheel is a coloured wedge and a text label (`DrawEntry` has `label`,
`isExcluded`, `isRetired`, `addedAt` — nothing visual). A draw between twelve colleagues reads as
twelve names; a draw between twelve *faces* reads as an event. F-053 gives each entry an optional
**avatar** — emoji, animated emoji, a bundled caricature, or a real photo — drawn in a circle with a
ring on the wheel and as a large hero in the winner reveal.

Everything the first three kinds need already exists in the app (Unicode emoji rendering, `Canvas`,
`CelebrationOverlay`, `ConicHalo`). The two real costs are **(a)** keeping the wheel at 60 fps with
images on it, and **(b)** the **licence** of whatever animated / caricature art is bundled.

The F-051 rule is untouched and is a ship gate here too: **the winner is chosen before the wheel
moves, and an avatar can never influence selection** (AC-3).

---

## 2. Goals / Non-Goals

**Goals**
- G1. Every entry can have an avatar of one of five kinds (§3 D2); **no avatar is the default** and renders as a derived monogram, so existing rosters look right with zero migration.
- G2. Avatars appear on the **wheel**, the **winner popup**, the **multi-draw sequence**, the **roster list** and the **draw log**.
- G3. Photos are **local-only**, downsampled, and removed when the entry or roster is deleted.
- G4. Bulk workflows: a folder of photos named after the entries, a CSV avatar column, "give everyone a caricature".
- G5. No regression of F-051's 60 fps at 200 entries, Reduced Motion alternative, or fairness guarantees.

**Non-Goals**
- N1. **No photo → caricature conversion** in v1 (needs a model; spike only).
- N2. **No network fetching** of avatars (no Gravatar, no URLs, no contacts import) — a participant's face is third-party personal data and Halo's draw module makes no network calls (F-051: "no network").
- N3. **No avatar syncing** between devices in v1 (the cloud line is a separate product surface).
- N4. **No video avatars**; no live camera capture in v1 (a file/drag import covers it; camera adds a TCC prompt for little gain).
- N5. Avatars do **not** change segment size, order, colour assignment or probability.

---

## 3. Decisions & Assumptions

| # | Decision | Why |
|---|---|---|
| D1 | `DrawEntry.avatar: EntryAvatar?` — **optional, default nil**. nil ⇒ derived **monogram** (initials on the segment's gradient) in the list, popup and strip; **on the wheel it is governed by D7** — *Automatic* keeps today's name-only wedge for an entry with no avatar (see §14, which records the reconciliation built on PR #54). | Existing rosters, the CSV import path and tests keep working unchanged; no stored data for the common case. |
| D2 | Five kinds: **monogram** (derived), **emoji** (any Unicode emoji grapheme, incl. ZWJ sequences), **animated** (bundled pack item), **caricature** (bundled pack item), **photo** (user file, copied in). | Matches the request; each kind has a distinct storage/rendering cost, so they are separate cases rather than one "image" blob. |
| D3 | **Photos are copied in, never referenced by path.** Centre-cropped to a square — on the face when Vision finds one (`VNDetectFaceRectanglesRequest`, on-device) — downsampled to ≤256 px, stored as JPEG (q 0.8) at `Application Support/Halo/luckydraw/avatars/<rosterID>/<entryID>.jpg`. | The original may move, be on a volume that unmounts, or be outside the sandbox; a path in a JSON file is also an injection surface (§6 NFR-S2). |
| D4 | **Wheel shows avatars only up to a threshold** (initial value 40 entries — to be tuned in spike S3). Beyond it the wheel stops drawing avatars (wedges/labels exactly as F-051 draws them today — FR-W6); the **popup still shows the avatar**. | Same degradation philosophy as F-051 §8.13 (labels and the spotlight drop out as the entry count grows). Avatars cost more per segment than text. |
| D5 | **Animated emoji animate in the winner popup (and optionally the segment under the pointer); everywhere else they show a static poster frame.** | One animation playing is cheap; 40 playing at once on a spinning `Canvas` is not. |
| D6 | **Animation format: pre-rendered APNG/GIF frame sequences decoded by ImageIO — no new package dependency** (provisional, spike S1). Lottie is the other candidate. | The project's only third-party dependency is Sentry; `lottie-ios` is a sizeable addition for one feature. ImageIO is system code. Minimum macOS is 13, so animated WebP decode (14+) is not safe to rely on. |
| D7 | Per-roster **Display mode**: *Auto* (avatar where the entry has one, else label), *Avatar + name*, *Avatar only*, *Name only* (today's behaviour). Default *Auto*. | Lets the user opt out per roster, and *Name only* is the F-051 regression baseline. |
| D8 | The **winner popup** reuses `DrawResultOverlay` + `ConicHalo`: avatar in a large ring (gold conic gradient for the winner), the name's per-character reveal unchanged, confetti unchanged. | The animation beats are already tuned (F-051 §8); this adds a hero element, not a second reveal system. |
| D9 | **Art source decided 2026-10-27: commissioned or self-drawn** — the owner supplies about 40 characters and a few animated emoji, so there are no third-party licence terms to inherit. Until the art exists the feature ships with emoji, monogram and photos only (§13 P0). Every pack still carries a `manifest.json` with author and licence, and an in-app Credits entry. | Removes the licence risk (§12 R1) for the bundled art; the pipeline (manifest, catalogue, Credits) is unchanged and would also accept an open-licence pack later. |

---

## 4. User Stories

- **US-1** As a team lead running a raffle, I want each participant's photo on the wheel so the room recognises the winner instantly.
- **US-2** As a teacher, I want a fun cartoon avatar assigned to each pupil without collecting photos.
- **US-3** As someone adding 30 names, I want to drop a folder of `Anna Maria.jpg`-style photos and have them attach automatically.
- **US-4** As a participant, I want my picture to stay on the organiser's Mac only, and disappear when the roster does.
- **US-5** As a user with Reduced Motion on, I want the same information without anything bouncing.
- **US-6** As an existing F-051 user, I want my rosters untouched and the wheel looking the same until I add an avatar.

---

## 5. Functional Requirements

### 5.1 Avatar model & assignment
- **FR-A1** Each entry has at most one avatar of kind *emoji / animated / caricature / photo*; *monogram* is the derived default.
- **FR-A2** **Picker** (from the entry row's avatar button, and double-click on the avatar): tabs *Emoji · Animated · Characters · Photo*. Emoji tab: recents + category grid + a field that accepts a pasted/typed emoji and rejects non-emoji input. Photo tab: Choose file…, drag-and-drop, paste from clipboard.
- **FR-A3** **Remove avatar** returns to the monogram.
- **FR-A4** **Monogram** = first grapheme of up to two words (grapheme-aware, so "Åsa", a CJK name, or an emoji-leading label never splits a character); empty label → "?".
- **FR-A5** **Auto-assign**: *Give everyone a character* picks from the Characters pack deterministically from `entry.id` (stable across launches, no repeats until the pack is exhausted), only filling entries that have no avatar.
- **FR-A6** Photo import accepts JPEG/PNG/HEIC; rejects >50 MB or >100 megapixel inputs *before* decoding (§6 NFR-S3).

### 5.2 Bulk
- **FR-B1** **Import photos from a folder**: files matched to entries by label — case-, diacritic- and whitespace-insensitive, extension ignored. Shows a result sheet: *matched N · unmatched files M · entries without a photo K*; nothing is applied until confirmed.
- **FR-B2** **CSV avatar column**: the existing roster import (`RosterImport`, first column = name) accepts an optional second column holding either an emoji or a filename relative to the CSV. Unknown second-column text is ignored, never an error. **Scope limits:** it applies to **multi-row** CSVs only — `RosterImport.labels(fromCSV:)` deliberately treats a single-row file as a comma-separated name list, so `Anna,😀` on one row stays two names; a relative filename is resolved inside the CSV's own folder and anything that escapes it (`../`, absolute) is ignored; and in a **sandboxed** build a CSV the user picks does not grant access to the files beside it, so filename cells work there only via the folder importer (FR-B1) or when the user grants the folder.

### 5.3 Wheel (`SpinnerWheelView`)
- **FR-W1** With avatars shown (D4/D7), each segment draws a **circular avatar with a ring** at ~72 % of the radius, rotating with the wheel and **kept upright** (the same flip logic F-051 uses so labels are never upside-down).
- **FR-W2** The ring takes the entry's **segment colour**; a 1 px dark inner stroke separates any photo from any ring colour.
- **FR-W3** During fast spin, avatars fade with the same speed curve labels use (`labelAlpha`) — a blur of faces carries no information and costs fill-rate.
- **FR-W4** The **near-miss spotlight** (F-051 §8.7) also lifts the avatar: scale 1.0 → 1.15 and the ring brightens.
- **FR-W5** Static poster frames only for animated avatars on the wheel (D5), except optionally the pointer segment.
- **FR-W6** Above the D4 threshold **avatars are omitted from the wheel**; labels, wedges and the hub follow F-051 unchanged. Note the existing limit is **not** what F-051 §8.13 says: the code drops labels above `SpinnerWheelView.labelLimit = 26` entries, while §8.13 states 120 — a pre-existing spec/code mismatch this feature must not paper over. Consequence to design for: between 27 and the D4 threshold (40) the wheel shows avatars **without** labels, so the avatar (or monogram) is the only identifier on the segment — so AC-4 (the segment under the pointer is the entry on the card) must be checked in that band, where the winner card is the only place the name appears.
- **FR-W7** The hub (centre) may show the *last winner's* avatar between spins (optional; default on).

### 5.4 Winner popup & sequence (`DrawResultOverlay`, `DrawSequenceOverlay`)
- **FR-P1** The popup shows the avatar large (target 144 pt) inside a **gold conic ring** (`ConicHalo`), above the existing name reveal.
- **FR-P2** **Hero transition:** the avatar travels from the winning segment's position to the popup centre while scaling up (matched-geometry style), 450 ms ease-out, before the name's per-character reveal begins. *Reduced Motion:* cross-fade, no travel.
- **FR-P3** Animated avatars **play** here, looping until dismissal; photos get a soft outer glow; emoji get a single scale-pop.
- **FR-P4** **Draw N in a row:** the sequence overlay shows a strip of winner avatars (ring + position number) that fills as each draw completes.
- **FR-P5** **Copy winner** and **CSV export** remain text-only — no image data is ever placed on the pasteboard or in the CSV in v1.

### 5.5 Roster list, log
- **FR-L1** Roster rows, chips and the Already-drawn log show a 24 pt avatar beside the label.
- **FR-L2** Put-back / retire / exclude visuals (dimmed, struck, "Back on the wheel") apply to the avatar too (desaturate).

### 5.6 Reduced Motion & accessibility
- **FR-R1** Reduced Motion: no hero travel, no animated playback (poster frame), no avatar scale on spotlight; the ring still marks the winner.
- **FR-R2** VoiceOver reads the entry label (and "photo" / emoji name where relevant); avatars are decorative otherwise.
- **FR-R3** Monogram text meets the F-051 4.5:1 contrast floor against every segment fill (`SegmentPaletteTests` extended).

---

## 6. Non-Functional Requirements

**Privacy / security**
- **NFR-S1** Photos never leave the Mac: no network call in the avatar path; not in `UserDefaults`; not in the CSV; not in Sentry breadcrumbs or the PDF report.
- **NFR-S2** The stored `fileName` is **untrusted input** (a roster JSON can be hand-edited or arrive from a future share feature). It must be a UUID-shaped name resolved *inside* the avatars directory; any value containing `/`, `..` or not matching the pattern is treated as "no avatar". A test feeds `../../etc/passwd`.
- **NFR-S3** Decoding is bounded: pixel dimensions are read from the header **before** decoding and the import is refused above 100 MP (decompression-bomb guard); ImageIO decodes straight to a thumbnail (`kCGImageSourceThumbnailMaxPixelSize`) so a 60 MP photo is never fully decoded.
- **NFR-S4** Deleting an entry, clearing entries, deleting a roster, or "Clear all photos" removes the files; an orphan sweep at load removes avatar files no entry references. **Owner-approved exception (2026-10-27, was OQ-4):** these are Halo's own copies, so permanent removal is the honest behaviour (trashing 500 avatar files would only litter the user's Trash). It is a `removeItem`, so it must be confined to the avatars directory (path check before every call), commented in source, and added to CLAUDE.md's "File deletion" rule beside `DriveSpeedTester`'s scratch file **at implementation time**.
- **NFR-S5** A participant's photo is third-party personal data: the picker shows a one-line note ("Stored only on this Mac; deleted with the roster").

**Performance & resources**
- **NFR-P1** 60 fps while spinning at the D4 threshold with every segment carrying a photo (measured, not asserted — spike S3 sets the real threshold).
- **NFR-P2** Decode off the main thread (an off-main `AvatarStore` — a class with GCD work as built, §14); `Canvas` receives **pre-resolved** images at the on-screen size (via `Canvas`'s `symbols`), never decodes in the draw closure.
- **NFR-P3** Memory: render-size cache (≤ 96 px, ~37 KB each) with an LRU cap of 64 MB — not 500 × 256 px × RGBA (256 × 256 × 4 B = 256 KB each, **~131 MB** uncapped).
- **NFR-P4** Disk: ≤ ~60 KB per photo, so a 500-entry roster is ≲ 30 MB worst case. Settings shows the total and a *Clear all photos* button.
- **NFR-P5** Opening a roster with 500 entries must not block on image decoding: monogram first, avatars fade in as they load.

**Compatibility**
- **NFR-C1** Older rosters (no `avatar` key) decode unchanged. A **newer file opened by an older build** loses nothing it can't see on read, but the older build will drop avatars when it re-saves — acceptable, noted in release notes.
- **NFR-C2** An unrecognised avatar *kind* in a future file decodes to `nil`, never throws (a thrown error would send the whole roster to the corrupt-file backup — the failure mode `DrawRoster.init(from:)` already guards against).

---

## 7. Architecture & Data Model

```swift
// Halo/Core/LuckyDraw/AvatarModels.swift  (UI-free, unit-tested)
enum EntryAvatar: Codable, Hashable {
    case emoji(String)                    // one grapheme cluster, validated
    case animated(pack: String, item: String)
    case character(pack: String, item: String)
    case photo(fileName: String)          // UUID-shaped, resolved inside the avatars dir
    // Codable: tolerant — unknown kind or invalid payload ⇒ nil at the call site (NFR-C2).
}

struct DrawEntry { …; var avatar: EntryAvatar? }          // optional ⇒ synthesized decode is `decodeIfPresent`
struct DrawRoster { …; var avatarDisplay: AvatarDisplayMode }   // .auto default (decodeIfPresent, like soundEnabled)
enum AvatarDisplayMode: String, Codable { case auto, avatarAndName, avatarOnly, nameOnly }
```

| Component | Role |
|---|---|
| `AvatarStore` (`actor` as first drafted; **built as a stateless class** — §14, CLAUDE.md "stateless generators") | Import → validate → crop (Vision) → downsample → write; resolve `EntryAvatar` → `CGImage` at a requested size; orphan sweep; storage accounting. |
| `AvatarImageCache` | `NSCache`-backed, keyed `(avatarID, pixelSize)`, cost-limited; posts "image ready" so the view fades it in. |
| `AvatarPackCatalog` | Reads bundled `Resources/avatar-packs/<pack>/manifest.json` (name, items, **licence, attribution, source URL**). Same bundle-first pattern as `signatures.json`. |
| `AnimatedAvatar` | Decodes an APNG/GIF via ImageIO into `[CGImage]` + per-frame delays; drives a `TimelineView`. |
| `AvatarView` (SwiftUI) | One view for list/popup/log: ring + content + poster/animated switching + Reduced Motion. |
| `SpinnerWheelView` | Draws avatars through `Canvas` `symbols` (pre-resolved), reusing `labelAlpha`/flip maths. |
| `RosterImport` | Extended with the optional second column; new `AvatarFolderMatcher` (pure, tested). |

`DrawEngine` and `SpinnerAnimator` are **not modified** (AC-3 depends on it).

---

## 8. Visual Specification

- **Ring:** stroke = 6 % of avatar diameter; wheel ring colour = entry's segment fill (existing `SegmentPalette`); winner ring = `ConicHalo` gold → accent gradient; 1 px `haloBackground` inner keyline.
- **Monogram:** initials in the F-051 near-white label colour (`#eef2fb`) on the segment gradient; font = the display face at ~42 % of diameter.
- **Wheel placement:** avatar centre at ~72 % radius; label moves outward (≈ 88 %) when both are shown; *Avatar only* centres the avatar at ~80 %. Diameter = min(arc length × 0.62, 0.22 × wheel radius), clamped to 22–56 pt.
- **Popup:** 144 pt avatar, ring 9 pt, glow radius 24 pt at 35 % accent; entrance = the FR-P2 travel then a 1.0 → 1.06 → 1.0 settle.
- **Dark-only app:** no adaptive colours; the ring and keyline are the only things that touch the background.

---

## 9. Acceptance Criteria (ship gate)

| # | Criterion | How verified |
|---|---|---|
| AC-1 | An existing F-051 roster file (written before this feature) opens identically; with `Name only` the wheel is pixel-equivalent to today's | Decode test on a recorded fixture; offscreen render diff |
| AC-2 | Each avatar kind can be assigned, persisted, reloaded and removed | `AvatarStoreTests`, `EntryAvatarCodableTests` |
| AC-3 | **Avatars never affect the draw**: with a fixed seed, the winner index is identical for the same roster with and without avatars; 100 k-draw χ² unchanged | `DrawFairnessWithAvatarsTests` (mutation-check: make the engine read avatar presence → test goes red) |
| AC-4 | The segment under the pointer shows the avatar of the entry named on the card, for every entry count 1…500 | Extends the F-051 landing-angle test |
| AC-5 | A `fileName` of `../x`, an absolute path, or a non-UUID never resolves to a file outside the avatars directory | `AvatarPathSafetyTests` |
| AC-6 | A 100 MP / 60 MB image is refused without a full decode; a normal 12 MP HEIC imports to ≤ 256 px | `AvatarImportLimitsTests` |
| AC-7 | Deleting an entry / roster / "Clear all photos" removes the files; orphan sweep removes strays | `AvatarStoreTests` |
| AC-8 | Reduced Motion: no travel, no playback, no spotlight scale; ring still shown | Manual + view-model flag test |
| AC-9 | 60 fps spinning at the configured threshold with all-photo segments (Instruments, M-series and an Intel Mac if available) | Manual — recorded in §14 |
| AC-10 | Unknown avatar kind in the file → roster still loads, that entry shows a monogram | `EntryAvatarCodableTests` |
| AC-11 | No network request is made by any avatar code path | Code audit + `grep`-style test over the module |
| AC-12 | Credits screen lists every bundled pack with licence and attribution | Manual; manifest-completeness unit test (no pack without `licence`) |

---

## 10. Test Plan

Unit (UI-free): `EntryAvatarCodableTests`, `MonogramTests` (single word, two words, "Åsa", CJK, emoji-first, empty, whitespace), `EmojiValidationTests` (ZWJ family, flag, keycap, skin tone, rejects "ab" and "🙂🙂"), `AvatarFolderMatcherTests` (diacritics, case, duplicates, extension), `AvatarPathSafetyTests`, `AvatarImportLimitsTests`, `AvatarStoreTests` (round-trip, delete cascade, orphan sweep, storage total), `DrawFairnessWithAvatarsTests`, `PackManifestTests`.
Rendering: offscreen renders of wheel + popup (the F-051 method), compared by eye and by a coarse luminance check; `SegmentPaletteTests` extended to monogram text.
Manual (cannot be asserted): hero transition feel, animated playback, ring contrast over real photos, 500-entry roster open time, Instruments frame-rate trace. Add cases to `MANUAL_TEST_PLAN.md` §20.2 when built.

---

## 11. Mobile Feasibility (governance requirement)

> Full study: [`HALO_MOBILE_ROADMAP.md`](../HALO_MOBILE_ROADMAP.md) §3 row + §9 "Feasibility — Lucky Draw Avatars (from desktop F-053)".

**Verdict: ✅ iOS · ✅ Android → Port, Priority P2 (rides on the F-051 mobile port).** Emoji, monogram, bundled packs and rendering are identical in kind. Photos are *easier* on phones — `PHPickerViewController` and the Android Photo Picker need **no permission**. Face-centred crop: Vision on iOS, ML Kit Face Detection (bundled model) on Android. **Contract to freeze now** so the mobile port reads the same roster files: the `EntryAvatar` JSON shape in §7. Mobile Lucky Draw itself is not built yet (F-051 port is P2), so this is a data-contract task today, not a code task.

---

## 12. Open Questions & Risks

| # | Item | Notes / proposed default |
|---|---|---|
| **R1** | **Art supply** *(re-framed 2026-10-27)*. Licensing is settled by D9 (commissioned / self-drawn). The remaining risk is **schedule**: the feature's headline visuals depend on art that does not exist yet, and its **format** (APNG/GIF frame sequence, ring-safe transparent background, size) must be fixed *before* the artist starts. | Spike S2 becomes an **art brief**: format, canvas size, frame count/rate, safe area inside the ring, naming, `manifest.json` fields, and a 3-item pilot to validate the pipeline. Earlier candidate sources (Noto animated emoji, Fluent Emoji, OpenMoji, DiceBear — all licences *recalled, never verified*) are a fallback only and **must be checked against each repo's LICENSE before any use**. Nothing is bundled until AC-12 is satisfiable. |
| R2 | Animated format (APNG/GIF via ImageIO vs Lottie). GIF is 256-colour, 1-bit alpha; APNG is better but heavier to author. | Spike S1 — render 3 candidate emoji in each, compare file size, fringing on the ring, CPU. Default: APNG. |
| R3 | "Photo → caricature" on device. Possible only via an ML model or Apple's Image Playground (availability by OS version and Apple-Intelligence eligibility **not verified**). | Out of scope for v1. Optional spike S4; if it works it is an *Characters → From my photo* button, still local. |
| R4 | **Wheel fill-rate with images.** Per-segment image draws inside one `Canvas` may drop below 60 fps on older Macs. | Spike S3 measures; D4 threshold is data-driven; fall-back is poster-only/low-res during spin. |
| R5 | Photos of identifiable people are sensitive — a user may later expect export/share. | v1: none (N2/N3). If roster export is ever added it needs an explicit "include photos?" decision. |
| OQ-1 | Default *Display mode* — *Auto* (proposed) vs *Avatar + name*? | Owner call. |
| OQ-2 | Are *Characters* one pack or several themes (animals, professions, retro)? | Start with one pack of ~40; themes are content, not code. |
| ~~OQ-4~~ | ~~`removeItem` on Halo's own avatar copies (NFR-S4) vs `trashItem`.~~ | **Resolved 2026-10-27: allowed.** A sanctioned exception limited to files under `Application Support/Halo/luckydraw/avatars/`, commented in source and added to CLAUDE.md beside the Drive Speed one when this is built. |
| OQ-3 | Hub shows last winner's avatar (FR-W7) — keep? | Proposed: yes, default on. |

---

## 13. Execution Plan

| Phase | Work | Est. | Exit |
|---|---|---|---|
| **P0 — Spikes & art brief** | S1 animated format · S2 **art brief + 3-item pilot for the commissioned set** · S3 wheel image fill-rate · (S4 caricature-from-photo, optional) | 1.5 d | Decisions D4/D6 confirmed or replaced; art brief handed over |
| **P1 — Model + store** | `EntryAvatar`, tolerant Codable, `AvatarStore`, cache, pack catalog, monogram, folder matcher — UI-free | 2 d | AC-1, 2, 3, 5, 6, 7, 10 green |
| **P2 — Picker + roster UI** | `AvatarView`, picker (emoji/animated/characters/photo), roster rows, drag-drop, bulk sheets | 2 d | AC-2 on screen |
| **P3 — Wheel** | Canvas symbols, placement, fade-with-speed, spotlight lift, threshold | 1.5 d | AC-4, AC-9 |
| **P4 — Popup, sequence, log** | Hero transition, gold ring, animated playback, winners strip, log avatars, Reduced Motion | 1.5 d | AC-8 |
| **P5 — Polish & docs** | Credits screen, storage settings, a11y pass, `MANUAL_TEST_PLAN.md`, F-051 spec cross-link, mobile contract | 1 d | AC-11, AC-12 |

**Dependencies:** F-051 (merged); **the commissioned character and animated-emoji art** (owner-supplied) — P1–P3 can proceed without it using emoji/monogram/photo, but P4's headline visuals and AC-12 cannot close until it exists. Touches `SpinnerWheelView.swift`, `DrawResultOverlay.swift`, `DrawSequenceOverlay.swift`, `DrawModels.swift`, `RosterPanelView.swift`, `RosterImport.swift`. New files use block `8225`–`8244`; add them with `scripts/add_source_files.rb` — never hand-edit `project.pbxproj`.

---

---

## 14. Implementation Record

### 14.1 PR #54 — merged into `release/v2.5` (written 2026-10-27)

**Built (P1–P4, for the kinds that need no art):**
`EntryAvatar` (emoji / photo, plus the reserved animated / character cases) with tolerant `Codable`; `AvatarDisplayMode` per roster; `AvatarStore` (copy-in, Vision face crop with a timeout, 256-px JPEG, bounded decode, path containment, orphan sweep, copy, delete); `AvatarImageCache`; `AvatarView`; the picker popover (Emoji / Photo); roster chips and log rows with avatars; avatars on the wheel (upright, faded with speed, spotlight lift, capped at 40 entries); the winner popup's gold-ringed avatar; the winners-strip avatars; folder import by name with a confirm sheet; "Clear all photos"; cascade deletes. 742 tests pass on a fresh clone; the three data-safety guards were mutation-checked.

**Differences from this spec, and why:**
- **Monogram vs Automatic.** D1 says nil renders as a monogram everywhere; D7 says Automatic shows an avatar only where one exists. They conflict on the wheel, so: the wheel's *Automatic* mode keeps today's name-only look for entries without an avatar (a pixel-identity test pins it), while chips, popup and strip *do* show the monogram. *Avatar + name* / *Avatar only* show monograms on the wheel too.
- **Vision timeout.** A face crop that never returns would leave the picker on "Importing…" forever, and concurrent Vision calls did stall in a test host — so detection runs on its own thread with a 4 s timeout and falls back to the centre crop.
- **`AvatarStore` is a class, not an actor** (stateless; CLAUDE.md's rule), with blocking work on GCD, not Swift's cooperative pool.
- **`AvatarImageCache` returns another decoded size** while the right one loads, so a larger avatar never flashes initials.

**Not verified at #54 (still true):** no one has used the picker, drop, folder sheet, popup animation or Reduced Motion in the running app; Vision on a real face is untested (test images are synthetic); the sandboxed release build was not tried. (#54's "not built" list — hero travel, hub last winner, storage readout, CSV column — is what #57 builds.)

### 14.2 v2.6 requirements added (BRD §6 and §4.2)

| ID | Requirement | Status |
|---|---|---|
| C-1 | **Hero travel**: the winner's avatar animates from its wheel segment to the popup (Reduce Motion → cross-fade) | 🔧 #57 |
| C-2 | **Hub last-winner**: the hub shows the previous winner's avatar (FR-W7) | 🔧 #57 — see "hub shows the last winner" below |
| C-3 | **Storage readout + manage**: avatar storage used, per roster, "Clear this roster's photos" (confirmed) | 🔧 #57 — **deviation: lives in the Lucky Draw roster panel, not Settings** |
| C-4 | **CSV avatar column**: export avatar kind + emoji/monogram (never photo bytes or paths); import accepts it | 🔧 #57 |
| C-5 | Update this record, `CLAUDE.md` avatars section, owner-art checklist for v2.7 | 🔧 record + checklist in this PR; **`CLAUDE.md` avatars section is a follow-up** (the docs PR does not edit `CLAUDE.md`) |
| C-6 | Animated emoji, bundled caricatures, "give everyone a character" | ⛔ **ART → v2.7** (`V2.7-06/07`) |
| H-07 | The orphan sweep never deletes a photo referenced by `luckyDraw.corrupt.json` | ✅ merged v2.5 (#54) |
| H-08 | Fairness tested end to end | 🔧 #60 |
| H-09 | Sweep tests assert both "no delete after a failed load" and "deletes true orphans after a clean load", without sleeps | 🔧 #60 |
| H-10 | Bounds hardened: fail-closed size, header-checked PNG/TIFF dimensions, one UUID case, 64 MB LRU cache | 🔧 #60 |
| H-11 | Measure the wheel; set the avatar-entry limit from data | 🔧 **partial** — see the table below; limit left at 40 |

### 14.3 PR #57 — completion (head `c700dfc`, unmerged, independently reviewed)

**Built:** C-3 (roster panel shows total photo bytes, this roster's bytes and a per-roster list; "Clear this roster's photos" behind a confirmation, touching only that roster's folder; deletion still goes through `AvatarStore.removeInsideRoot` — the existing, owner-approved NFR-S4 exception; **no new deletion path**; readout refreshes on any store change and scans off the main thread); C-4 (`name,avatar_kind,avatar_value`; a photo exports as the bare kind `photo` with an **empty** value; the only avatar a CSV can create on import is a validated single emoji — `photo`/`animated`/`character`/paths/`../`/oversized/combining-mark bombs yield none; `commitImport` re-validates; import never touches the avatars folder; row cap 5 000; formula-guard names round-trip); C-2 (hub shows the last winner when the display mode shows an avatar for that entry; unchanged F-051 hub while spinning, in name-only mode, or for an avatar-less entry under Automatic); C-1 (pure `WheelGeometry`/`HeroTravel`; `SpinnerWheelView` draws avatars with the same functions so the flight origin cannot drift; `WinnerHeroAvatar` flies from the winning segment to the popup slot in 450 ms ease-out; the name reveal waits for the hero's completion — `.logicallyComplete` on macOS 14+, the animation duration on macOS 13, plus a 2 s safety net); H-11 signposts (`os_signpost`, subsystem `com.halo.mac`, category `LuckyDrawWheel`) + a headless draw-cost test (skipped unless `HALO_MEASURE_DRAW_COST` is set).
**Review fixes:** the wheel now draws a **pre-retire pool snapshot while the result popup is up** (auto-retire previously removed the winner's segment before the hero started, so the hero flew from a spot showing a different entry — selection and retirement untouched, display only); name reveal gated on the hero; storage-readout staleness and main-thread scan; header-only CSV fix and a fairness **source-pin** test (`DrawEngine.swift` must not mention avatar/hub/hero/photo/emoji/display-mode — fragile by nature but the only check that can fail).

**Not built:** the C-5 `CLAUDE.md` section; animated/characters (ART); the avatar-entry limit is **unchanged (40)**.

**H-11 measurement** (offscreen CPU rasteriser, median ms/frame, **not on-screen fps**; the machine was loaded by parallel builds, so absolute numbers are noisy):

| entries | wheel pt | plain | with photo avatars | ratio |
|---|---|---|---|---|
| 10 | 480 | 12.6 | 13.6 | 1.08× |
| 20 | 480 | 18.1 | 23.3 | 1.29× |
| 40 | 480 | 14.3 | 15.4 | 1.08× |
| 10 | 720 | 29.6 | 34.9 | 1.18× |
| 20 | 720 | 47.4 | 52.3 | 1.10× |
| 40 | 720 | 29.3 | 30.7 | 1.05× |
| 60 | 720 | 34.7 | 36.3 | 1.05× |

What it supports: drawing avatars adds roughly 1.0–1.3× to the plain wheel's cost, and the plain wheel's own cost dominates; above ~60 entries at 480 pt the fitted diameter falls below the 20 pt minimum so no avatars are drawn. What it does **not** support: any statement about 60 fps on a real display (GPU/compositor not measured). Limit left at 40.

**Verified:** compiles; full `HaloTests` 800 tests — 799 pass, 1 failure is the pre-existing 5 s-wait timing test `AvatarImageCacheTests.missingPhotoIsNotRetriedEveryFrame` in a run where the machine stalled for ~13 minutes (passes in isolation 2/2); 23 new tests (storage accounting/clear scoping/symlink, CSV export/round-trip/hostile import/traversal/store re-validation/row cap, geometry vs `DrawEngine` for 4×50 random plans, hero start transform, hub model, fairness, 2 render tests incl. one tying the hero origin to what the wheel draws); mutation checks (re-importing any avatar; accepting `photo` in `avatar(kind:value:)`; exporting the photo file name; wiping every roster's folder; wheel drawing at 0.7r; hub branch disabled) — 17 failures in 8 tests, all red then green. The fairness test is an **invariant pin**: green before and after by design.

**NOT verified:** the **hero flight in the running app** (path, timing, ring landing on the popup, name reveal after it); Reduce Motion cross-fade visually (style selection unit-tested only); the hub avatar at real sizes with real photos (rendered offscreen only); 60 fps / Instruments / Intel Mac; the sandboxed release build; wheel-keeps-winner-segment and name-reveal gating **at model level only**.

**Known issues carried:**
- **The hub shows the last winner (`history.first`)** — right after a draw that is the winner just announced, beneath the popup. The BRD says "previous winner". Reviewer opinion: keep (it is more useful between spins and the transient is hidden behind the popup); if the owner means the one *before*, use `history.dropFirst().first` while a popup/interim winner is showing.
- **C-3 deviation:** readout in the roster panel, not Settings.
- `EmojiValidation.isSingleEmoji` accepts `"7" + U+0301` (pre-existing; harmless, bounded).
- The `WheelDrawCostMeasurement` 60-entry/480 pt row measured nothing (no avatars drawn) and was dropped.

### 14.4 PR #60 — hardening (unmerged; Lucky Draw parts)

H-08 (`LuckyDrawViewModel(store:generator:)` + `DrawEngine.plan(for:…using:)`: 60 seeds × 4 display modes, with and without photo/emoji avatars, same winner and landing angle; a filter on photo avatars turns it red), H-09 (`LuckyDrawStore(sweepScheduler:)` runs the sweep inline so tests assert outcomes with no `Task.sleep`; both directions asserted), H-10 (unreadable file size → `AvatarError.unreadable` instead of `?? 0`; `ImageHeaderProbe` reads PNG IHDR / TIFF IFD0 dimensions from raw header bytes before ImageIO; photo names normalised to one UUID case — a lower-case hand-edited name previously made the sweep delete its own photo; cache capped at **64 MB** with real **LRU**). Residuals: a roster of ≥ 256 entries all drawn at the 256-px bucket exceeds the cap and would thrash; a hand-placed lower-case file on a case-sensitive volume becomes unreachable (not deleted). **Not verified:** the 64 MB cap against a real 500-person roster on screen (verified by a 500-photo cache test).

### 14.5 Owner-art checklist for v2.7 (C-5)

Before any art work starts: fix the **format** (APNG vs GIF vs Lottie — spike S1) · canvas size, frame count/rate, ring-safe transparent safe area · naming and `manifest.json` fields incl. **licence and attribution, valid for both app stores** · a 3-item pilot to validate the pipeline · record the licence in the repo (AC-12). Nothing is bundled until AC-12 is satisfiable (`V2.7-06/07`).
