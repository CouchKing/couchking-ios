# CouchKing iOS — Android Parity Checklist (audited Sep 25, 2026)

Reference: Android app 2.0.93 line — `/data/couchking-tv/app/src/main/java/app/mediaboard/`
(MainActivity.kt ~6,044 lines, PlayerActivity.kt ~1,701, Store.kt, Discovery.kt, Addons.kt,
Sync.kt, Updater.kt, Trailers.kt, Sheets.kt, Legal.kt). iOS state: this repo as of the
scaffold + Session/Player session (all Swift files read line-by-line).

Legend: ✅ done · 🟡 partial (what's missing noted) · ❌ missing.
Android references are file + function/rough line so the implementer can read the exact behavior.

---

## 1. Auth & Accounts

- ✅ Sign in / sign up via `POST /tvapp/auth` (email+password, create w/ name, token stored) — `Sync.auth` (Sync.kt L27), iOS `Session.signIn`
- ✅ Sign out (clears email/token) — `showSettings` sign-out row (MainActivity ~L5615)
- 🟡 Sign-out semantics: Android **stashes** the whole account locally (profiles, addons, every profile's library) and restores it on re-sign-in, clears addons + content + Live TV + http cache so a guest starts clean. iOS just clears email/token — addons/state/liveTvOn survive sign-out. — `Store.stashAccount/unstashAccount/clearContentState` (Store.kt L73-96)
- ❌ Content-owner guard: signing into a DIFFERENT email wipes the previous owner's local library first (nothing commits until credentials are accepted — the auth order matters) — `Sync.auth` + `Store.contentOwner` (Sync.kt L27-60, Store.kt L53)
- ❌ Forgot password flow — `showForgotPassword` (MainActivity ~L575)
- ❌ Delete account (server-side delete — Apple requires this for apps with account creation) — `Sync.deleteAccount` (Sync.kt L95), Settings row (MainActivity ~L5637)
- ❌ Onboarding + Terms/Privacy acceptance gate before first use (guest mode starts only after accepting; full legal text in-app) — `showOnboarding`/`gate`/`termsLinksRow`/`Legal.kt` (MainActivity ~L511-548)
- 🟡 Access/expiry status: Android caches `expires`/`daysLeft` from `/tvapp/access`, shows "Access through … · N days left" / "⛔ expired" on the Settings account card, and an expiry banner **in the stream list** at play time (browse never blocked). iOS calls `/tvapp/access` only for addon auto-assign. — `Addons.access` (Addons.kt L32), `isExpired`/`expiryBanner` (MainActivity ~L413-431), Settings card (~L5590)
- ✅ Addon auto-assign after sign-in (service hands the addon URL; nobody pastes) — `checkAccessThen` (MainActivity ~L5944), iOS `Session.checkAccess`
- ❌ Silent re-check on every foreground/Settings open: addon assigned AFTER sign-in appears on next app open without visiting Settings — `onResume` (MainActivity ~L259-321)
- ❌ Device-cap / capacity gating messages (429/503/403 from stream gate → centered CouchKing modal with reason: "already watching on another device", "full capacity", "not on your plan") — `liveTune` gate + `showTopBanner` (MainActivity ~L2427-2500)

## 2. Profiles

- ✅ Profile picker "Who's watching?" grid — `showProfilePicker` (MainActivity ~L760), iOS `ProfilePickerView`
- ✅ Profile CRUD, max 5, tombstoned deletes (`profilesRemoved`), mt stamps — `Store.addProfile/renameProfile/deleteProfile` (Store.kt L118-148)
- 🟡 Avatar picker: iOS has 12 emoji; Android has avatar **and color** picker (profile hue drives the avatar tile color everywhere) — `addAvatarColorPicker`/`profileColor`/`profileHue`/`avatarView` (MainActivity ~L742-878)
- 🟡 Profile gate on launch: Android forces the picker when >1 profile and none picked, re-gates after sign-out, and handles "profiles arrived late after a failed first pull" WITHOUT rebuilding the picker mid-scroll (the cold-open cursor-jump fix). iOS `needsProfilePick` covers the basic gate only. — `profileGate` + late-sync guard (MainActivity ~L707, ~L259-321)
- ✅ Per-profile state blob (`states[pid]`), per-profile prefs (2.0.93 `activeProfile` guard on push) — Store.kt profile scoping, iOS `Session.pstate/setPstate`
- 🟡 Profile identity on every addon call: Android swaps `userName: "AJ #b9e1"` INTO the addon URL's config segment (`Addons.withUser`, Addons.kt L84-99) so For You/clicks/streams attribute per person. iOS appends `?u=` as a query param instead — verify the server honors the query form for catalog/stream/foryou, or switch to config-segment rewriting to match Android exactly.
- ❌ Switching profile clears per-profile content in memory + repaints instantly (mt-stamp picker repaint when another device edits profiles; 60s pull refreshes picker if changed) — `switchProfile`/`clearProfileContent` (Store.kt L149-166), `refreshPickerIfChanged` (MainActivity ~L364)
- ❌ Per-profile daily shuffle of category rows (`profileMix` — same category ≠ same order every day, differs per person) — MainActivity ~L942

## 3. Home & For You

- 🟡 Home rows: iOS fetches 7 hardcoded addon catalogs in parallel. Android Home = Continue Watching → Top 10 Today → For You Movies/Shows → user's chosen shelf lineup in user order, rows filling top-down sequentially (2.0.82 loading style AJ mandated — no skeletons). — `buildShelvesInto` (MainActivity ~L2507-2690)
- 🟡 For You: iOS hits `couchking-foryou-movies/series` catalog ids directly. Android discovers any manifest catalog named "for you" per type (nothing hardcoded), passes the profile via config segment, and has a full guest/tracker fallback chain: addon algo → TMDB rec graph seeded by continue+watchlist+watched → trending. — `Addons.forYouType` (Addons.kt L102), `forYouRows` (MainActivity ~L3363)
- ❌ Continue Watching row on Home: progress bars on tiles, stamp-sorted (newest watch stamp), "+N new episodes" badge that floats the show to the front AT ITS AIR TIME (`cwOrder` = max(watch stamp, badge'd air time)), badge dismissed on open — `addRow(withProgress)`/`newEpisodeCount`/`cwOrder`/`dismissNewEpsBadge` (MainActivity ~L2540-2570, L3390-3458). iOS shows CW only as a plain row in Library.
- ❌ CW resume-on-tap: tapping a CW tile resumes the right episode directly (`resumeFromCw`, `cwLast` per-title last-episode pointer, `cwProgress` %) — MainActivity ~L3188, Store.kt L696-713
- ❌ Top 10 Today row (giant ghost rank numerals behind posters, interleaved trending movies+shows) — `addTop10Row` (MainActivity ~L2691)
- ❌ Hero: rotating trending carousel (7 items, arrows + swipe fling on mobile; on TV an idle showcase narrating the top board every 9s, pausing while browsing) — `buildHeroPager` (~L4213), `buildTvBoard` (~L4007)
- ❌ Movies / Shows / Anime as separate browse tabs (Anime = TMDB Animation ∩ Japanese origin, 4 rows + hero; Movies/Shows = `Discovery.MOVIE_ROWS/SHOW_ROWS`) — `buildShelvesInto` (~L2580-2607), Discovery.kt
- ❌ Discover tab: type/catalog/genre/year dropdown-driven grid (genre chips on Details deep-link into it) — `buildDiscover` (MainActivity ~L2941)
- ❌ Customizable shelves: Settings → Shelves picker (grouped pill chips) + Reorder screen, synced to the account (debounced push so the 60s pull can't revert) — `showShelfPicker`/`showShelfReorder`/`persistShelves` (MainActivity ~L5759-5882), `Store.enabledShelves`
- ❌ Curated watch-order rows (Marvel chronological etc. — `ids` rows rendered in EXACT order, never shuffled) — `Discovery.SHELF_CATALOG` ids rows, `idsRow` (~L2678)
- ❌ Guest/tracker Home: TMDB-powered discovery rows when no addon (the store-review experience — SPEC.md relies on this) — `buildShelvesInto` FORYOU/tmdb branches
- 🟡 Poster tiles: iOS has poster + optional title. Android adds: watchlist ✓ badge, watched "done" badge, progress bar variant, new-eps badge, long-press context menu, focus ring, lazy art loading with viewport pass. — `poster`/`wlBadge`/`doneBadge` (MainActivity ~L3209, L3720-3742)
- ❌ Long-press/context title menu: Details / Add-Remove Library / Mark Watched-Unwatched / Clear Progress (single option = leaves CW), all mutating tiles IN PLACE without page rebuild — `titleMenu`/`repaintTiles`/`removeTileInPlace` (MainActivity ~L3459-3817)
- ❌ Live cross-device refresh while Home is open: 60s foreground pull + in-place Continue row/episode-bars repaint; also on every foreground resume (player-driven `homeStale` flag) — `liveSyncTick`/`refreshContinueRow`/`refreshEpisodeBars` (MainActivity ~L335, L3580-3650). iOS has the 60s pull in `Session.boot` but nothing repaints rows in place.

## 4. Search

- 🟡 Search runs only on submit on iOS. Android: live-as-you-type with 450ms debounce, results replace in place — `buildSearch` (MainActivity ~L2743)
- ✅ Movies + Shows sections from addon search catalogs
- ❌ People search: person cards strip → person page (filmography via `Discovery.searchPeople`/`showPerson`) — MainActivity ~L2779, L5456-5530
- ❌ Cast/director chips anywhere → person page (iOS cast chips are inert text)
- ❌ Search state restore: backing out of a result restores query + results, no keyboard grab — `buildSearch` restoring branch (~L2751)
- ❌ Live TV search integration: Android's Live TV tab search also finds shows airing in the next 96h ("channel + when") — `renderSearch` (buildLiveTvBody ~L1710)

## 5. Details & Episodes

- ✅ Header: poster, name, year, rating, description — `showDetail` (MainActivity ~L4296)
- 🟡 Android header extras: backdrop image with gradient, show LOGO image instead of text when available, runtime, genres as tappable chips → Discover pre-filtered — ~L4306-4360
- ✅ Action row: Trailer / Library toggle / Watched eye (movies only) / 👍 / 👎 with correct semantics (thumbs `{v,ts}`, toggle-off, mutual exclusion)
- 🟡 Android action row also has: hover/focus narration label beside icons, and (full flavor) the movie Download button — ~L4366-4425
- 🟡 Trailer: iOS opens YouTube in Safari. Android resolves innertube on-device (IOS client HLS first) → in-app `TrailerActivity` player → YouTube app fallback; store flavors keep it in-app (store neutrality). — Trailers.kt, `playTrailer/playTrailerEmbed/playTrailerExternal` (~L5532-5562)
- ❌ Where-to-watch provider chips for guests/tracker users (TMDB providers; stream chips accented, Rent·/Buy· chips; hidden when the user has an addon; "🎬 In theaters now" notice for recent movies with no providers). Store-flavor split: PLAY = rent/buy links only, AMAZON = plain labels no click-through — the iOS store build must follow the same pattern. — `showDetail` providers block (~L4478-4524), `openProvider`/`Links` (~L2735)
- 🟡 Movie streams: iOS = "Play" button → sheet. Android = streams auto-load inline on the page (Stremio behavior), expired banner inline, retry copy — ~L4452-4477
- ✅ Stream list rows (name + title/description)
- 🟡 Android stream extras: `ckExpired` marker → expiry banner instead of empty list; `ckNotice` flag; ONE quiet retry (900ms) so a dropped request never reads "no streams"; no-streams telemetry — `Addons.streams/debugNoStreams` (Addons.kt L140-178)
- ❌ Auto-poll when no streams: page polls until the background download/warm lands instead of dead-ending — ~L4873, L5332
- ✅ Season picker + episode list with thumbs, air dates
- 🟡 Episode rows Android extras: unaired 📅 badge with real air date, per-episode progress bars refreshed live (`refreshEpisodeBars`), current-episode highlight, episode Download button (full flavor) — `buildEpisodes`/`epCard`/`epRowV` (~L4539-4805)
- ✅ Per-episode watched eye toggle with scoped `wt:` tombstones
- ❌ Episode detail page (tap episode title → overview, air date, mark-watched, streams) — `showEpisodeDetail` (~L4806)
- ✅ Cinemeta fallback for meta when no addon
- ❌ TV-layout detail/episode variants (`showDetailTv`, `buildTvEpisodeStrip`, `tvPageShell`) — N/A for iPhone v1; needed if iPad/tvOS TV-style later

## 6. Player

- ✅ Playback with resume (local positions map, server `/player/resume` pos fallback, >2min threshold)
- 🟡 Resume conflict: Android also reconciles mid-play against server state (another device ahead by >60s, same-episode check) — PlayerActivity `start()` server-state block (~L586-626)
- ✅ Skip Intro / Skip Recap pills from `/player/resume` windows
- 🟡 Skip behavior details missing on iOS: recap-before-intro precedence with `*Handled` latches (don't re-show after skipping/crossing), 2s tail exclusion, animated slide-in, auto-focus with re-grab guard, and seek-discontinuity detection (`pendingIntroFrom`) — ticker (~L694-740), `onPositionDiscontinuity` (~L542)
- 🟡 After-credits: iOS shows a jump pill gated on `credits`. Android computes a floor = max(finishPoint, stinger−90s, prev stinger end), supports MULTIPLE stingers with "(1/2)" sequential labels, stateless re-offer by position, and a one-time "🎬 This movie has a scene during/after the credits" toast ~4min out — ticker (~L700-712), stinger nudge (~L778-785)
- ❌ Credits/finish point learned from subtitles: last SRT cue + 2s = credits start (`lastSrtCueMs` → `currentLeadMs`/`finishPointMs`) — drives next-up timing and mark-watched — ~L586-592, L825-841
- ✅ Autoplay next episode (pref-gated)
- 🟡 Next episode resolution: iOS re-fetches `/stream/series/<id:s:e+1>` and takes streams[0]. Android resolves via `Ck.resolveEpisode` with a **prefetch** starting 5min before the end (instant advance), season-crossing `nextEpisode()` from the real episode list (not e+1 guessing — breaks at season ends), and manual-next handling — `prefetchNext`/`playEpisode`/`nextEpisode` (~L906-1015)
- ❌ Next-Up card at credits time: thumbnail (blurred if unwatched + pref), title, Play/Dismiss, auto-focused, never interrupts; shown by time-remaining OR crossed-credits-point — `showNextUpCard`/`hideNextUp` (~L1062-1096, L1230)
- ❌ **"Are you still watching?"** (just shipped on ALL other surfaces — required): after 2 consecutive fully-input-less auto-advanced episodes, crown + "Are you still watching?" modal (Keep watching / I'm done), BACK = Next-Up card + chain reset, no answer in 5 min = stop playback and exit. `epTouched`/`idleEps` chain: any user input during an episode resets the chain. — `onEnded`/`showStillWatching` (PlayerActivity ~L1115-1229)
- ❌ Mark-watched on finish (position ≥ finishPoint at exit/end → episode/title watched, resume cleared; force-mark exempts only real resume ≥2min start — the false-watched@4% fix), `Ck.clearResume` on ended — `markWatchedIfDone` (~L842-873), `onEnded`
- ❌ Progress heartbeat to server: instant start-stamp (the moment playback starts, stamp + push so other devices resume-target immediately), report at 20s then every 30s, account push every 90s, **zombie guard** (frozen position = no beat/no push), `Ck.reportServer` — ticker (~L745-777). iOS saves position + CW entry only on dismiss — loses everything on crash/kill, no cross-device mid-episode pickup.

- 🟡 Subtitles: iOS = one auto-picked track rendered as overlay. Android: ranked multi-track list (addon `subtitles` json, English-best-first, up to 12), embedded-subs via `/webplay/subx`, side panel that STAYS OPEN with live-apply (size incl. Tiny, background, outline, position raised/high), off toggle, `flashLabel` pill on change — `subtitleOptions`/`showSubtitleSidePanel`/`applySubtitle`/`applySubScale` (~L1250-1367)
- ❌ Audio track picker (language pref default, `audioLang`) — `showAudioPicker` (~L1368)
- ❌ Playback speed picker (ends-at time recomputed by speed) — `showSpeedPicker` (~L1395)
- ❌ Aspect/scale cycle (fit/fill/zoom, `scaleMode` persisted) — `applyScale`/`cycleScale` (~L1411-1431)
- ❌ Seek step pref applied to seek controls/gestures (5/10/15/30s) — `Store.seekStepSec`, init (~L483)
- ❌ In-player episode panel: season tabs + episode strip, focus lands on current episode — `toggleEpisodePanel`/`buildSeasonTabs`/`showSeason`/`focusCurrentEpisode` (~L1016-1052, L1467-1491)
- ❌ Clock + "Ends 9:47 PM" readout (suppressed in live mode — rolling HLS duration lies) — ticker (~L656-668)
- ❌ Stats overlay (resolution/fps/refresh/dropped frames) — `updateStats` (~L800)
- ❌ Branded loading screen (channel/show logo pulse before first frame) — `buildLoadingScreen` (~L301)
- ❌ Placeholder/unaired handling: stream that lands on the "not yet available" clip loops it, hides Ends/skip UI, re-probes every 20s and hot-swaps to the real file when it lands — `maybeDetectPlaceholder` + placeholder branches (~L1097, ticker)
- ❌ Keep-screen-on (iOS: `UIApplication.shared.isIdleTimerDisabled` while playing) — Android window FLAG_KEEP_SCREEN_ON fix (Sep 18)
- 🟡 `/webplay` remux fallback exists on iOS (4s failed-status probe, carries `t=` offset) — but no mid-play stall fallback, only on initial open.
- ❌ Player error handling → retry/failover messaging — `onPlayerError` (~L538)
- ❌ Live mode: no Ends/resume/heartbeat, logo loading screen, live-window seeking semantics — `liveMode` branches throughout PlayerActivity
- ❌ Chapter windows via stream extras beyond `/player/resume` (Android also accepts `windows` intent extra with the stream) — `start()` (~L421-446)

## 7. Live TV

- 🟡 Tab gating: iOS detects a `tv` catalog in the manifest (same as Android `detectLiveTv`), but Android re-detects on every resume/sign-out (tab appears/disappears live, instantly on addon-add) — MainActivity ~L99-125
- ❌ **Playback wiring (AJ priority #1)**: tap channel → tuning screen (logo + "Tuning ESPN… / Now: <program>") → `/stream/tv/<id>.json` → pick HLS vs `ckTs` hub feed (hub .ts ONLY for `24-7-*` loop channels; HLS first for everything else) → **access gate probe** (429 device-cap / 503 capacity / 403 no-access → centered modal with reason, never a spinning player) → play; on back: guide re-align to NOW + cursor back on that channel — `liveTune` (MainActivity ~L2383-2452)
- ❌ Locked-plan state: catalog returning single `cklive:upgrade` meta → full-screen 🔒 "Live TV — Locked / not part of your plan" banner, nothing clickable — `buildLiveTv` (~L1610-1637)
- ❌ Guide grid: per-channel horizontal timelines (4px/min), pinned channel column, pinned header with date + scroll-synced time ticks, **red now-line**, half-hour-aligned start, Today scrolls 72h continuous, chunked lazy row fill (`vFill`/`vSweep`/`pump`) — `liveRenderGuide` (~L1878-2245)
- ❌ Day tabs: Today / Tomorrow / weekday / weekday+3 (4 tabs, 96h server window), refocus-after-rerender fix — ~L1880-1906
- ❌ Category chips: Guide / ★ Favorites / server sections / Local / 24-7 / All Channels — repaint in place, no full rebuild (cursor-jump fix), state persisted (genre/region/day) — `buildLiveTvBody` chips (~L1740-1815), `liveSaveState` (~L1554)
- ❌ Region dropdown (USA/UK/Canada) app-styled picker, per-region content — ~L1644-1676
- ❌ Live search box: channels + upcoming shows (96h), debounced, stale-response guard — `renderSearch` (~L1706-1723)
- ❌ Sports banner: per-sport strips only when that sport has a live game, + Upcoming strip, region-aware, game cards tune to per-game event feeds — `liveRenderBanner`/`liveGameCard` (~L1819-1877)
- ❌ Favorites: long-press star toggle (server-side per-PROFILE `p=` param), ★ FAVORITES section first in guide, local cache patch so the star shows instantly, Favorites chip view — `liveFavToggle` (~L2249), guide fav grouping (~L1936-1960)
- ❌ ↻ Continue Watching strip (recently tuned channels from guide.json `recent`) — ~L1908-1935
- ❌ LIVE badge / now-playing program title + time on channel rows — `liveNowTitle`/`liveRow` (~L2275-2382)
- ❌ Guide staleness: back from live player rebuilds guide centered on NOW + restores cursor to the watched channel — `liveGuideStale`/`liveFocusId`/`liveRestoreFocus` (~L78-87, onResume)
- ❌ Live TV leaves with the account on sign-out (tab drops immediately, manifest cache flushed) — sign-out row (~L5620)
- Note: hidden/dead channels + hide-channel (TG `/hidech`, `_lvDeadEvtGrp`) are SERVER-side — no client work beyond rendering what the server sends.

## 8. Library & Continue Watching

- 🟡 iOS Library = three plain rows (CW / My List / Watched). Functional but not the Android model below.
- ❌ Library = **watchlist only** (AJ rule: "why is stuff I clicked play on in my library?") — CW and watched history are NOT the library; Watched/Unwatched are sorts within your list — `buildLibrary` (~L2819-2837)
- ❌ Filters (All/Movies/Shows chips) + sort cycle (Recent / New episodes / A–Z / Z–A / Watched / Unwatched); "New episodes" is a real filter (only shows with unwatched new eps, most-new first) — ~L2853-2890
- ❌ Library search box — ~L2825
- ❌ "All" = Movies section first, Shows underneath, chunked rows of 15 (rows everywhere, no columns) — ~L2867-2890
- ❌ New-episode badges in Library grids — `paintGrids(counts)` (~L2853)
- ❌ CW ordering + resume semantics (see §3: `cwOrder`, `cwLast`, progress %, Clear Progress = leave CW with server tombstone `syncClear`) — Store.kt L649-786, MainActivity ~L4525
- 🟡 Scoped tombstones: iOS stamps `wl:`/`wt:` on add/remove (matches the scoped-ledger fix) but never writes `cw:` scope for continue removals, and CW entries lack the position-stamp the server sorts by — Store.kt `noteAdded/noteRemoved/tombstonedIn` (L586-611)
- ❌ Union merge on pull: Android merges remote+local (`importMerge`/`blobUnion` — ts-union per key, tombstone dead-checks, nothing ever lost); iOS `apply()` REPLACES local state with the server blob — offline changes since last push are dropped — Store.kt L273-489

## 9. Settings & Prefs Sync

- ✅ Settings screen with Account / Profiles / Addons / Player / Look sections
- ✅ Per-profile synced prefs helpers (pref/setPref → profile blob → push)
- 🟡 Pref keys/values parity: Android keys are `subScale` (0.8/1.0/1.3/1.6), `subLang` (**"en"|"off" ONLY** — AJ: "either English or off"; iOS offers Spanish → remove), `autoplayNext`, `seekStep` (5/10/15/30 — iOS lacks 5), `blurUnwatched`, `subBg` (default **false** on Android, iOS defaults true), `subOutline` (default true — missing on iOS), `subPos` (missing), `scaleMode` (missing), `audioLang` (missing), `showTitles` — Store.kt L807-843. Align keys+defaults exactly or cross-device prefs will disagree.
- ❌ Subtitle live preview box in Player settings (shows exactly what the options produce) — `showPlayerSettings` (~L5703-5720)
- ❌ Shelves picker + Reorder (see §3)
- 🟡 Addons: iOS has add-by-code + remove. Android: addons section signed-in only (guests get a sign-in prompt), `Addons.probe` validates + names the manifest before adding, silent service-assignment refresh on open — `showAddons` (~L5883)
- ❌ "Sync library now" row — ~L5612
- ❌ Account card with expiry/days-left/lifetime/expired states (see §1)
- ❌ Legal & About page with full in-app Terms + Privacy text (Legal.kt — App Store review wants reachable terms; iOS links out to couchking.app only) + version row — `showAbout`/`showTerms`/`showPrivacy` (~L5743, L958-980)
- 🟡 Blur pref honored on episode thumbs (iOS has it) but not on the next-up card / other art — `applyUnwatchedBlur`/`loadEpThumb` (Store.kt L847-908)

## 10. Updates & Gates

- ❌ Store mandatory-update gate: fetch `<serviceBase>/tvapp/store-version`, compare `minVersion` vs app version (numeric segment compare, `Updater.newer`), below-min → BLOCKING screen, one button deep-linking to the App Store listing. Nothing baked — the check rides the user-entered service base at runtime (store neutrality). — `showStoreMandatoryUpdate` (MainActivity ~L470-510), Updater.kt L54
- N/A Sideload self-update (Updater.kt APK path) — impossible on iOS; the store gate above is the entire requirement.
- ❌ Re-check on foreground + stale-gate clearing once updated — `attachUpdatePill`/onResume (~L392, L325-333)
- ✅ `appVer` on every state push (server-side version awareness) — iOS sends `ios-1.0.0`; keep it bumped per release.

## 11. Downloads / Offline

- ❌ (Deliberately out of iOS v1 per SPEC.md — Android has it ONLY in the full sideload flavor; Play/Amazon ship a `Downloads.ENABLED=false` stub with the whole branch dead-compiled.) If ever built for iOS it must be OFF in the App Store build: Downloads tab (addon-gated like Live TV), movie download button on Details, per-episode buttons, `/dlpick` lean-pick server offer (smallest H264/tier with real GB) — Downloads refs (MainActivity ~L51-58, L1014, L4418-4424, L4738-4743)

## 12. Misc UX

- 🟡 Back-stack page restore: Android returns to the exact scroll spot + the very tile you left (`pushPage`/`rememberHomeSpot`/`saveRowFocus`/`restoreRowFocus`/`findTileById`, per-row X memory). iOS NavigationStack gives coarse equivalents free — verify Home scroll + row offsets survive Detail round-trips — MainActivity ~L3651-3712, L3946-3991
- ❌ In-place tile mutation (no page rebuilds on library/watched changes — badges flip live, removals animate out) — `repaintTiles`/`removeTileInPlace` (~L3743-3817)
- 🟡 Theme: iOS accent `#A855F7` vs Android/Sheets `#7B5BF5`, panel `#1B1830`, card `#2C2649` — align the palette
- ❌ CouchKing-styled sheets everywhere (bottom pick sheet with purple ✓ current row, centered confirm card with focus ring) instead of system alerts — Sheets.kt
- ❌ Poster/image discipline (Android: RGB_565, 300MB disk poster cache, viewport art pass). iOS: add a URLCache/downsampling policy so scrolling doesn't re-fetch posters — MainActivity ~L181-258, `artPassNow` (~L3879)
- ❌ Crash guard + `no-streams` telemetry (`CrashGuard.report`) — CrashGuard.kt, `Addons.debugNoStreams` (Addons.kt L145)
- ❌ Brand "CouchKing" crown/gradient span, expiry banner component, centered gate modal component (§1) — ~L5991, L419, L2453
- 🟡 Tab bar: iOS has Home/Search/Library/[Live TV]/Settings. Android mobile order is Search, Home, Discover, [Downloads], Library, [Live TV], Settings — Discover tab missing entirely (see §3) — `navTabs` (~L88)

---

## Suggested implementation order (AJ's priorities first)

1. **Live TV playback wiring** — port `liveTune`: tuning screen → stream fetch → 24/7-vs-HLS pick → access-gate probe with the three modal messages → AVPlayer live mode (no resume/heartbeat) → return-to-channel focus. Then the locked-plan banner. (§7)
2. **For You correctness** — manifest-discovered "for you" catalogs + profile identity carried the way the Android client does (config-segment `userName` via a `withUser` port), guest fallback chain (library-seeded TMDB recs → trending). Verify thumbs actually shape the rows end-to-end. (§3)
3. **State-merge safety** — union merge on pull instead of replace; `positions` as `pos|dur|ts`; instant start-stamp + 30s heartbeat + zombie guard in the player. This is what makes cross-device Continue Watching trustworthy. (§8, §6)
4. **Player must-haves** — "Are you still watching?" (fresh AJ feature, every other surface has it), Next-Up card, mark-watched-on-finish, prefetch-next from the real episode list (season-crossing), credits-from-subtitles lead. (§6)
5. **CW row on Home** — progress bars, `cwOrder`, "+N new episodes" badges, resume-on-tap. (§3)
6. **Update gate** — `/tvapp/store-version` blocking screen + App Store deep link. Small; ship early so old builds can be retired. (§10)
7. **Library parity** — watchlist-only rule, filters/sorts, New-episodes filter. (§8)
8. **Details polish** — where-to-watch (store-flavor-gated), genres→Discover, people pages, episode detail page, no-streams auto-poll. (§5)
9. **Live TV guide** — day tabs, chips, favorites, sports banner, red now-line grid (the biggest single UI build; step 1 makes the tab useful before this lands). (§7)
10. **Settings/prefs alignment** — key names + defaults exactly matching Android so a profile's prefs mean the same thing on every device; delete account; in-app legal. (§9, §1)
11. Remaining Misc UX + Discover/Anime/Movies/Shows tabs + shelf customization + hero/Top 10.

## Store-safety constraints (App Store build — the Android flavor-split precedent)

- **Nothing baked**: no addon URLs, service hosts, or "couchking" strings in the binary. Service base is user-entered; the store-version check, access check and addon assignment all ride it at runtime. (Android: the `Dist` flavor object; a couchking URL in a store binary was the account-ban lesson.)
- **No external-store deep links** (the Amazon rejection, twice): where-to-watch on the App Store build ships as **plain labels or rent/buy only** behind a `Links.PROVIDER_CLICKS`-style compile flag, exactly like the amazon-flavor stub — decide the exact mode with AJ before submission.
- **No downloads** in the store build (the Play FGS demo-video trap).
- **Trailers in-app** (no bouncing out to YouTube pages).
- **Tracker-first review experience**: guest mode must be a complete app (discovery rows, search, library, thumbs, where-to-watch) with a NO-addon demo account for review — per SPEC.md.
- **Never download code**: the mandatory gate deep-links to the App Store listing; Live TV stays addon-gated so reviewers never see it.
