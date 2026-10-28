#!/bin/bash
# CouchKing TV setup for the onn 4K Google TV, run from a Mac on the same WiFi.
#   ./couchking-tv-setup.sh            debloat + build + install the launcher + sign in
#   ./couchking-tv-setup.sh --connect  just reconnect (finds the TV's new port by itself)
#   ./couchking-tv-setup.sh --update   rebuild + reinstall the launcher, nothing else
#   ./couchking-tv-setup.sh --signin   show your CouchKing account's shelves on the home screen
#   ./couchking-tv-setup.sh --signout  remove your CouchKing account from the home screen
#   ./couchking-tv-setup.sh --undo     re-enable everything this script disabled, restore stock home
# Only ever uses `pm disable-user --user 0` (reversible). Never uninstalls anything.
set -u
cd "$(dirname "$0")"
MODE="${1:-}"

CONF="$HOME/.couchking-tv"            # remembers the last address that worked
SAVED_TV=""
[ -f "$CONF" ] && SAVED_TV="$(sed -n 's/^TV=//p' "$CONF" | head -1)"
TV="${TV:-${SAVED_TV:-10.0.0.144:39113}}"
TV_IP="${TV%%:*}"
LAUNCHER_PKG="app.couchking.launcher"
LAUNCHER="$LAUNCHER_PKG/.HomeActivity"
STOCK_HOME="com.google.android.apps.tv.launcherx"
# Google TV's fallback HOME (setup wizard recovery); takes over once launcherx is off.
RECOVERY_HOME="com.google.android.tungsten.setupwraith"
SERVICE="https://couchking.app"
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
check_adb() {
  step "Checking adb"
  if ! command -v adb >/dev/null; then
    command -v brew >/dev/null || { warn "Homebrew is missing: install it from https://brew.sh then re-run."; exit 1; }
    info "adb not found, installing android-platform-tools…"
    brew install android-platform-tools || exit 1
  fi
  ok "$(adb version | head -1)"
}

# Wireless debugging picks a new port whenever the TV reboots or rejoins WiFi.
try_addr() {
  adb connect "$1" >/dev/null 2>&1
  [ "$(adb -s "$1" get-state 2>/dev/null)" = device ] || return 1
  TV="$1"; export ANDROID_SERIAL="$TV"
  printf 'TV=%s\n' "$TV" > "$CONF"
}

# Every ip:port the TV is advertising over mDNS, ours first.
mdns_addrs() {
  adb mdns services 2>/dev/null | grep '_adb-tls-connect' | grep -Eo '[0-9]+(\.[0-9]+){3}:[0-9]+' \
    | awk -v ip="$TV_IP:" 'index($0, ip) == 1 { print; next } { rest = rest $0 "\n" } END { printf "%s", rest }'
}

connect_tv() {
  step "Connecting to the onn"
  adb disconnect >/dev/null 2>&1
  if try_addr "$TV"; then
    :
  else
    info "Not at $TV any more — looking for the TV on your WiFi…"
    local a found=""
    for a in $(mdns_addrs); do try_addr "$a" && { found=1; break; }; done
    if [ -z "$found" ]; then
      warn "Couldn't find it automatically."
      info "On the TV: Settings > System > Developer options > Wireless debugging (make sure it's ON)."
      info "If it shows 'IP address & Port', type that here. Otherwise tap 'Pair device with pairing code'."
      read -r -p "    IP:port from the main Wireless debugging screen (Enter to pair instead): " A </dev/tty
      if [ -n "$A" ] && try_addr "$A"; then
        :
      else
        read -r -p "    Pairing IP:port from the 'Pair device' popup: " PAIR </dev/tty
        adb pair "$PAIR" </dev/tty || { warn "Pairing failed."; exit 1; }
        sleep 2
        for a in $(mdns_addrs); do try_addr "$a" && { found=1; break; }; done
        if [ -z "$found" ]; then
          read -r -p "    IP:port from the main Wireless debugging screen: " A </dev/tty
          try_addr "$A" || { warn "Still can't connect to $A."; exit 1; }
        fi
      fi
    fi
  fi
  ok "Connected at $TV: $(sh_tv getprop ro.product.model) · Android $(sh_tv getprop ro.build.version.release)"
}

# ---------------------------------------------------------------------------
undo_all() {
  step "Undo: re-enabling everything this script disabled"
  [ -f "$LOG" ] && while read -r p; do
    [ -n "$p" ] && sh_tv pm enable --user 0 "$p" >/dev/null && ok "enabled $p"
  done < "$LOG"
  sh_tv pm enable --user 0 "$STOCK_HOME" >/dev/null 2>&1
  sh_tv pm enable --user 0 "$RECOVERY_HOME" >/dev/null 2>&1
  # With CouchKing disabled, the stock launcher is the only HOME left and takes over.
  sh_tv pm disable-user --user 0 "$LAUNCHER_PKG" >/dev/null
  rm -f "$LOG"
  sh_tv input keyevent KEYCODE_HOME
  ok "Stock Google TV home restored (CouchKing launcher disabled, not uninstalled)."
}

debloat() {
  step "Making sure the already-disabled apps stay off"
  local enabled_all p found=0 label
  enabled_all=" $(sh_tv pm list packages -e | sed 's/^package://' | tr '\n' ' ') "
  for p in $ALREADY; do
    case "$enabled_all" in
      *" $p "*) info "$p came back on — turning it off again"; disable_pkg "$p";;
      *) ok "$p is off (or not installed)";;
    esac
  done

  step "Looking for other apps that aren't on your keep list"
  info "Keeping: CouchKing, YouTube, Spotify, Downloader."
  for p in $(sh_tv pm list packages -3 -e | sed 's/^package://' | sort); do
    in_list "$p" "$KEEP" && continue
    in_list "$p" "$ALREADY" && continue
    is_never "$p" && { info "skip (protected): $p"; continue; }
    found=1
    label=$(sh_tv dumpsys package "$p" | grep -m1 -E 'versionName=' | sed 's/^ *//')
    if ask "Disable $p ($label)?"; then disable_pkg "$p"; else info "kept $p"; fi
  done
  [ $found = 0 ] && ok "Nothing else to debloat — only your four apps are left."
}

