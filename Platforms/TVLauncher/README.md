# CouchKing TV Launcher (onn 4K Google TV)

A custom home screen that replaces Google TV's, styled after the CouchKing app's own Home:

- **Hero** — full-screen backdrops of today's trending movies & shows (TMDB, same source and
  key as the app), crossfading every 9s, with title, year, ★ rating and synopsis.
- **Your apps** — CouchKing, YouTube, Spotify, Downloader as TV-banner tiles.
- **Top 10 Today on CouchKing** — posters with giant outlined rank numerals; focusing one
  puts it in the hero, OK opens CouchKing.
- Header: crown wordmark, greeting, clock/date, ⚙ Settings. BACK is swallowed.
- Works offline: the last trending list is cached; with none yet, a CouchKing brand hero shows.

Opening a Top 10 title launches CouchKing with extras `ck_tmdb_id` (int), `ck_type`
(`movie`/`tv`) and `ck_title`. CouchKing doesn't read them yet — once it does, the launcher
deep-links straight to that title.

## Run it (on your Mac, same WiFi as the TV)

```sh
cd Platforms/TVLauncher
./couchking-tv-setup.sh            # debloat + build + install + set as Home
TV=10.0.0.144:41234 ./couchking-tv-setup.sh   # if the TV's debugging port changed
./couchking-tv-setup.sh --undo     # re-enable everything it disabled, restore stock home
```

The script installs anything missing (adb, JDK 17, Android SDK 34) via Homebrew,
only uses `pm disable-user --user 0` (reversible, never uninstalls), refuses to touch
protected system packages (gms, gsf, vending, webview, systemui, …), and asks before
disabling anything that isn't already on the list. Everything it disables is logged to
`disabled-by-couchking.txt` for `--undo`.

Package: `app.couchking.launcher/.HomeActivity`
