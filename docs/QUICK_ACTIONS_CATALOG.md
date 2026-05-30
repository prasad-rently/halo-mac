# Halo — Quick Actions Catalog (v3.0 Planning)

## Status Legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Proposed — not yet started |
| `[~]` | In progress |
| `[x]` | Implemented in code |
| `[✓]` | Validated — builds and runs without errors |
| `[✅]` | Tested — manually confirmed working on device |
| `[🚀]` | Shipped — released to users |

> **How to update:** When an action moves through stages, replace the symbol in its row.
> Commit the change with `docs(actions): mark <ActionName> as [stage]`.

---

> **Purpose:** Catalog of proposed Quick Actions to expand the built-in library from 15 → ~90 actions.
> Actions are grouped by theme and audience. Each entry describes what it does, who it helps,
> how it would be implemented, and whether it needs admin privileges.
>
> **Target audiences:** iOS/macOS Developers · Web Developers · System Admins · Designers ·
> Illustrators · Video Editors · Photographers · Content Creators · General Mac power users.
>
> **Legend:**
> 🔒 = requires admin (sudo/osascript privileges)
> ⚡ = built-in Swift (not shell)
> 🎨 = Creator / Designer audience
> 💻 = Developer audience
> 🔧 = System / Power user
> 📋 = Clipboard utility

---

## ✅ Currently Shipped (15 actions — v2.2 baseline)

| Status | # | Name | Category |
|--------|---|------|----------|
| [🚀] | 1 | Clear Derived Data | Xcode |
| [🚀] | 2 | Clear SPM Cache | Xcode |
| [🚀] | 3 | Reset iOS Simulators | Xcode |
| [🚀] | 4 | Kill Xcode | Xcode |
| [🚀] | 5 | Flush DNS Cache 🔒 | System |
| [🚀] | 6 | Purge Inactive RAM 🔒 | System |
| [🚀] | 7 | Empty Trash ⚡ | System |
| [🚀] | 8 | Rebuild Spotlight Index 🔒 | System |
| [🚀] | 9 | Repair Disk Permissions | System |
| [🚀] | 10 | Run Speed Test ⚡ | Network |
| [🚀] | 11 | Check Connectivity | Network |
| [🚀] | 12 | Show Network Interfaces | Network |
| [🚀] | 13 | Run Smart Scan ⚡ | Halo |
| [🚀] | 14 | Export Health Report ⚡ | Halo |
| [🚀] | 15 | Clear Clipboard History ⚡ | Halo |

---

## 🧑‍💻 Category 1 — Xcode & Apple Platform Development

*Audience: iOS, macOS, watchOS, tvOS developers*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 16 | **Clear CocoaPods Cache** | 💻 | — | Runs `pod cache clean --all` to remove all cached CocoaPods pod specs and downloaded sources. Resolves "pod install" failures caused by corrupt cache. |
| [ ] | 17 | **Deintegrate CocoaPods** | 💻 | — | Runs `pod deintegrate` in the current project to cleanly remove CocoaPods integration. Use before switching to SPM or when pod integration is broken. |
| [ ] | 18 | **Clear Xcode Module Cache** | 💻 | — | Deletes `~/Library/Developer/Xcode/ModuleCache` — large directory that grows to multiple GB; Xcode regenerates it automatically. Resolves mysterious module import errors. |
| [ ] | 19 | **Clean All Simulator Runtimes** | 💻 | — | Runs `xcrun simctl delete unavailable` to remove simulator runtimes for iOS versions that are no longer installed in Xcode, freeing multiple GB. |
| [ ] | 20 | **Open Simulator App** | 💻 | — | Launches the iOS Simulator app with `open -a Simulator` — a quick shortcut without opening Xcode. |
| [ ] | 21 | **Show Xcode Build Logs** | 💻 | — | Opens the most recent Xcode build log directory at `~/Library/Developer/Xcode/DerivedData/*/Logs/Build` in Finder. |
| [ ] | 22 | **Clear Provisioning Profiles** | 💻 | — | Deletes all provisioning profiles from `~/Library/MobileDevice/Provisioning Profiles/`. Xcode re-downloads them on next build. Fixes "profile expired" build errors. |
| [ ] | 23 | **Kill Simulator Processes** | 💻 | — | `pkill -f "Simulator"` — force-kills all running simulator instances. Faster than quitting from the menu when they freeze. |
| [ ] | 24 | **Show Build UUID → dSYM** | 💻 | — | Extracts the UUID of the most recent debug build using `dwarfdump --uuid` and prints it. Useful for matching crash reports to dSYMs. |
| [ ] | 25 | **Clear Swift Package Resolved** | 💻 | — | Deletes `Package.resolved` files in common Xcode project locations, forcing a fresh dependency resolution on next build. |

