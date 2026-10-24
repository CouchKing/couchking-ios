# CouchKing TV Launcher (onn 4K Google TV)

A custom home screen that replaces Google TV's: CouchKing wordmark, a live clock,
and four big D-pad tiles — CouchKing, YouTube, Spotify, Downloader — plus a Settings pill.
BACK is swallowed so you can't fall out of Home.

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
