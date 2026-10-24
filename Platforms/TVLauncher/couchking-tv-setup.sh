#!/bin/bash
# CouchKing TV setup for the onn 4K Google TV, run from a Mac on the same WiFi.
#   ./couchking-tv-setup.sh          debloat + build + install the CouchKing launcher
#   ./couchking-tv-setup.sh --undo   re-enable everything this script disabled, restore stock home
# Only ever uses `pm disable-user --user 0` (reversible). Never uninstalls anything.
set -u
cd "$(dirname "$0")"

TV="${TV:-10.0.0.144:39113}"
export ANDROID_SERIAL="$TV"
LAUNCHER_PKG="app.couchking.launcher"
LAUNCHER="$LAUNCHER_PKG/.HomeActivity"
STOCK_HOME="com.google.android.apps.tv.launcherx"
LOG="$PWD/disabled-by-couchking.txt"

KEEP="app.mediaboard com.google.android.youtube.tv com.spotify.tv.android com.esaba.downloader $LAUNCHER_PKG"
ALREADY="com.netflix.ninja com.netflix.tokenmanager com.google.android.play.games com.google.android.feedback
com.google.android.partnersetup com.onn.updatenotification com.android.printspooler
com.google.android.youtube.tvmusic tv.twitch.android.app"
NEVER='gms|gsf|vending|webview|systemui|inputmethod|tv\.settings|tv\.remote\.service|bluetooth|katniss|droidlogic|amlogic|onn.*pair|pair.*onn|permissioncontroller|packageinstaller'

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m✔ %s\033[0m\n' "$*"; }
warn() { printf '    \033[31m✘ %s\033[0m\n' "$*"; }
ask()  { local a; read -r -p "    $1 [y/N] " a </dev/tty; [ "$a" = y ] || [ "$a" = Y ]; }
sh_tv() { adb shell "$@" | tr -d '\r'; }
is_never() { echo "$1" | grep -Eq "$NEVER"; }
in_list() { case " $(echo $2) " in *" $1 "*) return 0;; esac; return 1; }

disable_pkg() {
  local p="$1"
  if is_never "$p"; then warn "refusing to touch $p (protected)"; return; fi
  if sh_tv pm disable-user --user 0 "$p" | grep -q "new state: disabled"; then
    ok "disabled $p"; grep -qx "$p" "$LOG" 2>/dev/null || echo "$p" >> "$LOG"
  else
    warn "could not disable $p"
  fi
}

# ---------------------------------------------------------------------------
step "1/7  Checking adb"
if ! command -v adb >/dev/null; then
  command -v brew >/dev/null || { warn "Homebrew is missing: install it from https://brew.sh then re-run."; exit 1; }
  info "adb not found, installing android-platform-tools…"
  brew install android-platform-tools || exit 1
fi
ok "$(adb version | head -1)"

# ---------------------------------------------------------------------------
step "2/7  Connecting to the onn at $TV"
connect() { adb connect "$TV" >/dev/null 2>&1; [ "$(adb -s "$TV" get-state 2>/dev/null)" = device ]; }
if ! connect; then
  warn "Couldn't connect."
  info "On the TV: Settings > System > Developer options > Wireless debugging > Pair device with pairing code."
  read -r -p "    Pairing IP:port shown on the TV (e.g. 10.0.0.144:41234): " PAIR </dev/tty
  adb pair "$PAIR" || { warn "Pairing failed."; exit 1; }
  info "Now look at the main Wireless debugging screen (IP address & Port) — that port is usually different."
  read -r -p "    Connect IP:port [$TV]: " NEWTV </dev/tty
  TV="${NEWTV:-$TV}"; export ANDROID_SERIAL="$TV"
  connect || { warn "Still can't connect to $TV."; exit 1; }
fi
adb devices
ok "Connected: $(sh_tv getprop ro.product.model) · Android $(sh_tv getprop ro.build.version.release)"

# ---------------------------------------------------------------------------
if [ "${1:-}" = "--undo" ]; then
  step "Undo: re-enabling everything this script disabled"
  [ -f "$LOG" ] && while read -r p; do
    [ -n "$p" ] && sh_tv pm enable --user 0 "$p" >/dev/null && ok "enabled $p"
  done < "$LOG"
  sh_tv pm enable --user 0 "$STOCK_HOME" >/dev/null 2>&1
  # With CouchKing disabled, the stock launcher is the only HOME left and takes over.
  sh_tv pm disable-user --user 0 "$LAUNCHER_PKG" >/dev/null
  rm -f "$LOG"
  sh_tv input keyevent KEYCODE_HOME
  ok "Stock Google TV home restored (CouchKing launcher disabled, not uninstalled)."
  exit 0
fi

