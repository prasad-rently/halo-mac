# F-051 — Lucky Draw Spinner Wheel (NFeat-128)

> **Status:** 🗓 Planned · **Platform:** Desktop (mobile: ✅ Port — see §11)
> **Depends on:** `CelebrationOverlay` (F-037 particle engine) · `AppModule` sidebar
> **Reserved pbxproj ID block:** `8181`–`8190` (claimed in `CLAUDE.md`)

---

## 1. Summary

A **Lucky Draw** module: the user types in any number of names or items, Halo
renders them as a colour-segmented wheel, and one press spins it to reveal a
single random winner with a full celebration sequence. Entries can be added,
edited, removed, temporarily excluded, and — the point of a draw — **automatically
retired once they win**, so a roster can be drawn down round by round without the
same name coming up twice.

Everything is local, instant, and offline. There is no scanning, no system access,
and no network call anywhere in this feature; it is the first purely *social*
surface in Halo, and the animation quality **is** the feature. A draw that reveals
its winner without tension is just a random-number generator with a circle drawn
around it.

## 2. Goals / Non-Goals

**Goals**
- Add / bulk-paste / edit / remove an arbitrary number of names or items.
- Spin a wheel that is genuinely, verifiably uniform-random — and *feels* fair.
- Exclude or auto-retire previously drawn names so the pool shrinks per round.
- Multiple saved rosters (a class list, a team, a raffle) that persist across launches.
- A reveal sequence — deceleration, near-miss suspense, confetti poppers, name
  reveal — that is worth watching more than once (§8, the core of this spec).
- Full keyboard operation and a genuine reduced-motion path.

**Non-Goals (v1)**
- **Weighted odds** per entry. Deferred — it complicates both the segment geometry
  and the fairness story, and no stated use case needs it yet.