# ---------------------------------------------------------------------------
build_launcher() {
  step "Building the CouchKing launcher"
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
  if [ ! -d "$ANDROID_HOME/platforms/android-34" ] || [ ! -d "$ANDROID_HOME/build-tools/34.0.0" ]; then
    info "Installing Android SDK platform 34 + build-tools (first run only, takes a few minutes)…"
    yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1
    "$SDKMANAGER" --sdk_root="$ANDROID_HOME" "platforms;android-34" "build-tools;34.0.0" >/dev/null || exit 1
  fi
  echo "sdk.dir=$ANDROID_HOME" > local.properties
  ok "SDK: $ANDROID_HOME"

  info "Compiling + signing with the debug keystore…"
  ./gradlew --console=plain -q assembleDebug || { warn "Build failed."; exit 1; }
  APK="$PWD/app/build/outputs/apk/debug/app-debug.apk"
  ok "Built $APK"
}

home_is_ours() {
  sh_tv input keyevent KEYCODE_HOME; sleep 2
  sh_tv dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | grep -q "$LAUNCHER_PKG"
}

install_launcher() {
  step "Installing and setting CouchKing as the home screen"
  adb install -r "$APK" | tail -1
  sh_tv pm enable --user 0 "$LAUNCHER_PKG" >/dev/null
  sh_tv cmd package set-home-activity --user 0 "$LAUNCHER"
  if home_is_ours; then
    ok "Home key now opens CouchKing."
    return
  fi
  warn "Google TV's own launcher ($STOCK_HOME) is still grabbing the Home button."
  info "Disabling it is reversible (./couchking-tv-setup.sh --undo brings it back)."
  ask "Disable $STOCK_HOME so CouchKing owns Home?" || return
  disable_pkg "$STOCK_HOME"
  sh_tv cmd package set-home-activity --user 0 "$LAUNCHER"
  if home_is_ours; then ok "Home key now opens CouchKing."; return; fi
  warn "Google TV's fallback home ($RECOVERY_HOME, the setup-wizard recovery screen) took over."
  info "It's only needed during first-time TV setup. Reversible with --undo."
  ask "Disable $RECOVERY_HOME too?" || return
  disable_pkg "$RECOVERY_HOME"
  sh_tv cmd package set-home-activity --user 0 "$LAUNCHER"
  home_is_ours && ok "Home key now opens CouchKing." || warn "Still not ours — tell Claude what's on screen."
}

# ---------------------------------------------------------------------------
json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Signs in on the Mac (the password never goes to the TV) and hands the home screen the token,
# so it can show this account's Continue Watching + My List. Read-only: it never edits the library.
sign_in() {
  step "Signing the home screen in to CouchKing"
  local email password resp code body token err
  read -r -p "    CouchKing email: " email </dev/tty
  read -r -s -p "    CouchKing password (hidden as you type): " password </dev/tty; echo
  email="$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  resp="$(curl -sS -m 20 -X POST "$SERVICE/tvapp/auth" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' -H 'X-CK-Model: CouchKing Home (onn)' \
    -d "{\"email\":\"$(json_str "$email")\",\"password\":\"$(json_str "$password")\",\"mode\":\"signin\",\"appVer\":\"launcher-1.0\"}" \
    -w $'\n%{http_code}')" || { warn "Couldn't reach CouchKing — check the Mac's internet."; return 1; }
  password=""
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  token="$(printf '%s' "$body" | plutil -extract token raw -o - - 2>/dev/null)"
  if [ -z "$token" ]; then
    err="$(printf '%s' "$body" | plutil -extract error raw -o - - 2>/dev/null)"
    warn "Sign-in failed (${err:-HTTP $code})."
    return 1
  fi
  sh_tv "am start -n $LAUNCHER --es ck_email '$email' --es ck_token '$token'" >/dev/null
  ok "Signed in as $email — your Continue Watching + My List appear on the home screen."
}

sign_out() {
  step "Removing your CouchKing account from the home screen"
  sh_tv "am start -n $LAUNCHER --ez ck_signout true" >/dev/null
  ok "Signed out (the CouchKing app itself is untouched)."
}

summary() {
  step "Summary"
  info "Disabled packages on the TV:"
  sh_tv pm list packages -d | sed 's/^package:/      - /'
  info "Default home: $(sh_tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)"
  echo
  if ask "Press HOME on the remote now. Do you see the CouchKing home screen?"; then
    ok "Done — long live the King. 👑"
  else
    warn "Tell Claude what you see and paste this output."
  fi
}

# ---------------------------------------------------------------------------
check_adb
connect_tv
case "$MODE" in
  --connect) ok "Ready. Re-run any command — it'll use $TV.";;
  --undo)    undo_all;;
  --signin)  sign_in;;
  --signout) sign_out;;
  --update)  build_launcher; install_launcher;;
  "")
    debloat
    build_launcher
    install_launcher
    if ask "Show your CouchKing account's Continue Watching + My List on the home screen?"; then sign_in; fi
    summary;;
  *) warn "Unknown option $MODE (use --connect, --update, --signin, --signout or --undo)"; exit 1;;
esac