# ---------------------------------------------------------------------------
step "3/7  Making sure the already-disabled apps stay off"
ENABLED_ALL=" $(sh_tv pm list packages -e | sed 's/^package://' | tr '\n' ' ') "
for p in $ALREADY; do
  case "$ENABLED_ALL" in
    *" $p "*) info "$p came back on — turning it off again"; disable_pkg "$p";;
    *) ok "$p is off (or not installed)";;
  esac
done

# ---------------------------------------------------------------------------
step "4/7  Looking for other apps that aren't on your keep list"
info "Keeping: CouchKing, YouTube, Spotify, Downloader."
FOUND=0
for p in $(sh_tv pm list packages -3 -e | sed 's/^package://' | sort); do
  in_list "$p" "$KEEP" && continue
  in_list "$p" "$ALREADY" && continue
  is_never "$p" && { info "skip (protected): $p"; continue; }
  FOUND=1
  label=$(sh_tv dumpsys package "$p" | grep -m1 -E 'versionName=' | sed 's/^ *//')
  if ask "Disable $p ($label)?"; then disable_pkg "$p"; else info "kept $p"; fi
done
[ $FOUND = 0 ] && ok "Nothing else to debloat — only your four apps are left."

# ---------------------------------------------------------------------------
step "5/7  Building the CouchKing launcher"
# A prebuilt JDK (Temurin cask): the openjdk@17 formula compiles from source on older macOS.
find_jdk() {
  # A JDK unpacked by hand (no admin password needed): ~/jdk17, or JAVA_HOME set by the caller.
  for h in "${JAVA_HOME:-}" "$HOME"/jdk17/Contents/Home "$HOME"/jdk17; do
    [ -n "$h" ] && [ -x "$h/bin/java" ] && { echo "$h"; return 0; }
  done
  /usr/libexec/java_home -v 17 2>/dev/null || /usr/libexec/java_home -v 21 2>/dev/null; }
if ! find_jdk >/dev/null; then
  info "Installing JDK 17 (Temurin, prebuilt — macOS may ask for your password)…"
  brew install --cask temurin@17 || {
    warn "Couldn't install Java. Download the macOS .pkg for JDK 17 from https://adoptium.net, install it, then re-run."
    exit 1
  }
fi
JAVA_HOME="$(find_jdk)" || { warn "JDK 17 still not found."; exit 1; }
export JAVA_HOME
ok "JDK: $JAVA_HOME"

export ANDROID_HOME="${ANDROID_HOME:-$(brew --prefix)/share/android-commandlinetools}"
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$SDKMANAGER" ]; then
  info "Installing Android command-line tools…"; brew install --cask android-commandlinetools || exit 1
fi
info "Installing Android SDK platform 34 + build-tools (first run only)…"
yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1
"$SDKMANAGER" --sdk_root="$ANDROID_HOME" "platforms;android-34" "build-tools;34.0.0" >/dev/null || exit 1
echo "sdk.dir=$ANDROID_HOME" > local.properties
ok "SDK: $ANDROID_HOME"

info "Compiling + signing with the debug keystore…"
./gradlew --console=plain -q assembleDebug || { warn "Build failed."; exit 1; }
APK="$PWD/app/build/outputs/apk/debug/app-debug.apk"
ok "Built $APK"

# ---------------------------------------------------------------------------
step "6/7  Installing and setting CouchKing as the home screen"
adb install -r "$APK" | tail -1
sh_tv pm enable --user 0 "$LAUNCHER_PKG" >/dev/null
sh_tv cmd package set-home-activity --user 0 "$LAUNCHER"

home_is_ours() {
  sh_tv input keyevent KEYCODE_HOME; sleep 2
  sh_tv dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | grep -q "$LAUNCHER_PKG"
}
if home_is_ours; then
  ok "Home key now opens CouchKing."
else
  warn "Google TV's own launcher ($STOCK_HOME) is still grabbing the Home button."
  info "Disabling it is reversible (./couchking-tv-setup.sh --undo brings it back)."
  if ask "Disable $STOCK_HOME so CouchKing owns Home?"; then
    disable_pkg "$STOCK_HOME"
    sh_tv cmd package set-home-activity --user 0 "$LAUNCHER"
    home_is_ours && ok "Home key now opens CouchKing." || warn "Still not ours — tell Claude what's on screen."
  fi
fi

# ---------------------------------------------------------------------------
step "7/7  Summary"
info "Disabled packages on the TV:"
sh_tv pm list packages -d | sed 's/^package:/      - /'
info "Default home: $(sh_tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)"
echo
if ask "Press HOME on the remote now. Do you see the CouchKing home screen?"; then
  ok "Done — long live the King. 👑"
else
  warn "Tell Claude what you see and paste this output."
fi