---

## 🌐 Category 2 — Web & JavaScript / Node.js Development

*Audience: Frontend devs, React/Vue/Next.js, Node.js backend devs*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 26 | **Remove node_modules** | 💻 | — | Prompts for a directory path (defaults to `~/Desktop`) and deletes its `node_modules` folder using `find . -name "node_modules" -maxdepth 2 -type d -exec rm -rf`. Recovers gigabytes instantly. |
| [ ] | 27 | **Clear npm Cache** | 💻 | — | Runs `npm cache clean --force`. Fixes mysterious npm install failures caused by corrupt cached packages. |
| [ ] | 28 | **Clear Yarn Cache** | 💻 | — | Runs `yarn cache clean`. Same as npm cache clean but for Yarn package manager. |
| [ ] | 29 | **Clear pnpm Store** | 💻 | — | Runs `pnpm store prune` to remove unreferenced packages from the pnpm content-addressable store. |
| [ ] | 30 | **Kill Process on Port** | 💻 | — | Reads a port number from the clipboard (or uses 3000 as default) and runs `lsof -ti:PORT | xargs kill -9` to free a port occupied by a crashed dev server. |
| [ ] | 31 | **Show All Listening Ports** | 💻 | — | Runs `lsof -iTCP -sTCP:LISTEN -n -P` to list all ports with active listeners, grouped by process name. Essential for debugging "port already in use" errors. |
| [ ] | 32 | **Clear Vite / Webpack Cache** | 💻 | — | Removes `.cache`, `node_modules/.cache`, and `.vite` directories from the current user's common project locations. |
| [ ] | 33 | **Check npm Outdated Packages** | 💻 | — | Runs `npm outdated --global` to list globally installed npm packages that have newer versions available. |
| [ ] | 34 | **Clear Homebrew Cache** | 💻 | — | Runs `brew cleanup --prune=all` to remove old Homebrew downloads and formula versions, often freeing 2-5 GB. |
| [ ] | 35 | **Update Homebrew** | 💻 | — | Runs `brew update && brew upgrade` in the background with live output streaming. Keeps all CLI tools current. |

---

## 🖥 Category 3 — System Maintenance & macOS Housekeeping

