# Halo Mobile (iOS) — design system

Halo mobile is a **glanceable utility**, not an information screen: dark cards, live numbers, rings,
big tappable actions. It must read as the same product as the Halo desktop app
(`Halo/DesignSystem/DesignSystem.swift`). Code lives in `HaloMobile/DesignSystem/`. Dark-only — never add adaptive colours.

## Tokens (`Tokens.swift`)

| Token | Hex | Use |
|---|---|---|
| `haloBackground` | `#080c14` | screen background |
| `haloSurface` | `#0d1220` | tab bar, nested wells |
| `haloSurface2` | `#131928` | **cards** (as on desktop) |
| `haloAccent` / `haloAccent2` | `#4f7cff` / `#7b5ea7` | primary action gradient pair (accent2 is fill-only) |
| `haloGreen` / `haloAmber` / `haloRed` | `#22d97a` / `#f5a623` / `#ff4d6a` | healthy / warning-or-limit / problem |
| `haloCyan` / `haloPurple` | `#00d4e8` / `#b06cff` | URL / code content |
| `haloText` / `haloText2` | `#f0f2f8` / `#8892a8` | primary / secondary text (desktop values) |
| `haloText3` | `#7a869e` | tertiary text. **Deliberately lighter than desktop's `#4a5568`** (2.3:1, fails AA). Desktop value kept as `haloTextDecor`, decoration only. |
| `haloAccentFill` | `#3f68ee` | start colour of the primary button gradient. Desktop's `#4f7cff` gives a 3.7:1 white label (needs 4.5:1 at 17pt); this gives 4.7:1. |
| `haloAccentText` | `#7a9bff` | accent-coloured *text on an accent-tinted pill* (info badge, accent chip): `#4f7cff` on its own tint is 3.9:1, this is 5.7:1. Use `Color.haloReadable(tint)`. |

`HaloState` (`.ok .warning .error .info .neutral`) maps state to colour **and** an SF Symbol — pair colour with a word/icon, never colour alone.
Typography is `HaloFont` (text styles → Dynamic Type). Layout constants in `HaloLayout` (16pt gutters, 14pt card radius, 44pt min target). `HaloHaptics` for feedback. `HaloAppearance.install()` styles tab/nav bars (called from the app entry).

## Components

| Component | What | Notes |
|---|---|---|
| `HaloCard(accentTop:padding:)` | surface card | `HaloCard(padding: 0)` for list-style cards |
| `HaloMetricTile` | icon + big number + label (+ sparkline) | 2-up in `LazyVGrid`; `action:` makes it tappable |
| `HaloRing` | status ring + centre value + caption | the Home hero |
| `HaloSparkline` | mini bars | decorative; hidden from VoiceOver |
| `HaloSectionHeader("Title", actionLabel:action:onInfo:)` | small-caps header | `onInfo` shows an (i) → `HaloInfoSheet` |
| `HaloChip` | pill; with `action` it is a filter chip | hit area padded to 44pt |
| `HaloStatusBadge("Ready", .ok)` | state pill (icon + word) | |
| `HaloPrimaryButton` / `HaloSecondaryButton` | gradient / ghost action | primary = one per screen, full width, haptic |
| `HaloIconButton(icon:label:)` | 44pt circular icon button | `label` is required (VoiceOver) |
| `HaloListRow` + `HaloRowDivider` | icon tile, title, one-line subtitle, trailing | put several in `HaloCard(padding: 0)` |
| `HaloEmptyState` | icon + title + one line + one action | scroll-safe (no unbounded frame) |
| `HaloInfoSheet` / `.haloInfoSheet(...)` / `HaloInfoButton` | where explanations live | `HaloInfoPoint(icon, tint, title, text)` |

Every file ends in `#Preview`s. Screen chrome: `.haloScreen()` (background), `.haloAnimation(_:value:)` (respects Reduce Motion).

## Copy rules

- Titles ≤ 3 words. Subtitles one short line. Numbers and icons over sentences. No paragraphs on a primary screen.
- Empty state = one line + one action. The long version goes behind an (i) in a `HaloInfoSheet`.
- **Honest limits are moved, never deleted** ("Viewer only on iPhone", "not encrypted in transit", "app must be open to receive") — as a small chip or inside an info sheet.
- All user-visible strings live in `Strings.swift` (`HaloStrings.<Area>.…`); add your own nested enum rather than editing someone else's.

## Do / Don't

- DO use `HaloCard` + `HaloListRow` for lists instead of `List`/`Form` chrome; DO colour state semantically; DO give every icon-only control a VoiceOver label; DO use `.minimumScaleFactor` on key numbers instead of truncating them.
- DON'T use fixed `.font(.system(size:))` for text (Dynamic Type); DON'T hard-code colours or hex in views; DON'T add a paragraph to a main surface; DON'T hide a limitation to make a screen cleaner; DON'T use `maxHeight: .infinity` as an empty-state root inside a scroll view.
- Accessibility baseline: ≥44pt targets, AA contrast on `haloSurface2`, `accessibilityIdentifier`s kept stable (existing UI scripts use them), Reduce Motion respected.