- Team/group *assignment* (splitting a roster into N balanced groups). Separate feature.
- Any network, sync, or multi-device draw. Local only. (A synced roster would sit
  on F-045's foundation later, not here.)
- Images/avatars on segments. Text labels only in v1.
- Sound design beyond a single optional tick + fanfare pair (§8.11).

## 3. Decisions & Assumptions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **New top-level sidebar module `luckyDraw`**, not a Clipboard/Actions tab | It owns persistent user data (rosters, history) and a full-window canvas. Actions are one-shot commands; this is a workspace. Added to `AppModule.reorderable`, so it sits wherever the user drags it. |
| D2 | **The winner is chosen *before* the animation starts** | `SystemRandomNumberGenerator` picks the index; the wheel then animates to a pre-computed target angle. The alternative — simulating friction and reading off whatever lands under the pointer — makes the distribution a property of the physics code, which is much harder to prove uniform and trivially skewed by a float rounding bug. **The animation is a presentation of the result, never its source.** Stated plainly in the in-app fairness popover so it is never mistaken for theatre hiding a fix. |
| D3 | Persistence = **JSON file** at `Application Support/Halo/luckyDraw.json` | Follows the `MemoryTrendTracker` precedent (`memoryTrendHistory.json`), not the `AlertLog`-in-`UserDefaults` one: several rosters × hundreds of entries × draw history is past what belongs in a plist that is loaded into memory whole. |
| D4 | Rendered with **one `Canvas` inside `TimelineView(.animation)`** | Same engine as `CelebrationOverlay`. A per-frame angle function is required anyway for the pointer ratchet, the motion smear and the tick trigger; 200 `Path` views in a `ZStack` would not hold 60 fps and could not do any of those. |
| D5 | Confetti reuses `CelebrationManager` via a **new `CelebrationType.luckyDrawWinner`** case | Not a parallel particle system. One engine, one `enableCelebrations` toggle the user already knows. |
| D6 | **Auto-retire winner defaults ON** | It is the behaviour that makes the feature a *draw* rather than a spinner. Per-roster, so a "pick a restaurant" list can turn it off. |
| D7 | Retired ≠ deleted | A drawn name moves to a visible **Already drawn** rail and can be put back with one click. Nothing the user typed is ever destroyed by the app's own mechanics. |
| D8 | Hard cap **500 entries**; wheel rendering degrades in two documented steps | Above 60 entries segment labels become index numbers; above 120 the rim is drawn without text and the roster list is the label surface. A 500-slice wheel is still a legible ring of colour; 5,000 is a disc. |
| D9 | **Sound is off by default**, and is the first sound Halo has ever made | The app currently contains no `NSSound`/`AVAudioPlayer` call at all. Introducing audio is a product decision, not an implementation detail — so it ships opt-in, per-roster, with its own toggle. |
| D10 | Spin duration is a **user setting** (3 s / 5 s / 8 s, default 5 s) | 5 s is long enough for the deceleration to build tension and short enough to run 30 draws in a row without the operator resenting it. |
| D11 | `accessibilityReduceMotion` gets a **real alternative path**, not a shortened spin | See §8.12. This is the first Halo surface with motion significant enough to need one. |

## 4. User Stories

- **US-1** As a teacher, I paste 32 student names in one go and draw one at random.
- **US-2** As the same teacher, I draw 32 times over a lesson and never get a repeat,
  because each winner retires itself from the wheel.
- **US-3** As a raffle host, I want the wheel to slow down convincingly so the room
  watches the last two seconds instead of the result popping up instantly.
- **US-4** As a user, I can put a name back after retiring it, because I drew by mistake.
- **US-5** As a user, I keep several rosters (Team, Chores, Lunch spots) and switch between them.
- **US-6** As a user with one person absent today, I exclude them for this session
  without deleting them from the roster.
- **US-7** As a sceptical participant, I can read exactly how the winner is chosen.
- **US-8** As a user who finds motion uncomfortable, the draw still works and still
  feels like an event, without a spinning disc.
- **US-9** As a user, I copy the winner, or the whole draw history, to the clipboard.

## 5. Functional Requirements

### Roster management
- **FR-1** Add an entry via a single text field; **Return** commits and keeps focus for the next one.
- **FR-2** Pasting **multi-line text** splits on newlines into one entry per line
  (also on commas when the paste contains no newline). Blank lines dropped.
- **FR-3** Dropping a `.txt` or `.csv` file on the roster imports it the same way.
- **FR-4** Duplicate labels are detected on add/import and the user chooses
  **Keep both / Skip duplicates** — never silently merged (two people can share a name).
- **FR-5** Edit an entry in place (double-click the chip); remove one entry; **Clear all** behind a confirmation.
- **FR-6** **Exclude** toggle per entry — the entry stays in the roster, greyed, and is off the wheel. Distinct from retired (FR-8).
- **FR-7** Entry cap 500 (D8), with a clear message at the limit rather than a silent drop.

### Drawing
- **FR-8** **Auto-retire winner** toggle per roster (default ON, D6). A retired entry
  leaves the wheel, the remaining segments re-flow (§8.9), and it appears in the
  **Already drawn** rail in draw order.
- **FR-9** **Put back** any retired entry individually, or **Reset draw** to return them all.
- **FR-10** **Draw N in a row** (2–10): runs N sequential spins, each with its own
  reveal, accumulating into a winners list. Cancellable mid-sequence.
- **FR-11** Winner selection is uniform over *eligible* entries only (not excluded,
  not retired), from `SystemRandomNumberGenerator`. If exactly one entry is eligible
  the wheel still spins and lands on it; if zero are eligible, Spin is disabled with
  an explicit reason.
- **FR-12** A **Fairness** popover states, in plain words: the winner is drawn from
  the system CSPRNG before the wheel moves, every eligible entry has identical odds,
  nothing about the spin influences the outcome, and no result leaves the Mac.

### Rosters, history, export
- **FR-13** Multiple named rosters: create, rename, duplicate, delete (delete confirmed).
- **FR-14** Per-roster **draw history** — winner label + timestamp, most recent first, capped at 200.
- **FR-15** Copy winner to clipboard; copy full history; export history as CSV via `NSSavePanel`.
- **FR-16** All state persists across relaunch (D3): rosters, entries, exclusions,
  retired set, history, per-roster settings.

### Interaction
- **FR-17** Keyboard: **Space** spins, **⌘N** new roster, **⌫** removes the selected chip,
  **Esc** dismisses the result, **⌘⇧R** resets the draw. Spin is disabled while spinning.
- **FR-18** The result sheet offers **Spin Again**, **Put Winner Back** (when auto-retire
  is on), and **Close**. Clicking the wheel during a spin does nothing — no interrupting
  a draw in progress, which would invite "re-roll until I like it".
- **FR-19** Per-roster settings: spin duration (D10), sound on/off (D9), confetti on/off
  (defers to the global `enableCelebrations`), auto-retire on/off.

## 6. Non-Functional Requirements

| Area | Requirement |
|------|-------------|
| **Performance** | Sustained **60 fps** during spin + confetti at 200 entries on Apple Silicon. One `Canvas` pass per frame; no per-segment SwiftUI views. Particle count halves when `ProcessInfo.processInfo.isLowPowerModeEnabled`. |
| **Correctness** | Uniform distribution over eligible entries — unit-tested with a χ² goodness-of-fit check over 100 k draws (§10). The landing angle must resolve to the pre-selected index for **every** entry count 1…500 (off-by-one at the 0°/360° seam is the obvious failure). |
| **Accessibility** | Full keyboard path (FR-17); VoiceOver announces the winner via an `.accessibilityLabel` on the result card and an announcement post; reduced-motion path (§8.12); every segment colour pair meets 4.5:1 against its label text. Colour is never the only carrier of state — retired and excluded chips also carry an icon. |
| **Privacy** | No network. Nothing sent to Sentry — roster contents are user text and never enter a crash report or log line. |
| **Persistence safety** | Atomic write (`.atomic`) to `luckyDraw.json`; a corrupt/unreadable file falls back to an empty roster set and is backed up as `luckyDraw.corrupt.json` rather than overwritten. |
| **Design** | Dark-only, `DesignSystem.swift` tokens only (`DESIGN_SYSTEM.md`). Segment palette is a generated 12-hue ramp seeded from `haloAccent`/`haloAccent2`/`haloGreen`/`haloAmber`/`haloPurple`/`haloCyan`, cycling with alternating luminance so neighbouring segments always separate. |

## 7. Architecture & Data Model

```
Halo/Features/LuckyDraw/
├── LuckyDrawView.swift          module shell: roster rail + wheel stage + history
├── SpinnerWheelView.swift       TimelineView(.animation) + Canvas — wheel, pointer, smear
├── SpinnerAnimator.swift        pure angle/velocity math over elapsed time (no UI)
├── DrawResultOverlay.swift      winner card, shockwave, per-character reveal
├── RosterEditorView.swift       chips, add field, bulk paste, exclude/retire rails
└── LuckyDrawViewModel.swift     @MainActor ObservableObject, owned by the view

Halo/Core/LuckyDraw/
├── LuckyDrawStore.swift         @MainActor singleton — load/save luckyDraw.json
└── DrawEngine.swift             winner selection + target-angle computation
```

```swift
struct DrawEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var colorIndex: Int          // index into the generated segment ramp
    var isExcluded: Bool         // FR-6 — user-silenced, stays visible
    var isRetired: Bool          // FR-8 — already won this round
    let addedAt: Date
}

struct DrawRoster: Identifiable, Codable {
    let id: UUID
    var name: String
    var entries: [DrawEntry]
    var history: [DrawResult]    // capped 200, most recent first
    var autoRetireWinner: Bool   // default true
    var spinDuration: SpinDuration   // .quick(3) / .standard(5) / .dramatic(8)
    var soundEnabled: Bool       // default false
    var modifiedAt: Date

    var eligible: [DrawEntry] { entries.filter { !$0.isExcluded && !$0.isRetired } }
}

struct DrawResult: Identifiable, Codable {
    let id: UUID
    let entryID: UUID
    let label: String            // denormalised: survives the entry being deleted
    let drawnAt: Date
}
```

**`DrawEngine` — the whole of the randomness, in one testable place:**

```swift
struct SpinPlan {
    let winnerIndex: Int         // index into roster.eligible
    let totalRotation: Double    // degrees, always positive (clockwise)
    let duration: Double
}

func plan(eligibleCount: Int, duration: Double) -> SpinPlan {
    var rng = SystemRandomNumberGenerator()
    let winner = Int.random(in: 0..<eligibleCount, using: &rng)   // D2 — the only random draw
    let segment = 360.0 / Double(eligibleCount)
    // Land inside the winner's arc but not dead-centre: ±38 % of the half-arc,
    // so consecutive wins don't stop at a visibly identical angle.
    let jitter = Double.random(in: -0.38...0.38, using: &rng) * (segment / 2)
    let centre = 360.0 - (Double(winner) * segment + segment / 2) + jitter
    let fullSpins = Double(Int.random(in: 5...8, using: &rng)) * 360
    return SpinPlan(winnerIndex: winner, totalRotation: fullSpins + centre, duration: duration)
}
```

Pointer sits at **12 o'clock**; the wheel rotates **clockwise**; segment 0 starts at
12 o'clock and runs clockwise. `centre` is the counter-rotation that brings the
winner's arc back under the pointer — the `360.0 -` is the seam that §10's
every-count test exists to protect.

**`SpinnerAnimator` — pure functions of elapsed time**, so the animation is unit-testable
without a view: `angle(at:)`, `angularVelocity(at:)`, `blurAmount(at:)`,
`segmentUnderPointer(at:)`. `SpinnerWheelView` is then a thin renderer, and the tick
ratchet, motion smear and spotlight all read from one source of truth.

## 8. Animation Specification

> This is the feature. Every number below is a starting value tuned to be adjusted
> on a real display, not a guess to be shipped unlooked-at.

**8.1 Idle.** The wheel is still. A faint conic sheen (`haloAccent` → `haloAccent2`,
12 % opacity) sweeps the rim once every 4 s — enough to read as live, not enough to
distract. The Spin button breathes on hover: scale 1.0 → 1.03, glow radius 8 → 16 pt,
`easeInOut` 0.25 s.

**8.2 Wind-up (0.28 s).** On press the wheel **counter-rotates 8°** and scales to
0.97 while the button compresses to 0.94. Anticipation: the recoil is what makes the
launch read as force rather than a cut.

**8.3 Launch (0 → 0.12 T).** Ease-in from rest to peak angular velocity ≈ **1080 °/s**
(three turns a second). The wind-up unwinds through zero into the launch in one
continuous motion — never two separate animations meeting at a stop.

**8.4 Cruise (0.12 T → 0.45 T).** Near-constant peak velocity. Segment labels fade to
25 % opacity; an **angular smear** overlay ramps to full (concentric arc strokes at
decreasing alpha, trailing 18° behind each segment edge — a cheap motion-blur proxy;
a real Gaussian blur on a rotating canvas costs more than the effect is worth). The
rim glow intensifies and the drop shadow under the wheel softens and spreads, as if
it has lifted.

**8.5 Decay (0.45 T → T).** The tension curve, and the single most important number
in this document:

```
progress(t) = 1 - pow(1 - t, 3.4)      // t normalised 0…1 over the decay phase
```

The **last 15 % of the time covers barely 1 % of the decay phase's rotation** — the
wheel visibly *labours* past the final few names. Exponential decay (`1 - e^-kt`) was
considered and rejected: it never truly arrives, so the stop has to be faked with a
cut-off, and the cut-off is visible.

> **3.4, not 4.2.** The first draft of this spec specified 4.2. Running it in the
> interactive preview showed why that is wrong: at 4.2 the wheel's velocity in the final
> 0.8 s falls to ~2 °/s, which does not read as suspense — it reads as the app having
> frozen. 3.4 lands the final second in the 20–60 °/s band, which is slow enough to
> count the remaining names and fast enough to still be motion. This is R1's tuning pass
> beginning, not ending: **re-verify on real hardware** before Done.

**8.6 Ratchet pointer.** A physical flipper at 12 o'clock. Every time a segment
boundary passes beneath it, it deflects by `min(18°, velocity / 60)` and springs back
with `interpolatingSpring(stiffness: 380, damping: 14)`. At cruise it flutters into a
continuous blur; in the last second it delivers **discrete, countable clicks** — which
is precisely what makes a slowing wheel feel physical rather than merely slow.

**8.7 Near-miss spotlight (final ~0.6 s).** When angular velocity drops below **45 °/s**,
the wheel dims to 70 % except the segment currently under the pointer, which lifts:
scale 1.04, brightness +12 %, and a 2 pt `haloAccent` glow ring. As the wheel creeps,
the spotlight hands off segment to segment. **This is the highest-value animation in
the feature** — it converts the last half-second from waiting into watching, and it is
what makes a near-miss land as a near-miss.

**8.8 Settle.** The wheel overshoots its target by **1.5–3°** and springs back
(`spring(response: 0.55, dampingFraction: 0.62)`). Never a hard stop — a hard stop
reads as a bug even when it is correct.

**8.9 Reveal sequence** (t = 0 at settle):

| t (s) | Beat |
|-------|------|
| 0.00 | Winner segment flashes white at 35 % for 90 ms. |
| 0.08 | **Confetti poppers** — two cannons at the lower-left and lower-right of the wheel, firing 55° inward. 140 particles (ribbons, discs, stars), launch speed 900–1400 pt/s, gravity 1600 pt/s², drag 0.985 /frame, per-particle spin 180–720 °/s, 2.6 s life with fade over the final 0.8 s. Palette: accent, accent2, green, amber, purple, cyan. Ribbons flutter — each gets a sine-driven lateral wobble so it tumbles instead of falling straight. |
| 0.12 | Winner card scales in from 0.80, blur 8 → 0 pt, opacity 0 → 1, `spring(response: 0.42, dampingFraction: 0.68)`. |
| 0.30 | Name text reveals **per character**, 12 ms apart, each rising 10 pt on its own spring. Applied only to labels ≤ 24 characters; longer labels fade in whole, because a stagger across 40 characters reads as a stutter, not a flourish. |
| 0.45 | Radial shockwave ring expands from the hub to 1.6× wheel radius over 0.7 s, 3 pt stroke, opacity 0.5 → 0. |
| 0.60 | A `haloGreen` glow breathes twice beneath the card (0.9 s each). |
| ongoing | A slow conic halo rotates behind the winner card (20 s/turn) while the sheet is up. |

**8.10 Retire & re-flow (0.5 s).** The winner's segment shrinks to zero arc while
**every remaining segment re-proportions to its new angle in the same
`spring(response: 0.6, dampingFraction: 0.8)`**. Segments never teleport. The retired
chip travels to the *Already drawn* rail via `matchedGeometryEffect`, so the wheel and
the roster list read as two views of one object rather than two lists that happen to agree.

**8.11 Sound (opt-in, D9).** Two cues only: a short ratchet **tick** fired from 8.6
(rate-limited to 20 /s, below which it becomes a buzz), and a single soft **fanfare**
at reveal. No looping spin sound.

**8.12 Reduced motion** (`@Environment(\.accessibilityReduceMotion)`). Not a faster
spin — a different presentation: the wheel cross-fades its highlight to the winning
segment over 0.4 s, the winner card fades in without scale, blur or per-character
stagger, the confetti is replaced by one static badge flash, and the shockwave and
smear are omitted entirely. The draw is still an event; nothing spins, pulses, or
flies. Confetti additionally respects the existing `enableCelebrations` setting.

**8.13 Performance guards.** Above 120 entries: no labels, no per-segment spotlight
(the pointer alone marks position). Low Power Mode: particle count halved, smear off.
The frame budget is checked against the 200-entry case, not the 8-entry demo case.

## 9. Acceptance Criteria

1. 250 names pasted in one action become 250 entries; the wheel renders and spins at 60 fps.
2. With auto-retire on, N consecutive draws over an N-entry roster yield **N distinct
   winners** and end in an explicit "all drawn" state offering **Reset draw**.
3. The segment that stops under the pointer is the entry named on the winner card —
   verified for entry counts 1, 2, 3, 7, 60, 120, 499, 500.
4. 100 k simulated draws over a 10-entry roster pass a χ² uniformity test at p > 0.01.
5. Excluding an entry removes it from the wheel and from selection; un-excluding restores it.
6. A retired entry can be put back individually, and **Reset draw** restores all of them.
7. Quit and relaunch: rosters, entries, exclusions, retired set, history and per-roster
   settings are all exactly as left.
8. Reduced Motion on: no rotation, no confetti, no blur — and the winner is still
   announced and still visually unambiguous.
9. Keyboard only, no mouse: create a roster, add three names, spin, read the winner, reset.
10. The Fairness popover's description matches the implementation (D2) word for word.
11. `scripts/audit-entitlements.sh` and the full `HaloTests` suite pass; no new entitlement
    is required by this feature.

## 10. Test Plan

**Unit (`HaloTests`)**
- `DrawEngineTests` — χ² uniformity (AC-4); `plan()` returns an in-range index for
  counts 1…500; the **landing angle resolves to `winnerIndex` for every count 1…500**
  (the 0°/360° seam); jitter never crosses a segment boundary.
- `SpinnerAnimatorTests` — angle is monotonic non-decreasing; `angle(at: T)` equals
  `totalRotation` exactly; velocity is 0 at t=0 and t=T and peaks inside the cruise
  window; `segmentUnderPointer(at: T)` equals `winnerIndex`.
- `LuckyDrawStoreTests` — round-trip encode/decode; 200-entry history cap; corrupt file
  falls back to empty and writes `luckyDraw.corrupt.json` without data loss;
  duplicate-label detection (FR-4).
- `RosterTests` — `eligible` excludes both excluded and retired; retire → put back →
  eligible again; reset clears the whole retired set.

**Manual (`docs/MANUAL_TEST_PLAN.md` addendum)** — the animation beats of §8 cannot be
asserted in code and get an explicit checklist: wind-up recoil visible; no seam between
wind-up and launch; smear present at cruise; final second delivers countable ticks;
spotlight hands off between segments; overshoot-and-settle visible; confetti fires from
two points, not one; per-character reveal on a short name and whole-fade on a long one;
re-flow is continuous with no teleport. Plus: 500-entry render, Low Power Mode, Reduced
Motion, and a 30-draw run for repeat-winner regressions.

## 11. Mobile Feasibility (governance requirement)

Recorded in [`HALO_MOBILE_ROADMAP.md`](../HALO_MOBILE_ROADMAP.md) §3 and §9.

- **iOS:** ✅ Port — SwiftUI `Canvas` + `TimelineView` is the same code. `CoreHaptics`
  makes the §8.6 ratchet *better* than on the Mac: a real transient per tick.
- **Android:** ✅ Port — Jetpack Compose `Canvas` + `withInfiniteAnimationFrameNanos`,
  `VibrationEffect.createOneShot` for ticks.
- **Blockers:** none. No OS API, permission, or entitlement is involved — this is pure
  computation and drawing, the textbook §2-prong-1 "OS-agnostic win".
- **Adaptation:** phone layout stacks the roster beneath the wheel; bulk paste replaces
  drag-and-drop import; share-sheet export replaces `NSSavePanel`.
- **Verdict:** Port · **Priority P2** (high delight-per-effort, zero platform risk).

## 12. Open Questions & Risks

| # | Item | Default taken |
|---|------|---------------|
| Q1 | Should the wheel live in the main window or also be presentable as a full-screen/detached panel for a room? | Main window in v1. A detached presentation panel is the obvious v1.1 (the `FocusSessionOverlayController` `NSPanel` pattern already exists to copy). |
| Q2 | Weighted entries | Deferred (§2). Revisit only if a real use case appears. |
| Q3 | Should draws be shareable as an image (winner card → PNG to clipboard)? | Deferred; `ReportGenerator`'s Core Graphics path would make it cheap later. |
| Q4 | A Siri Shortcut / App Intent (`RunLuckyDrawIntent`) | Deferred to v1.1 — the module's value is watching it, which an intent can't deliver. |
| R1 | **Risk:** the 4.2 exponent, the 45 °/s spotlight threshold and the 1080 °/s peak are tuned values. Shipping them unlooked-at is the most likely way this feature lands flat. | Mandatory tuning pass on real hardware before Done; §10's manual checklist gates it. |
| R2 | **Risk:** users may assume the visible spin decides the winner and read a fast landing as rigged. | The Fairness popover (FR-12) is a requirement, not a nicety. |

## 13. Execution Plan

| Phase | Work | Effort |
|-------|------|--------|
| **P1 — Data & engine** | `DrawEntry`/`DrawRoster`/`DrawResult`, `LuckyDrawStore` (JSON + atomic write + corrupt fallback), `DrawEngine.plan()`, `SpinnerAnimator` pure math. Full unit suite. **No UI.** | 1.0 d |
| **P2 — Roster UI** | Module registration in `AppModule` (+ `reorderable`), `LuckyDrawView` shell, `RosterEditorView`: add field, bulk paste, file drop, edit, remove, exclude, roster switcher. Static wheel render. | 1.0 d |
| **P3 — Spin & wheel** | `SpinnerWheelView` `Canvas`: segments, labels, degradation steps, wind-up → launch → cruise → decay → settle, ratchet pointer, angular smear, near-miss spotlight. | 1.5 d |
| **P4 — Reveal & celebration** | `CelebrationType.luckyDrawWinner` popper emitter, `DrawResultOverlay` (card, per-character reveal, shockwave, halo), retire + re-flow with `matchedGeometryEffect`, Already-drawn rail. | 1.0 d |
| **P5 — Settings, a11y, polish** | Per-roster settings, optional sound, Fairness popover, keyboard map, reduced-motion path, history + CSV export, Low Power Mode guards, 500-entry perf pass, tuning pass (R1). | 1.0 d |
| **P6 — Docs & governance** | `CLAUDE.md` module section + ID-block claim, `FEATURE_ROADMAP.md` card → Done, `HALO_MOBILE_ROADMAP.md` row + study, `USER_GUIDE.md`, `MANUAL_TEST_PLAN.md` addendum. | 0.5 d |

**Total ≈ 6 days.** P1 is deliberately first and UI-free: it is the half that has to be
*correct*, while P3–P4 are the half that has to be *felt*, and they are much easier to
tune once the numbers underneath them are already trustworthy.

---

## 14. Implementation Record

Built on `feat/f051-lucky-draw`. See `docs/FEATURE_ROADMAP.md` → F-051 → **As actually
built** for the full list of deltas from this document and, importantly, the list of
specced requirements that were **not** built in this pass (file-drop import, duplicate
detection, draw-N-in-a-row, the wider keyboard map, sound, roster rename UI).

The two behavioural decisions worth reading back into §5 if this is ever revised:

- **FR-8 amended.** Put back returns the entry to the wheel *and leaves its row in the
  draw log*, flagged `wasReturned`. §5 described retirement and put-back without saying
  what happens to the log row; the answer is that it stays, because the log records draws
  rather than mirroring the retired set. A put-back entry can win again and writes a
  second row.
- **NFR "Design" amended.** The palette in §6 said "generated 12-hue ramp seeded from
  haloAccent/haloAccent2/haloGreen/haloAmber/haloPurple/haloCyan". That was wrong on
  screen — six accent hues as pie slices is exactly the toy-chart look the section was
  trying to avoid, and it forces the label colour to flip per segment. What shipped is a
  single blue→violet sweep at alternating luminance with one near-white label colour,
  contrast-tested at 4.5:1 across entry counts 1…500.
