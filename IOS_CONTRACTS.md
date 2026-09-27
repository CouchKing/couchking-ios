# iOS Build Contracts — everything needed to finish the blocked PARITY items

This file exists because several PARITY.md items were blocked on API contracts that live on
the server / Android side, not in this repo. Those contracts are now written down here, exactly.
Build the items below **on the same branch**, compile-verify each (CI runs xcodegen + xcodebuild
on macos-15), commit in small batches, keep the PR updated.

Conventions that apply everywhere:
- All titles key off **IMDb id** (`tt…`); stream ids are `tt…:S:E`. TMDB results resolve to imdb via `/{kind}/{id}/external_ids`.
- Metadata source is **Cinemeta**: `https://v3-cinemeta.strem.io/catalog|meta/{type}/{id}.json` (type = `movie`/`series`), with TMDB fallback when unreachable — same as Android.
- All Live TV times are **epoch milliseconds**; display in **America/New_York (ET)** to match every other client.
- Live-channel play id = `cklive:` + channel `id`.

---

## 1. TMDB access — unblocks guest For You (#50), Anime tab (#46), provider chips (#71), Discover year (#47), people search (#59)

**There is NO server TMDB proxy.** Clients call TMDB v3 directly with a hardcoded public read-only key.
Embed the SAME key iOS-side (a constant in a Discovery layer), exactly like Android does:

```
TMDB_KEY = b05e998c589bf1393c1059bd1d4c5895
```
Base: `https://api.themoviedb.org/3/…?api_key=<KEY>` · Images: `https://image.tmdb.org/t/p/w342<poster_path>` (w185 small).
Required disclaimer already in web privacy/terms: "uses the TMDB API but is not endorsed or certified by TMDB."

