# CouchKing — macOS + tvOS build brief (for the cloud agent)

**Goal:** ship the existing iPhone SwiftUI app as a **universal app** that also runs natively on
**Apple TV (tvOS)** and **Mac (macOS)**, from this same codebase, to the same App Store record.
The iPhone target is DONE and shipping to TestFlight — do **not** regress it. Add the two new
platforms alongside it.

Standing order from the owner (AJ): every platform must match the Android app "to a T" —
same features, same sync, same tracking. Treat every Android/iOS feature as a tvOS/macOS TODO.

---

## Ground truth

- Repo: `github.com/CouchKing/couchking-ios`, branch `master`. Push directly (org repo is public;
  private macOS runners are billing-blocked — do NOT flip it private).
- **Apple Team ID: `9DQ4PK94U6`**. **Shared bundle ID for ALL platforms: `app.couchking.ios`**
  (universal purchase = one bundle ID across iOS/tvOS/macOS; do not invent new ones).
- Build system: **XcodeGen** (`project.yml`), no `.pbxproj` in git. Add a file by dropping it in
  `CouchKing/`; add a target by editing `project.yml`.
- CI: `.github/workflows/build.yml` on **macos-15** (Xcode 16 — required; XcodeGen emits project
  format 77 that Xcode 15 can't read). CI compiles with `CODE_SIGNING_ALLOWED=NO`, uploads a
  `build-log` artifact on failure. **CI is the only compiler — there is no local Mac.** Push,
  poll the run, read the `build-log` ARTIFACT on failure (job-logs API returns empty zips for
  this org). Never leave `master` red.
- Contracts: `IOS_CONTRACTS.md` (auth/state/resume/TMDB/Live TV — all real, verified). Parity
  checklist: `PARITY.md`. Android reference: `/data/couchking-tv/...` (not in this repo).

## Codebase shape (18 Swift files, near-pure SwiftUI)

Almost everything is portable as-is. Only **two files** touch iOS-only UIKit and need `#if os()`
shims:

- `CouchKing/Views/DetailView.swift`
  - L71 `UIApplication.shared.open(u)` — provider "where to watch" link. macOS → `NSWorkspace.shared.open`; tvOS → hide the link (no browser).
  - L250-267 `WKWebView` trailer player. **WKWebView does NOT exist on tvOS.** macOS → WKWebView via `NSViewRepresentable`; tvOS → play the trailer through `AVPlayer` (YouTube embed won't load; use the addon trailer wrapper only if it returns a direct stream, else hide the trailer button on tvOS).
- `CouchKing/Views/PlayerView.swift`
  - L541 / L1099 `UIApplication.shared.isIdleTimerDisabled` — iOS-only. Wrap in `#if os(iOS)`; macOS/tvOS don't need it.

Everything else (`Core/*` networking/sync/state-merge/catalog/TMDB, `HomeView`, `Search/Browse`,
`Library`, `SettingsView`, `LiveTVView`, `EpisodesView`, `StreamSheet`) is plain SwiftUI + AVKit
and should compile on all three platforms unchanged or with trivial guards.

---

## Work plan

### 1. project.yml — add two targets sharing the same sources
All three targets set `PRODUCT_BUNDLE_IDENTIFIER = app.couchking.ios`, `MARKETING_VERSION 1.0.0`,
`CURRENT_PROJECT_VERSION 1`, `DEVELOPMENT_TEAM = 9DQ4PK94U6`. Reuse `sources: [CouchKing]` for all.

```yaml
  CouchKing-tvOS:
    type: application
    platform: tvOS
    deploymentTarget: "17.0"
    sources: [CouchKing]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.couchking.ios
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        DEVELOPMENT_TEAM: "9DQ4PK94U6"
        SWIFT_VERSION: "5.9"

  CouchKing-macOS:
    type: application
    platform: macOS
    deploymentTarget: "13.0"
    sources: [CouchKing]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.couchking.ios
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        DEVELOPMENT_TEAM: "9DQ4PK94U6"
        SWIFT_VERSION: "5.9"
        # macOS app sandbox: allow outgoing network for the API + video
```
Set the deployment target / Info.plist per platform. Add `com.apple.security.network.client`
sandbox entitlement for the macOS target.

### 2. Compile clean on both, one platform at a time
- Fix the 3 shim sites above with `#if os(iOS)/os(macOS)/os(tvOS)`.
- Expect a handful more: `NavigationView`/toolbar placement differ on macOS; `.navigationBarTitle`
  is iOS/tvOS only; `Color(UIColor…)` → `Color(nsColor…)` on macOS; `onTapGesture` vs focus.
- Commit in small batches, push, watch CI go green for the new targets before moving on.

### 3. tvOS is the real work — the focus engine
tvOS has **no touch and no cursor**; everything is remote/focus-driven. Standard SwiftUI controls
(Button, List, TabView) get focus for free, but the custom poster **grids/rows** need
`.focusable()`, `@FocusState`, and `.focusSection()` so the Siri Remote can move between rows and
the selected tile scales/highlights (tvOS "shelf" feel). The player overlay (skip-intro/recap/
after-credits pills, subtitle toggles) must be reachable with the remote's play/pause + swipe.
Mirror the Android TV app's navigation model (`/data/couchking-tv` MainActivity) for row order and
focus behavior. This is the bulk of the effort — budget most of the tvOS time here.

### 4. macOS polish
Native window, resizable grid, hover states, keyboard shortcuts (space = play/pause, arrows).
Menu bar minimal. Note: a separate Electron desktop app exists for Mac already — this native
build is additive; keep it simple and parity-focused, don't rebuild desktop-only features.

### 5. CI — add compile jobs (signing comes later, separately)
Add `compile-tvos` and `compile-macos` jobs mirroring the iOS `compile` job:
`xcodebuild -scheme CouchKing-tvOS -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build`
and `-scheme CouchKing-macOS -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build`.
Upload `build-log` on failure. **Do not** add signing/upload lanes — the main session owns the
App Store Connect API key + TestFlight lane and will add tvOS/macOS to the same record once these
compile green.

## Definition of done
- All three targets compile green on macos-15 CI.
- tvOS: full remote-driven navigation, every Home row + Library + Live TV + Search + Details +
  Player reachable and usable with the Siri Remote; playback with skip/subtitle controls works.
- macOS: window app, browse + play + settings + sync all work.
- Sync is identical across all platforms (same `/tvapp/state` push/pull, same profile prefs) —
  a change on Apple TV shows on iPhone/Android and vice versa.
- `PARITY.md` gets tvOS/macOS status columns (or a note) so the grind is trackable.
- `master` never left red; each platform's first green run noted in the PR/commit.

## Gotchas (learned the hard way)
- macos-15 runner only (Xcode 16 project format).
- Release device builds split into stub + dylibs unless `ENABLE_DEBUG_DYLIB=NO` — matters only for
  the IPA lane, not compile.
- Read the **artifact** for errors, not the job-log API (returns empty zips for this org).
- Don't enable Apple capabilities (Push, iCloud, Sign In with Apple) — the app uses none; extras
  trip review.