*Audience: All Mac users, sysadmins*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 36 | **Restart Finder** | 🔧 | — | `killall Finder` — Finder relaunches automatically. Fixes stuck desktop icons, frozen Finder windows, or missing external drives in the sidebar without needing a full reboot. |
| [ ] | 37 | **Restart Dock** | 🔧 | — | `killall Dock` — Dock relaunches automatically. Fixes vanishing icons, stuck badges, or unresponsive Dock animations. |
| [ ] | 38 | **Restart Menu Bar (SystemUIServer)** | 🔧 | — | `killall SystemUIServer` — restarts the system UI server that controls the menu bar extras. Fixes frozen menu bar icons or missing status items. |
| [ ] | 39 | **Toggle Hidden Files Visibility** | 🔧 | — | Toggles `defaults write com.apple.finder AppleShowAllFiles` between true/false and restarts Finder. Shows/hides dot-files in Finder windows. |
| [ ] | 40 | **Toggle Dark / Light Mode** | 🔧 | — | Uses `osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode'` to switch appearance without opening System Settings. |
| [ ] | 41 | **Clear Font Cache** | 🔧 | 🔒 | Runs `atsutil databases -remove` and `atsutil server -shutdown` to clear macOS's font cache database. Fixes font rendering issues in design apps. |
| [ ] | 42 | **Rebuild Launch Services** | 🔧 | — | Runs `/System/Library/Frameworks/CoreServices.framework/.../lsregister -kill -r -domain local -domain system -domain user` to rebuild the Launch Services database. Fixes "Open With" menu showing duplicate apps. |
| [ ] | 43 | **Remove .DS_Store Files** | 🔧 | — | `find ~ -name ".DS_Store" -maxdepth 6 -delete 2>/dev/null` — recursively removes Finder metadata files from your home directory. Prevents accidental commits of .DS_Store to git repos. |
| [ ] | 44 | **Show Disk Usage by Folder** | 🔧 | — | Runs `du -sh ~/*/` to display the size of each top-level folder in your home directory. Quick overview of what's consuming disk space. |
| [ ] | 45 | **Clear System Log Files** | 🔧 | 🔒 | Removes log files older than 7 days from `/private/var/log/` and `~/Library/Logs/`. Frees disk space occupied by verbose application logs. |
| [ ] | 46 | **Disable Spotlight Indexing (Temp)** | 🔧 | 🔒 | Runs `mdutil -i off /` to pause Spotlight indexing. Useful during intensive development builds or video rendering when Spotlight consumes I/O. Re-enables with Rebuild Spotlight action. |

---

## 📡 Category 4 — Network, Wi-Fi & Security

*Audience: Developers, sysadmins, remote workers, content creators*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 47 | **Show Public IP Address** | 🔧 | — | `curl -s https://api.ipify.org` — displays your current public-facing IP address. Useful for whitelisting, remote access setup, or verifying VPN tunnel. |
| [ ] | 48 | **Show Wi-Fi Password** | 🔧 | — | Reads the password for the currently connected Wi-Fi network from the macOS Keychain using `security find-generic-password -ga "SSID"`. No admin needed for your own network. |
| [ ] | 49 | **Generate Wi-Fi QR Code** | 🔧 | — | Reads current SSID + password and generates a `WIFI:T:WPA;S:<ssid>;P:<password>;;` QR code using Python's `qrcode` library or a shell approach. Scan with any phone to connect instantly. Great for sharing Wi-Fi with guests. |
| [ ] | 50 | **Toggle Wi-Fi** | 🔧 | — | `networksetup -setairportpower en0 off/on` — toggles Wi-Fi on or off. Useful one-click way to force a reconnect or switch to ethernet. |
| [ ] | 51 | **Toggle Bluetooth** | 🔧 | — | Uses `blueutil --power 0` / `blueutil --power 1` (Homebrew) or `osascript` to toggle Bluetooth. Useful for resolving audio device conflicts or saving battery. |
| [ ] | 52 | **DNS Lookup (Clipboard Domain)** | 🔧 | — | Reads a domain name from clipboard and runs `dig +short` against it to resolve all DNS records. Shows A, AAAA, MX, CNAME records. |
| [ ] | 53 | **Check SSL Certificate Expiry** | 💻 | — | Reads a domain from clipboard and runs `echo | openssl s_client -connect DOMAIN:443 2>/dev/null | openssl x509 -noout -dates` to show the SSL cert's expiry date. |
| [ ] | 54 | **Show Active Network Connections** | 🔧 | — | `netstat -an | grep ESTABLISHED` — lists all active TCP connections with remote addresses. Helps spot unexpected outgoing connections. |
| [ ] | 55 | **Trace Route to Clipboard Host** | 🔧 | — | Reads a hostname/IP from clipboard and runs `traceroute -m 15` to show the network path and latency at each hop. |
| [ ] | 56 | **Renew DHCP Lease** | 🔧 | 🔒 | `ipconfig set en0 DHCP` — forces the Mac to request a new IP address from the DHCP server. Fixes "IP address conflict" or "No IP address" issues without disconnecting from Wi-Fi. |

