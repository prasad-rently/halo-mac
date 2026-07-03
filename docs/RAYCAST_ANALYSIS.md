# Raycast Ecosystem — Deep Analysis & Halo Feature Proposals

> Date: 2026-06-02
> Sources: [raycast/extensions](https://github.com/raycast/extensions) · [raycast/ray-so](https://github.com/raycast/ray-so)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [raycast/extensions — The Extension Marketplace](#2-raycastextensions--the-extension-marketplace)
3. [raycast/ray-so — The Developer Toolkit](#3-raycastray-so--the-developer-toolkit)
4. [UI/UX Patterns Worth Stealing](#4-uiux-patterns-worth-stealing)
5. [System Utility Extensions — Deep Catalogue](#5-system-utility-extensions--deep-catalogue)
6. [What Halo Already Covers](#6-what-halo-already-covers)
7. [Feature Proposals for Halo — The Crown Jewels](#7-feature-proposals-for-halo--the-crown-jewels)
8. [Priority Matrix](#8-priority-matrix)
9. [Key Takeaways](#9-key-takeaways)

---

## 1. Executive Summary

Raycast has built two complementary open-source projects:

| Project | What It Is | Scale |
|---------|-----------|-------|
| **raycast/extensions** | Monorepo of 2,962 community extensions for the Raycast launcher | 7.5k stars, 6.2k forks, 18,851 commits |
| **raycast/ray-so** | Suite of 8 free web-based developer tools (code images, icon maker, presets, themes) | Next.js 16 + React 19 + Shiki + Jotai |

Together they represent the most complete catalog of "what macOS power users want" — validated by install counts (Kill Process: 604k, Color Picker: 456k, Spotify: 398k) and community contributions (2,962 extensions, 80+ themes, 89+ AI prompts, 129 quicklinks).

**For Halo**, these repos are a goldmine of:
- **Validated feature ideas** — the install counts prove demand
- **Exact shell commands** — dock-tinker, flush-dns, etc. are ready-to-use
- **UX patterns** — menu bar templating, cache-first rendering, celebration moments
- **Visual design language** — glassmorphism, gradient systems, noise textures
- **Architecture patterns** — AI-callable tools, shareable configurations, preference-driven customization

---

## 2. raycast/extensions — The Extension Marketplace

### 2.1 Architecture

A monorepo where each extension is a self-contained Node.js/React package:

```
extensions/
├── kill-process/
│   ├── package.json       # manifest: commands, preferences, AI tools
│   ├── src/
│   │   ├── index.tsx      # main command (List view)
│   │   ├── menu-bar.tsx   # menu bar command
│   │   └── tools/         # AI-callable tool definitions
│   └── assets/
├── system-monitor/
├── dock-tinker/
├── port-manager/
└── ... (2,962 extensions)
```

### 2.2 Command Modes

Every extension command runs in one of three modes:

| Mode | Description | Halo Equivalent |
|------|-------------|-----------------|
| `"view"` | Renders React UI (List, Grid, Form, Detail) | Feature views (Dashboard, Cleanup, etc.) |
| `"no-view"` | Runs script → shows HUD confirmation → exits | `ActionCommand.shell()` quick actions |
| `"menu-bar"` | Persistent `MenuBarExtra` with background refresh | `MenuBarDisplayStyle` enum |

### 2.3 The Raycast API Surface

**UI Components**: `List` (searchable, with detail panels), `Grid` (icon/image), `Detail` (markdown + metadata), `Form` (typed inputs), `ActionPanel` (context menus), `MenuBarExtra` (menu bar items with submenus)

**System APIs**: `Clipboard` (read/copy/paste with history offset 0–5), `Storage` (persistent key-value), `Cache` (fast in-memory with disk persistence), `Preferences` (7 typed input types), `OAuth` (built-in flow)

**Feedback**: `showToast()` (animated/success/failure with action buttons), `showHUD()` (brief overlay), `Alert` (confirmation dialogs), `raycast://confetti` (celebration animation)

**AI Tools**: Extensions can expose typed functions that Raycast AI invokes conversationally — with JSDoc descriptions for discovery and optional confirmation dialogs before destructive operations.

### 2.4 Category Breakdown

| Category | Count | Top Examples |
|----------|-------|--------------|
| Developer Tools | ~800 | Kill Process (604k), Port Manager, GitHub, Docker, brew |
| Productivity | ~700 | Todoist, Linear, Notion, Calendar, Reminders |
| Web/SaaS Integrations | ~500 | Slack, Gmail, Google Drive, Jira, Figma, Vercel |
| System Utilities | ~200 | System Monitor, Battery Health, Dock Tinker, Flush DNS |
| Communication | ~150 | Telegram, Discord, WhatsApp |
| Media & Design | ~150 | Spotify (398k), Color Picker (456k), Unsplash |
| AI & ML | ~100 | GPT integrations, Claude API, Gemini |
| Finance | ~80 | Stock trackers, crypto portfolios |
| Documentation Search | ~100 | MDN, React docs, Flutter docs |
| Fun & Lifestyle | ~100 | Weather, recipes, emoji tools |

### 2.5 Distribution Model

Extensions are submitted as PRs → reviewed by Raycast team → published to the in-app Store. Users install with one click. No ratings system — only download counts. Updates via republish from the monorepo.

---

## 3. raycast/ray-so — The Developer Toolkit

### 3.1 Overview

ray.so is a suite of **8 free web tools** at [ray.so](https://ray.so):

| Tool | Purpose |
|------|---------|
| **Code Images** | Beautiful syntax-highlighted code screenshots (flagship) |
| **Icon Maker** | Customizable icon generator with gradients, noise, glare |
| **Themes Explorer** | 80+ community Raycast themes with live preview |
| **AI Presets Explorer** | 50+ pre-configured AI assistant personas |
| **AI Prompts Explorer** | 89+ prompt templates across 13 categories |
| **Snippets Explorer** | Text expansion snippets with dynamic placeholders |
| **Quicklinks Explorer** | 129 URL quicklinks with argument substitution |
| **iOS App Icons** | Themed icon sets for iPhone shortcuts |

### 3.2 Tech Stack

| Layer | Technology |
|-------|-----------|
| Framework | Next.js 16.2, React 19.2, TypeScript 5.4 |
| Styling | Tailwind CSS 3.4 + CSS Modules |
| State | Jotai 2.8 + `atomWithHash` (URL-synced state) |
| Syntax highlighting | Shiki 1.x (WASM, 80 language grammars) |
| Code formatting | Prettier 3.x + Ruff WASM (Python) |
| Image export | `html-to-image` (DOM → PNG/SVG at 2x/4x/6x) |
| UI primitives | Radix UI (dialog, dropdown, popover, select, toast) |
| URL shortening | Dub SDK → `go.ray.so` |
| Icons | `@raycast/icons` library |
| Hosting | Vercel (Edge Runtime for API routes) |

### 3.3 Code Image Generator — Full Specification

**The flagship feature.** Generates beautiful, shareable code screenshots.

#### Languages (80 total)
Swift, TypeScript, JavaScript, Python, Rust, Go, Java, Kotlin, C++, C#, Ruby, PHP, Scala, Dart, Elixir, Haskell, Lua, Zig, Gleam, OCaml, SQL, GraphQL, HTML, CSS, SCSS, JSON, YAML, TOML, Markdown, Docker, Bash, PowerShell, and 48 more.

#### Themes (40 total)

**14 Standard themes:**
Bitmap, Noir, Ice, Sand, Forest, Mono, Breeze, Candy, Crimson, Falcon, Meadow, Midnight, Raindrop, Sunset

**18 Partner/branded themes** (each with a unique decorative frame):
Vercel, Supabase, Tailwind, OpenAI, Mintlify, Prisma, Clerk, ElevenLabs, Resend, Trigger.dev, Nuxt, Browserbase, Cloudflare, Gemini, Stripe, Firecrawl, AWS, Evil Rabbit

Each theme defines:
```typescript
{
  id: string,
  name: string,
  background: { from: color, to: color },  // gradient
  syntax: {
    foreground, constant, string, comment, keyword,
    parameter, function, stringExpression, punctuation,
    link, number, property, objectLiteral,
    highlightedLine: { active, inactive },
    diff: { insert, delete, line }
  }
}
```

#### Customization Options

| Option | Values | Shortcut |
|--------|--------|----------|
| Theme | 40 themes | `C` cycles |
| Dark/Light mode | Toggle per theme | `D` |
| Background | On/off (transparent export) | `B` |
| Padding | 16px / 32px / 64px / 128px | `P` cycles |
| Language | 80 languages + auto-detect | — |
| Line numbers | Show/hide | — |
| Font | 10 monospace fonts | — |
| Window width | 520–920px (draggable with ruler) | — |
| File name | Editable title bar text | — |
| Line highlighting | Alt+click to toggle | — |
| Code formatting | Prettier (JS/TS/HTML/CSS) / Ruff (Python) | `⇧⌥F` |

**Fonts**: JetBrains Mono (default), Geist Mono, IBM Plex Mono, Fira Code, Soehne Mono, Roboto Mono, Commit Mono, Space Mono, Source Code Pro, Google Sans Code

#### Export Options

| Format | Detail |
|--------|--------|
| PNG | 2x, 4x (default), or 6x pixel ratio |
| SVG | Vector export |
| Copy to clipboard | PNG blob via Clipboard API |
| Copy URL | Shortened via `go.ray.so`, all settings encoded in URL hash |

#### URL Sharing Scheme

All state is serialized into the URL hash via Jotai `atomWithHash`:
```
https://ray.so/#code=BASE64&theme=vercel&darkMode=true&padding=64
  &background=true&language=swift&title=MyFile.swift
  &lineNumbers=true&width=720&highlightedLines=1,3,5
```
Code is Base64-encoded. Every configuration is shareable as a link — no server-side storage needed.

#### Easter Egg
Typing a bunny emoji unlocks the "Evil Rabbit" theme with a flash animation.

### 3.4 Icon Maker — Full Specification

#### Icon Sources
- Raycast icon library (searchable catalog)
- Custom SVG upload
- Custom PNG upload
- Text-based (up to 2 characters)
- Random icon generator

#### Background Customization

| Property | Options |
|----------|---------|
| Fill type | Linear gradient, Radial gradient, Solid color |
| Gradient | Primary/secondary color, angle (linear) or position + spread (radial) |
| Radial glare | Glow overlay effect toggle |
| Noise texture | Opacity 0–100% |
| Border radius | 0–256px |
| Stroke | Size, color, opacity |

**24 gradient presets** with curated color combinations.

#### Export
- PNG at configurable resolution (multiple simultaneous exports)
- SVG vector
- Copy to clipboard
- Shareable URL (shortened)
- Native share sheet

#### Features
- Undo/redo with full history
- Zoom control (25%–200%+)
- Recent colors palette
- Keyboard shortcuts: `⌘Z` undo, `⌘C` copy, `⌘⇧E` export

### 3.5 Explorers — Presets, Prompts, Snippets, Quicklinks, Themes

All 5 explorers follow an identical architecture:

```
explorer/
├── data.ts              # Hardcoded items (no database)
├── [[...slug]]/page.tsx # Category-based catch-all routing
├── shared/page.tsx      # URL-imported items
├── components/          # InfoDialog, Toast, Instructions
└── og/route.tsx         # OpenGraph image generation
```

**Sharing model**: Items are encoded in URL parameters → user clicks "Add to Raycast" → `raycast://` deep link imports into the app. Community contributions via PR to the monorepo.

#### Snippet Placeholders
```
{cursor}     — cursor position after expansion
{date}       — current date
{time}       — current time
{clipboard}  — clipboard contents
{argument}   — user prompt
{calculator} — inline math evaluation
```

#### AI Preset Schema
```typescript
{
  name: string,
  description: string,
  instructions: string,        // system prompt
  creativity: "none" | "low" | "medium" | "high" | "maximum",
  model: "claude-sonnet" | "gpt-4o" | "groq" | "mistral",
  tools?: ["calendar", "github", "linear"],
  webSearch?: boolean,
  imageGeneration?: boolean
}
```

### 3.6 Design System

#### Color System
| Token | Value | Usage |
|-------|-------|-------|
| Background | `hsl(0 0% 5%)` | App background (dark) |
| Panel | `hsl(0 0% 9.4%)` | Card/panel surfaces |
| Frame BG (dark) | `rgba(0,0,0,0.75)` | Glassmorphism overlay |
| Frame BG (light) | `rgba(255,255,255,0.75)` | Glassmorphism overlay |
| Line numbers | 20% opacity | Subtle secondary text |
| Title text | 60% opacity | Frame titles |

12-step gray scale with matching alpha variants. Light theme inverts the scale.

#### Animations
| Name | Duration | Effect |
|------|----------|--------|
| `flicker` | 2000ms | Opacity pulse |
| `flash` | 2000ms | Opacity fade (Easter egg) |
| `nightRider` | 2000ms | Horizontal sweep |
| `load` | 500ms | Horizontal scale |
| `slideDownAndFade` | 150ms | Entrance animation |
| `overlayShow` | 250ms | Modal overlay fade |
| `contentShow` | 250ms | Modal content scale-in |

#### Visual Effects
- **Glassmorphism**: Semi-transparent backgrounds with blur (`backdrop-filter`)
- **Gradient backgrounds**: Per-theme `from/to` color pairs
- **Noise texture overlay**: Adjustable opacity (icon maker)
- **Radial glare**: Light bloom effect (icon maker)
- **Checkerboard pattern**: Shown when background is disabled (transparency indicator)
- **Partner frames**: Custom decorative elements per branded theme (gridlines, brackets, logos)

---

## 4. UI/UX Patterns Worth Stealing

### 4.1 Cache-First Rendering (System Monitor)

```
render(cached) → fetch(fresh) → render(fresh) → persist(fresh to cache)
```

System Monitor uses `Cache` to show stale data instantly on launch, then updates with live data. Eliminates loading spinners on repeat visits. **Halo equivalent**: AppState already writes every 2s to the App Group container — the widget uses this pattern, but feature views could benefit from it too (show cached data while scanner actors initialize).

### 4.2 Format String Templating (System Monitor Menu Bar)

Users define custom format templates for menu bar display:
```
CPU: <PERCENT>%          → "CPU: 42%"
<VALUE>/<TOTAL> GB       → "8.2/16.0 GB"
↑<UP>/s ↓<DOWN>/s       → "↑1.2MB/s ↓5.4MB/s"
```

Special tokens: `<PERCENT>`, `<VALUE>`, `<TOTAL>`, `<UP>`, `<DOWN>`, `<BR>` (line break), `<MODE>` ("Free"/"Used" toggle).

**For Halo**: Replace the fixed `MenuBarDisplayStyle` enum with user-configurable format strings. Users could compose exactly what they want: `"CPU <CPU>% · RAM <RAM>% · ↓<NET>"`.

### 4.3 Pinnable Menu Bar Stats (System Monitor)

Users can pin any single metric (CPU, temp, memory, battery, network, storage) to appear as the menu bar title text. Clicking a stat in the dropdown toggles its pin. Stored in `LocalStorage`.

**For Halo**: Allow users to pin specific metrics to the menu bar from any module — not just the 4 fixed styles.

### 4.4 Configurable Primary Action (Port Manager)

Users choose which action is the default (Enter key) via a preference dropdown. Options include Kill, Show Details, Show in Finder, Copy Info, etc.

**For Halo**: Let users set their most-used action as the default for each action category. "Developer" category → default action = "Clear Derived Data" instead of the first in the list.

### 4.5 Celebration & Feedback Hierarchy

Raycast's feedback tiering:
1. **Animated Toast** → in-progress operations (spinner)
2. **Success/Failure Toast** → completion with optional undo/retry buttons
3. **HUD** → quick confirmations after the window closes
4. **Confetti** → celebration moments (`raycast://confetti`)
5. **Sound effects** → `afplay` for audio feedback

**For Halo**: Add celebration moments after significant completions:
- Smart Scan completes with green health → confetti-style particle animation
- Cleanup frees > 5 GB → "space recovered" celebration
- 30-day streak of healthy system → achievement badge

### 4.6 Alt-Key Alternates (MenuBarExtra)

Menu bar items support an `alternate` prop — holding Option reveals a different action. E.g., "Restart" becomes "Force Restart" when Option is held.

**For Halo**: In the menu bar dropdown, Option-click "Run Smart Scan" could become "Run Deep Scan", or "Show Dashboard" could become "Export Report".

### 4.7 URL-Encoded Shareable State (ray.so)

Every configuration is encoded in the URL hash. No server-side storage needed. Users share a link and the recipient gets the exact same view.

**For Halo**: Encode custom action configurations as shareable deep links or QR codes. A user creates a custom action → exports as `halo://action/BASE64` → shares with colleagues.

### 4.8 Named Entities (Port Manager)

Port Manager lets users assign friendly names to port numbers ("React Dev → 3000", "Postgres → 5432"). Simple `Record<number, { name: string }>` stored in Cache.

**For Halo**: Apply this pattern to:
- **Named ports** in a port manager feature
- **Named clipboard slots** (pin important items with labels)
- **Named scan profiles** (custom scan configurations)

### 4.9 AI Tool Definitions with Confirmation

```typescript
export default async function killProcess(input: { pid: number, force: boolean }) { ... }

export const confirmation: Tool.Confirmation<Input> = async (input) => ({
  style: Action.Style.Destructive,
  message: "Kill this process?",
  info: [{ name: "PID", value: String(input.pid) }]
});
```

**For Halo**: When building Siri Shortcuts / App Intents integration, follow this pattern — typed inputs with structured confirmation for destructive operations.

---

## 5. System Utility Extensions — Deep Catalogue

### 5.1 Process Management

#### kill-process (604k installs)

| Feature | Detail |
|---------|--------|
| Data model | `Process { pid, cpu, mem, type, path, processName, appName }` |
| Process types | `.prefPane`, `.app`, `.binary`, `.aggregatedApp` (parent+children grouped) |
| App grouping | Tree aggregation — Chrome's 20 subprocesses → one row with combined CPU/RAM |
| Refresh | `useInterval(3000ms)` with concurrent-fetch guard |
| Actions | Kill, Force Kill, Restart, Force Restart, Kill All, Copy Path, Reload |
| Post-kill behavior | Configurable: close window, clear search, or navigate to root |
| AI tools | `list-processes`, `kill-process` (with confirmation), `killall-process` |
| Sorting | CPU or Memory, togglable |

#### auto-quit-app

Monitors running apps for idle state (no visible windows). Auto-quits after configurable timeout. Excludes system processes and user-pinned apps. Menu bar indicator shows count of idle apps.

### 5.2 System Monitor

| Component | Detail |
|-----------|--------|
| CPU | Usage %, temperature (avg + max), load averages (1/5/15 min), uptime, top 5 processes |
| Memory | Used/free/total, pressure level, swap usage |
| Network | Upload/download speed, interface details |
| Power | Battery %, condition, power source, time remaining |
| Storage | Used/free/total per volume |
| Refresh rates | CPU: 1s, load avg: 10s, top processes: 5s, temperature: 3s (independent timers) |
| Menu bar | Pinnable stats, format string templating, Free/Used toggle |
| Background | `interval: "10s"` for menu bar; `useInterval(2000ms)` when dropdown is open |
| Caching | `Cache` API persists last snapshot → instant render on re-launch |

### 5.3 Port Manager

| Feature | Detail |
|---------|--------|
| Data | `ProcessInfo { pid, path, name, parentPid, user, protocol, portInfo[] }` |
| Named ports | `Record<number, { name: string }>` in Cache; duplicate detection |
| Actions (8) | Kill, Kill All, Kill Parent, Show Details, Show in Finder, Copy Info, Copy Commands, Reload |
| Kill signal | Configurable: "Ask each time" / "Always SIGTERM" / "Always SIGKILL" |
| Primary action | User-selectable default action via preference dropdown |
| Menu bar | Open port count with 1-minute refresh |
| Copy commands | Generates ready-to-paste `lsof` and `kill` commands |

### 5.4 Dock Tinker

12 no-view commands, each a separate file. Pattern: `closeMainWindow()` → `showToast(animated)` → shell command → `showHUD("Done")`.

| Command | Shell |
|---------|-------|
| Add Spacer | `defaults write com.apple.dock persistent-apps -array-add '{"tile-type"="spacer-tile";}' && killall Dock` |
| Add Small Spacer | `... "tile-type"="small-spacer-tile" ...` |
| Set Dock Size | `defaults write com.apple.dock tilesize -int <N> && killall Dock` |
| Toggle Auto-hide | AppleScript: `tell dock preferences to set autohide to not autohide` |
| Set Auto-hide Delay | `defaults write com.apple.dock autohide-delay -float <N> && killall Dock` |
| Set Animation Time | `defaults write com.apple.dock autohide-time-modifier -float <N> && killall Dock` |
| Set Orientation | `defaults write com.apple.dock orientation <left/right/bottom> && killall Dock` |
| Minimize Effect | `defaults write com.apple.dock mineffect <genie/scale/suck> && killall Dock` |
| Toggle Hidden Apps Dim | `defaults write com.apple.dock showhidden -bool <toggle> && killall Dock` |
| Toggle Recents | `defaults write com.apple.dock show-recents -bool <toggle> && killall Dock` |
| Toggle Static Only | `defaults write com.apple.dock static-only -bool <toggle> && killall Dock` |
| Reset to Default | `defaults delete com.apple.dock && killall Dock` |

### 5.5 Battery

| Extension | Technique |
|-----------|-----------|
| `battery-health` | Reads `ioreg -arn AppleSmartBattery` (raw registry) + `system_profiler SPPowerDataType -xml` (system profiler) |
| `battery-menubar` | 30s refresh, shows capacity + power draw in menu bar title |
| `battery-optimizer` | Charge limit management via `batt` CLI; threshold alerts |

### 5.6 Network

| Extension | What It Does |
|-----------|-------------|
| `network-speed` | Speed test |
| `network-diagnostics` | Full diagnostic panel |
| `network-menubar-monitor` | Upload/download stats in menu bar |
| `flush-dns` | `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder` |
| `dns-lookup` | A/AAAA/MX/NS/TXT/CNAME/SOA record lookup |
| `ip-finder` | Local network device scanner |
| `wifi-password-reveal` | Keychain password extraction |
| `connect-to-vpn` | VPN connect/disconnect |

### 5.7 Cleanup

| Extension | What It Does |
|-----------|-------------|
| `appcleaner` | App uninstall + leftover cleanup (Preferences, Caches, App Support, Containers) |
| `dev-cache-cleaner` | Developer-specific caches (DerivedData, CocoaPods, npm, yarn) |
| `folder-cleaner` | Age-based cleanup rules |
| `downloads-manager` | 7 commands: search, organize, auto-clean by age, layout options |
| `dot-underscore-files-cleaner` | `find ~ -name "._*" -type f -delete` |
| `kill-node-modules` | Find and remove `node_modules` recursively |

### 5.8 Display & Dock & Audio

| Extension | What It Does |
|-----------|-------------|
| `display-modes` | Switch resolutions and refresh rates |
| `displayplacer` | Arrange multi-monitor layouts programmatically |
| `mirror-displays` | Toggle mirror/extend mode |
| `audio-device` | Switch audio input/output devices |
| `restart-system-processes` | Restart Finder, Dock, Menu Bar, Audio, WindowServer |

### 5.9 Creative / Interesting Extensions

| Extension | What It Does |
|-----------|-------------|
| `color-picker` (456k) | System-level color picking via **native Swift module**; color naming; history; AI color generation |
| `animated-window-manager` | Bridges to Hammerspoon for animated window tiling |
| `clipboard-sequential-paste` | Paste multi-line list items one at a time per invocation |
| `ai-screenshot` | Modifies screenshots with generative AI |
| `1-click-confetti` | `open("raycast://confetti")` + sound effect via `afplay` |
| `ray-so` (extension) | URL-encodes selected code → opens ray.so with theme/settings |

---

## 6. What Halo Already Covers

Halo consolidates what Raycast users need **10+ separate extensions** for:

| Raycast Extensions Needed | Halo Module | Halo Advantage |
|--------------------------|-------------|----------------|
| system-monitor + battery-health + battery-menubar | Dashboard + Performance + MenuBar | Native Swift, 2s refresh, no Electron |
| kill-process | Actions → "Kill Process on Port" | Integrated with system metrics |
| appcleaner + dev-cache-cleaner + folder-cleaner | Cleanup + Applications (deep uninstall) | 12-path leftover scanner |
| disk-usage | Files → SpaceLens | Visual treemap |
| clipboard-editor + clipboard-formatter + encoding-tools | Clipboard + Actions (14 transforms) | 500-item history, Quick Picker |
| network-speed + flush-dns + network-diagnostics | Actions (Network category) + Performance | Speed test with warm-up |
| system-information | Dashboard (health score, all metrics) | Unified health score |
| restart-system-processes | Actions → System category | Already have Restart Finder/Dock/MenuBar |

**Halo's structural advantages over Raycast's extension model:**
- **Native performance**: Swift/SwiftUI vs. Node.js/Electron — faster, lower memory
- **Unified UX**: One coherent app vs. fragmented extensions
- **Real-time monitoring**: 2s metric refresh vs. 10s+ background intervals
- **Persistent menu bar**: Native `MenuBarExtra` with 4 display styles
- **70 built-in actions**: No installation needed
- **Smart Scan**: Orchestrated multi-module scan with health scoring

---

## 7. Feature Proposals for Halo — The Crown Jewels

### 7.1 Code Snippet Beautifier (Inspired by ray.so)

**What**: Detect code on the clipboard → apply syntax highlighting → export as a beautiful PNG image. A native macOS equivalent of ray.so's flagship feature.

**Why**: ray.so is one of Raycast's most visible products. Developers share code screenshots daily on Twitter/Slack/docs. A native clipboard-aware version eliminates the browser round-trip.

**How it works in Halo**:
1. User copies code → opens Quick Action Picker (`⌘⇧A`)
2. Selects "Beautify Code" action
3. A sheet appears with:
   - Live preview of the code with syntax highlighting
   - Theme picker (8–12 themes matching Halo's dark aesthetic)
   - Padding selector (16/32/64/128px)
   - Background toggle (gradient or transparent)
   - Language auto-detect with manual override
   - Font picker (SF Mono, JetBrains Mono, Fira Code)
   - Window chrome toggle (traffic lights + title bar)
4. Export: Copy to Clipboard (PNG), Save as PNG, Save as PDF

**Implementation**:
- Syntax highlighting via Apple's `NSAttributedString` with a Swift syntax highlighter library (e.g., [Splash](https://github.com/JohnSundell/Splash) for Swift, or a tree-sitter binding for multi-language)
- Rendering via `NSView` → `NSBitmapImageRep` for PNG export
- Themes stored as `[String: NSColor]` dictionaries in a `CodeTheme` model
- New `CodeBeautifierView.swift` as a sheet presented from the Clipboard or Actions module

**Scope**: New feature view + 1 action entry. Medium effort, high visibility.

---

### 7.2 Dock & Desktop Tinker Actions (Inspired by dock-tinker)

**What**: A new "Dock & Desktop" action category with 14 shell actions for hidden macOS preferences.

**Why**: Raycast's dock-tinker is one of its most beloved utility extensions. These are all simple `defaults write` commands that Halo's `ActionCommand.shell` system handles natively.

**Actions**:

| # | Action | Command | Sudo |
|---|--------|---------|------|
| 1 | Add Dock Spacer | `defaults write com.apple.dock persistent-apps -array-add '{"tile-type"="spacer-tile";}' && killall Dock` | No |
| 2 | Add Small Dock Spacer | `defaults write com.apple.dock persistent-apps -array-add '{"tile-type"="small-spacer-tile";}' && killall Dock` | No |
| 3 | Reset Dock to Default | `defaults delete com.apple.dock && killall Dock` | No |
| 4 | Toggle Auto-Hide Dock | `osascript -e 'tell app "System Events" to tell dock preferences to set autohide to not autohide of dock preferences'` | No |
| 5 | Set Auto-Hide Delay (0s) | `defaults write com.apple.dock autohide-delay -float 0 && killall Dock` | No |
| 6 | Set Minimize: Suck Effect | `defaults write com.apple.dock mineffect suck && killall Dock` | No |
| 7 | Set Minimize: Scale Effect | `defaults write com.apple.dock mineffect scale && killall Dock` | No |
| 8 | Set Minimize: Genie Effect | `defaults write com.apple.dock mineffect genie && killall Dock` | No |
| 9 | Toggle Recent Apps in Dock | Script to toggle `show-recents` bool | No |
| 10 | Dock Position: Left | `defaults write com.apple.dock orientation left && killall Dock` | No |
| 11 | Dock Position: Right | `defaults write com.apple.dock orientation right && killall Dock` | No |
| 12 | Dock Position: Bottom | `defaults write com.apple.dock orientation bottom && killall Dock` | No |
| 13 | Toggle Single App Mode | Script to toggle `single-app` bool | No |
| 14 | Toggle Dim Hidden Apps | Script to toggle `showhidden` bool | No |

**Effort**: Low — add entries to `ActionLibrary.swift` predefined actions array.

---

### 7.3 Port Manager (Inspired by port-manager)

**What**: A dedicated port management view showing all listening ports with process info, named ports, and kill actions.

**Why**: Kill Process has 604k Raycast installs. Port management is a top developer need. Halo already has "Kill Process on Port" and "Show All Listening Ports" as actions, but a dedicated view with named ports would be a major upgrade.

**Features**:
- **Port list**: PID, process name, port number, protocol (TCP/UDP), state — parsed from `lsof -iTCP -sTCP:LISTEN -P -n`
- **Named ports**: User-assigned friendly names ("React Dev → 3000") persisted to UserDefaults
- **Kill actions**: SIGTERM or SIGKILL with configurable default (ask / always SIGTERM / always SIGKILL)
- **Kill parent**: Option to kill the parent process (e.g., kill the Node.js parent, not just a worker)
- **Copy commands**: Generate ready-to-paste `lsof -i :<port>` and `kill -9 <pid>` commands
- **Filtering**: By port range, process name, or named port label
- **Menu bar integration**: Show count of open ports or specific watched ports

**Implementation**:
- New `PortManagerView.swift` + `PortManagerViewModel.swift`
- New `PortScanner` actor that wraps `lsof` parsing
- Named ports model: `struct NamedPort: Codable { let port: Int; let name: String }`
- Refresh timer: 5s interval
- Add as a tab in Performance module or as a standalone sidebar item

**Effort**: Medium. New view + viewmodel + scanner actor.

---

### 7.4 Auto-Quit Idle Apps (Inspired by auto-quit-app)

**What**: Monitor running apps for idle state (no visible windows, no foreground activity). Suggest or auto-quit after a configurable timeout.

**Why**: A unique "smart resource reclamation" feature that no standalone macOS app does well. Aligns perfectly with Halo's "system health" identity.

**Features**:
- Monitor `NSWorkspace.shared.runningApplications` for idle state
- Track window count via Accessibility API (`AXUIElementCopyAttributeValue`)
- Configurable timeout: 15m / 30m / 1h / 2h
- Show notification before auto-quitting: "Figma has been idle for 1h — quit to free 850 MB?"
- Allowlist/blocklist (exclude system processes, menu bar apps, user-pinned apps)
- Dashboard integration: "Apps auto-quit today: 3, RAM recovered: 2.1 GB"
- Settings: enable/disable, timeout, exclude list, auto-quit vs. suggest-only mode

**Implementation**:
- New `IdleAppMonitor` actor with `NSWorkspace.didActivateApplicationNotification` observation
- Window count via `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)`
- Idle tracking: `[BundleID: Date]` dictionary of last-active timestamps
- Notification via `AlertManager.fire()` with "Quit" and "Keep" actions

**Effort**: Medium — Accessibility API integration and careful allowlist UX.

---

### 7.5 Downloads Manager (Inspired by downloads-manager)

**What**: A "Downloads" section in the Files module for organizing and cleaning `~/Downloads`.

**Why**: `~/Downloads` is universally cluttered. Raycast's downloads-manager has 7 commands for managing it. Halo's file scanning infrastructure makes this easy.

**Features**:
- **Age-based grouping**: Today, This Week, This Month, Older (30–90 days), Very Old (90+ days)
- **Size breakdown**: Total size per group with visual bar chart
- **One-click cleanup**: "Clean Old Downloads" moves 90+ day files to Trash (with confirmation review sheet)
- **Auto-organize**: Optionally sort files into subfolders by type (Images/, Documents/, Archives/, Videos/, Code/, Other/)
- **Size threshold alert**: Notification when `~/Downloads` exceeds a configurable size (default 5 GB)
- **Quick actions**: "Open in Finder", "Sort by Size", "Sort by Date"

**Implementation**:
- Extend `FileSystemScanner` with `scanDownloads() async -> DownloadsSummary`
- Age grouping using `FileManager.attributesOfItem` creation/modification dates
- Auto-organize via `FileManager.moveItem(at:to:)` with type detection from UTI
- Threshold alert via `AlertManager` triggered during periodic metrics refresh

**Effort**: Low-Medium — leverages existing file scanning infrastructure.

---

### 7.6 Customizable Menu Bar Format Strings (Inspired by system-monitor)

**What**: Replace the fixed `MenuBarDisplayStyle` enum with user-configurable format string templates.

**Why**: System Monitor's format string system is one of its most praised features. Users want to compose exactly what appears in their menu bar.

**Current state** (Halo):
```swift
enum MenuBarDisplayStyle: String {
    case icon       // Halo icon only
    case textStats  // "CPU 42% · RAM 61%"
    case miniBar    // 4px capsule progress bars
    case dot        // colored dot
}
```

**Proposed upgrade**:
```swift
// User-configurable format string
// Default: "CPU <CPU>% · RAM <RAM>%"
// Custom: "↓<NET_DOWN> ↑<NET_UP> · <BATTERY>%🔋"

enum MenuBarToken: String {
    case cpu = "<CPU>"           // CPU usage %
    case ram = "<RAM>"           // RAM usage %
    case disk = "<DISK>"         // Disk usage %
    case battery = "<BATTERY>"   // Battery %
    case netDown = "<NET_DOWN>"  // Download speed
    case netUp = "<NET_UP>"      // Upload speed
    case temp = "<TEMP>"         // CPU temperature
    case health = "<HEALTH>"     // Health score
}
```

**Features**:
- Text field in Settings for custom format string
- Live preview of the rendered menu bar text
- Preset templates: "Minimal" (`<CPU>%`), "Standard" (`CPU <CPU>% · RAM <RAM>%`), "Full" (`<CPU>% · <RAM>% · <DISK>% · <BATTERY>%`), "Network" (`↓<NET_DOWN> ↑<NET_UP>`)
- Keep existing styles as presets (icon, miniBar, dot)
- Free/Used toggle per metric (show 42% used or 58% free)

**Effort**: Medium — parsing + rendering + settings UI.

---

### 7.7 Display & Audio Quick Actions (Inspired by display-modes, audio-device)

**What**: Two new action categories covering display and audio controls.

**Display Actions (6)**:

| Action | Command |
|--------|---------|
| Toggle Dark Mode | `osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to not dark mode'` |
| Screenshot to Clipboard | `screencapture -c` |
| Screenshot Region to Clipboard | `screencapture -ic` |
| Screenshot with Timer (5s) | `screencapture -T5 ~/Desktop/screenshot.png` |
| Toggle Desktop Icons | `defaults write com.apple.finder CreateDesktop -bool <toggle> && killall Finder` |
| Reset Display Settings | `displayplacer` based or System Preferences deep link |

**Audio Actions (5)**:

| Action | Command |
|--------|---------|
| Toggle Mute Microphone | `osascript -e 'set volume input volume 0'` / restore via stored state |
| Set Output: Built-in Speakers | `SwitchAudioSource -s "MacBook Pro Speakers"` (requires brew install) |
| Set Output: Headphones | `SwitchAudioSource -s "External Headphones"` |
| Toggle Do Not Disturb | `shortcuts run "Toggle Do Not Disturb"` or Focus filter |
| Play/Pause Media | `osascript -e 'tell app "Music" to playpause'` |

**Effort**: Low — shell actions for `ActionLibrary.swift`.

---

### 7.8 System Junk & Developer Cache Cleaner Actions (Inspired by dev-cache-cleaner, dot-underscore-files-cleaner)

**What**: Expand the System and Developer action categories with targeted cleanup commands.

**New System Cleanup Actions (7)**:

| Action | Command |
|--------|---------|
| Remove ._ Resource Fork Files | `find ~ -name "._*" -type f -delete 2>/dev/null` |
| Clear Font Caches | `sudo atsutil databases -remove && atsutil server -shutdown && atsutil server -ping` |
| Clear System Logs | `sudo rm -rf /private/var/log/asl/*.asl` |
| Clear User Logs | `rm -rf ~/Library/Logs/*` |
| Remove Broken Symlinks | `find ~ -maxdepth 3 -type l ! -exec test -e {} \; -delete 2>/dev/null` |
| Clear Recent Items | `osascript -e 'tell application "System Events" to delete every recent item of every recent application'` |
| Flush Quicklook Cache | `qlmanage -r cache` |

**New Developer Cleanup Actions (5)**:

| Action | Command |
|--------|---------|
| Clear CocoaPods Cache | `pod cache clean --all` |
| Clear Gradle Cache | `rm -rf ~/.gradle/caches` |
| Clear Docker Unused Images | `docker system prune -f` |
| Clear pip Cache | `pip cache purge` |
| Clear Homebrew Cache | `brew cleanup -s && rm -rf $(brew --cache)` |

**Effort**: Low — add entries to `ActionLibrary.swift`.

---

### 7.9 Celebration & Delight Moments (Inspired by Raycast confetti)

**What**: Add micro-celebrations and feedback animations for significant achievements.

**Why**: Raycast's confetti, toasts, and HUDs create a sense of accomplishment. Halo's dark aesthetic is perfect for particle effects and glow animations.

**Celebration triggers**:

| Event | Animation |
|-------|-----------|
| Smart Scan completes with score ≥ 90 | Green particle burst around health ring |
| Cleanup frees > 1 GB | Space-recovered counter with scale-up animation |
| First scan of the day | Subtle glow pulse on the dashboard |
| 7-day streak of healthy system | Achievement badge appears in sidebar |
| Action completes successfully | Brief green checkmark flash in the status area |
| Export report generated | Document-fly-away animation |

**Implementation**:
- `CelebrationView.swift` — overlay `Canvas` with particle system using `TimelineView`
- Trigger via `NotificationCenter.default.post(name: .haloCelebration, object: CelebrationType)`
- Particle types: confetti, sparkle, glow, pulse
- Duration: 1.5–2s, non-blocking, auto-dismiss
- Respect `UserDefaults["enableCelebrations"]` toggle (default: true)

**Effort**: Medium — custom Canvas animations, but contained to one overlay view.

---

### 7.10 Shareable Action Configurations (Inspired by ray.so URL scheme)

**What**: Encode custom action configurations as shareable deep links or QR codes.

**Why**: ray.so's killer insight is that every configuration is a URL. For Halo, this means custom actions become portable and shareable.

**How it works**:
1. User creates a custom action (name, icon, script, keywords, sudo)
2. Clicks "Share" → generates a `halo://action/BASE64` deep link
3. Recipient clicks the link → Halo opens with an import confirmation sheet
4. Action is added to their custom actions library

**URL scheme**:
```
halo://action/{base64-encoded-json}
halo://actions/{base64-encoded-array}   // batch import
```

**Bonus — QR Code Export**:
- Generate a QR code from the deep link (Halo already has "Generate QR Code" action)
- Print/display the QR for workshop/team sharing scenarios

**Implementation**:
- Register `halo://` URL scheme in `Info.plist`
- `HaloApp.onOpenURL { url in ... }` handler
- `ActionImportView` sheet with preview of the incoming action
- Base64 encode/decode using `JSONEncoder` → `Data.base64EncodedString()`

**Effort**: Medium — URL scheme registration + import UI.

---

### 7.11 Siri Shortcuts / App Intents Integration (Inspired by Raycast AI Tools)

**What**: Expose Halo's capabilities as Siri Shortcuts actions via the App Intents framework.

**Why**: Raycast's newest pattern — AI-callable tools — shows where the industry is heading. Apple's equivalent is App Intents / Siri Shortcuts. This makes Halo composable with other apps and automations.

**Intents to expose**:

| Intent | Input | Output |
|--------|-------|--------|
| Get Health Score | — | Int (0–100) |
| Get CPU Usage | — | Double (%) |
| Get Battery Health | — | String ("Excellent"/"Good"/"Fair"/"Poor") |
| Get Disk Space | — | String ("45.2 GB free of 500 GB") |
| Run Smart Scan | — | String (summary) |
| Run Action | Action name (String) | String (output) |
| Get Clipboard History | Count (Int) | [String] |
| Export Health Report | — | File (PDF) |

**User automations enabled**:
- "When health score < 60, send me a notification"
- "Every Monday at 9 AM, run Smart Scan and email me the report"
- "Add Halo health score to a Shortcuts widget on my Home Screen"
- "Hey Siri, what's my Mac's health score?"

**Implementation**:
- `AppIntent` structs in a new `Halo/Intents/` directory
- `AppShortcutsProvider` for discoverability in the Shortcuts app
- Bridge to `AppState` for reading metrics, `ActionRunner` for executing actions
- Confirmation via `IntentDialog` for destructive actions

**Effort**: High — App Intents framework learning curve, but extremely high value.

---

### 7.12 Icon & Asset Generator (Inspired by ray.so Icon Maker)

**What**: A native icon generator built into the Actions or Files module.

**Why**: ray.so's Icon Maker is popular among developers for creating app icons, folder icons, and project logos. A native version leverages CoreGraphics for instant rendering without a browser.

**Features**:
- **Background**: Linear/radial gradient with color picker, 24 preset gradients
- **Icon source**: SF Symbols (searchable), custom SVG/PNG, text (1–2 chars), emoji
- **Effects**: Noise texture overlay, radial glare, border radius, stroke
- **Export**: PNG (multiple resolutions: 128/256/512/1024), ICNS (macOS app icon format), Copy to clipboard
- **Presets**: App icon, folder icon, website favicon, social media avatar
- **Batch export**: Generate all sizes for Xcode asset catalog (16–1024px)

**Implementation**:
- `IconMakerView.swift` — SwiftUI view with live `Canvas` preview
- Gradient rendering via `LinearGradient`/`RadialGradient`
- SF Symbols via `Image(systemName:)` with dynamic sizing
- PNG export via `NSBitmapImageRep`
- ICNS export via `NSWorkspace` icon writing APIs
- Noise texture via `CIFilter.randomGenerator()` composited at adjustable opacity

**Effort**: High — custom rendering pipeline, but visually impressive and differentiated.

---

### 7.13 Snippet / Text Expansion Engine (Inspired by ray.so Snippets)

**What**: Add template-based text expansion to the Clipboard module.

**Why**: Raycast's snippets with dynamic placeholders (`{date}`, `{clipboard}`, `{cursor}`) are one of its most-used features. Halo's clipboard infrastructure is the perfect foundation.

**Features**:
- **Snippet library**: User-defined text snippets with trigger keywords
- **Dynamic placeholders**: `{date}`, `{time}`, `{clipboard}`, `{uuid}`, `{random:8}` (random string)
- **Expansion modes**: Via Quick Picker (`⌘⇧A` search) or system-wide keyword trigger
- **Categories**: Organize snippets by group (Email, Code, Symbols, Personal)
- **Import**: From ray.so snippets URL, CSV, or JSON
- **Sync with Clipboard module**: Snippets appear alongside clipboard history in the Quick Picker

**Example snippets**:
```
Trigger: "//sig"  →  "Best regards,\n{clipboard}\nSent on {date}"
Trigger: "//uuid" →  "{uuid}"
Trigger: "//meet" →  "Meeting Notes — {date}\nAttendees: {cursor}\nAgenda:\n- "
```

**Implementation**:
- `Snippet` model in `ActionModels.swift`: `id, trigger, body, category, placeholders`
- Expansion engine: regex replace `{token}` with computed values
- Storage: `UserDefaults["haloSnippets"]` as JSON
- Integration: Add snippets as a section in `ClipboardQuickPickerView`

**Effort**: Medium — model + storage + Quick Picker integration.

---

## 8. Priority Matrix

### Tier 1 — Quick Wins (Low effort, immediate value)

| # | Proposal | Effort | Impact |
|---|----------|--------|--------|
| 7.2 | Dock & Desktop Tinker Actions | **Very Low** | Medium |
| 7.7 | Display & Audio Quick Actions | **Very Low** | Medium |
| 7.8 | System Junk & Dev Cache Actions | **Very Low** | Medium |

*These are all `ActionLibrary.swift` entries — no new views, no new models. Ship in one session.*

### Tier 2 — High-Value Features (Medium effort, high differentiation)

| # | Proposal | Effort | Impact |
|---|----------|--------|--------|
| 7.5 | Downloads Manager | **Low-Med** | High |
| 7.3 | Port Manager | **Medium** | High |
| 7.6 | Menu Bar Format Strings | **Medium** | High |
| 7.9 | Celebration & Delight Moments | **Medium** | Medium-High |

*Each is a 1–2 session build. Port Manager and Downloads Manager add visible new capabilities.*

### Tier 3 — Differentiating Features (Medium-High effort, unique positioning)

| # | Proposal | Effort | Impact |
|---|----------|--------|--------|
| 7.1 | Code Snippet Beautifier | **Medium** | Very High |
| 7.4 | Auto-Quit Idle Apps | **Medium** | High |
| 7.10 | Shareable Action Configs | **Medium** | Medium-High |
| 7.13 | Snippet / Text Expansion | **Medium** | High |

*These features don't exist in any single macOS utility. They position Halo as uniquely comprehensive.*

### Tier 4 — Strategic Investments (High effort, long-term value)

| # | Proposal | Effort | Impact |
|---|----------|--------|--------|
| 7.11 | Siri Shortcuts / App Intents | **High** | Very High |
| 7.12 | Icon & Asset Generator | **High** | High |

*These are multi-session builds but create platform-level integration and visual wow factor.*

---

## 9. Key Takeaways

### What Raycast Validates About Halo

1. **The action-runner pattern is correct.** Raycast's most popular system utilities (dock-tinker, flush-dns, restart-processes) are one-shot shell commands — exactly what Halo's `ActionCommand.shell` provides. The 604k installs on Kill Process confirm that process/port management is a top need.

2. **Menu bar monitoring is essential.** Every Raycast monitoring extension offers a menu bar variant. Halo's `MenuBarDisplayStyle` is already strong; format string templating would make it best-in-class.

3. **Native > Electron.** Halo's Swift/SwiftUI implementation gives it a fundamental performance and integration advantage over Raycast's Node.js extension model. Real-time 2s refresh vs. 10s+ background intervals. No Electron memory overhead.

4. **Unified > Fragmented.** Users install 10+ Raycast extensions to get what Halo provides in one app. The consolidated experience with a health score and Smart Scan is a clear value proposition.

### What Raycast Teaches Halo

1. **Delight matters.** Confetti, celebration moments, immediate feedback. Halo's dark aesthetic is perfect for particle effects and glow animations — lean into it.

2. **Customization wins.** Format strings for the menu bar, configurable primary actions, named entities. Let users make Halo theirs.

3. **Shareability creates virality.** ray.so's URL-encoded state makes every creation shareable. Halo should make custom actions portable via `halo://` deep links.

4. **AI integration is the next frontier.** Raycast's AI-callable tools and ray.so's AI presets show where developer tools are heading. Siri Shortcuts / App Intents is Apple's equivalent — and Halo is perfectly positioned to be the first native system utility to offer it.

5. **Developer-specific features drive adoption.** Port management, cache cleaning, and code beautification are developer-focused features with outsized demand. Halo should lean into the developer audience.

---

*This document should be treated as a living reference. As features are implemented, move them from the Priority Matrix to the Completed Features table in CLAUDE.md.*
