# CouchKing iOS — Specification (Sep 25, 2026)

Goal: feature parity with the Android app (v2.0.93), native for iPhone (iPad later),
distributed on the Apple App Store.

## Store strategy (the part that decides everything)

Apple is stricter than Google/Amazon. We use the SAME angle that got the Play/Amazon
builds approved, hardened for Apple review:

- **Ships as a TRACKER app**: discovery (Trending/Fresh/Top/service rows), search,
  trailers, where-to-watch (TMDB providers), library/watched tracking, profiles,
  thumbs ratings — fully functional for a reviewer with NO account.
- **Nothing baked in**: no addon URLs, no stream hosts, no "CouchKing service" strings
  in the binary. Streaming appears only after a user signs in AND their account has an
  addon assigned (server-side whitelist, exactly like the Android store flavor asking
  its user-entered service base).
- **In-app playback via AVPlayer** with the existing `/webplay` fMP4 remux (H.264 +
  AAC stereo) — the same endpoint the web app uses, so no codec surprises on iOS.
- No downloads in v1 (that's what triggered the Play FGS demo-video problem).
  No external-store deep links (the Amazon lesson). Live TV addon-gated like Android.

## What AJ must provide (blockers, in order)

1. **Apple Developer Program** enrollment — $99/yr, developer.apple.com, use the
   business Apple ID. Individual enrollment is fine (no D-U-N-S needed).
2. Once enrolled: **App Store Connect API key** (Users & Access → Integrations →
   App Store Connect API → Team key, role: App Manager). Download the .p8 — that goes
   into GitHub secrets so CI can sign + upload to TestFlight with zero Mac needed.
3. **App record** in App Store Connect: name "CouchKing" (check availability; fallback
   "CouchKing TV Tracker"), bundle id `app.couchking.ios`, primary category
   Entertainment.
4. Privacy policy URL (reuse couchking.app one) + support URL.
5. A **demo account for review** with NO addon (tracker mode) — reviewers must see a
   complete tracker app.

## Architecture

- **SwiftUI**, iOS 16+, no third-party deps (URLSession + AVKit only) — fewer review
  surface areas, no dependency licenses.
- Same backend, zero new server work:
  - `POST /tvapp/login`, `POST /tvapp/state` (profiles, watchlist/watched/continue,
    prefs, thumbs `ratings {id:{v,ts}}` — per-id newest-ts merge, same as Android)
  - addon manifest/catalog/stream endpoints (user's assigned addon URL from
    `/torrent/tvaccess` check at sign-in, delivered by the server — never baked)
  - `/webplay?u=<b64url>&t=<sec>` for playback, `/webplay/start` for seek offset
  - TMDB for search/meta/providers (key delivered by server config at runtime, not
    compiled in)
- Project generated with **XcodeGen** (project.yml in repo — no .pbxproj merge hell),
  built + TestFlight-uploaded by **GitHub Actions macOS runners** (same pattern as the
  desktop app's CI). CI compiles on every push = our compile check from the Linux box.

## Feature parity map (Android → iOS)

| Android (2.0.93) | iOS v1 | Notes |
|---|---|---|
| Sign in / accounts | ✅ | same endpoints |
| Netflix-style profiles (5) | ✅ | per-profile state, same tags |
| Home rows (CW, For You, Trending, services, Marvel-in-order) | ✅ | addon catalogs; Marvel rows exact order |
| Search + people | ✅ | |
| Details: trailer/library/eye/👍👎 | ✅ | identical semantics incl. ratings ts |
| Player: subs, audio tracks, speed, skip-intro/recap/credits, after-credits, autoplay-next | ✅ core; skip windows from `/player/resume` | AVPlayer + webplay |
| Live TV (addon-gated) | ✅ v1.1 | HLS plays natively on iOS |
| Offline downloads | ❌ v1 | sideload-only feature on Android too |
| Mandatory update gate | ✅ | `/tvapp/store-version`-style check, deep link to App Store |

## Phases

1. **Scaffold** (this repo, now): app shell, sign-in, profiles, state sync, Home rows,
   details w/ thumbs, AVPlayer + webplay, tracker guest mode. CI compiling green.
2. **TestFlight**: AJ enrolls; wire signing secrets; internal build on his iPhone.
   Iterate to parity (player polish, Live TV, skip buttons, subtitles).
3. **Review submission**: tracker-mode demo account, screenshots, metadata.