---

## 📁 Category 5 — File & Folder Management

*Audience: All Mac users, especially developers and creators with large file collections*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 57 | **Find Recently Modified Files** | 🔧 | — | `find ~ -maxdepth 3 -mmin -60 -type f` — lists files modified in the last 60 minutes across your home directory. Useful after an app update or sync to see what changed. |
| [ ] | 58 | **Archive Downloads Folder** | 🎨 | — | Zips `~/Downloads` with a timestamp suffix (`Downloads_2026-05-31.zip`) and moves the zip to `~/Desktop`. Gives a clean Downloads folder while keeping a backup. |
| [ ] | 59 | **Find Empty Folders** | 🔧 | — | `find ~ -maxdepth 5 -type d -empty` — lists empty directories that can be safely deleted, helping tidy up project leftovers. |
| [ ] | 60 | **Show Largest Files (Home Dir)** | 🔧 | — | `find ~ -maxdepth 5 -type f -size +100M -exec du -sh {} \; 2>/dev/null | sort -rh | head -20` — surfaces the 20 largest files eating your disk. |
| [ ] | 61 | **Eject All External Disks** | 🔧 | — | Uses `osascript` to tell Finder to eject all removable disks. Clean way to disconnect all USB drives / SD cards before packing up. |
| [ ] | 62 | **Create Dated Backup of Clipboard Path** | 🔧 | — | Reads a file path from clipboard and copies it to `<original>_backup_YYYYMMDD` using `cp -a`. Quick insurance before making risky file edits. |
| [ ] | 63 | **Batch Rename: Add Date Prefix** | 🎨 | — | Reads a folder path from clipboard and prepends today's date to each filename. Useful for photographers/video editors organising raw files by shoot date. |
| [ ] | 64 | **Remove Quarantine Flag** | 💻 | — | `xattr -rd com.apple.quarantine <clipboard-path>` — removes the macOS quarantine flag from a downloaded file or app that is being blocked by Gatekeeper. |

---

## 🎨 Category 6 — Creative Suite Cache Cleanup

*Audience: Illustrators, designers, video editors, photographers using Adobe, Final Cut, DaVinci, etc.*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 65 | **Clear Final Cut Pro Render Cache** | 🎨 | — | Deletes Final Cut Pro's render files from `~/Movies/Final Cut Pro/`. FCP regenerates these on demand. Frees gigabytes when a project is complete. |
| [ ] | 66 | **Clear Final Cut Pro Motion Templates Cache** | 🎨 | — | Removes Motion template render cache from `~/Library/Application Support/Motion/Library/`. Fixes slowdowns when the template library becomes very large. |
| [ ] | 67 | **Clear DaVinci Resolve Cache** | 🎨 | — | Deletes `~/Library/Application Support/DaVinci Resolve/` cache sub-folders. Resolves database corruption, frees disk space between projects. |
| [ ] | 68 | **Clear Adobe Premiere Cache** | 🎨 | — | Removes `~/Library/Application Support/Adobe/Common/Media Cache/` and `Media Cache Files/`. Fixes Premiere slowdowns and "cache full" alerts on long-form projects. |
| [ ] | 69 | **Clear After Effects Cache** | 🎨 | — | Deletes `~/Library/Caches/Adobe/After Effects/` disk cache. AE rebuilds the preview cache on demand. Essential maintenance between heavy motion projects. |
| [ ] | 70 | **Clear Adobe Photoshop Scratch Disk** | 🎨 | — | Empties Photoshop's designated scratch disk temp files at `~/Library/Application Support/Adobe/Photoshop/`. Frees space locked by Photoshop temp files after crashes. |
| [ ] | 71 | **Clear Lightroom Preview Cache** | 🎨 | — | Removes the `Lightroom Catalog Previews.lrdata` file found next to the main catalog. Lightroom regenerates previews on demand. Massively reduces catalog size. |
| [ ] | 72 | **Clear Figma Local Cache** | 🎨 | — | Deletes `~/Library/Application Support/Figma/Desktop/` cache. Fixes Figma Desktop slowdowns or sync issues on large files. |
| [ ] | 73 | **Clear Logic Pro Cache** | 🎨 | — | Removes Logic's EXS/Sampler Instrument cache from `~/Music/Audio Music Apps/Plug-In Settings/`. Fixes Logic's slow startup after adding large sample libraries. |
| [ ] | 74 | **Clear Sketch App Cache** | 🎨 | — | Deletes `~/Library/Application Support/com.bohemiancoding.sketch3/` cache. Fixes Sketch slowdowns on large design systems with many symbols and assets. |

