# Reference apps — build tvOS/macOS to MATCH these exactly

The earlier tvOS/macOS pass was done **blind** (the real apps weren't available), so the 10-foot /
desktop UX was guessed from a written description. These are now the **actual shipping apps**.
Use them as the source of truth and make the Apple TV / Mac targets match them — layout, row order,
colors, spacing, focus/hover behavior, player controls. This folder is reference ONLY (it is not in
any Xcode target's `sources`, so it never compiles into the app).

## Apple TV target → match `android-tv/` (the Firestick app)
The Firestick UI is built **programmatically in Kotlin**, not XML — so the real reference is the code:
- **`MainActivity.kt`** (~386 KB) — the whole leanback shell: tab/row order, Home hero + Top 10 +
  Continue Watching, focus handling, catalog rows, Live TV tab, Settings. This defines the
  Apple-TV look you must reproduce. Read the row-building and focus code closely.
- **`PlayerActivity.kt`** — player overlay: control layout, skip-intro/recap/after-credits pills,
  subtitle/audio panels, resume behavior. Match the tvOS PlayerView to this.
- **`Sheets.kt`** — bottom-sheet menus (poster long-press actions, stream picker).
- **`EpisodeAdapter.kt`** + `res/layout/item_episode.xml` — episode row cell.
- **`res/colors.xml`, `res/styles.xml`** — exact brand colors + text styles. Use these values.
- `res/layout/*.xml` — the few XML layouts (player, controls, episode item).

## Mac target → match `desktop/` (the Electron desktop app)
- **`style.css`** (34 KB) — the definitive desktop look: colors, tile sizes, grid, sidebar, hero,
  hover states. Port these to the macOS SwiftUI window.
- **`app.js`** (152 KB) — desktop renderer behavior: sidebar nav, hero rotation, hover-to-pause,
  row layout, details/stream flow, Live TV guide. Match interaction patterns.
- **`ck-web.js`, `catalog.js`** — shared web/catalog logic (row composition, catalog fetch).
- **`index.html`** — page/window structure.

## Rules (unchanged from MULTIPLATFORM.md)
- One bundle id `app.couchking.ios`, shared Swift sources under `CouchKing/`.
- **NO downloads anywhere** — streaming only, App Store safe.
- CI (macos-15) is the only compiler: push, poll, read the build-log artifact on failure, keep
  master green. Signing/TestFlight is owned by the main session — don't touch those lanes.
- No hardcoded secrets exist in these files (verified); the only key is the public TMDB key already
  in `IOS_CONTRACTS.md`.