Endpoint menu (mirror Android's Discovery.kt):
| Purpose | Endpoint |
|---|---|
| Search titles | `/search/{movie\|tv}?query=Q&include_adult=false` |
| Search people | `/search/person?query=Q` → filmography `/person/{id}/combined_credits` |
| imdb→tmdb | `/find/{imdbId}?external_source=imdb_id` (movie_results / tv_results) |
| tmdb→imdb | `/{movie\|tv}/{id}/external_ids` |
| Details + credits + trailers | `/{movie\|tv}/{id}?append_to_response=credits,videos` |
| Recommendations | `/{movie\|tv}/{id}/recommendations` |
| Watch providers | `/{movie\|tv}/{id}/watch/providers` → `results.US.{flatrate,rent,buy,link}` |
| Discover | `/discover/{movie\|tv}?sort_by=popularity.desc&…` |
| Trending | `/trending/{movie\|tv}/week` |

### 1a. Anime tab (#46) — "Animation ∩ Japanese origin"
Two rows, TMDB discover, resolve each result to imdb via external_ids:
```
Anime         → discover/tv?with_genres=16&with_origin_country=JP&sort_by=popularity.desc  (kind=tv)
Anime Movies  → discover/movie?with_genres=16&with_origin_country=JP&sort_by=popularity.desc (kind=movie)
```

### 1b. Guest/tracker For You (#50) — fallback chain, in order
1. **Addon algo first:** the catalog in the installed manifest whose name contains "for you" (per type, pass profile). If non-empty, use it (iOS already does this).
2. **TMDB rec graph** (no addon / empty): seed from the user's own library = continue + watchlist + watched, split by type. Take up to 8 strongest seeds. For each: `/find/{imdb}` → tmdb id → `/{kind}/{id}/recommendations`. **Consensus rank**: count how many seeds recommend each candidate, sort by vote-count then popularity, drop anything already in the library. On Home interleave movie+TV recs.
3. **Trending** if seeds/recs empty: `/trending/{kind}/week`.

### 1c. Where-to-watch provider chips (#71) — guests/tracker only (hide once an addon is installed)
`/find/{imdb}` → tmdb id → `/{kind}/{id}/watch/providers` → `results.US`. Map `flatrate`→stream, `rent`→rent, `buy`→buy (each = list of provider_name), plus `link` (JustWatch).
Render: header "▶ Where to watch"; stream chips (accented) take 4; "Rent · X" take 4; "Buy · X" take 4 (skip buys already in rent). **"🎬 In theaters now — home release hasn't happened yet"** gold notice when zero providers AND type=movie AND no addons AND year ≥ currentYear−1.
iOS is single-distribution → mirror Android **sideload** behavior (full stream/rent/buy, clickable to the provider app/site) unless App Store review forces rent/buy-only.
US provider ids: Netflix 8, Hulu 15, Disney+ 337, Max 1899, Prime 9, Apple TV+ 350, Paramount+ 2303/2616/531, Peacock 386.

### 1d. Discover year (#47)
Year filter reroutes through TMDB discover (Cinemeta can't year-filter): `primary_release_year=Y` (movie) / `first_air_date_year=Y` (tv). If the selected catalog is already a `discover/` row, append the year param; else `discover/{kind}?sort_by=popularity.desc&vote_count.gte=40&<year>`. Dropdown = "All years" + (currentYear…1950). Genre layers via `with_genres=<id>`.

---

## 2. Live TV guide family — unblocks guide grid, day tabs, region, sports banner, favorites, recent strip, staleness (#119 and siblings)

Host = the user's own addon authority (`liveHost`). Key = `subKey` from the addon URL config segment (uppercased). Profile = per-profile id string (≤24 chars).

### 2a. GET `{liveHost}/live/{KEY}/guide.json?p={profile}&r={region}`
`r`: omit/"" = USA, `UK`, or `CA`. Cache client-side ~55s per region. Response:
```json
{
  "at": 1700000000000,          // server "now" epoch ms — the reference for live/next + freshness
  "devices": 2,                  // concurrent-device tier
  "favs": ["chid", ...],         // favorite channel IDS (this key/profile)
  "favChannels": [Channel, ...], // favorites as full objects (may be outside region)
  "recent": ["chid", ...],       // recently-tuned ids, ≤12, last 72h
  "channels": [Channel, ...]     // the grid, ≤600
}
```
`Channel = { id, name, logo, genre, section, progs: [Programme] }`
- `section` = the header to group under (curated section / league "NFL" / event category / provider genre / "Recently Watched"; "" = ungrouped).
- `Programme = { s, e, t }` — **short keys**: s=start ms, e=end ms, t=title. Grid channels carry up to 96h; favChannels/recents 48h. Only programmes with `e > now`.
- **Now/next is derived client-side** (no separate block): now = programme with `s <= at < e`; next = first with `s > at`.
- **403 `{err:"no-livetv"}`** = key invalid/expired. A single catalog meta `id=="cklive:upgrade"` = render locked 🔒 panel.

### 2b. POST `{liveHost}/live/{KEY}/fav?id={chid}&on={0|1}&p={profile}` — **params are query-string, not body**
`on=1` add, `on=0` remove (client sends desired state, not a toggle). → `{ok:true,on:<bool>}`. Long-press a channel = flip favorite, update locally instant.

### 2c. GET `{liveHost}/live/{KEY}/games.json` — sports banner. Cache 60s but **must not serve stale** (stale paints yesterday's LIVE games).
```json
{ "at": 1700000000000,
  "sports": [ { "sport":"Football", "emoji":"🏈",
      "live": [Game], "soon": [Game] } ] }
```
Sports order: Football, Baseball, Basketball, Hockey, Fights, Fútbol, Tennis, Golf, More Sports.
`Game = { t, ch, chid, logo, s, e, when, rg }` — t=matchup, ch=network label, **chid=`cklive:`+id (the play id)**, s/e=epoch ms, when=human ET string, rg=`US`/`UK`/`CA`. Live vs upcoming = which array it's in (no boolean). A game with `e<=now` is dropped. Fútbol shows under UK region.

### 2d. Tune a channel: GET `{addonBase}/stream/tv/{urlencoded chid}.json` → `{streams:[{url, ckTs}]}`.
`ckTs==1` = steady `.ts` hub — use ONLY for 24/7 loop channels (id prefix `24-7-`/`en-24-7-`); everything else prefers plain HLS. Before opening the player, HEAD-probe the HLS url (gate): **429 = another device watching, 503 = at capacity, 403 = not on plan** → show the CouchKing modal with that reason (this is also PARITY #25).
Category/search channels: `{addonBase}/catalog/tv/{catId}/genre={cat}.json` and `.../search={q}.json`. Send the "24/7" category as **`24-7`** (a `%2F` 404s).

### 2e. Guide UI layout (top→bottom), to replicate:
1. Title "Live TV" + region chip "🌎 USA ▾" (USA/UK/Canada → codes ""/"UK"/"CA"; picking one resets to Guide + rebuilds).
2. Live-games banner from games.json: per-sport red "LIVE NOW" strips + one "📅 Upcoming games" strip; **self-refresh every 3 min** (skip if the user's cursor is inside it).
3. Search field, ~350ms debounce; blank query repaints body in place (no page rebuild).
4. Category chips: `["Guide","★ Favorites"] + <sections present in channels> + (USA ? ["Local","24/7"] : []) + ["All Channels"]`; chip click repaints body only.
5. Body:
   - **Guide** → grid: **Day tabs** = ["Today","Tomorrow", weekday+2, weekday+3] (server ships 96h; day is session-only, always opens on Today). **Recent strip** "↻ Continue watching" from `recent` (≤12) with current program title. Grid: left fixed channel column + shared horizontal timeline; `dayStart` = current half-hour (Today) / 6:00 AM (other days); Today window 72h else 24h. Group ★Favorites first, then uppercase SECTION headers. Current program block highlighted + a 2px red now-line at the current minute; channel click = tune, long-press = ★ toggle. (Android virtualizes for Firestick OOM — iOS just use normal cell reuse.)
   - **★ Favorites** → rows from `favChannels`.
   - **section name** → channels where `section == chip`.
   - **Local / 24/7 / All Channels** → catalog `genre=` fetch.
6. **Staleness:** stamp when the page was built; on foreground resume rebuild any Live TV page older than **60s**; freeze the red now-line at tune time and rebuild the guide on return; refetch favs+recent when the in-player ★/channel-hop set a dirty flag.

---

## 3. Curated watch-order rows (#49) — exact ordered IMDb id lists, rendered UNSHUFFLED
Resolve each id via Cinemeta meta (try the row's type, then the other, then TMDB `/find`), keep list order. Register three shelves:

**"Marvel: Release Order"** (movie):
```
tt0371746 tt0800080 tt1228705 tt0800369 tt0458339 tt0848228 tt1300854 tt1981115 tt1843866
tt2015381 tt2395427 tt0478970 tt3498820 tt1211837 tt3896198 tt2250912 tt3501632 tt1825683
tt4154756 tt5095030 tt4154664 tt4154796 tt6320628 tt9140560 tt9208876 tt9140554 tt3480822
tt10168312 tt9376612 tt9032400 tt10160804 tt10872600 tt10234724 tt9419884 tt10857164
tt10648342 tt10857160 tt9114286 tt10954600 tt6791350 tt13157618 tt10676048 tt13966962
tt6263850 tt15571732 tt14513804 tt18923754 tt20969586 tt13623126 tt10676052 tt16027014
tt21066182 tt22084616 tt23112594 tt21357150 tt21361444
```

**"Marvel: Chronological"** (movie — Disney+ story order):
```
tt0458339 tt4154664 tt0371746 tt1228705 tt0800080 tt0800369 tt0848228 tt1300854 tt1981115
tt1843866 tt2015381 tt3896198 tt2395427 tt0478970 tt3498820 tt3480822 tt1825683 tt2250912
tt1211837 tt3501632 tt5095030 tt4154756 tt4154796 tt6320628 tt9140560 tt9208876 tt9376612
tt9032400 tt10872600 tt10160804 tt9140554 tt10168312 tt10234724 tt9419884 tt10857164
tt10648342 tt10857160 tt9114286 tt13157618 tt10954600 tt6791350 tt10676048 tt13966962
tt6263850 tt15571732 tt14513804 tt18923754 tt20969586 tt13623126 tt10676052 tt16027014
tt21066182 tt22084616 tt23112594 tt21357150 tt21361444
```

**"X-Men Movies"** (movie):
```
tt0120903 tt0290334 tt0376994 tt0458525 tt1270798 tt1430132 tt1877832 tt1431045 tt3385516
tt3315342 tt5463162 tt6565702 tt4682266 tt6263850
```

---

## 4. Embedded subtitles via `/webplay/subx` (#74 embedded-subs) + probe (#105 stats input)
- **Probe:** GET `{addonBase}/webplay/probe?u={base64url media url}` → `{ duration, vcodec, acodec, subs:[{i,lang,title,forced,hi}] }`. `duration` seconds (0=fail). `i` is the subtitle stream index to pass to subx.
- **Extract sub:** GET `{addonBase}/webplay/subx?u={base64url}&i={index}&t={startSeconds}` → progressively-streamed `text/vtt` (ffmpeg live-converts to WebVTT, timestamps on the file's absolute clock — align with player position). Host of `u` must be couchking.app / tb-cdn.st / torbox.
- base64url = standard base64 with `+`→`-`, `/`→`_`, `=` stripped.
- Only text subs (PGS/DVD bitmap not offered). Use this to add embedded-subtitle tracks alongside the addon's `subtitles` json list.

---

## 5. Placeholder / "not yet available" hot-swap (#107)
No status endpoint — the signal is in the Stremio **stream object** you already fetch:
- **Still a placeholder:** stream `url` points at `{SITE}/unavailable?k=unaired|nostream` (or `_downloading.mp4`), `name` looks like `⏳ CouchKing | Downloading / Searching / NN%`, response carries `cacheMaxAge: 15`, and `behaviorHints.notWebReady: true` (+ `ckNotice:true` for unaired/dead). → loop the placeholder clip, hide Ends/skip UI, re-request the stream every ~15–20s.
- **Real file landed:** `name` = `👑 CouchKing | <quality>`, real play url (not `/unavailable`), `behaviorHints.notWebReady: false`. → hot-swap to it, restore UI.
- `GET {SITE}/unavailable?k=unaired` (302→ck-unaired.mp4), `?k=nostream` (→ck-nostream.mp4), else _downloading.mp4 — these are the loopable placeholder videos.

---

## PARITY items this unblocks
- #46 Anime tab · #47 Discover year · #49 curated watch-order rows · #50 guest/tracker For You · #59 people search + #60 cast chips · #71 provider chips → **§1, §3**
- Live TV guide grid / day tabs / region / sports banner / favorites / recent strip / staleness (#119 + siblings) · #25 device-cap gate → **§2**
- #74 embedded subs · #105 stats overlay (probe gives vcodec/duration) → **§4**
- #107 placeholder hot-swap → **§5**

Still legitimately out of scope (leave as-is): TV-layout variants (#81, iPhone v1 N/A), offline downloads (per AJ), and any no-streams **telemetry/crash beacon** (no such client endpoint exists — the retry + placeholder handling above is the whole contract).