---

## 📋 Category 7 — Text & Clipboard Utilities

*Audience: All users — especially content creators, developers, writers*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 75 | **Generate QR Code from Clipboard** | 📋 | — | Takes whatever text/URL is in the clipboard and generates a QR code saved as PNG to ~/Desktop. Uses Python's `qrcode` library or `qrencode` CLI. Great for sharing links, contact info, or Wi-Fi credentials. |
| [ ] | 76 | **URL Encode Clipboard** | 📋 💻 | — | Runs `python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip()))"` on clipboard content. Converts spaces and special chars to %XX format for use in URLs. |
| [ ] | 77 | **URL Decode Clipboard** | 📋 💻 | — | Reverses URL encoding — converts `%20` back to spaces, etc. Essential for reading encoded redirect URLs or API query parameters. |
| [ ] | 78 | **Base64 Encode Clipboard** | 📋 💻 | — | `echo -n "$(pbpaste)" | base64` — encodes clipboard content to Base64. Used in API authentication headers, email attachments, embedding images in CSS. |
| [ ] | 79 | **Base64 Decode Clipboard** | 📋 💻 | — | `pbpaste | base64 --decode` — decodes Base64-encoded text from clipboard. Useful for reading JWT token payloads or encoded API responses. |
| [ ] | 80 | **Format JSON in Clipboard** | 📋 💻 | — | `pbpaste | python3 -m json.tool | pbcopy` — takes minified JSON from clipboard and pretty-prints it with proper indentation. Copies result back to clipboard. |
| [ ] | 81 | **Minify JSON in Clipboard** | 📋 💻 | — | Reads formatted JSON from clipboard and produces the compact single-line version. Useful when pasting JSON into API request bodies or config files. |
| [ ] | 82 | **Count Words in Clipboard** | 📋 🎨 | — | Counts words, characters, and lines in the current clipboard content. Displayed in the output panel. Useful for writers checking article/tweet length. |
| [ ] | 83 | **Convert Clipboard to UPPERCASE** | 📋 | — | `pbpaste | tr '[:lower:]' '[:upper:]' | pbcopy` — transforms all text in clipboard to uppercase and replaces clipboard contents. |
| [ ] | 84 | **Convert Clipboard to lowercase** | 📋 | — | Same as above but to lowercase. |
| [ ] | 85 | **Sort Clipboard Lines Alphabetically** | 📋 💻 | — | Splits clipboard text by newline, sorts alphabetically, and copies back. Useful for sorting import lists, CSS properties, or bullet points. |
| [ ] | 86 | **Remove Duplicate Lines** | 📋 💻 | — | `pbpaste | sort -u | pbcopy` — deduplicates lines in clipboard. Useful for cleaning up lists of IDs, URLs, or log entries. |
| [ ] | 87 | **Strip Formatting from Clipboard** | 📋 | — | Clears rich text formatting by reading `pbpaste` (which strips formatting by default on macOS) and writing it back with `pbcopy`. Pastes as plain text to any app. |
| [ ] | 88 | **Hash Clipboard (SHA-256)** | 📋 💻 | — | `echo -n "$(pbpaste)" | shasum -a 256` — generates a SHA-256 hash of clipboard content. Useful for verifying integrity of passwords, tokens, or content. |

