# F-054 — Spike notes: S-A (git under the sandbox) and S-B (sandboxed removal of the Trash URL)

> Written during the v2.6 build (2026-10-28). These resolve spec §12 **R5** and **R6** as far as they can be resolved
> **without running a sandboxed build** — which this session could not do (a sandboxed Halo needs a provisioning-signed
> build; every Halo DMG shipped so far is *unsandboxed*, CLAUDE.md gotcha 27). Both are therefore **analysis plus a
> defensive design, not measurements**, and the PR lists them under *NOT verified*.

## What was established (from the repo, not from a run)

| Fact | Source |
|---|---|
| Release entitlements turn the App Sandbox **on**; Debug entitlements (what shipped DMGs are signed with) leave it **off**. | `Halo/Halo.entitlements`, `Halo/Halo-Debug.entitlements`, CLAUDE.md gotcha 27 |
| `ShellReader` documents that under the sandbox `posix_spawn` is denied and reports it as `launchFailure`. | `Halo/Core/ShellReader.swift` header, CLAUDE.md gotcha 20 |
| `Halo.entitlements` carries `com.apple.security.temporary-exception.files.home-relative-path.read-write` for `/.Trash/` (among others) and `user-selected.read-write`. | `Halo/Halo.entitlements` |
| Nothing in the entitlements covers `<volume>/.Trashes/<uid>` (Trash on an external volume). | same |

## S-A — does `git` run through `ShellReader` in a sandboxed release build?

**Not proven; assumed NO, and the feature is built to be correct either way.**

* The repo's own contract says the spawn is denied, so `GitGate.locateGit()` (which also uses `ShellReader` for
  `xcode-select -p`) returns `nil` and `GitGate.inspect` returns `.unavailable`.
* `locateGit()` never spawns `/usr/bin/git` itself — on a Mac without the Command Line Tools that is a shim that raises an
  "install developer tools" dialog (spec R5). It probes Homebrew / CLT paths and `xcode-select -p` instead.
* **Not-a-repo vs git-unavailable is separated without spawning anything:** `GitGate.isInsideWorkTreeByFilesystem` walks up
  looking for a `.git` entry, which a sandboxed app can do inside a folder the user granted.

**Degrade path (implemented and tested — `whenGitCannotRunRepoItemsAreUnverifiedAndDistLikeFoldersAreDropped`):**

| Situation | Result |
|---|---|
| Not in a git work tree | offered, **Unverified** (`.notRepo`), Move to Trash only (D-02) |
| In a work tree, git cannot answer (`.unavailable`) | offered as **Unverified**, Move to Trash only, **never** picked by smart-select; counted in the scan summary |
| Catalogue rule needs a positive git-ignore (`dist`, `.next`, `.nuxt`, `Pods`, `Carthage`) and git cannot answer | **not offered** |
| Pane | a standing notice: "Git can't run in this build …" — no silent omission |

**Residual risk, stated plainly:** in a sandboxed build, a *committed* `build/` (or `target/`, `node_modules/` …) inside a git
repo, with a matching marker file, is offered as *Unverified* because git cannot say it is tracked. It is only ever *moved to
the Trash* (recoverable) and is labelled, but it is a weaker guarantee than the unsandboxed build gives. Pure-Swift
`.gitignore`/index parsing was deliberately **not** attempted (spec: "do not approximate `git check-ignore`"). The clean fix
for a sandboxed release is an XPC helper that runs git; until then the pane in a sandboxed build is a reduced feature.

## S-B — can a sandboxed build remove the URL that `trashItem` returned?

**Not proven; therefore permanent removal (FR-U5b) is HIDDEN in a sandboxed build.**

* Plausibly *yes* for `~/.Trash/<name>`: the `/.Trash/` home-relative read-write exception is present, and read-write
  includes unlink. Plausibly *no* for `<volume>/.Trashes/<uid>/…`, which no entitlement covers. Neither was run.
* Because it is unproven, the design is "unproven ⇒ unavailable":
  * `BuildArtifactRemover.permanentRemovalAvailable(sandboxed:)` is `!sandboxed` (sandbox detected at runtime via the
    `APP_SANDBOX_CONTAINER_ID` environment variable, the same check `PerceptualDuplicateDetector` uses);
  * the review sheet **does not render** the "Move to Trash and empty those items" button when it is false (hidden, not
    disabled-without-explanation);
  * `BuildArtifactRemover.trashAndEmpty` itself **refuses every item** when it is false (defence in depth — a stray caller
    cannot reach `removeItem` in a sandboxed build) — tested.
* Only the unsandboxed build (today's shipped DMGs) offers the permanent action. Lighting it up for a sandboxed build is
  a one-line change to `permanentRemovalAvailable` **after** someone runs the sandboxed round trip
  (`trashItem` → `removeItem(resultingItemURL)` on the home volume and on an external volume) and records the result.

## Open for whoever has a sandboxed, provisioning-signed build

1. Run `git --version` through `ShellReader` from the sandboxed app. Expected: `launchFailure`; if it succeeds, the
   degrade path is simply never taken.
2. Round-trip a temp folder through `trashItem` + `removeItem(resultingItemURL)` on the home volume and on an external volume.
3. Confirm the *Choose folders…* bookmark flow (`NSOpenPanel` → security-scoped bookmark → `scanRoots`) reads a project tree.
