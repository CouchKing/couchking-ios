# CouchKing TV Launcher (onn 4K Google TV)

A custom home screen that replaces Google TV's, styled after the CouchKing app's own Home:

- **Hero** — full-screen backdrop + title, year, ★ rating, synopsis. Idles through today's
  trending titles every 9s (TMDB, same source and key as the app); follows whatever you focus.
- **Your apps** — CouchKing, YouTube, Spotify, Downloader as TV-banner tiles.
- **Continue Watching** — your CouchKing profile's in-progress titles, newest first, with a gold
  progress bar and S/E chip. Focus one and the hero loads its backdrop + synopsis (Cinemeta).
- **<Name>'s List** — the profile's watchlist.
- **Top 10 Today on CouchKing** — posters with giant outlined rank numerals.
- Header: crown wordmark, "Good evening, <profile>", clock/date, profile switcher, ⚙ Settings.
- Shelves slide up Netflix-style as you go down. BACK is swallowed. Works offline from cache.

The account shelves read the same `GET /tvapp/state` blob every CouchKing client syncs, and
refresh every 5 minutes. The launcher never writes to it, so it can't change your library.

## Commands (on your Mac, same WiFi as the TV)

```sh
cd Platforms/TVLauncher
./couchking-tv-setup.sh            # debloat + build + install + set as Home + sign in
./couchking-tv-setup.sh --connect  # lost the connection? finds the TV's new port by itself
./couchking-tv-setup.sh --update   # rebuild + reinstall after pulling new launcher code
./couchking-tv-setup.sh --signin   # show your CouchKing account's shelves
./couchking-tv-setup.sh --signout  # remove the account from the home screen
./couchking-tv-setup.sh --undo     # re-enable everything it disabled, restore stock home
```

The last working address is remembered in `~/.couchking-tv`. Sign-in happens on the Mac; the
TV only ever receives the session token.

The script installs anything missing (adb, JDK 17, Android SDK 34), only uses
`pm disable-user --user 0` (reversible, never uninstalls), refuses to touch protected system
packages (gms, gsf, vending, webview, systemui, …), and asks before disabling anything that isn't
already on the list. Everything it disables is logged to `disabled-by-couchking.txt` for `--undo`.

## Deep links (needs a CouchKing app change)

Opening a title launches CouchKing with these extras. CouchKing doesn't read them yet; once it
does, the home screen jumps straight to the title / resumes the episode:

| extra | from | value |
|---|---|---|
| `ck_imdb_id` | Continue Watching, My List | `tt…` |
| `ck_resume` | Continue Watching | `tt…:S:E` for a show, the id for a movie |
| `ck_profile` | Continue Watching, My List | CouchKing profile id |
| `ck_tmdb_id` | Top 10 | TMDB id (int) |
| `ck_type` | all | `movie` / `series` |
| `ck_title` | all | display name |

Package: `app.couchking.launcher/.HomeActivity`