---

## 🎬 Category 8 — Media, Image & Video Utilities

*Audience: Photographers, video editors, content creators, illustrators*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 89 | **Convert Clipboard Image Path: HEIC → JPEG** | 🎨 | — | Reads a `.heic` file path from clipboard and converts it to JPEG using `sips -s format jpeg`. HEIC files from iPhone cameras are often unsupported by older apps. |
| [ ] | 90 | **Optimise Images in Downloads Folder** | 🎨 | — | Runs `sips --resampleWidth 2560` on all JPEG/PNG files in `~/Downloads` to reduce resolution on oversized images. Makes sharing and uploading faster. |
| [ ] | 91 | **Get Video File Info** | 🎨 | — | Reads a video file path from clipboard and runs `ffprobe -v quiet -print_format json -show_streams` to display codec, resolution, frame rate, duration, and bitrate. Requires `ffprobe` (Homebrew `ffmpeg`). |
| [ ] | 92 | **Extract Audio from Video (Clipboard Path)** | 🎨 | — | Reads a video file path from clipboard and runs `ffmpeg -i INPUT -vn -acodec copy OUTPUT.m4a` to extract the audio track without re-encoding. |
| [ ] | 93 | **Create GIF from Clipboard Video** | 🎨 | — | Uses `ffmpeg` to convert a short video (clipboard path) to an optimised GIF using a palette-based approach. Output saved next to the source file. |
| [ ] | 94 | **Take Full-Page Screenshot** | 🎨 | — | Runs `screencapture -x ~/Desktop/screenshot_$(date +%Y%m%d_%H%M%S).png` — takes a screenshot without the shutter sound and saves to Desktop with a timestamp. |
| [ ] | 95 | **Start 10-Second Screen Recording** | 🎨 | — | Uses `screencapture -V 10 ~/Desktop/recording_$(date +%Y%m%d_%H%M%S).mov` to capture a 10-second silent screen recording. |
| [ ] | 96 | **Resize Clipboard Image to 1080p** | 🎨 | — | Reads an image path from clipboard, uses `sips` to resize the longest dimension to 1920px while maintaining aspect ratio. Ideal for preparing social media assets. |

---

## ⚙️ Category 9 — macOS System Toggles & Quick Settings

*Audience: All Mac users wanting one-click system control*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 97 | **Lock Screen** | 🔧 | — | `/System/Library/CoreServices/Menu\ Extras/User.menu/Contents/Resources/CGSession -suspend` — instantly locks the screen. Faster than Ctrl+Cmd+Q for users who need keyboard-free locking. |
| [ ] | 98 | **Start Screensaver** | 🔧 | — | `open -a ScreenSaverEngine` — launches the screensaver. Useful as a quick "I'm stepping away" signal in open offices. |
| [ ] | 99 | **Set Volume to 0% (Mute)** | 🔧 | — | `osascript -e 'set volume output muted true'` — mutes system audio instantly. Useful before joining a meeting or when a notification fires during a recording. |
| [ ] | 100 | **Set Volume to 50%** | 🔧 | — | `osascript -e 'set volume output volume 50'` — sets a standard working volume. |
| [ ] | 101 | **Announce Time (Text-to-Speech)** | 🔧 | — | `say "The time is $(date +%I:%M %p)"` — macOS's built-in TTS reads the current time aloud. Amusing and useful in accessibility contexts. |
| [ ] | 102 | **Enable Do Not Disturb** | 🔧 | — | Uses `osascript` to activate Focus / Do Not Disturb mode. Prevents notifications during focused work sessions or screen recordings. |
| [ ] | 103 | **Show Battery Health Details** | 🔧 | — | Runs `system_profiler SPPowerDataType` and parses cycle count, design capacity, and max capacity. Shows the same data as Halo's Battery section but accessible from the quick picker. |
| [ ] | 104 | **Generate Secure Password** | 🔧 | — | `openssl rand -base64 24 | tr -d '/+=' | cut -c1-20 | pbcopy` — generates a 20-character cryptographically secure random password and copies it to clipboard. |
| [ ] | 105 | **Generate UUID** | 💻 📋 | — | `uuidgen | pbcopy` — generates a UUID v4 and copies it to clipboard. Used in database IDs, API keys, asset naming. |

---

## 🐳 Category 10 — Docker & Containers

*Audience: Backend developers, DevOps, full-stack devs*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 106 | **Start Docker Desktop** | 💻 | — | `open -a Docker` — launches Docker Desktop in the background. Avoids having to hunt for the Docker app icon. |
| [ ] | 107 | **Stop All Running Containers** | 💻 | — | `docker stop $(docker ps -q) 2>/dev/null` — gracefully stops every running container. Useful before shutting down or switching projects. |
| [ ] | 108 | **Remove All Stopped Containers** | 💻 | — | `docker container prune -f` — removes all stopped containers. Keeps the container list clean without affecting running ones. |
| [ ] | 109 | **Remove Dangling Images** | 💻 | — | `docker image prune -f` — removes `<none>` tagged images that accumulate after rebuilds. Typically recovers 1-5 GB. |
| [ ] | 110 | **Full Docker Cleanup (Volumes + Cache)** | 💻 | — | `docker system prune -af --volumes` — removes ALL unused containers, images, networks, and volumes. Use when Docker is consuming excessive disk space. ⚠ Destructive — cannot be undone. |
| [ ] | 111 | **Show Docker Disk Usage** | 💻 | — | `docker system df` — shows how much disk space Docker is using broken down by images, containers, volumes, and build cache. |

---

## 🔐 Category 11 — Developer Security & Keys

*Audience: Developers working with APIs, SSH, certificates*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 112 | **Generate SSH Key Pair** | 💻 | — | Generates a new `ed25519` SSH key pair with a timestamped filename in `~/.ssh/` using `ssh-keygen -t ed25519 -C "halo@generated"`. Copies the public key to clipboard for immediate pasting into GitHub/GitLab. |
| [ ] | 113 | **Copy SSH Public Key** | 💻 | — | `cat ~/.ssh/id_ed25519.pub | pbcopy` — copies the default SSH public key to clipboard. The single most-used action when setting up a new server or git remote. |
| [ ] | 114 | **List SSH Config Hosts** | 💻 | — | `cat ~/.ssh/config | grep "^Host"` — lists all named SSH hosts from your config. Quick reference for server aliases without opening a terminal. |
| [ ] | 115 | **Test SSH Connection** | 💻 | — | Reads a `user@host` from clipboard and runs `ssh -o ConnectTimeout=5 -T` to test connectivity. Reports success/failure without opening a full shell. |
| [ ] | 116 | **Check for Leaked API Keys in Clipboard** | 💻 | — | Scans clipboard content against patterns for common API key formats (AWS, Stripe, GitHub tokens, OpenAI keys). Alerts if a key pattern is detected. Prevents accidentally sharing keys in chat or commits. |

---

## 🌿 Category 12 — Git Utilities

*Audience: All developers using Git*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 117 | **Git: Garbage Collect All Repos** | 💻 | — | Finds all `.git` directories in `~/Developer` and `~/Projects` (up to 3 levels deep) and runs `git gc --auto` on each to compact loose objects and save disk space. |
| [ ] | 118 | **Show Global Git Config** | 💻 | — | `git config --global --list` — prints all global git settings (user.name, user.email, aliases etc.) in the output panel. Quick reference without opening a terminal. |
| [ ] | 119 | **Set Git User for This Machine** | 💻 | — | Prompts via `osascript` dialog for name and email, then runs `git config --global user.name` and `git config --global user.email`. Useful when setting up a new Mac. |
| [ ] | 120 | **Clear Git Credential Cache** | 💻 | — | `git credential-cache exit` — clears cached git credentials. Useful when switching between GitHub accounts or after rotating a personal access token. |

---

## 🚀 Category 13 — Productivity & Workflow

*Audience: Content creators, remote workers, anyone wanting macOS automation*

| # | Action | Audience | 🔒 | Description |
|---|--------|----------|----|-------------|
| [ ] | 121 | **Start 25-min Pomodoro Timer** | 🎨 💻 | — | Runs a 25-minute countdown using a background process and posts a macOS notification at the end: "Time's up — take a 5-minute break." No apps needed. |
| [ ] | 122 | **Open Today in Calendar** | 🔧 | — | `open -a Calendar` — launches Calendar scrolled to today. |
| [ ] | 123 | **Create Reminder from Clipboard** | 🔧 | — | Reads text from clipboard and creates a macOS Reminder using `osascript` (Reminders app scripting). Due: 1 hour from now. |
| [ ] | 124 | **Speak Clipboard (Text-to-Speech)** | 🎨 | — | `pbpaste | say` — reads the current clipboard text aloud using macOS TTS. Useful for proofreading content, accessibility, or just checking how copy sounds. |
| [ ] | 125 | **Open New Markdown Note on Desktop** | 🎨 | — | Creates a new timestamped `.md` file on the Desktop (`Note_20260531.md`) and opens it in the default Markdown editor. Quick note-taking without app switching. |

---

## Summary Table

| Category | Count | Primary Audience |
|----------|-------|-----------------|
| Xcode & Apple Platform | 10 | iOS/macOS Devs |
| Web & JS / Node.js | 10 | Web Devs |
| System Maintenance | 11 | All Mac users |
| Network, Wi-Fi & Security | 10 | Devs, power users |
| File & Folder Management | 8 | All users |
| Creative Suite Cleanup | 10 | Designers, Video Editors |
| Text & Clipboard Utilities | 14 | All users |
| Media, Image & Video | 8 | Creators, Photographers |
| macOS Toggles & Settings | 9 | All users |
| Docker & Containers | 6 | Backend Devs, DevOps |
| Developer Security & Keys | 5 | Developers |
| Git Utilities | 4 | All Developers |
| Productivity & Workflow | 5 | All users |
| **Total proposed** | **110** | |
| Already shipped | 15 | |
| **Grand total (v3.0)** | **125** | |

---

## Implementation Priority (Recommended Phasing)

### Phase 1 — High-value, low effort (~25 actions, 2 weeks)
All shell commands, no new Swift needed:
- Toggle Hidden Files, Restart Finder/Dock, Show Public IP, Show Wi-Fi Password
- Generate Secure Password, Generate UUID, Clear npm/Yarn Cache, Kill Port
- Remove node_modules, Word Count Clipboard, Format JSON, Sort Lines
- Lock Screen, Set Volume, Remove .DS_Store, Show Largest Files
- Eject All Disks, Copy SSH Public Key, Show All Listening Ports

### Phase 2 — Creator-focused (~25 actions, 2 weeks)
Some require Homebrew tools (ffmpeg, qrencode):
- All Creative Suite cache clears (FCP, Premiere, After Effects, Lightroom, Figma, Logic)
- QR Code generator, Video Info, Extract Audio, Screenshot actions
- Image convert/resize (uses `sips` — built into macOS, no install needed)

### Phase 3 — Advanced developer tools (~30 actions, 3 weeks)
May need dependency checks:
- Docker actions (need Docker installed)
- Git utilities
- Xcode advanced (provisioning profiles, dSYM)
- SSL cert check, DNS lookup, SSH key generation
- CocoaPods, Homebrew, pnpm actions

### Dependency Policy
Actions that require third-party tools (ffmpeg, qrencode, blueutil) should:
1. First check if the tool is installed: `which ffmpeg > /dev/null 2>&1`
2. If missing, output an actionable install command: `⚠ Install with: brew install ffmpeg`
3. Never silently fail

---

*Document drafted: 2026-05-31 | Based on Halo v2.2 Quick Actions module*
*Next step: implement Phase 1 actions in ActionLibrary.swift*
