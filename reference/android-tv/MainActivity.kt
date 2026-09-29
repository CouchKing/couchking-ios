package app.mediaboard

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.EditorInfo
import android.widget.*
import androidx.core.view.setPadding
import androidx.core.view.doOnPreDraw
import coil.dispose
import coil.load
import androidx.core.widget.doAfterTextChanged
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/**
 * Netflix-style shell with top tabs (Home / Movies / Shows / Anime / Search / Library),
 * Stremio-style detail pages, and a watched-tracker. Guests get full discovery + tracking;
 * playing needs a user-added addon (the Play path simply doesn't exist until one is added).
 */
class MainActivity : Activity() {
    // process-scoped: true once a profile is picked this app-launch, survives activity
    // recreation (Fire OS memory reclaim) but resets on a true cold start → cold open
    // always shows the profile picker, mid-session recreation auto-resumes (AJ Sep 18)
    companion object { @Volatile var sessionActive = false }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var root: FrameLayout
    private val bg = Color.parseColor("#0C0B14")
    private val card = Color.parseColor("#1B1830")
    private val fg = Color.WHITE
    private val dim = Color.parseColor("#A9A5C0")
    private val accent = Color.parseColor("#7B5BF5")
    private var tab = "Home"
    private var updateOffered: String? = null
    private var lastTitle: Title? = null

    // Stremio IA: slim bottom bar on mobile; full left rail on TV (search lives on the rail)
    // Downloads exists ONLY on the full (sideload) mobile build: the list is decided off
    // Downloads.ENABLED (a const the store stub pins to false — the whole branch is dead
    // code there, tab name included via the inlined Downloads.TAB) and off !isTv (AJ:
    // Firestick gets nothing). Lazy because isTv needs an attached context, which a plain
    // field initializer runs too early for.
    private val mobileTabs: List<String> by lazy {
        if (Downloads.ENABLED && !isTv)
            listOf("Search", "Home", "Discover", Downloads.TAB, "Library", "Settings")
        else listOf("Search", "Home", "Discover", "Library", "Settings")
    }
    private val tvTabs = listOf("Search", "Home", "Discover", "Library", "Settings")

    // LIVE TV is ADDON-GATED (AJ Sep 17): the tab exists only while an installed addon's
    // manifest carries a type:'tv' catalog — the shell itself stays a neutral client.
    private var liveTvOn = false
    private var liveTvAddon: String? = null          // base url of the addon serving it
    private var liveTvCatId: String = ""
    private var liveTvGenres: List<String> = emptyList()
    // set when the live player opens: the guide's red now-line froze at tune time, so the
    // page rebuilds (re-aligned to NOW) the moment they back out (AJ Sep 24: "the red line
    // doesn't update unless you update the page")
    private var liveGuideStale = false
    private var liveGuideGen = 0   // invalidates in-flight chunked guide builds on rebuild
    // the channel they were just watching: the rebuilt page puts the cursor BACK on its row
    // (AJ Sep 24: "will my cursor be right where i left off") — rows land async, so the
    // restore retries briefly until the tagged row exists
    private var liveFocusId: String? = null
    private fun liveRestoreFocus(rootCol: View, tries: Int = 20) {   // 20: guide rows stream in chunks now
        val fid = liveFocusId ?: return
        val v = rootCol.findViewWithTag<View>("lvfoc:$fid")
        if (v != null) {
            liveFocusId = null
            v.post { v.requestFocus()
                v.requestRectangleOnScreen(android.graphics.Rect(0, 0, v.width, v.height), false) }
        } else if (tries > 0) rootCol.postDelayed({ liveRestoreFocus(rootCol, tries - 1) }, 150)
        else liveFocusId = null
    }
    private fun navTabs(): List<String> {
        val t = mutableListOf("Search", "Home", "Discover")
        // Downloads is ACCOUNT-gated just like Live TV (AJ Sep 18: "should see downloads for
        // guest same as live tv"): a guest has no addons = no streams to download, so the tab
        // is hidden until they sign in and their service is connected.
        if (Downloads.ENABLED && !isTv && Store.addons(this).isNotEmpty()) t.add(Downloads.TAB)
        t.add("Library")
        if (liveTvOn) t.add("Live TV")   // rides right above Settings
        t.add("Settings")
        return t
    }
    private suspend fun detectLiveTv() {
        val prev = liveTvOn
        var on = false
        for (a in Store.addons(this)) {
            val m = Http.jsonCached("${a.url}/manifest.json") ?: continue
            val cats = m.optJSONArray("catalogs") ?: continue
            val hit = (0 until cats.length()).mapNotNull { cats.optJSONObject(it) }
                .firstOrNull { it.optString("type") == "tv" }
            if (hit != null) {
                on = true; liveTvAddon = a.url; liveTvCatId = hit.optString("id")
                liveTvGenres = hit.optJSONArray("genres")?.let { g -> (0 until g.length()).map { g.optString(it) } } ?: emptyList()
                break
            }
        }
        liveTvOn = on
        if (prev != on && tab == "Home" && Store.onboarded(this)) runOnUiThread { runCatching { showMain() } }
    }

    private val isTv: Boolean by lazy {
        (getSystemService(UI_MODE_SERVICE) as android.app.UiModeManager).currentModeType ==
            android.content.res.Configuration.UI_MODE_TYPE_TELEVISION
    }

    private var contentRef: View? = null
    private var lastContentFocus: View? = null   // the poster the cursor was on
    private var focusGraceUntil = 0L

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // cold start / return-from-player: land the cursor ON the first row item, never the
        // menu — this event fires when focusing can actually succeed (timed retries lost
        // races on slow sticks, so the first button press was opening the rail instead)
        if (hasFocus && isTv && System.currentTimeMillis() < focusGraceUntil &&
            (currentFocus == null || (railHasFocus() && !userNavigatedSincePageShown())))
            (firstContentFocus ?: contentRef?.let { focusableOf(it) })?.requestFocus()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        lastTitle?.let {
            outState.putString("navId", it.id); outState.putString("navType", it.type)
            outState.putString("navName", it.name); outState.putString("navPoster", it.poster)
        }
    }

    /** Fire OS kills a memory-heavy app SILENTLY (no crash trace ever arrives) — so beacon
     *  the pressure while we're still alive, and shed the image cache to dodge the kill. */
    private var lowmemReported = false
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level == TRIM_MEMORY_UI_HIDDEN) return   // backgrounded, not real pressure
        // GRADUATED (AJ Sep 15): Fire OS fires RUNNING_LOW (10) constantly during NORMAL
        // browsing on the sticks. The old code nuked the ENTIRE image cache + dropped every
        // off-screen poster on every one of those — which is exactly what made the home screen
        // thrash into "a bunch of blank squares" that had to re-decode. Now we only shed HARD
        // when a kill is actually imminent; at mild pressure we leave the cache alone so posters
        // stay instant (Netflix/Stremio don't blank out on a routine trim, and neither should we).
        when {
            level >= TRIM_MEMORY_MODERATE -> {                 // 60/80: about to be killed — survive
                runCatching { coil.Coil.imageLoader(this).memoryCache?.clear() }
                runCatching { Http.dropCache() }               // shelf-JSON cache goes too
                if (mainStash?.parent == null) { mainStash = null; mainStashTab = null }  // detached page tree = free it
                runCatching { artPassNow(aggressive = true) }
            }
            level >= TRIM_MEMORY_RUNNING_CRITICAL -> {         // 15: real foreground pressure — trim
                runCatching { artPassNow() }                   // drop only far off-screen art, keep the cache + visible
            }
            // level 10 (RUNNING_LOW): ignore — the normal scroll art-pass already bounds memory
        }
        // once per session, only for genuine pressure (not the routine level-10 noise) so the
        // admin side doesn't read normal browsing as a stream of "crashes" (Sep 3)
        if (!lowmemReported && level >= TRIM_MEMORY_RUNNING_CRITICAL) {
            lowmemReported = true
            val rt = Runtime.getRuntime()
            val heap10 = ((rt.totalMemory() - rt.freeMemory()) / 1048576 / 10) * 10   // 10MB buckets: stable dedup key
            CrashGuard.report(this, "lowmem", "level=$level tab=$tab heap≈${heap10}MB max=${rt.maxMemory() / 1048576}MB")
        }
    }

    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        CrashGuard.install(this)
        // low-RAM TV image pipeline (Stremio-class smoothness on a 1GB stick): RGB_565
        // halves every decoded bitmap, the memory cache stays small, and disk caching
        // ignores server headers so revisited art is always instant. Fire OS was silently
        // memory-killing the app once decoded bitmaps piled up — no crash report, just gone.
        coil.Coil.setImageLoader(coil.ImageLoader.Builder(this)
            .allowRgb565(true)
            // 0.15 starved a browse session: neighbor backdrops + a couple rows of
            // tiles evicted each other, so refocus/scroll-back RE-DECODED posters every
            // time ("art got laggy", AJ Sep 11). 0.25 is still LRU-bounded and trimmed
            // under pressure — the LMK protection is the tile virtualization (dropping
            // offscreen ImageView drawables), not this percentage.
            .memoryCache { coil.memory.MemoryCache.Builder(this).maxSizePercent(0.25).build() }
            // PERSISTENT DISK CACHE (AJ Sep 18 "Stremio's images load instantly"): without
            // this, posters re-download every session. 300MB on disk = once seen, a poster
            // loads instantly from disk forever after — the biggest perceived-speed win.
            .diskCache { coil.disk.DiskCache.Builder()
                .directory(cacheDir.resolve("ck_img_cache"))
                .maxSizeBytes(300L * 1024 * 1024).build() }
            .crossfade(false)   // no fade = the image just appears (snappier on TV)
            .respectCacheHeaders(false)
            // nearly all art rides ONE host (metahub) and OkHttp caps a host at 5
            // concurrent calls — a freshly revealed row of ~8 posters queued behind
            // itself, which read as one-by-one pop-in on the stick
            .callFactory(okhttp3.OkHttpClient.Builder()
                .dispatcher(okhttp3.Dispatcher().apply { maxRequestsPerHost = 12 })
                .build())
            .build())
        // catalog/meta JSON survives restarts (AJ Sep 24 "fast like Netflix"): cold opens
        // paint rows + descriptions from disk instantly, network refreshes behind them
        Http.diskDir = cacheDir.resolve("ck_json_cache").apply { mkdirs() }
        Thread {   // startup sweep: anything a week old is dead weight on a 1GB stick
            runCatching {
                val cut = System.currentTimeMillis() - 7 * 86400_000L
                Http.diskDir?.listFiles()?.forEach { if (it.lastModified() < cut) it.delete() }
            }
        }.start()
        root = FrameLayout(this).apply { setBackgroundColor(bg) }
        setContentView(root)
        // ONE app-wide scroll listener (the window's tree observer sees every scroller —
        // vertical boards AND each row's horizontal strip) drives the debounced art pass
        root.viewTreeObserver.addOnScrollChangedListener { scheduleArtPass() }
        // one-time migration (full channel): apex-hosted addon URLs move to the direct mirror
        if (Dist.MIGRATE_FROM.isNotBlank()) Store.addons(this).filter { it.url.startsWith(Dist.MIGRATE_FROM) }.forEach {
            Store.removeAddon(this, it.url)
            Store.addAddon(this, Addon(it.url.replace(Dist.MIGRATE_FROM, Dist.MIGRATE_TO), it.name))
        }
        pendingContentFocus = true   // open ON the Home content, not the menu rail
        if (Store.onboarded(this)) profileGate() else showOnboarding()
        // Android killed us behind the player? Come back to the page they LEFT, not Home
        s?.getString("navId")?.let { nid ->
            showDetail(Title(nid, s.getString("navType") ?: "movie",
                s.getString("navName") ?: "", s.getString("navPoster")))
        }
        // every launch pulls the account state so shelves + settings match the other devices
        if (Store.signedIn(this)) scope.launch {
            // OFF the UI thread: the network fetch is already IO, but importMerge (parsing +
            // merging the whole synced state blob into prefs) ran on MAIN and froze the cursor
            // on the profile picker for ~a second on cold open. Run it all on IO. (AJ Sep 27)
            withContext(Dispatchers.IO) { Sync.pullMerge(this@MainActivity) }
            // profiles just synced down and nobody's picked yet -> who's watching.
            // NEVER showMain() while the picker is up (was flashing Home/Continue Watching
            // between two picker renders, AJ Sep 18). Only re-show the picker if it isn't
            // already up (no flicker), and only showMain once a profile IS picked.
            if (!profilePicked) {
                if (!pickerShowing() && Store.profiles(this@MainActivity).isNotEmpty()
                    && Store.onboarded(this@MainActivity)) profileGate()
            } else if (tab == "Home" && Store.onboarded(this@MainActivity)) {
                // THE "PROFILE BLIP" (AJ Sep 18 "it does it if I only had the app open kinda
                // recently"): on a WARM reopen profileGate() already auto-resumed straight into
                // Home from the cached profile blob a few lines up. Calling a full showMain()
                // here tore that whole Home down and rebuilt it a beat later once this async
                // pull landed — posters reload, focus jumps, the page visibly flashes. A COLD
                // open never hit this (no profile picked yet → shows the picker instead), which
                // is exactly why it only blipped when the app had been open recently.
                // Repaint IN PLACE with what the pull brought down instead — same as onResume.
                runCatching { refreshContinueRow() }; runCatching { refreshEpisodeBars() }
            }
            withContext(Dispatchers.IO) { runCatching { detectLiveTv() } }
        } else scope.launch { withContext(Dispatchers.IO) { runCatching { detectLiveTv() } } }
    }

    override fun onResume() {
        super.onResume()
        // Returned from the player after it AUTO-ADVANCED episodes → jump the stale episode page
        // to the CURRENT episode (leaving the show under it, so BACK goes to the show, not the
        // episode we started on). (AJ Sep 27: watched ep2→ep5, back showed ep2's streams)
        Ck.playerAdvancedShow?.let { adv ->
            Ck.playerAdvancedShow = null
            val m = curEpMeta
            if (m != null && m.id == adv) {
                val cur = currentEpisode(m)
                if (cur != null && (cur.season != curEpEp?.season || cur.episode != curEpEp?.episode)) {
                    poppingBack = true          // REPLACE the stale episode page, don't stack it
                    runCatching { showEpisodeDetail(m, cur) }
                    poppingBack = false
                }
            }
        }
        // Google Play In-App Update check (store flavor only; no-op stub elsewhere). Forced
        // (immediate) when the release's inAppUpdatePriority >=4 in Play Console; Play installs
        // it in-app with no store visit. Also resumes an interrupted immediate update. (AJ Sep 27)
        runCatching { checkStoreUpdate(this) }
        // the player changed progress/watched state: Continue Watching must already be
        // right when Home reappears — new order, fresh bars, finished movies gone (AJ:
        // "should update by the time I close the player", Coyote vs Acme)
        // hardened: a repaint glitch must never take the app down (v0.92 stick crash)
        if (Ck.homeStale) { Ck.homeStale = false
            runCatching { refreshContinueRow() }; runCatching { refreshEpisodeBars() } }
        // still-watching timed out overnight: whoever's back gets "Who's watching?"
        if (Ck.stillWatchTimedOut) { Ck.stillWatchTimedOut = false
            runCatching { showProfilePicker() } }
        // back from the live player: rebuild the guide so the red now-line + current-program
        // blocks reflect NOW, not tune time (rebuild also re-centers the timeline on now)
        if (Ck.liveDirty) { Ck.liveDirty = false; liveGuideAt = 0 }   // in-player ★/hops: refetch favs+recent
        Ck.liveFocus?.let { liveFocusId = it; Ck.liveFocus = null }   // cursor lands on the LAST channel they hopped to
        if (liveGuideStale) { liveGuideStale = false
            if (tab == "Live TV") runCatching { showMain("Live TV") } else liveFocusId = null }
        // ANY other wake onto a Live TV page older than a minute repaints it too (AJ Sep 26
        // "it still has the old games up and i gotta refresh the live page") — reopening the
        // app on the tab used to show yesterday's games until a manual refresh
        else if (tab == "Live TV" && livePageAt > 0 && System.currentTimeMillis() - livePageAt > 60_000)
            runCatching { showMain("Live TV") }
        // pick up what other devices watched (resume bars etc.) the moment we're back
        if (Store.signedIn(this)) scope.launch {
            val profsBefore = profilesSig()
            val pulled = try { Sync.pullMerge(this@MainActivity) } catch (_: Exception) { false }
            // a profile added/edited on ANOTHER TV lands here the moment we wake, not on the
            // next full app relaunch (AJ Sep 17: second Fire TV showed stale profiles)
            if (pulled) refreshPickerIfChanged(profsBefore)
            // an account with NO profiles must land on "Create your profile" — THEY name it
            // (AJ Sep 26 "i want it to show up with the profile that they create"). The
            // launch race used to let them slip past and browse profile-less forever
            // (Stefan): the create screen only ever showed if the FIRST pull won the race.
            if (!profileCreatePrompted && pulled && !profilePicked &&
                Store.profiles(this@MainActivity).isEmpty() &&
                (Store.serviceBase(this@MainActivity).isNotBlank() || Dist.DEFAULT_SERVICE.isNotBlank()) &&
                !pickerShowing()) {
                profileCreatePrompted = true
                runCatching { showProfileCreate(first = true) }
            }
            // keep the cached expiry fresh (drives the Settings line + the play-time
            // banner) — but DO NOT block the whole app (AJ Sep 18: browsing stays open,
            // the expired banner only appears where streams would be, at play time)
            runCatching {
                Addons.access(this@MainActivity, Store.account(this@MainActivity))?.let { acc ->
                    Store.setAccessStatus(this@MainActivity, acc.expires, acc.daysLeft)
                }
            }
            // repaint with what the pull just brought DOWN (Sep 13): fresh cross-device
            // order/positions previously sat unrendered until the next full Home rebuild —
            // the phone kept showing days-old order even though it had already synced
            if (pulled && tab == "Home") {
                runCatching { refreshContinueRow() }; runCatching { refreshEpisodeBars() }
            }
            // if they entered a code before being granted, the addon appears the moment
            // they're enabled — no need to visit Settings (just reopen the app)
            if (Store.serviceBase(this@MainActivity).isNotBlank() && Store.addons(this@MainActivity).isEmpty()) {
                try {
                    Addons.access(this@MainActivity, Store.account(this@MainActivity))?.assignedAddon?.let { url ->
                        val nm = runCatching { Addons.probe(url)?.name }.getOrNull() ?: Dist.DEFAULT_ADDON_NAME
                        Store.addAddon(this@MainActivity, Addon(url, nm))
                    }
                } catch (_: Exception) {}
            }
            // same late-sync catch as launch: profiles arrived after a failed first pull.
            // MUST skip while the picker is already up (same guard as the launch path) —
            // without it, this fired 1-3s into EVERY cold open when the routine pull landed,
            // rebuilt the picker mid-scroll, and snapped the cursor back to the first face
            // (AJ Sep 24: "it ALWAYS jumps back to the first and then I can scroll freely").
            if (!profilePicked && !pickerShowing() && tab == "Home" && Store.onboarded(this@MainActivity)
                && Store.profiles(this@MainActivity).isNotEmpty()) profileGate()
            runCatching { detectLiveTv() }
        }
        liveSyncHandler.removeCallbacks(liveSyncTick)
        liveSyncHandler.postDelayed(liveSyncTick, 60_000)
        // clear a stale update pill: if the offered version is now installed, rebuild home
        val cur = try { packageManager.getPackageInfo(packageName, 0).versionName } catch (_: Exception) { null }
        if (updateOffered != null && updateOffered == cur) {
            updateOffered = null; pendingUpdate = null
            root.findViewWithTag<View>("updpill")?.let { root.removeView(it) }
            if (Store.onboarded(this)) showMain()
        }
    }

    override fun onPause() {
        super.onPause()
        liveSyncHandler.removeCallbacks(liveSyncTick)
        // push the library to the account so other devices pick it up
        if (Store.signedIn(this)) Thread {
            try { kotlinx.coroutines.runBlocking { Sync.push(this@MainActivity) } } catch (_: Exception) { }
        }.start()
    }

    // LIVE Home refresh (AJ Sep 13, full-sync pass): an app sitting open on Home never
    // pulled — the TV could binge a whole season while the phone showed days-old order.
    // Every 60s in the foreground: pull + repaint the Continue row in place.
    private val liveSyncHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val liveSyncTick = object : Runnable {
        override fun run() {
            if (Store.signedIn(this@MainActivity)) scope.launch {
                val profsBefore = profilesSig()
                val ok = try { Sync.pullMerge(this@MainActivity) } catch (_: Exception) { false }
                if (ok) {
                    if (tab == "Home") runCatching { refreshContinueRow() }
                    // bars repaint on EVERY page (AJ Sep 14: a position synced in while he
                    // sat on the episode list — the CW bar knew, the purple bar didn't)
                    runCatching { refreshEpisodeBars() }
                    refreshPickerIfChanged(profsBefore)
                }
            }
            // who's-watching open = someone may be adding a profile on the other TV right
            // now — poll fast so it shows up while they're still looking at the page
            liveSyncHandler.postDelayed(this, if (pickerShowing()) 15_000L else 60_000L)
        }
    }

    // ---- live profile sync (AJ Sep 17): profiles ride the same pulls as CW, but the
    // who's-watching page never repainted — the other Fire TV kept showing stale
    // profiles/colors "until way later". Sig-gated so an unchanged tick never re-renders
    // (a repaint yanks focus back to the first face). ----
    // ORDER-INDEPENDENT (AJ Sep 18): the sync reorders profiles, which changed the sig and
    // rebuilt the picker mid-open — resetting the cursor to the first profile ("blinks back
    // to the first then I can move"). Sorting means only a real add/remove/rename rebuilds.
    private fun profilesSig(): String =
        Store.profiles(this).map { "${it.id},${it.name},${it.avatar},${it.color}" }.sorted().joinToString("|")
    private fun pickerShowing(): Boolean = root.findViewWithTag<View>("profilePicker") != null
    private fun refreshPickerIfChanged(before: String) {
        if (!pickerShowing()) return
        // NEVER rebuild while the cursor is on the picker (reset focus to first profile).
        if (root.findFocus() != null) return
        if (before != profilesSig()) runCatching { showProfilePicker() }
    }

    override fun onDestroy() { scope.cancel(); super.onDestroy() }
    private var pendingUpdate: Updater.Update? = null
    // once a MANDATORY update screen is up it must stay up. It's a child of root, but every
    // swap() does root.removeAllViews() — a background pull/refresh that rebuilt a page then
    // WIPED the cover and left the live page tappable behind it (AJ Sep 18: "I could still
    // click behind the mandatory updates"). These latch the block so swap() re-asserts it.
    private var mandatoryUpd: Updater.Update? = null
    private var storeMandatoryActive = false

    private fun swap(v: View) {
        root.removeAllViews(); root.addView(v)
        pageShownAt = System.currentTimeMillis()   // keys after this = deliberate navigation
        attachUpdatePill()
        scheduleArtPass()   // the new page's lazy tiles need their first load
        // re-assert an active mandatory block on top of whatever just rendered
        mandatoryUpd?.let { showMandatoryUpdate(it) }
        if (storeMandatoryActive) showStoreMandatoryUpdate()
    }

    /** The gold update button rides ABOVE every page (it kept getting rebuilt away when Home
     *  refreshed) — pinned top-center, focusable ring, stays until the new version is on. */
    private fun attachUpdatePill() {
        val upd = pendingUpdate ?: return
        if (isTv) return   // TV: the rail carries the Update entry below Settings instead
        if (root.findViewWithTag<View>("updpill") != null) return
        val b = Button(this).apply {
            tag = "updpill"
            text = "⬆ Update to v${upd.version}"; isAllCaps = false; setTextColor(Color.BLACK)
            background = selBg(Color.parseColor("#F5C518"), 22, Color.WHITE); stateListAnimator = null
            isFocusable = true
            layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL)
                .apply { setMargins(0, if (isTv) dp(6) else statusBarPad(), 0, 0) }
            setOnClickListener { Updater.downloadAndInstall(this@MainActivity, upd) { st -> text = st } }
        }
        root.addView(b)
    }

    /** MANDATORY update screen (AJ Sep 13): full-screen block, the Update button is the only
     *  focusable/clickable thing, BACK is consumed. Shown when the channel's minVersion is
     *  above this build — ends cross-device version skew for good. */
    // browsing stays OPEN; only at PLAY time, if the sub is expired, a plain BANNER (no
    // button, no dialog) shows WHERE THE STREAMS would be (AJ Sep 18). Instant, from cache.
    private fun isExpired(): Boolean {
        if (!Store.signedIn(this) || Store.accessExpiry(this).isBlank()) return false
        val d = Store.accessDaysLeft(this)
        return d in -3649..-1
    }
    // the banner view itself — a message, nothing clickable
    private fun expiryBanner(): View = column().apply {
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(dp(24), dp(40), dp(24), dp(40))
        addView(TextView(this@MainActivity).apply { text = "⛔"; textSize = 44f; gravity = Gravity.CENTER })
        addView(TextView(this@MainActivity).apply {
            text = "Subscription expired"; setTextColor(fg); textSize = 20f
            setTypeface(typeface, Typeface.BOLD); gravity = Gravity.CENTER; setPadding(0, dp(10), 0, dp(6))
        })
        addView(TextView(this@MainActivity).apply {
            text = "Renew your plan to keep watching."; setTextColor(dim); textSize = 14f; gravity = Gravity.CENTER
        })
    }

    private fun showMandatoryUpdate(upd: Updater.Update) {
        mandatoryUpd = upd   // latch so swap() re-asserts it (see swap())
        if (root.findViewWithTag<View>("mandupd") != null) return
        root.findViewWithTag<View>("updpill")?.let { root.removeView(it) }
        root.findViewWithTag<View>("expblock")?.let { root.removeView(it) }   // update always wins over any leftover cover
        val cover = LinearLayout(this).apply {
            tag = "mandupd"; orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#FF0E0C1B"))   // FULLY opaque — nothing behind shows or is clickable
            isClickable = true; isFocusable = true
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            setOnClickListener {}   // consume ALL taps so nothing behind is clickable (AJ Sep 18)
            setOnKeyListener { _, keyCode, _ -> keyCode == android.view.KeyEvent.KEYCODE_BACK }
        }
        cover.addView(bigText("Update required", 26f).apply { gravity = Gravity.CENTER })
        cover.addView(dimText("This version is out of date and can't sync correctly.\nUpdate to v${upd.version} to keep watching.").apply {
            gravity = Gravity.CENTER; setPadding(dp(24), dp(8), dp(24), dp(18))
        })
        val btn = Button(this).apply {
            text = "⬆ Update now"; isAllCaps = false; setTextColor(Color.BLACK)
            background = selBg(Color.parseColor("#F5C518"), 22, Color.WHITE); stateListAnimator = null
            isFocusable = true
            setOnKeyListener { _, keyCode, _ -> keyCode == android.view.KeyEvent.KEYCODE_BACK }
            setOnClickListener { Updater.downloadAndInstall(this@MainActivity, upd) { st -> text = st } }
        }
        cover.addView(btn)
        // FOCUS TRAP (AJ Sep 18 "I can still click behind the mandatory screen"): on TV the
        // D-pad could move focus to the rows BEHIND the cover. Block focus on everything
        // already in root so ONLY the Update button is reachable.
        for (i in 0 until root.childCount) (root.getChildAt(i) as? android.view.ViewGroup)
            ?.descendantFocusability = android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS
        root.addView(cover)
        cover.bringToFront()   // always the top-most view
        btn.requestFocus()
    }

    /** Store-flavor version gate (AJ Sep 13, coded Sep 14): below the service's published
     *  minVersion the app blocks exactly like the sideload mandatory screen, but the only
     *  button opens this build's OWN store listing (Play or Amazon by flavor). */
    private fun showStoreMandatoryUpdate() {
        storeMandatoryActive = true   // latch so swap() re-asserts it (see swap())
        if (root.findViewWithTag<View>("mandupd") != null) return
        val cover = LinearLayout(this).apply {
            tag = "mandupd"; orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#FF0E0C1B"))   // FULLY opaque — nothing behind shows
            isClickable = true; isFocusable = true
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            setOnClickListener {}   // consume ALL taps so nothing behind is tappable (AJ Sep 18)
            setOnKeyListener { _, keyCode, _ -> keyCode == android.view.KeyEvent.KEYCODE_BACK }
        }
        cover.addView(bigText("Update required", 26f).apply { gravity = Gravity.CENTER })
        cover.addView(dimText("This version is out of date and can't sync correctly.\nUpdate from the store to keep watching.").apply {
            gravity = Gravity.CENTER; setPadding(dp(24), dp(8), dp(24), dp(18))
        })
        val amazon = BuildConfig.FLAVOR == "amazon"
        val btn = Button(this).apply {
            text = if (amazon) "⬆ Update on Amazon Appstore" else "⬆ Update on Google Play"
            isAllCaps = false; setTextColor(Color.BLACK)
            background = selBg(Color.parseColor("#F5C518"), 22, Color.WHITE); stateListAnimator = null
            isFocusable = true
            setOnKeyListener { _, keyCode, _ -> keyCode == android.view.KeyEvent.KEYCODE_BACK }
            setOnClickListener {
                val deep = if (amazon) "amzn://apps/android?p=$packageName" else "market://details?id=$packageName"
                val web = if (amazon) "https://www.amazon.com/gp/mas/dl/android?p=$packageName"
                          else "https://play.google.com/store/apps/details?id=$packageName"
                try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(deep))) }
                catch (_: Exception) { try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(web))) } catch (_: Exception) {} }
            }
        }
        cover.addView(btn)
        // FOCUS TRAP (same as the sideload cover): block D-pad focus on everything already in
        // root so ONLY the Update button is reachable behind the block on TV.
        for (i in 0 until root.childCount) (root.getChildAt(i) as? android.view.ViewGroup)
            ?.descendantFocusability = android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS
        root.addView(cover)
        cover.bringToFront()
        btn.requestFocus()
    }

    // ---------- onboarding: welcome -> real Sign in / Create account pages ----------
    private fun showOnboarding() {
        val col = column().apply { gravity = Gravity.CENTER; setPadding(dp(28)) }
        col.addView(ImageView(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(120), dp(120)); load(R.drawable.ck_logo)
        })
        col.addView(bigText("CouchKing", 30f).apply { text = brandSpan("CouchKing") })
        col.addView(dimText("Discover movies & shows — trailers, ratings, cast, where to watch, and your own watch tracker."))
        // Everyone accepts once before entering (guests included) — required for the stores.
        val agree = CheckBox(this).apply {
            text = "I agree to the Terms & Conditions and Privacy Policy"
            setTextColor(fg); buttonTintList = android.content.res.ColorStateList.valueOf(accent)
            setPadding(dp(6), dp(10), 0, dp(2)); isChecked = Store.acceptedLegal(this@MainActivity)
        }
        fun gate(go: () -> Unit): () -> Unit = {
            if (!agree.isChecked) toast("Please accept the Terms & Privacy Policy to continue")
            else { Store.setAcceptedLegal(this); go() }
        }
        col.addView(pill("Sign in", gate { showSignIn() }))
        col.addView(pill("Create account", gate { showSignUp() }))
        col.addView(ghostPill("Continue as guest", gate { Store.setOnboarded(this); profileGate() }))
        col.addView(agree)
        col.addView(termsLinksRow())
        swap(scroll(col))
    }

    private fun termsLinksRow() = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(TextView(this@MainActivity).apply {
            text = "Terms & Conditions"; setTextColor(accent); setPadding(0, dp(10), dp(18), dp(10))
            isClickable = true; isFocusable = true
            setOnClickListener { showTerms() }
        })
        addView(TextView(this@MainActivity).apply {
            text = "Privacy Policy"; setTextColor(accent); setPadding(0, dp(10), 0, dp(10))
            isClickable = true; isFocusable = true
            setOnClickListener { showPrivacy() }
        })
    }

    private fun showSignIn() {
        val col = column().apply { gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(28), statusBarPad(), dp(28), dp(28)) }
        col.addView(bigText("Sign in", 26f))
        col.addView(dimText("Welcome back — your library follows your account."))
        val email = field("Email").apply { inputType = 0x21 }
        val pass = field("Password").apply { inputType = 0x81 }
        col.addView(email); col.addView(pass)
        col.addView(pill("Sign in") {
            val addr = email.text.toString().trim()
            if (addr.isBlank() || pass.text.isBlank()) { toast("Enter email and password"); return@pill }
            toast("Signing in…")
            scope.launch {
                val r = Sync.auth(this@MainActivity, addr, pass.text.toString(), mode = "signin")
                if (!r.ok) { toast(r.error ?: "Sign-in failed"); return@launch }
                finishAuth(addr, created = false)
            }
        })
        col.addView(ghostPill("Forgot password?") { showForgotPassword(email.text.toString().trim()) })
        col.addView(ghostPill("New here? Create account") { showSignUp() })
        col.addView(ghostPill("‹ Back") { if (Store.onboarded(this)) showSettings() else showOnboarding() })
        swap(scroll(col))
    }

    /** Forgot password: email -> 6-digit code (15 min) -> new password. The service resets
     *  the account token, so other devices just re-prompt for the new password. */
    private fun showForgotPassword(prefill: String = "") {
        val col = column().apply { gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(28), statusBarPad(), dp(28), dp(28)) }
        col.addView(bigText("Reset password", 26f))
        col.addView(dimText("We'll email you a 6-digit code — it expires in 15 minutes."))
        val email = field("Email").apply { inputType = 0x21; setText(prefill) }
        col.addView(email)
        val codeRow = column().apply { visibility = View.GONE }
        val code = field("6-digit code").apply { inputType = 0x2 }
        val pass = field("New password (4+ characters)").apply { inputType = 0x81 }
        val pass2 = field("Confirm new password").apply { inputType = 0x81 }
        codeRow.addView(code); codeRow.addView(pass); codeRow.addView(pass2)
        lateinit var sendPill: View
        sendPill = pill("Email me the code") {
            val addr = email.text.toString().trim()
            if (!addr.contains("@") || !addr.contains(".")) { toast("Enter a valid email"); return@pill }
            toast("Sending…")
            scope.launch {
                Http.post("${Store.serviceBase(this@MainActivity).ifBlank { Dist.DEFAULT_SERVICE }}/tvapp/reset-request",
                    org.json.JSONObject().put("email", addr))
                toast("If that email has an account, the code is on its way")
                codeRow.visibility = View.VISIBLE
                code.requestFocus()
            }
        }
        col.addView(sendPill)
        col.addView(codeRow)
        codeRow.addView(pill("Set new password") {
            val addr = email.text.toString().trim()
            when {
                code.text.length != 6 -> toast("Enter the 6-digit code from the email")
                pass.text.length < 4 -> toast("Password needs 4+ characters")
                pass.text.toString() != pass2.text.toString() -> toast("Passwords don't match")
                else -> scope.launch {
                    val r = Http.post("${Store.serviceBase(this@MainActivity).ifBlank { Dist.DEFAULT_SERVICE }}/tvapp/reset",
                        org.json.JSONObject().put("email", addr).put("code", code.text.toString().trim())
                            .put("password", pass.text.toString()))
                    if (r?.optBoolean("ok") == true) {
                        toast("Password updated — signing you in")
                        val a = Sync.auth(this@MainActivity, addr, pass.text.toString(), mode = "signin")
                        if (a.ok) finishAuth(addr, created = false) else showSignIn()
                    } else toast(r?.optString("error")?.ifBlank { null } ?: "Wrong or expired code")
                }
            }
        })
        col.addView(ghostPill("‹ Back") { showSignIn() })
        swap(scroll(col))
    }

    private fun showSignUp() {
        val col = column().apply { gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(28), statusBarPad(), dp(28), dp(28)) }
        col.addView(bigText("Create account", 26f))
        col.addView(dimText("One account, every device — your watchlist and history sync."))
        val name = field("Name").apply { inputType = 0x2001 }
        val email = field("Email").apply { inputType = 0x21 }
        val pass = field("Password (4+ characters)").apply { inputType = 0x81 }
        val pass2 = field("Confirm password").apply { inputType = 0x81 }
        col.addView(name); col.addView(email); col.addView(pass); col.addView(pass2)
        val terms = CheckBox(this).apply {
            text = "I agree to the Terms & Conditions"; setTextColor(dim)
            buttonTintList = android.content.res.ColorStateList.valueOf(accent)
        }
        col.addView(terms)
        col.addView(termsLinksRow())
        col.addView(pill("Create account") {
            val addr = email.text.toString().trim()
            when {
                name.text.isBlank() -> toast("Enter your name")
                !addr.contains("@") || !addr.contains(".") -> toast("Enter a valid email")
                pass.text.length < 4 -> toast("Password needs 4+ characters")
                pass.text.toString() != pass2.text.toString() -> toast("Passwords don't match")
                !terms.isChecked -> toast("Please accept the Terms & Conditions")
                else -> {
                    toast("Creating account…")
                    scope.launch {
                        val r = Sync.auth(this@MainActivity, addr, pass.text.toString(),
                            name = name.text.toString().trim(), mode = "signup")
                        if (!r.ok) { toast(r.error ?: "Couldn't create the account"); return@launch }
                        finishAuth(addr, created = r.created)
                    }
                }
            }
        })
        col.addView(ghostPill("Already have an account? Sign in") { showSignIn() })
        col.addView(ghostPill("‹ Back") { if (Store.onboarded(this)) showSettings() else showOnboarding() })
        swap(scroll(col))
    }

    /** Post-auth: allow-list check + silent install of the account's ASSIGNED addon (the
     *  owner's /whitelist command maps email -> addon URL — nobody pastes anything). */
    private fun finishAuth(addr: String, created: Boolean) {
        Store.setOnboarded(this)
        toast(if (created) "Account created — your library now syncs across devices" else "Signed in — library synced")
        scope.launch {
            // restore the account BEFORE the who's-watching gate, with retries — one
            // dropped request must never read as "brand-new account" (that's how a
            // returning sign-in got a forced Create Profile over two real profiles)
            var acc: Addons.Access? = null
            var pulled = false
            for (i in 0 until 3) {
                if (acc == null) acc = Addons.access(this@MainActivity, addr)
                if (!pulled) pulled = Sync.pullMerge(this@MainActivity)
                if (acc != null && pulled) break
                kotlinx.coroutines.delay(1200)
            }
            acc?.let { a ->
                Store.setAccessStatus(this@MainActivity, a.expires, a.daysLeft)
                val assigned = a.assignedAddon
                if (assigned != null && Store.addons(this@MainActivity).isEmpty()) {
                    // install directly — probe is only for a prettier name, never a gate
                    val nm = runCatching { Addons.probe(assigned)?.name }.getOrNull() ?: Dist.DEFAULT_ADDON_NAME
                    Store.addAddon(this@MainActivity, Addon(assigned, nm))
                }
            }
            // the addon just landed mid-session: Live TV must gate ON now, not on the next
            // relaunch (AJ Sep 24: "have to close the app and open it back up for live tv")
            runCatching { detectLiveTv() }
            if (!pulled && !created && Store.profiles(this@MainActivity).isEmpty())
                toast("Signed in — couldn't reach your service yet; your profiles appear once it syncs")
            profileGate()
        }
    }

    // ---- Netflix-style profiles: FIRST thing after launch — who's watching? ----
    private var profilePicked = false
    private var profileCreatePrompted = false   // one create-screen walk-in per process
    private val avatarChoices = listOf(
        "👑", "🦁", "🦊", "🐼", "🐸", "🚀", "🌸", "🎮", "🐱", "🐶", "🐰", "🐻",
        "🐧", "🦄", "⚽", "🍕", "🤖", "👽", "🦸", "🍿", "⭐", "🌟", "🎈", "🎸")
    // pickable avatar background colors (a profile's color is stored on it; blank = derived
    // from the id so old profiles are unchanged). First entry mirrors the old default hue.
    private val colorChoices = listOf(
        "#7B5BF5", "#E2574C", "#4CAF7D", "#E2A54C", "#4C9DE2", "#C24CE2", "#E24C9D", "#3FB6B0")

    private fun profileGate() {
        // profiles belong to ACCOUNTS: sign in first, THEN who's-watching. Guests never
        // see any of it (AJ) — they browse straight in.
        if (!Store.signedIn(this)) { showMain(); return }
        // your profiles live on the account and only sync once a service is connected. On a
        // fresh store sign-in there's no service yet, so DON'T force a throwaway "create
        // profile" — let them in; the picker appears after they add their access code and
        // their real profiles sync down. (Same on TV and mobile.)
        val serviceReady = Store.serviceBase(this).isNotBlank() || Dist.DEFAULT_SERVICE.isNotBlank()
        val profs = Store.profiles(this)
        when {
            profs.isEmpty() && !serviceReady -> showMain()
            // no profiles AND no successful sync yet: we can't tell "new account" from
            // "couldn't ask" — let them browse; the picker appears when the pull lands
            profs.isEmpty() && !Sync.pulledOk -> showMain()
            profs.isEmpty() -> showProfileCreate(first = true)
            !profilePicked -> {
                // AUTO-RESUME only when the activity was recreated MID-SESSION (Fire OS
                // reclaimed MainActivity while the player was up) — sessionActive is a
                // process-scoped flag: true = same process (recreation), false = a true
                // COLD app open. On cold open ALWAYS ask "who's watching" (AJ Sep 18: "it
                // used to ask what profile, now it just puts me in"). The 6h prefs check
                // alone was skipping the picker on every launch.
                val p = getSharedPreferences("ckprof", 0)
                val lp = p.getString("lastPid", "") ?: ""
                if (sessionActive && lp.isNotBlank() && profs.any { it.id == lp }) {
                    Store.switchProfile(this, lp)
                    profilePicked = true; sessionActive = true
                    showMain(p.getString("lastTab", "Home") ?: "Home")   // land where they WERE
                } else showProfilePicker()
            }
            else -> showMain()
        }
    }

    private fun profileColor(id: String): Int {
        val palette = listOf("#7B5BF5", "#E2574C", "#4CAF7D", "#E2A54C", "#4C9DE2", "#C24CE2")
        return Color.parseColor(palette[Math.abs(id.hashCode()) % palette.size])
    }

    private fun profileHue(pr: Store.Profile): Int =
        pr.color.ifBlank { "" }.let { c -> runCatching { Color.parseColor(c) }.getOrNull() } ?: profileColor(pr.id)

    private fun avatarView(pr: Store.Profile, size: Int): View = FrameLayout(this).apply {
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
        background = GradientDrawable().apply { setColor(profileHue(pr)); shape = GradientDrawable.OVAL }
        addView(TextView(this@MainActivity).apply {
            text = pr.avatar.ifBlank { pr.name.take(1).uppercase() }
            textSize = size * 0.42f; gravity = Gravity.CENTER; setTextColor(fg)
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
        })
    }

    private fun showProfilePicker() {
        // if the picker is ALREADY up and the cursor is on a face, remember WHICH one —
        // any rebuild (late sync, repaint) must put the cursor back there, never on face #1
        // (AJ Sep 24 "it ALWAYS jumps back to the first"). Fresh open: null → first face.
        val keepPid = if (pickerShowing()) root.findFocus()?.tag as? String else null
        val col = column().apply { gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(28), dp(48), dp(28), dp(28)) }
        col.addView(bigText("Who's watching?", 28f))
        col.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(0, dp(26)) })
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        Store.profiles(this).forEach { pr ->
            row.addView(column().apply {
                gravity = Gravity.CENTER_HORIZONTAL
                tag = pr.id   // identifies the tile for cursor restore across rebuilds
                // even padding all round so the focus square sits CENTERED on the tile (was
                // 0dp top/bottom → the ring hugged the avatar top and sat lopsided). (AJ Sep 15)
                setPadding(dp(14), dp(14), dp(14), dp(12))
                isFocusable = true; isClickable = true; isLongClickable = true
                background = selBg(Color.TRANSPARENT, 18)
                addView(avatarView(pr, 92))
                addView(TextView(this@MainActivity).apply {
                    text = pr.name; setTextColor(fg); textSize = 15f; gravity = Gravity.CENTER
                    setPadding(0, dp(8), 0, 0)
                })
                setOnClickListener {
                    Store.switchProfile(this@MainActivity, pr.id)
                    profilePicked = true; sessionActive = true
                    // remember on DISK: Fire OS reclaims this activity during playback and
                    // backing out re-asked "who's watching" every time (AJ Sep 17)
                    getSharedPreferences("ckprof", 0).edit().putString("lastPid", pr.id)
                        .putLong("pickedAt", System.currentTimeMillis()).apply()
                    homeScrollY = 0; homeSavedRow = -1; rowScrollX.clear(); pendingContentFocus = true   // open at the TOP, not mid-catalog
                    scope.launch { Sync.push(this@MainActivity) }
                    showMain("Home")
                }
                setOnLongClickListener { showProfileEdit(pr); true }
            })
        }
        if (Store.profiles(this).size < 5) row.addView(column().apply {
            gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(14), dp(14), dp(14), dp(12))
            isFocusable = true; isClickable = true; background = selBg(Color.TRANSPARENT, 18)
            addView(FrameLayout(this@MainActivity).apply {
                layoutParams = LinearLayout.LayoutParams(dp(92), dp(92))
                background = GradientDrawable().apply {
                    setColor(Color.parseColor("#241F3D")); shape = GradientDrawable.OVAL
                    setStroke(dp(2), Color.parseColor("#4A4470"))
                }
                addView(TextView(this@MainActivity).apply {
                    text = "＋"; textSize = 38f; gravity = Gravity.CENTER; setTextColor(dim)
                    layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                })
            })
            addView(TextView(this@MainActivity).apply {
                text = "Add profile"; setTextColor(dim); textSize = 15f; gravity = Gravity.CENTER
                setPadding(0, dp(8), 0, 0)
            })
            setOnClickListener { showProfileCreate(first = false) }
        })
        col.addView(horizScroll(row))
        col.addView(dimText("Hold OK on a profile to edit or remove it.").apply { gravity = Gravity.CENTER })
        // tagged so the live-sync tick can spot the page and repaint it when a profile
        // added/edited on another device syncs down (swap() drops the tag with the view)
        val page = scroll(col)
        page.tag = "profilePicker"
        swap(page)
        // TV: cursor lands ON the first face with NO dead beat — try now, after layout, and one
        // more post as a backstop (AJ Sep 18: "can't move for a second"). MOBILE is touch —
        // grabbing focus just paints a stuck square around the first profile (AJ Sep 18: "we
        // don't need that on mobile"), so only the TV D-pad gets the auto-focus.
        if (isTv) {
            // land on the REMEMBERED face after a rebuild, else the first face (fresh open)
            val target = (0 until row.childCount).map { row.getChildAt(it) }
                .firstOrNull { keepPid != null && it.tag == keepPid } ?: row.getChildAt(0)
            target?.isFocusableInTouchMode = true
            target?.requestFocus()
            // backstops fire AFTER layout — on a slow cold open the user may have already
            // d-padded to another profile by then, and an unconditional grab yanked the
            // cursor back to face #1 (AJ Sep 24 "it ALWAYS jumps back to the first").
            // Only rescue focus if it hasn't landed on any profile yet.
            target?.doOnPreDraw { if (row.focusedChild == null) it.requestFocus() }
            target?.post { if (row.focusedChild == null) target.requestFocus() }
        }
    }

    // holds the avatar+color the picker is currently set to (mutated by the chips/swatches)
    private class ProfilePick(var avatar: String, var color: String)

    /** Shared avatar-emoji + background-color picker, appended to a settings column. Used by
     *  both Create and Edit so they stay consistent. Mutates `pick` as the user selects. */
    private fun addAvatarColorPicker(col: LinearLayout, pick: ProfilePick) {
        val chips = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val chipViews = ArrayList<TextView>()
        avatarChoices.forEach { emo ->
            chips.addView(TextView(this).apply {
                text = emo; textSize = 24f; setPadding(dp(10), dp(8), dp(10), dp(8))
                isFocusable = true; isClickable = true; background = selBg(Color.TRANSPARENT, 16)
                alpha = if (emo == pick.avatar) 1f else 0.5f
                setOnClickListener { pick.avatar = emo; chipViews.forEach { it.alpha = 0.5f }; alpha = 1f }
                chipViews.add(this)
            })
        }
        col.addView(dimText("Pick an avatar:"))
        col.addView(horizScroll(chips))
        val sw = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val swViews = ArrayList<View>()
        colorChoices.forEach { hex ->
            sw.addView(FrameLayout(this).apply {
                layoutParams = LinearLayout.LayoutParams(dp(46), dp(46)).apply { setMargins(dp(6), dp(8), dp(6), dp(8)) }
                isFocusable = true; isClickable = true
                background = GradientDrawable().apply { setColor(Color.parseColor(hex)); cornerRadius = dp(12).toFloat() }
                foreground = selBg(Color.TRANSPARENT, 14)   // focus ring on top of the color
                alpha = if (hex == pick.color) 1f else 0.5f
                setOnClickListener { pick.color = hex; swViews.forEach { it.alpha = 0.5f }; alpha = 1f }
                swViews.add(this)
            })
        }
        col.addView(dimText("Pick a color:"))
        col.addView(horizScroll(sw))
    }

    private fun showProfileCreate(first: Boolean) {
        val col = column().apply { gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(28), dp(44), dp(28), dp(28)) }
        col.addView(bigText(if (first) "Create your profile" else "Add a profile", 26f))
        col.addView(dimText("Your watchlist, progress, and picks stay yours."))
        val name = field("Name")
        col.addView(name)
        val pick = ProfilePick("", "")
        addAvatarColorPicker(col, pick)
        col.addView(pill(if (first) "Start watching" else "Create") {
            val nm = name.text.toString().trim()
            if (nm.isBlank()) { toast("Enter a name"); return@pill }
            val pr = Store.addProfile(this, nm, pick.avatar, pick.color)
            if (pr == null) { toast("Profile limit reached (5)"); return@pill }
            if (!first) Store.switchProfile(this, pr.id)
            profilePicked = true; sessionActive = true
            homeScrollY = 0; homeSavedRow = -1; rowScrollX.clear(); pendingContentFocus = true
            // brand-new profile → let them pick their Home shelves first, THEN land on Home (AJ Sep 15)
            showShelfPicker {
                scope.launch { Sync.push(this@MainActivity) }
                showMain("Home")
            }
        })
        if (!first) col.addView(ghostPill("‹ Back") { showProfilePicker() })
        swap(scroll(col))
        name.post { name.requestFocus() }   // cursor straight into the name field
    }

    // Edit profile: a full branded panel (was a bare system AlertDialog) — same look as Create,
    // now you can change the PICTURE + COLOR too, not just the name. (AJ Sep 15)
    private fun showProfileEdit(pr: Store.Profile) {
        val col = column().apply { gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(28), dp(44), dp(28), dp(28)) }
        col.addView(bigText("Edit profile", 26f))
        col.addView(dimText("Change the name, picture, or color — or remove this profile."))
        val name = field("Name").apply { setText(pr.name) }
        col.addView(name)
        val pick = ProfilePick(pr.avatar, pr.color)
        addAvatarColorPicker(col, pick)
        col.addView(pill("Save") {
            Store.renameProfile(this, pr.id, name.text.toString(), pick.avatar, pick.color)
            scope.launch { Sync.push(this@MainActivity) }
            showProfilePicker()
        })
        col.addView(ghostPill("Delete profile") {
            if (Store.profiles(this).size <= 1) { toast("Can't delete the last profile"); return@ghostPill }
            Store.deleteProfile(this, pr.id)
            scope.launch { Sync.push(this@MainActivity) }
            showProfilePicker()
        })
        col.addView(ghostPill("‹ Back") { showProfilePicker() })
        swap(scroll(col))
        name.post { name.requestFocus() }
    }

    /** The active profile's identity for the service: display name + a short unique tag from
     *  the profile id, so two profiles with the SAME name (even across accounts on a shared
     *  key) never blend their watch history or For You. The server strips the "#tag" for
     *  display, so logs still read as just the name. Blank when no profile (guest). */
    private fun profileSeg(): String =
        Store.currentProfileObj(this)?.let { "${it.name} #${it.id.takeLast(4)}" } ?: ""

    /** Deterministic per-profile, per-day reorder of a category row: stable all day, a fresh
     *  mix tomorrow, and different for each profile — so rows never feel like the same rehash.
     *  Ranked rows (Top 10) are never passed through this. */
    private fun profileMix(items: List<Title>): List<Title> {
        if (items.size < 4) return items
        val pid = Store.currentProfile(this).ifBlank { "guest" }
        val day = System.currentTimeMillis() / 86_400_000L
        val seed = (pid.hashCode().toLong() * 1_000_003L) xor day
        return items.shuffled(java.util.Random(seed))
    }

    /** The active profile rides into play URLs (?u=) so the service tracks progress and
     *  personalizes per person — only touches URLs that already carry a u param. */
    private fun withProfile(url: String): String {
        val seg = profileSeg().ifBlank { return url }
        if (!url.contains("u=")) return url
        return url.replace(Regex("([?&])u=[^&]*"), "$1u=" + java.net.URLEncoder.encode(seg, "UTF-8"))
    }

    private fun showTerms() = showLegal("Terms & Conditions", Legal.TERMS)
    private fun showPrivacy() = showLegal("Privacy Policy", Legal.PRIVACY)

    private fun showLegal(title: String, text: String) {
        val col = column().apply { setPadding(dp(20)) }
        col.addView(ghostPill("‹ Back") { if (Store.onboarded(this)) showSettings() else showOnboarding() })
        col.addView(bigText(title, 22f))
        col.addView(TextView(this).apply {
            this.text = text.trim(); setTextColor(Color.parseColor("#CCCCCC")); textSize = 13.5f
            setLineSpacing(0f, 1.2f); setPadding(0, dp(4), 0, dp(24))
        })
        swap(scroll(col))
    }

    // ---------- main shell: left rail on TV (Stremio), bottom bar on mobile ----------
    // BACK = the page you left, not a rebuild (AJ Sep 17 mobile: "I clicked back, it should
    // just be there"). The built main page is stashed on swap-away; popping back re-attaches
    // the SAME view tree — scroll position, loaded rows, and art all intact — then repaints
    // only what legitimately changes while away (Continue row, episode bars). Mobile only:
    // the TV path keeps its rebuild + D-pad focus-restore machinery (now fast via the
    // jsonCached row data), and a reattach would fight the board's focus grabber.
    private var mainStash: View? = null
    private var mainStashTab: String? = null
    private fun showMainCached(selected: String) {
        // the profile picker is up and nobody's chosen yet — NOTHING replaces it with Home
        // (killed the picker→Continue Watching→picker blink for good, AJ Sep 18)
        if (pickerShowing() && !profilePicked) return
        val v = mainStash
        // a stashed Live TV page goes stale fast (old games, red now-line at build time) —
        // reattach only when it's under a minute old; older = rebuild fresh (AJ Sep 26)
        val liveTooOld = selected == "Live TV" && System.currentTimeMillis() - livePageAt > 60_000
        // Reattach the already-built page = instant switch (no rebuild). REBUILD instead when the
        // content changed since it was stashed (contentDirty: library/watched/rating/profile) or a
        // Live TV page went stale (>60s), so it's never showing old data. Now on TV too (was
        // mobile-only) — the biggest Firestick "switching feels slow" win. (AJ Sep 27)
        if (v != null && mainStashTab == selected && v.parent == null && !liveTooOld && !Ck.contentDirty) {
            root.removeAllViews(); root.addView(v)
            tab = selected
            pageShownAt = System.currentTimeMillis()
            attachUpdatePill()
            navStack.clear(); currentPage = { showMainCached(selected) }; poppingBack = false
            runCatching { refreshContinueRow() }; runCatching { refreshEpisodeBars() }
            scheduleArtPass()
            // TV: re-anchor d-pad focus onto a CONTENT tile — never the nav rail. The old
            // `?: focusableOf(v)` fell back to the whole page (rail included), so on a back-out
            // the Home MENU grabbed focus ("menu just opens", AJ Sep 27). Now: if nothing's
            // focused OR focus landed on the rail, pull it to the content; else leave it be.
            if (isTv) contentRef?.let { c -> c.postDelayed({
                runCatching { if (currentFocus == null || railHasFocus()) focusableOf(c)?.requestFocus() }
            }, 60) }
            return
        }
        if (Ck.contentDirty) Ck.contentDirty = false   // consumed — the rebuild below is fresh
        showMain(selected)
    }

    private fun showMain(selected: String = tab) {
        if (pickerShowing() && !profilePicked) return   // never blink Home over the picker
        // remember where we came FROM when opening Live TV so BACK returns there (AJ Sep 26
        // "back out of Live TV opens the Home menu blank instead of taking me back where i was")
        if (selected == "Live TV" && tab != "Live TV") liveTvReturnTab = tab
        getSharedPreferences("ckprof", 0).edit().putString("lastTab", selected).apply()   // survive recreation
        navStack.clear(); currentPage = { showMainCached(selected) }; poppingBack = false
        if (selected == "Settings") { showSettings(); return }
        if (selected != "Search")
            window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN)
        tab = selected
        val content = column()
        when (selected) {
            "Search" -> buildSearch(content)
            "Library" -> buildLibrary(content)
            "Discover" -> buildDiscover(content)
            // full flavor only: the WHOLE tab (UI + strings) lives in Downloads.kt so the
            // store/amazon binaries never carry it (their stub's TAB is "" — never matched)
            Downloads.TAB -> if (Downloads.ENABLED) Downloads.buildTab(this, content)
            "Live TV" -> buildLiveTv(content)
            else -> buildShelves(content, selected)
        }
        if (isTv) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setBackgroundColor(bg) }
            row.addView(railView(selected))
            // scroll headroom: even a 1-row page can lift its row to the top line —
            // without this the ScrollView clamps and the row above stays visible
            content.setPadding(content.paddingLeft, content.paddingTop, content.paddingRight,
                resources.displayMetrics.heightPixels)
            val sv = object : ScrollView(this) {
                override fun dispatchKeyEvent(e: android.view.KeyEvent): Boolean {
                    // Stremio feel: the cursor only moves BETWEEN things — when there's
                    // nothing further up/down, nothing happens (no tiny pixel-scrolls)
                    // END-OF-ROW: left/right never leaps to another line (AJ Sep 17 "end
                    // of a list it jumps up") — a horizontal move must stay level or die
                    if (e.action == android.view.KeyEvent.ACTION_DOWN &&
                        (e.keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT ||
                         e.keyCode == android.view.KeyEvent.KEYCODE_DPAD_RIGHT)) {
                        val f2 = findFocus()
                        if (f2 != null && f2 !== this) {
                            val dir2 = if (e.keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT) View.FOCUS_LEFT else View.FOCUS_RIGHT
                            val nxt = f2.focusSearch(dir2)
                            if (nxt == null) return true
                            val a = IntArray(2); f2.getLocationOnScreen(a)
                            val b = IntArray(2); nxt.getLocationOnScreen(b)
                            if (kotlin.math.abs((a[1] + f2.height / 2) - (b[1] + nxt.height / 2)) > f2.height) return true
                        }
                    }
                    if (e.action == android.view.KeyEvent.ACTION_DOWN &&
                        (e.keyCode == android.view.KeyEvent.KEYCODE_DPAD_UP ||
                         e.keyCode == android.view.KeyEvent.KEYCODE_DPAD_DOWN)) {
                        val f = findFocus()
                        if (f != null && f !== this) {
                            val up = e.keyCode == android.view.KeyEvent.KEYCODE_DPAD_UP
                            // SEARCH: the box is an EditText (not a row) — handle it explicitly so
                            // DOWN drops into results (never the nav rail) and UP just stays put
                            // instead of escaping (AJ Sep 27).
                            if (tab == "Search" && f === searchInput) {
                                if (!up) searchResultsHost?.let { focusableOf(it) }?.requestFocus()
                                return true
                            }
                            // rows land where you LEFT them (or their start), Stremio-style
                            val rows = ArrayList<HorizontalScrollView>()
                            fun collect(vg: android.view.ViewGroup) {
                                for (i in 0 until vg.childCount) {
                                    val c = vg.getChildAt(i)
                                    if (c is HorizontalScrollView) rows.add(c)
                                    else if (c is android.view.ViewGroup) collect(c)
                                }
                            }
                            collect(this)
                            var q: View? = f
                            while (q != null && q !is HorizontalScrollView) q = q.parent as? View
                            // the guide's shared timeline lane: navigate INSIDE it
                            // spatially (blocks above/below). BUT at the TOP of the lane, UP
                            // must escape to the chips/region row above — else you scroll
                            // down into the guide and can't get back up (AJ Sep 18 "stuck
                            // off the page").
                            if (q?.tag == "lane") {
                                if (up) {
                                    val nxt = f.focusSearch(View.FOCUS_UP)
                                    var inLane = false; var v: View? = nxt
                                    while (v != null) { if (v === q) { inLane = true; break }; v = v.parent as? View }
                                    if (!inLane) {   // at the top of the lane → jump to the row above it
                                        val ci2 = rows.indexOf(q)
                                        rows.getOrNull(ci2 - 1)?.let { above ->
                                            focusableOf(above.getChildAt(0) ?: above)?.let { it.requestFocus(); return true }
                                        }
                                    }
                                }
                                return super.dispatchKeyEvent(e)
                            }
                            val ci = rows.indexOf(q)
                            if (ci >= 0) {
                                val target = rows.getOrNull(ci + if (up) -1 else 1)
                                if (target != null) {
                                    val strip = target.getChildAt(0) as? android.view.ViewGroup
                                    val kept = (target.tag as? Int)
                                        ?.let { strip?.getChildAt(it.coerceIn(0, (strip.childCount - 1).coerceAtLeast(0))) }
                                    val dest = kept?.let { k -> focusableOf(k) } ?: strip?.let { s -> focusableOf(s) }
                                    if (dest != null) {
                                        // LIVE TV: landing on the topmost strip (e.g. the category
                                        // chips) scrolls the page fully to y=0 so the "Live TV"
                                        // title + region selector above it are on-screen too, not
                                        // clipped off the top (AJ Sep 26 "if i go up to Football I
                                        // should at least be able to see the rest").
                                        if (up && tab == "Live TV" && rows.indexOf(target) == 0) smoothScrollTo(0, 0)
                                        dest.requestFocus(); return true
                                    }
                                }
                                // LIVE TV: UP from the topmost strip lands on the "🌎 USA ▾"
                                // region chip (AJ Sep 26 "no way to scroll back up to the country
                                // selector") — the header row isn't a HorizontalScrollView so the
                                // row-walk never reached it. Scroll to the very top so the chip and
                                // the "Live TV" title are both on-screen when it takes focus.
                                if (target == null && up && tab == "Live TV")
                                    liveRegionChip?.takeIf { it.isAttachedToWindow }?.let {
                                        smoothScrollTo(0, 0); it.requestFocus(); return true
                                    }
                                // SEARCH: UP from the top results row lands back on the search box
                                // (scroll to top so the box is fully on-screen) — AJ Sep 27 "can't
                                // scroll back up to the search bar". Without this the generic
                                // top-edge guard below would swallow the press.
                                if (target == null && up && tab == "Search")
                                    searchInput?.takeIf { it.isAttachedToWindow }?.let {
                                        smoothScrollTo(0, 0); it.requestFocus(); return true
                                    }
                                // top OR bottom edge: STAY — never escape to the nav rail
                                // ("up from Continue Watching opens the Home menu", AJ Sep 18)
                                if (target == null) return true
                            }
                            val dir = if (up) View.FOCUS_UP else View.FOCUS_DOWN
                            if (f.focusSearch(dir) == null) return true
                        }
                    }
                    return super.dispatchKeyEvent(e)
                }
                // LIVE TV: keep the focused row FULLY below the pinned time-header — never half
                // under it, never a half-cursor (AJ Sep 27). Pretend the focused rect starts a
                // header-height higher so the ScrollView drops it clear of the floating header.
                override fun computeScrollDeltaToGetChildRectOnScreen(rect: android.graphics.Rect): Int {
                    val hdr = liveHdrFloatHost
                    if (tab == "Live TV" && hdr != null && hdr.visibility == View.VISIBLE && hdr.height > 0) {
                        val r = android.graphics.Rect(rect); r.top -= hdr.height + dp(4)
                        return super.computeScrollDeltaToGetChildRectOnScreen(r)
                    }
                    return super.computeScrollDeltaToGetChildRectOnScreen(rect)
                }
            }.apply {
                addView(content); isFillViewport = true; isVerticalScrollBarEnabled = false
            }
            // STREMIO TV BOARD on every tab: the focused title's art fills the screen,
            // info floats top-left, rows glide over the lower half (AJ: search/discover/
            // library should narrate exactly like Home)
            sv.setBackgroundColor(Color.TRANSPARENT)
            sv.clipChildren = true; sv.clipToPadding = true   // rows never rise over the info
            sv.setPadding(0, 0, 0, 0)
            // Live TV skips the board: no artwork to narrate = the top half was just BLANK
            // and everything "started in the middle" (AJ Sep 17)
            if (selected == "Live TV") {
                sv.setBackgroundColor(bg)
                val wrap = FrameLayout(this)
                wrap.addView(sv, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
                val floatHost = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL; visibility = View.GONE
                    setBackgroundColor(bg); elevation = dp(4).toFloat()
                    setPadding(dp(12), 0, dp(12), 0)
                }
                liveHdrFloatHost = floatHost
                liveHdrMaker?.let { mk -> floatHost.removeAllViews(); floatHost.addView(mk()) }
                wrap.addView(floatHost, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
                sv.viewTreeObserver.addOnScrollChangedListener {
                    val hv = liveHdrView ?: return@addOnScrollChangedListener
                    if (!hv.isAttachedToWindow) { floatHost.visibility = View.GONE; return@addOnScrollChangedListener }
                    val hl = IntArray(2); hv.getLocationOnScreen(hl)
                    val sl = IntArray(2); sv.getLocationOnScreen(sl)
                    floatHost.visibility = if (hl[1] < sl[1]) View.VISIBLE else View.GONE
                }
                row.addView(wrap, lp(0, MATCH_PARENT, 1f))
            } else row.addView(buildTvBoard(sv), lp(0, MATCH_PARENT, 1f))
            swap(row)
            mainStash = row; mainStashTab = selected   // TV instant-switch: reattach this built page (AJ Sep 27)
            homeScroll = sv   // every board tab locks rows into position (Library too)
            val keepY = pendingScrollY; pendingScrollY = -1   // in-place refresh: stay put
            if (keepY < 0 && (selected == "Search" || selected == "Discover")) sv.post { sv.scrollTo(0, 0) }
            val y = if (keepY >= 0) keepY else if (selected == "Home") homeScrollY else 0
            // tab-switch return to Home: aim the focus restorer at the tile you left (the
            // back-from-detail path sets restoreFocusAfterBack itself — don't clobber it)
            if (selected == "Home" && keepY < 0 && !restoreFocusAfterBack && homeSavedRow >= 0) {
                savedRowIdx = homeSavedRow; savedItemIdx = homeSavedItem; restoreFocusAfterBack = true
            }
            if (y > 0) restoreScrollPreDraw(sv, y)
            contentRef = content
            focusGraceUntil = System.currentTimeMillis() + 4000
            if (isTv) {
                var tries = 0
                lateinit var grab: () -> Unit
                grab = {
                    val f = focusableOf(content)
                    when {
                        // coming back from a page: wait for THE remembered tile's row to
                        // build instead of grabbing tile #1 (which scrolls to the top)
                        restoreFocusAfterBack && currentFocus == null && restoreRowFocus(content) ->
                            restoreFocusAfterBack = false
                        restoreFocusAfterBack && currentFocus == null && tries++ < 28 ->
                            content.postDelayed(grab, 250)
                        f != null && currentFocus == null -> f.requestFocus()
                        f == null && tries++ < 16 -> content.postDelayed(grab, 250)
                        else -> {}
                    }
                }
                content.postDelayed(grab, 120)
            }
            if (pendingContentFocus) {
                pendingContentFocus = false
                // rows stream in async — keep trying until something real takes the cursor
                firstContentFocus = null
                // extra late ticks (AJ Sep 15 "back always jumps to the top"): give slow
                // Firestick network rows time to build the remembered tile's row before we give
                // up and grab tile #1 (which scrolls the page to the top). Only the back-restore
                // path waits this long — a fresh page still grabs focus on the first tick.
                val delays = listOf(80L, 400L, 900L, 1600L, 2600L, 3800L, 5200L, 6800L)
                for ((di, delay) in delays.withIndex()) sv.postDelayed({
                    val f = currentFocus
                    if (f != null && f.parent != null && !railHasFocus()) return@postDelayed
                    // they went to the menu ON PURPOSE — never yank the cursor back out
                    if (railHasFocus() && userNavigatedSincePageShown()) return@postDelayed
                    if (restoreFocusAfterBack && restoreRowFocus(content)) { restoreFocusAfterBack = false; return@postDelayed }
                    if (di == delays.lastIndex) restoreFocusAfterBack = false
                    if (!restoreFocusAfterBack || di == delays.lastIndex)
                        (firstContentFocus ?: focusableOf(content))?.requestFocus()
                }, delay)
            }
        } else {
            val col = column()
            col.addView(mobileHeader(selected))
            col.addView(content)
            val page = FrameLayout(this).apply { setBackgroundColor(bg) }
            col.setPadding(0, 0, 0, dp(70))   // clear the bottom bar
            val sv = scroll(col)
            page.addView(sv)
            // MOBILE STICKY GUIDE HEADER (AJ Sep 18 "on mobile I want the channel and time at
            // the top when you're scrolling"): mirror the Firestick/web behavior. The guide's
            // date+time-tick header lives inside the scroll and used to scroll away on mobile.
            // A floating copy pins to the top the moment the real one scrolls above the
            // viewport — position:sticky, done by hand (the same trick the TV branch uses).
            if (selected == "Live TV") {
                val topPad = statusBarPad()
                val floatHost = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL; visibility = View.GONE
                    setBackgroundColor(bg); elevation = dp(4).toFloat()
                    // FLUSH TO THE VERY TOP with the opaque background running up THROUGH the
                    // status-bar strip (top padding, not a top margin). The old margin left a
                    // gap above the pinned header and rows scrolled visibly through it — AJ Sep
                    // 18 "I can see stuff scrolling above it, I want it to just go into it like
                    // TV and web". Now content slides UNDER the header and nothing shows above.
                    setPadding(dp(12), topPad, dp(12), dp(2))
                }
                liveHdrFloatHost = floatHost
                liveHdrMaker?.let { mk -> floatHost.removeAllViews(); floatHost.addView(mk()) }
                page.addView(floatHost, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.TOP))
                sv.viewTreeObserver.addOnScrollChangedListener {
                    val hv = liveHdrView ?: return@addOnScrollChangedListener
                    if (!hv.isAttachedToWindow) { floatHost.visibility = View.GONE; return@addOnScrollChangedListener }
                    val hl = IntArray(2); hv.getLocationOnScreen(hl)
                    // pin the instant the real header's top reaches the bottom of the status
                    // bar (where the floating copy's header content sits) — they coincide at
                    // the boundary, so there's no jump and no visible gap on the way in/out
                    floatHost.visibility = if (hl[1] <= topPad) View.VISIBLE else View.GONE
                }
            }
            page.addView(bottomNav(), FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.BOTTOM))
            swap(page)
            homeScroll = sv
            mainStash = page; mainStashTab = selected   // back re-attaches this exact page
            val keepY = pendingScrollY; pendingScrollY = -1   // in-place refresh: stay put
            val y = if (keepY >= 0) keepY else if (selected == "Home") homeScrollY else 0
            if (y > 0) restoreScrollPreDraw(sv, y)
        }
    }

    /** The page's rows build asynchronously — on the first frames the content is still too
     *  short to take the saved offset, so an immediate scrollTo clamps to the top and the
     *  late corrector then snaps back down (the "jumps to the top and back" AJ sees on
     *  add/mark/tab-switch). Hold the page invisible until the content can actually hold
     *  the offset (or 700ms, whichever first), then land it in one motion.
     *  Sep 10 (AJ: "go back to Home and it jumps to the top"): the 700ms/1s deadline fired
     *  while network rows were still building, scrollTo CLAMPED to the short page, and
     *  nothing ever corrected it. Now a corrector keeps re-applying the offset as the page
     *  grows — until it actually holds, the user scrolls away, or 6s passes. */
    private fun restoreScrollPreDraw(sv: ScrollView, y: Int) {
        sv.alpha = 0f
        val start = System.currentTimeMillis()
        sv.viewTreeObserver.addOnPreDrawListener(object : android.view.ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (sv.alpha >= 1f) { sv.viewTreeObserver.removeOnPreDrawListener(this); return true }
                val child = sv.getChildAt(0)
                val fits = sv.height > 0 && child != null && child.height - sv.height >= y
                if (!fits && System.currentTimeMillis() - start < 700) return false
                sv.viewTreeObserver.removeOnPreDrawListener(this)
                sv.scrollTo(0, y); sv.alpha = 1f
                if (sv.scrollY < y) keepRestoringScroll(sv, y)   // clamped short — finish later
                return false
            }
        })
        // belt-and-suspenders: whatever happens, the page is visible and positioned by 1s
        sv.postDelayed({
            if (sv.alpha < 1f) {
                sv.scrollTo(0, y); sv.alpha = 1f
                if (sv.scrollY < y) keepRestoringScroll(sv, y)
            }
        }, 1000)
    }

    /** Re-apply a clamped restore offset as async rows grow the page. Stops the moment the
     *  offset holds, the USER scrolls somewhere else (never yank them around), or 6s passes. */
    private fun keepRestoringScroll(sv: ScrollView, y: Int) {
        val start = System.currentTimeMillis()
        var lastApplied = sv.scrollY
        lateinit var tick: Runnable
        tick = Runnable {
            if (!sv.isAttachedToWindow) return@Runnable
            when {
                sv.scrollY >= y -> {}                                   // landed — done
                Math.abs(sv.scrollY - lastApplied) > dp(40) -> {}       // user took over — stop
                System.currentTimeMillis() - start > 6000 -> {}         // page really is short
                else -> {
                    sv.scrollTo(0, y); lastApplied = sv.scrollY
                    sv.postDelayed(tick, 200)
                }
            }
        }
        sv.postDelayed(tick, 200)
    }

    /** Stremio-style TV rail: slim icon strip, the current tab highlighted; sliding focus
     *  onto it expands the labels ("Home", "Discover"…), leaving collapses it again. */
    private fun railView(selected: String): View {
        val labels = ArrayList<TextView>()
        val rail = column().apply {
            // Stremio-style: the rail floats OVER the art, no solid strip (AJ, photo 13) —
            // the board's own left gradient keeps the icons readable
            setBackgroundColor(Color.TRANSPARENT)
            setPadding(dp(8), dp(18), dp(8), dp(18))
            gravity = Gravity.CENTER_VERTICAL   // Stremio: icons ride the middle of the screen
            layoutParams = LinearLayout.LayoutParams(dp(64), MATCH_PARENT)
            // NO LayoutTransition here: Fire OS crashes animating children that detach
            // mid-transition when pages swap under the rail (v0.92 stick crash suspect)
        }
        var expanded = false
        fun setExpanded(on: Boolean) {
            if (on == expanded) return
            expanded = on
            rail.layoutParams = LinearLayout.LayoutParams(dp(if (on) 190 else 64), MATCH_PARENT)
            // expanded = a translucent panel slides over the art (AJ, photo 14);
            // collapsed = fully transparent, icons float on the board's own gradient
            rail.setBackgroundColor(if (on) Color.parseColor("#EE0D0B18") else Color.TRANSPARENT)
            labels.forEach { it.visibility = if (on) View.VISIBLE else View.GONE }
            // selected tab shows its purple highlight box only while the menu is open;
            // collapsed it stays transparent so the icons float on the art (AJ Sep 10)
            railSelectedView?.background = selBg(if (on) Color.parseColor("#332D55") else Color.TRANSPARENT, 12)
        }
        val focusWatch = View.OnFocusChangeListener { _, _ ->
            rail.post { setExpanded(rail.hasFocus() || rail.focusedChild != null) }
        }
        rail.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(dp(6), 0, 0, dp(18)) }
            addView(ImageView(this@MainActivity).apply {
                layoutParams = LinearLayout.LayoutParams(dp(36), dp(36))
                load(R.drawable.ck_logo)
            })
            // wordmark rides next to the logo when the menu opens (AJ, photo 14) —
            // brand-split like the site: COUCH purple, KING white
            addView(TextView(this@MainActivity).apply {
                // wordmark is title-case "CouchKing" (not all-caps) — matches the site (AJ Sep 10)
                text = brandSpan("CouchKing"); setTextColor(fg); textSize = 17f
                setTypeface(typeface, Typeface.BOLD); letterSpacing = 0.02f
                setPadding(dp(10), 0, 0, 0)
                visibility = View.GONE
                labels.add(this)
            })
        })
        railRef = rail
        // PROFILE at the very top of the menu (AJ): avatar circle + name, opens the picker;
        // + circle when none exists yet. Account feature — guests get no profile entry.
        if (Store.signedIn(this)) (Store.currentProfileObj(this) ?: Store.Profile("", "Add profile", "＋")).let { pr ->
            rail.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                isFocusable = true; isClickable = true
                background = selBg(Color.TRANSPARENT, 12)
                setPadding(dp(11), dp(9), dp(12), dp(9))
                layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, 0, 0, dp(14)) }
                // d-pad handling lives in the unified rail key handler below
                addView(FrameLayout(this@MainActivity).apply {
                    layoutParams = LinearLayout.LayoutParams(dp(26), dp(26)).apply { setMargins(0, 0, dp(11), 0) }
                    background = GradientDrawable().apply { setColor(profileHue(pr)); shape = GradientDrawable.OVAL }
                    addView(TextView(this@MainActivity).apply {
                        text = pr.avatar.ifBlank { pr.name.take(1).uppercase() }
                        textSize = 12f; gravity = Gravity.CENTER; setTextColor(fg)
                        layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                    })
                })
                addView(TextView(this@MainActivity).apply {
                    text = pr.name; textSize = 15.5f; setTextColor(dim)
                    visibility = View.GONE
                    labels.add(this)
                })
                onFocusChangeListener = focusWatch
                setOnClickListener {
                    if (Store.profiles(this@MainActivity).isEmpty()) showProfileCreate(first = true)
                    else { profilePicked = false; showProfilePicker() }
                }
            })
        }
        for (t in navTabs()) rail.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            isFocusable = true; isClickable = true
            // Stremio-style (AJ Sep 10): collapsed rail = NO box behind icons, the selected
            // tab reads only via its brighter icon tint. The purple highlight box on the
            // selected item is painted on by setExpanded() when the menu opens.
            background = selBg(Color.TRANSPARENT, 12)
            setPadding(dp(13), dp(11), dp(12), dp(11))
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(10), 0, dp(10)) }
            // d-pad handling lives in the unified rail key handler below
            addView(ImageView(this@MainActivity).apply {
                setImageResource(navIcon[t]!!)
                setColorFilter(if (t == selected) fg else dim)
                layoutParams = LinearLayout.LayoutParams(dp(22), dp(22)).apply { setMargins(0, 0, dp(13), 0) }
            })
            addView(TextView(this@MainActivity).apply {
                text = t; textSize = 15.5f
                setTextColor(if (t == selected) fg else dim)
                setTypeface(typeface, if (t == selected) Typeface.BOLD else Typeface.NORMAL)
                visibility = View.GONE
                labels.add(this)
            })
            onFocusChangeListener = focusWatch
            if (t == selected) { id = View.generateViewId(); railSelectedId = id; railSelectedView = this }
            setOnClickListener {
                // clicking Home ALWAYS lands at the TOP (Continue Watching), not the saved
                // mid-page row (AJ Sep 18: "click Home from any row, it drops me on For You
                // movies — take me back to the top"). Other tabs keep their remembered spot.
                if (t == "Home") { homeScrollY = 0; homeSavedRow = -1; homeSavedItem = -1; rowScrollX.clear() }
                else rememberHomeSpot(t)
                pendingContentFocus = true; showMain(t)
            }
        })
        pendingUpdate?.let { upd ->
            rail.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                isFocusable = true; isClickable = true
                background = selBg(Color.parseColor("#F5C518"), 12)
                setPadding(dp(13), dp(11), dp(12), dp(11))
                layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(16), 0, dp(2)) }
                addView(TextView(this@MainActivity).apply {
                    text = "⬆"; setTextColor(Color.BLACK); textSize = 15f; setTypeface(typeface, Typeface.BOLD)
                    layoutParams = LinearLayout.LayoutParams(dp(22), WRAP_CONTENT).apply { setMargins(0, 0, dp(13), 0) }
                })
                addView(TextView(this@MainActivity).apply {
                    text = "Update"; textSize = 15.5f; setTextColor(Color.BLACK)
                    setTypeface(typeface, Typeface.BOLD)
                    visibility = View.GONE
                    labels.add(this)
                })
                onFocusChangeListener = focusWatch
                setOnClickListener {
                    val self = getChildAt(1) as TextView
                    Updater.downloadAndInstall(this@MainActivity, upd) { st -> self.text = st; self.visibility = View.VISIBLE }
                }
            }, (rail.childCount - 1).coerceAtLeast(0))   // insert ABOVE Settings — a full rail (Live TV added) buried it below, hidden (AJ Sep 27)
        }
        // THE MENU IS A FOCUS ISLAND: nextFocus pins alone weren't enough — with the page
        // scrolled down, Android's focus search still found a grid tile geometrically
        // "above" a rail entry and UP jumped back into the library. The key handler is
        // authoritative: UP/DOWN move strictly WITHIN the rail's own entries and CONSUME
        // the event (top/bottom edges included), LEFT is the screen edge, RIGHT returns
        // to the tile the cursor came from.
        val focusables = (0 until rail.childCount).map { rail.getChildAt(it) }.filter { it.isFocusable }
        focusables.forEach { if (it.id == View.NO_ID) it.id = View.generateViewId() }
        focusables.forEachIndexed { i, v ->
            v.nextFocusUpId = focusables[(i - 1).coerceAtLeast(0)].id
            v.nextFocusDownId = focusables[(i + 1).coerceAtMost(focusables.size - 1)].id
            v.setOnKeyListener { _, kc, ev ->
                if (ev.action != android.view.KeyEvent.ACTION_DOWN) return@setOnKeyListener false
                when (kc) {
                    android.view.KeyEvent.KEYCODE_DPAD_UP -> {
                        if (i > 0) focusables[i - 1].requestFocus(); true
                    }
                    android.view.KeyEvent.KEYCODE_DPAD_DOWN -> {
                        if (i < focusables.size - 1) focusables[i + 1].requestFocus(); true
                    }
                    android.view.KeyEvent.KEYCODE_DPAD_LEFT -> true   // the menu is the edge
                    android.view.KeyEvent.KEYCODE_DPAD_RIGHT ->
                        if (lastContentFocus?.isAttachedToWindow == true) {
                            lastContentFocus?.requestFocus(); true
                        } else false   // fall through: geometric search enters the content
                    else -> false
                }
            }
        }
        return rail
    }

    /** Status-bar/notch clearance so the header never sits under the camera. */
    private fun statusBarPad(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return (if (id > 0) resources.getDimensionPixelSize(id) else dp(28)) + dp(6)
    }

    private fun mobileHeader(selected: String): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), statusBarPad(), dp(12), dp(4))
        }
        bar.addView(ImageView(this).apply { layoutParams = LinearLayout.LayoutParams(dp(30), dp(30)); load(R.drawable.ck_logo) })
        bar.addView(TextView(this).apply {
            text = brandSpan("  CouchKing"); setTextColor(fg); textSize = 19f; setTypeface(typeface, Typeface.BOLD)
        }, lp(0, WRAP_CONTENT, 1f))
        // profile avatar top-right (Netflix mobile): tap = Who's watching (switch/add/edit);
        // no profile yet -> a + circle that opens Create. Guests get no profile entry.
        if (Store.signedIn(this)) run {
            val pr = Store.currentProfileObj(this)
            // who's signed in, right by the avatar (AJ) — tap target stays the circle
            pr?.name?.takeIf { it.isNotBlank() }?.let { nm ->
                bar.addView(TextView(this).apply {
                    text = nm; setTextColor(dim); textSize = 13.5f
                    setPadding(0, 0, dp(8), 0); maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                })
            }
            bar.addView(FrameLayout(this).apply {
                layoutParams = LinearLayout.LayoutParams(dp(32), dp(32))
                background = GradientDrawable().apply {
                    setColor(pr?.let { profileHue(it) } ?: Color.parseColor("#241F3D"))
                    shape = GradientDrawable.OVAL
                    if (pr == null) setStroke(dp(1), Color.parseColor("#4A4470"))
                }
                isClickable = true; isFocusable = true
                addView(TextView(this@MainActivity).apply {
                    text = pr?.avatar?.ifBlank { pr.name.take(1).uppercase() } ?: "＋"
                    textSize = 14f; gravity = Gravity.CENTER; setTextColor(fg)
                    layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                })
                setOnClickListener {
                    if (Store.profiles(this@MainActivity).isEmpty()) showProfileCreate(first = true)
                    else { profilePicked = false; showProfilePicker() }
                }
            })
        }
        return bar
    }

    private val navIcon = mapOf("Home" to R.drawable.ic_home, "Discover" to R.drawable.ic_discover,
        "Movies" to R.drawable.ic_movies, "Shows" to R.drawable.ic_shows, "Anime" to R.drawable.ic_anime,
        "Live TV" to R.drawable.ic_shows,
        "Search" to R.drawable.ic_search, "Library" to R.drawable.ic_library, "Settings" to R.drawable.ic_settings)

    private fun bottomNav(): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            // black ombre riding up behind the icons instead of a hard strip (AJ, photo 12)
            background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(Color.parseColor("#F2000000"), Color.parseColor("#CC000000"), Color.parseColor("#00000000")))
            setPadding(0, dp(10), 0, dp(9))
            weightSum = navTabs().size.toFloat()
        }
        for (t in navTabs()) {
            val item = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
                layoutParams = lp(0, WRAP_CONTENT, 1f); isClickable = true; isFocusable = true
                setOnClickListener { rememberHomeSpot(t); showMain(t) }
            }
            item.addView(ImageView(this).apply {
                // Downloads has no navIcon entry: its drawable lives in src/full/res (so
                // store variants never ship it), which main code can't reference by R id
                // without breaking the store compile — the flavor object hands the id over
                setImageResource(navIcon[t] ?: (if (Downloads.ENABLED) Downloads.navIconRes() else 0))
                setColorFilter(if (t == tab) accent else dim)
                layoutParams = LinearLayout.LayoutParams(dp(28), dp(28))
            })
            item.addView(TextView(this).apply {
                text = t; textSize = 11f; gravity = Gravity.CENTER
                setTextColor(if (t == tab) accent else dim)
                setTypeface(typeface, if (t == tab) Typeface.BOLD else Typeface.NORMAL)
            })
            bar.addView(item)
        }
        return bar
    }

    // ---- LIVE TV page (AJ Sep 17): genre chips + channel grid straight off the addon's
    // tv catalog. Click = fetch the channel's health-ordered streams, hand the first to the
    // player (foreign HLS url → Ck.parse null → none of the resume/watched machinery runs).
    // ---- LIVE TV: web-app parity (AJ Sep 17 "apk/tv/desktop should look like the web") —
    // classic guide grid w/ day tabs, live-games banner by region, channel+show search,
    // region chips (USA/UK/Canada), guide rows w/ now+progress+next, tuning screen ----
    private var liveGenre = "Guide"
    private var liveRegion = ""                       // "" = USA
    // view state SURVIVES player round-trips + activity recreation (AJ Sep 17 "goes back
    // to usa everytime… we need to stay on what we click")
    private var liveStateLoaded = false
    private fun liveSaveState() = getSharedPreferences("cklive", 0).edit()
        .putString("g", liveGenre).putString("r", liveRegion).apply()
    private var liveGuideJson: org.json.JSONObject? = null
    // sticky guide header (web position:sticky): the real header in the flow + a floating
    // copy pinned over the page once you scroll past it
    private var liveHdrView: View? = null
    private var liveHdrFloatHost: LinearLayout? = null
    private var liveHdrMaker: (() -> View)? = null
    private var liveRegionChip: View? = null          // the "🌎 USA ▾" corner chip — d-pad UP from the top row lands here (AJ Sep 26)
    private var liveTvReturnTab: String? = null       // the tab we were on before opening Live TV — BACK returns here, not a blank Home (AJ Sep 26)
    private var liveGuideAt = 0L
    private var livePageAt = 0L                       // when the Live TV page was last BUILT (freshness gate)
    private var liveGuideRegion = "?"
    private var liveDay = 0                           // 0=Today 1=Tomorrow 2=day after
    private var liveDayRefocus = false                // day-tab click re-render: grab focus back
    private var liveRenderBody: (() -> Unit)? = null  // re-render live body in place (search-blank)
    private val liveUi = android.os.Handler(android.os.Looper.getMainLooper())

    private fun liveHost(): String = runCatching {
        val u = java.net.URL(liveTvAddon!!); u.protocol + "://" + u.authority
    }.getOrDefault("")   // host comes from the USER's own addon; no baked couchking fallback

    private fun liveKey(): String {
        // scan every path segment for the url-encoded {"subKey":…} config — some addon
        // urls carry an /a/ prefix before it (same bug the web hit)
        for (seg in runCatching { java.net.URL(liveTvAddon!!).path }.getOrDefault("").split("/")) {
            val k = runCatching {
                org.json.JSONObject(java.net.URLDecoder.decode(seg, "UTF-8")).optString("subKey")
            }.getOrDefault("")
            if (k.isNotBlank()) return k
        }
        return Ck.key(this) ?: ""
    }

    private suspend fun liveGuideData(): org.json.JSONObject? {
        if (liveGuideJson != null && liveGuideRegion == liveRegion &&
            System.currentTimeMillis() - liveGuideAt < 55_000) return liveGuideJson
        val r = if (liveRegion.isNotBlank()) "?r=$liveRegion" else ""
        val d = Http.json("${liveHost()}/live/${liveKey()}/guide.json?p=" + java.net.URLEncoder.encode(Store.currentProfile(this), "UTF-8") + (if (liveRegion.isNotBlank()) "&r=$liveRegion" else ""))
        if (d != null && (d.optJSONArray("channels")?.length() ?: 0) > 0) {
            liveGuideJson = d; liveGuideAt = System.currentTimeMillis(); liveGuideRegion = liveRegion
        }
        return if (liveGuideRegion == liveRegion) liveGuideJson else null
    }

    private fun liveFmtT(ms: Long): String =
        java.text.SimpleDateFormat("h:mm a", java.util.Locale.US).format(java.util.Date(ms))

    private fun buildLiveTv(col: LinearLayout) {
        val addonBase = liveTvAddon ?: return
        if (!liveStateLoaded) {
            liveStateLoaded = true
            val p = getSharedPreferences("cklive", 0)
            liveGenre = p.getString("g", "Guide") ?: "Guide"
            liveRegion = p.getString("r", "") ?: ""
            // NEVER restore the day tab (AJ Sep 25 "guide still starts at 6am tomorrow"):
            // a saved "Tomorrow" from a past session made every guide open land on the
            // Tomorrow tab's 6 AM top forever. Day choice lives for the session only —
            // a fresh open always starts on Today at the current half-hour.
            liveDay = 0
        }
        // TV OVERSCAN INSET (AJ Sep 26 "it cuts off the words LIVE TV and Football at the top"):
        // Live TV skips buildTvBoard (which pushes every other tab's content down by dp(232)),
        // so its "Live TV" title + category chips sat flush at y=0 and the TV's overscan ate the
        // top strip. Give the page a top inset that clears typical 1080p overscan (~dp(27)).
        col.setPadding(dp(12), if (isTv) dp(36) else dp(6), dp(12), if (isTv) dp(30) else dp(90))
        // LOCKED (Live TV not on this plan, AJ Sep 18): full-screen centered banner,
        // nothing clickable — no chips, guide, or channels
        scope.launch {
            val chk = Http.jsonCached("$addonBase/catalog/tv/$liveTvCatId.json", 60_000L)
            val metas = chk?.optJSONArray("metas")
            if (metas != null && metas.length() == 1 && metas.optJSONObject(0)?.optString("id") == "cklive:upgrade") {
                col.removeAllViews()
                col.setPadding(0, 0, 0, 0)
                col.addView(column().apply {
                    gravity = Gravity.CENTER
                    // fill the whole screen height so it sits in the DIRECT middle, not
                    // just centered in the content area at the top (AJ Sep 18)
                    minimumHeight = resources.displayMetrics.heightPixels - dp(80)
                    layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
                    addView(TextView(this@MainActivity).apply { text = "🔒"; textSize = 48f; gravity = Gravity.CENTER })
                    addView(TextView(this@MainActivity).apply {
                        text = "CouchKing Live TV — Locked"; setTextColor(fg); textSize = 22f
                        setTypeface(typeface, android.graphics.Typeface.BOLD); gravity = Gravity.CENTER
                        setPadding(0, dp(14), 0, dp(8))
                    })
                    addView(TextView(this@MainActivity).apply {
                        text = "Live TV isn't part of your plan.\nContact support to unlock it."
                        setTextColor(dim); textSize = 14f; gravity = Gravity.CENTER
                    })
                })
                return@launch
            }
            buildLiveTvBody(col, addonBase)
        }
    }

    private fun buildLiveTvBody(col: LinearLayout, addonBase: String) {
        livePageAt = System.currentTimeMillis()   // freshness stamp: resume/stash checks read this
        // row 1: region chips + search
        val topRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        // region DROPDOWN (AJ Sep 17 "should still be a drop down on mobile and firestick")
        val regLabel = when (liveRegion) { "UK" -> "UK"; "CA" -> "Canada"; else -> "USA" }
        topRow.addView(TextView(this).apply {
            text = "🌎 $regLabel ▾"; textSize = 12.5f
            setTextColor(fg)
            background = selBg(Color.parseColor("#241F3D"), 18)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            isClickable = true; isFocusable = true
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, 0, dp(6), 0) }
            setOnClickListener {
                // app-styled dark picker, not the stock Android dialog (AJ Sep 17)
                val d2 = android.app.Dialog(this@MainActivity)
                d2.window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
                d2.setContentView(column().apply {
                    background = selBg(Color.parseColor("#1B1830"), 16)
                    setPadding(dp(10), dp(10), dp(10), dp(10))
                    for ((code2, lbl2) in listOf("" to "🇺🇸 USA", "UK" to "🇬🇧 UK", "CA" to "🇨🇦 Canada"))
                        addView(TextView(this@MainActivity).apply {
                            text = (if (liveRegion == code2) "✓ " else "   ") + lbl2
                            setTextColor(if (liveRegion == code2) fg else dim); textSize = 15.5f
                            setPadding(dp(20), dp(11), dp(34), dp(11))
                            isFocusable = true; isClickable = true
                            background = selBg(Color.parseColor("#1B1830"), 10)
                            setOnClickListener {
                                liveRegion = code2; liveGenre = "Guide"; liveSaveState()
                                d2.dismiss(); showMain("Live TV")
                            }
                        })
                })
                d2.show()
            }
        })
        val search = android.widget.EditText(this).apply {
            hint = "🔎 Channels & shows"; setHintTextColor(dim); setTextColor(fg); textSize = 13f
            background = selBg(Color.parseColor("#1C1832"), 18)
            setPadding(dp(14), dp(7), dp(14), dp(7))
            isSingleLine = true
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
            layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { setMargins(dp(6), 0, 0, 0) }
        }
        topRow.addView(search)
        // every interactive strip must BE a HorizontalScrollView — the TV d-pad nav only
        // walks between HSV rows (why day tabs/rows were unreachable, AJ Sep 17)
        // ORDER = the web page exactly (AJ Sep 17): "Live TV" + region IN THE CORNER,
        // then LIVE NOW + Upcoming strips, then search, then chips, then content
        col.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            addView(TextView(this@MainActivity).apply {
                text = "Live TV"; setTextColor(fg); textSize = 22f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
            })
            addView(topRow.getChildAt(0).also { liveRegionChip = it; topRow.removeViewAt(0) })   // region chip → right corner (also the d-pad-UP target)
        })
        val banner = column(); col.addView(banner)
        col.addView(horizScroll(topRow).apply { isFillViewport = true })
        val chips = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(8), 0, 0)
        }
        col.addView(horizScroll(chips))
        val holder = column(); col.addView(holder)
        holder.addView(dimText("Loading…"))
        val renderSearch: (String) -> Unit = { q ->
            scope.launch {
                val o = Http.json("$addonBase/catalog/tv/$liveTvCatId/search=" +
                    java.net.URLEncoder.encode(q, "UTF-8").replace("+", "%20") + ".json")
                if (q == search.text.toString().trim()) {   // stale response guard
                    val metas = o?.optJSONArray("metas") ?: org.json.JSONArray()
                    holder.removeAllViews(); banner.removeAllViews()
                    if (metas.length() == 0) holder.addView(dimText("No channels or shows match."))
                    else for (i in 0 until metas.length()) {
                        val m = metas.optJSONObject(i) ?: continue
                        holder.addView(liveRowWrap(liveRowFromMeta(m)))
                    }
                }
            }
        }
        var searchPending: Runnable? = null
        search.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) {
                searchPending?.let { liveUi.removeCallbacks(it) }
                val q = s?.toString()?.trim() ?: ""
                // blank query: re-render the body IN PLACE (keeps the search field + your
                // cursor) — showMain rebuilt the whole page and dumped focus to the nav
                // rail = "deleting the word kicks me to Home" (AJ Sep 18)
                searchPending = Runnable { if (q.isBlank()) liveRenderBody?.invoke() else renderSearch(q) }
                liveUi.postDelayed(searchPending!!, 350)
            }
        })
        scope.launch {
            val gd = liveGuideData()
            val secs = LinkedHashSet<String>()
            val chans = gd?.optJSONArray("channels") ?: org.json.JSONArray()
            for (i in 0 until chans.length())
                chans.optJSONObject(i)?.optString("section")?.takeIf { it.isNotBlank() }?.let { secs.add(it) }
            val genres = listOf("Guide", "★ Favorites") + secs +
                (if (liveRegion.isBlank()) listOf("Local", "24/7") else emptyList()) + listOf("All Channels")
            // render IN PLACE (AJ Sep 17 "cursor keeps jumping back to usa / opening the
            // home menu"): chip clicks repaint the body BELOW the chips — a full showMain
            // rebuild reset focus + scroll every single click
            val chipViews = HashMap<String, TextView>()
            fun paintChips() {
                for ((g2, v2) in chipViews) {
                    val on = g2 == liveGenre
                    v2.setTextColor(if (on) fg else dim)
                    v2.background = selBg(Color.parseColor(if (on) "#7B5BF5" else "#241F3D"), 20)
                }
            }
            lateinit var renderBody: () -> Unit
            renderBody = {
                liveRenderBody = renderBody   // let the search handler re-render in place
                liveRenderBanner(banner)
                holder.removeAllViews()
                when {
                    liveGenre == "Guide" -> liveRenderGuide(holder, gd) { paintChips(); renderBody() }
                    liveGenre == "★ Favorites" -> {   // full objects ride in guide.json favChannels
                        val fc = gd?.optJSONArray("favChannels") ?: org.json.JSONArray()
                        if (fc.length() == 0) holder.addView(dimText("No favorites yet — long-press any channel to ★ it (search finds the hidden ones)."))
                        else {
                            val now = System.currentTimeMillis()
                            for (i in 0 until fc.length())
                                fc.optJSONObject(i)?.let { holder.addView(liveRowWrap(liveRowFromGuideChannel(it, now))) }
                        }
                    }
                    secs.contains(liveGenre) -> {   // section straight from guide data
                        val now = System.currentTimeMillis()
                        var any = false
                        for (i in 0 until chans.length()) {
                            val c = chans.optJSONObject(i) ?: continue
                            if (c.optString("section") != liveGenre) continue
                            any = true
                            holder.addView(liveRowWrap(liveRowFromGuideChannel(c, now)))
                        }
                        if (!any) holder.addView(dimText("Nothing here right now."))
                    }
                    else -> {   // catalog views: Local / 24⁄7 / All Channels
                        holder.addView(dimText("Loading channels…"))
                        scope.launch {
                            // slash-free "24-7" — a %2F in the path 404s (nginx decodes it)
                            val url = "$addonBase/catalog/tv/$liveTvCatId/genre=" +
                                java.net.URLEncoder.encode(liveGenre.replace("24/7", "24-7"), "UTF-8").replace("+", "%20") + ".json"
                            val o = Http.jsonCached(url, 5 * 60_000L)
                            val metas = o?.optJSONArray("metas") ?: org.json.JSONArray()
                            holder.removeAllViews()
                            if (metas.length() == 0) holder.addView(dimText("No channels in this category right now."))
                            else for (i in 0 until metas.length()) {
                                val m = metas.optJSONObject(i) ?: continue
                                holder.addView(liveRowWrap(liveRowFromMeta(m)))
                            }
                        }
                    }
                }
            }
            chips.removeAllViews()
            for (g in genres) {
                val v2 = TextView(this@MainActivity).apply {
                    text = g; textSize = 13.5f
                    setPadding(dp(14), dp(7), dp(14), dp(7))
                    isClickable = true; isFocusable = true
                    layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, 0, dp(8), dp(8)) }
                    setOnClickListener { liveGenre = g; liveSaveState(); paintChips(); renderBody() }
                }
                chipViews[g] = v2; chips.addView(v2)
            }
            // OPEN Live TV with the cursor on the GUIDE button, not the region selector (AJ Sep 27).
            // The chips build async after the guide fetch, so grab it here once it exists — only if
            // focus is still on the region chip / rail / nothing (i.e. a fresh open, user hasn't moved).
            chipViews["Guide"]?.let { gc ->
                firstContentFocus = gc
                gc.post { val f = currentFocus; if (f == null || f === liveRegionChip || railHasFocus()) gc.requestFocus() }
            }
            paintChips()
            renderBody()
            // back from a live session: cursor returns to the channel they were watching
            liveRestoreFocus(col)
        }
    }

    // LIVE-GAMES banner: sport strips only when that sport has a live game + one Upcoming
    // strip. Region-aware: Fútbol rides with UK, each region sees its own games.
    // SELF-REFRESHING every 3 min while the page is up (AJ Sep 26 "old games still up"):
    // finished games fall off the LIVE strips on their own — no re-entry needed. Skips a
    // round if the cursor is ON the strip (a re-render under the cursor would dump focus).
    private var liveBannerGen = 0
    private fun liveRenderBanner(el: LinearLayout) {
        val gen = ++liveBannerGen
        fun tickLater() {
            liveUi.postDelayed({
                if (gen != liveBannerGen || tab != "Live TV" || !el.isAttachedToWindow) return@postDelayed
                var f: View? = currentFocus; var inside = false
                while (f != null) { if (f === el) { inside = true; break }; f = f.parent as? View }
                if (inside) tickLater() else liveRenderBanner(el)
            }, 180_000)
        }
        tickLater()
        scope.launch {
            // noStale: games strips must come off the WIRE — the 24h disk cache painted
            // yesterday's LIVE games on the first render back (AJ Sep 26 "wtf")
            val d = Http.jsonCached("${liveHost()}/live/${liveKey()}/games.json", 60_000L, noStale = true) ?: return@launch
            val sports = d.optJSONArray("sports") ?: return@launch
            el.removeAllViews()
            val want = if (liveRegion.isBlank()) "US" else liveRegion
            fun keep(sport: String, g: org.json.JSONObject): Boolean =
                if (sport == "Fútbol") want == "UK" else g.optString("rg", "US") == want
            val soonAll = ArrayList<Pair<org.json.JSONObject, String>>()
            for (i in 0 until sports.length()) {
                val sp = sports.optJSONObject(i) ?: continue
                val sport = sp.optString("sport"); val emoji = sp.optString("emoji")
                val live = sp.optJSONArray("live") ?: org.json.JSONArray()
                val kept = (0 until live.length()).mapNotNull { live.optJSONObject(it) }.filter { keep(sport, it) }
                val soon = sp.optJSONArray("soon") ?: org.json.JSONArray()
                (0 until soon.length()).mapNotNull { soon.optJSONObject(it) }
                    .filter { keep(sport, it) }.forEach { soonAll.add(it to emoji) }
                if (kept.isEmpty()) continue
                el.addView(TextView(this@MainActivity).apply {
                    text = "$emoji $sport — LIVE NOW"; setTextColor(Color.parseColor("#E64545"))
                    textSize = 13.5f; setPadding(0, dp(10), 0, dp(4))
                })
                val strip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                for (g in kept) strip.addView(liveGameCard(g, true))
                el.addView(horizScroll(strip))
            }
            if (soonAll.isNotEmpty()) {
                soonAll.sortBy { it.first.optLong("s") }
                el.addView(TextView(this@MainActivity).apply {
                    text = "📅 Upcoming games"; setTextColor(dim); textSize = 13.5f; setPadding(0, dp(10), 0, dp(4))
                })
                val strip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                for ((g, e) in soonAll.take(25)) strip.addView(liveGameCard(g, false, e))
                el.addView(horizScroll(strip))
            }
        }
    }

    private fun liveGameCard(g: org.json.JSONObject, live: Boolean, emoji: String = ""): View =
        column().apply {
            background = selBg(Color.parseColor(if (live) "#2A1A22" else "#1C1832"), 12)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            isFocusable = true; isClickable = true
            tag = "lvfoc:" + g.optString("chid")   // cursor-restore target after a live session
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, 0, dp(8), dp(4)) }
            addView(TextView(this@MainActivity).apply {
                text = (if (emoji.isNotBlank()) "$emoji " else "") + g.optString("t")
                setTextColor(fg); textSize = 13f; maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END; maxWidth = dp(260)
            })
            addView(TextView(this@MainActivity).apply {
                text = (if (live) "🔴 LIVE" else g.optString("when")) + " • " + g.optString("ch")
                setTextColor(if (live) Color.parseColor("#E64545") else dim); textSize = 11f; maxLines = 1
            })
            setOnClickListener { liveTune(g.optString("chid"), g.optString("ch"), g.optString("logo"), g.optString("t")) }
        }

    // CLASSIC GUIDE GRID: fixed channel column + one shared horizontal timeline (all rows
    // scroll together), day tabs, current programme highlighted, ★ favs pinned first
    private fun liveRenderGuide(holder: LinearLayout, gd: org.json.JSONObject?, onRerender: () -> Unit = {}) {
        if (gd == null) { holder.addView(dimText("Loading the guide…")); return }
        val tabs = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(4), 0, dp(6)) }
        val dayAfter = java.text.SimpleDateFormat("EEEE", java.util.Locale.US)
            .format(java.util.Date(System.currentTimeMillis() + 2 * 86400_000L))   // "Saturday", like web
        // 4th tab (AJ Sep 25 "guide doesn't go out 3 days"): from a Thursday the 3-tab guide
        // stopped at Saturday — Sunday (game day) needs its own tab; server ships 96h now
        val day3 = java.text.SimpleDateFormat("EEEE", java.util.Locale.US)
            .format(java.util.Date(System.currentTimeMillis() + 3 * 86400_000L))
        var activeDayTab: View? = null
        for ((i, lbl) in listOf("Today", "Tomorrow", dayAfter, day3).withIndex()) {
            val on = i == liveDay
            val tv = TextView(this).apply {
                text = lbl; textSize = 12.5f; setTextColor(if (on) fg else dim)
                background = selBg(Color.parseColor(if (on) "#3A3450" else "#1C1832"), 14)
                setPadding(dp(12), dp(5), dp(12), dp(5))
                isClickable = true; isFocusable = true
                layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, 0, dp(6), 0) }
                // re-render clears+rebuilds these tabs → the clicked one is detached →
                // focus fell to the nav rail = "clicking today/tomorrow opens Home" (AJ
                // Sep 18). liveDayRefocus tells the fresh guide to grab focus back.
                setOnClickListener { liveDay = i; liveSaveState(); liveDayRefocus = true; onRerender() }
            }
            if (on) activeDayTab = tv
            tabs.addView(tv)
        }
        holder.addView(horizScroll(tabs))   // HSV = reachable by the TV row-nav
        if (liveDayRefocus) { liveDayRefocus = false; activeDayTab?.let { t -> t.post { t.requestFocus() } } }
        val chans = gd.optJSONArray("channels") ?: return
        // ↻ Continue Watching strip like the web (AJ Sep 17): channels this key tunes
        val recIds = gd.optJSONArray("recent")
        if (recIds != null && recIds.length() > 0) {
            val byId2 = HashMap<String, org.json.JSONObject>()
            for (i in 0 until chans.length()) chans.optJSONObject(i)?.let { byId2[it.optString("id")] = it }
            val strip2 = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            var anyR = false
            for (i in 0 until minOf(recIds.length(), 12)) {
                val c2 = byId2[recIds.optString(i)] ?: continue
                anyR = true
                val nt = liveNowTitle(c2, System.currentTimeMillis())
                strip2.addView(column().apply {
                    background = selBg(Color.parseColor("#241F3D"), 12)
                    setPadding(dp(12), dp(8), dp(12), dp(8))
                    isFocusable = true; isClickable = true
                    layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, 0, dp(8), dp(4)) }
                    addView(TextView(this@MainActivity).apply { text = c2.optString("name"); setTextColor(fg); textSize = 12.5f; maxLines = 1 })
                    if (nt.isNotBlank()) addView(TextView(this@MainActivity).apply {
                        text = nt; setTextColor(dim); textSize = 10.5f; maxLines = 1
                        maxWidth = dp(200); ellipsize = android.text.TextUtils.TruncateAt.END })
                    setOnClickListener { liveTune("cklive:" + c2.optString("id"), c2.optString("name"), c2.optString("logo"), nt) }
                })
            }
            if (anyR) {
                holder.addView(TextView(this).apply { text = "↻ Continue watching"; setTextColor(dim); textSize = 12.5f; setPadding(0, dp(2), 0, dp(4)) })
                holder.addView(horizScroll(strip2))
            }
        }
        val favs = HashSet<String>()
        gd.optJSONArray("favs")?.let { for (i in 0 until it.length()) favs.add(it.optString(i)) }
        val now = System.currentTimeMillis()
        val dayStart = if (liveDay == 0) now - (now % 1_800_000L) else {   // half-hour aligned so the red now-line has room
            val cal = java.util.Calendar.getInstance()
            cal.add(java.util.Calendar.DAY_OF_YEAR, liveDay)
            cal.set(java.util.Calendar.HOUR_OF_DAY, 6); cal.set(java.util.Calendar.MINUTE, 0); cal.set(java.util.Calendar.SECOND, 0)
            cal.timeInMillis
        }
        // TODAY scrolls 72h STRAIGHT THROUGH (AJ Sep 25 "when i scroll doesn't go out like
        // 3 days just 12 hours" — restores the Sep 18 behavior AJ liked); the day tabs are
        // 24h jump points. The 12h speed trim predates chunked row building — rows stream
        // in behind the first paint now, so the wide window doesn't slow the open. Channels
        // whose EPG source only publishes ~24h just end early; the big cable class scrolls
        // the full span.
        val winEnd = dayStart + (if (liveDay == 0) 72 else 24) * 3600_000L
        val pxPerMin = dp(4)   // wider timeline — dp(3) read as "compacted" (AJ)
        val rowH = dp(52)
        val ordered = ArrayList<org.json.JSONObject>()
        for (i in 0 until chans.length()) chans.optJSONObject(i)?.let { ordered.add(it) }
        // web-grid grouping: ★ FAVORITES first as its own section, then the lineup by
        // SECTION under purple uppercase headers (AJ: "it says sports and such — make
        // that on there")
        val favRows = ordered.filter { favs.contains(it.optString("id")) }
        val restRows = ordered.filter { !favs.contains(it.optString("id")) }
        // ONE strip per channel (channel cell + its programme blocks) — the TV d-pad nav
        // moves BETWEEN HSV rows, so a single shared timeline made the whole guide one
        // unscrollable centered blob (AJ Sep 17). Per-row scroll = per-row timeline.
        // CHANNEL + TIME header box, web-guide style (AJ Sep 17) — built by a maker so a
        // FLOATING COPY can pin to the top while the guide scrolls (web position:sticky).
        // Every header's tick strip scroll-syncs with the timeline lane below.
        val tickHsvs = ArrayList<HorizontalScrollView>()
        val dateCells = ArrayList<TextView>()
        fun mkHeader(): View = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(bg)
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(2), 0, dp(2)) }
            addView(TextView(this@MainActivity).apply {
                // date rides the pinned header so you always know WHAT DAY you're on
                // once you scroll past today (AJ Sep 17)
                text = java.text.SimpleDateFormat("EEE M/d", java.util.Locale.US).format(java.util.Date(dayStart))
                setTextColor(fg); textSize = 12.5f
                dateCells.add(this)
                background = selBg(Color.parseColor("#16132A"), 6)
                layoutParams = LinearLayout.LayoutParams(dp(150), dp(26)); setPadding(dp(6), dp(4), 0, 0)
            })
            val ticksRow = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
            var tms = dayStart - (dayStart % 1_800_000L)
            while (tms < winEnd) {
                ticksRow.addView(TextView(this@MainActivity).apply {
                    text = liveFmtT(tms); setTextColor(fg); textSize = 11.5f
                    layoutParams = LinearLayout.LayoutParams(30 * pxPerMin, dp(26))
                    setPadding(dp(4), dp(3), 0, 0)
                })
                tms += 1_800_000L
            }
            addView(HorizontalScrollView(this@MainActivity).apply {
                isHorizontalScrollBarEnabled = false; isFocusable = false
                addView(ticksRow)
                tickHsvs.add(this)
                layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { setMargins(dp(2), 0, 0, 0) }
            })
        }
        val hdrRow = mkHeader()
        holder.addView(hdrRow)
        liveHdrView = hdrRow
        liveHdrMaker = { mkHeader() }
        liveHdrFloatHost?.let { host -> host.removeAllViews(); host.addView(mkHeader()) }
        // rows straight in the page: an inner scroll pane jammed against the TV's
        // focus-driven scrolling (rows wedged behind the header, AJ Sep 17)
        val rowsHolder = holder
        fun secHdr(t: String) = rowsHolder.addView(TextView(this).apply {
            text = t.uppercase(); setTextColor(Color.parseColor("#A08EF0")); textSize = 11.5f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setBackgroundColor(Color.parseColor("#1B1636"))
            setPadding(dp(8), dp(4), dp(8), dp(4))
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(4), 0, dp(1)) }
        })
        val grouped = ArrayList<Pair<String?, org.json.JSONObject?>>()
        if (favRows.isNotEmpty()) { grouped.add("★ Favorites" to null); favRows.forEach { grouped.add(null to it) } }
        var lastSec = ""
        // NO row cap (was 150, then 230): the whole lineup renders — categories up top,
        // game blocks at the very bottom (AJ Sep 25). Chunked building below keeps the
        // open instant; a cap here is what made bottom-of-grid sections vanish entirely.
        for (c0 in restRows) {
            val sec = c0.optString("section").ifBlank { c0.optString("genre").ifBlank { "More Channels" } }
            if (sec != lastSec) { lastSec = sec; grouped.add(sec to null) }
            grouped.add(null to c0)
        }
        // SHARED timeline everywhere (AJ Sep 17 "the singular row scrolling — how are you
        // supposed to track what time something is"): one horizontal lane moves every row
        // together, web-style. The d-pad nav exempts the lane (tag) and walks it spatially.
        val leftColM: LinearLayout? = column()
        val rightRowsM: LinearLayout? = column()
        // VIRTUALIZED strips (AJ Sep 25, Fold6 OOM + Firestick LMK: the guide built a real
        // TextView for every block = ~20k StaticLayouts once the window went 96h — <1% of a
        // 512MB heap free at crash). The channel column stays whole (it's the d-pad skeleton
        // and the lvfoc: cursor-restore target); each timeline strip is a fixed-size shell
        // that fills with blocks only near the viewport and empties again when it scrolls
        // far away, so live views stay bounded at a few screens' worth no matter how many
        // channels or how wide the day window. Strip sizes never change on fill/empty —
        // tops are stable, no relayout churn.
        val timelineW = (((winEnd - dayStart) / 60_000L).toInt() * pxPerMin)
        val vStrips = ArrayList<Pair<LinearLayout, org.json.JSONObject>>()
        fun buildEntry(hdrTxt: String?, cOrNull: org.json.JSONObject?) {
            if (hdrTxt != null) {
                run {
                    leftColM!!.addView(TextView(this).apply {
                        text = hdrTxt.uppercase(); setTextColor(Color.parseColor("#A08EF0")); textSize = 10.5f
                        setTypeface(typeface, android.graphics.Typeface.BOLD)
                        setBackgroundColor(Color.parseColor("#1B1636"))
                        setPadding(dp(6), dp(3), 0, 0)
                        layoutParams = LinearLayout.LayoutParams(dp(150), dp(22))
                    })
                    rightRowsM!!.addView(View(this).apply {
                        setBackgroundColor(Color.parseColor("#1B1636"))
                        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(22))
                    })
                }
                return
            }
            val c = cOrNull!!
            val cid = c.optString("id"); val nm = c.optString("name"); val lg = c.optString("logo")
            // REAL-TV-GUIDE pinning (AJ Sep 17): channel cell lives OUTSIDE the scrolling
            // strip so it stays put while the timeline scrolls under it
            val strip = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                // fixed width even while empty — the lane's scroll extent and every row's
                // top must not depend on whether the strip is currently filled
                layoutParams = LinearLayout.LayoutParams(timelineW, rowH)
            }
            val chCell = (LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                layoutParams = LinearLayout.LayoutParams(dp(150), rowH)
                isFocusable = true; isClickable = true
                tag = "lvfoc:cklive:$cid"   // cursor-restore target after a live session ends
                background = selBg(Color.parseColor("#16132A"), 8)
                setPadding(dp(6), 0, dp(4), 0)
                if (lg.isNotBlank()) addView(ImageView(this@MainActivity).apply {
                    layoutParams = LinearLayout.LayoutParams(dp(26), dp(26)).apply { setMargins(0, 0, dp(5), 0) }
                    scaleType = ImageView.ScaleType.FIT_CENTER; load(lg)
                })
                fun cellStar(on: Boolean): CharSequence = if (on) android.text.SpannableString("★ $nm").apply {
                    setSpan(android.text.style.ForegroundColorSpan(Color.parseColor("#F5C542")), 0, 1, 0)
                } else android.text.SpannableString(nm)
                val cellTv = TextView(this@MainActivity).apply {
                    text = cellStar(favs.contains(cid))
                    setTextColor(fg); textSize = 12.5f; maxLines = 2
                    ellipsize = android.text.TextUtils.TruncateAt.END
                }
                addView(cellTv)
                setOnClickListener { liveTune("cklive:$cid", nm, lg, liveNowTitle(c, now)) }
                setOnLongClickListener {
                    val on = !favs.contains(cid)
                    if (on) favs.add(cid) else favs.remove(cid)
                    liveFavToggle(cid, on)
                    cellTv.text = cellStar(on)   // instant flip
                    true
                }
            })
            vStrips.add(strip to c)   // blocks build lazily in vFill when the row nears the viewport
            leftColM!!.addView(chCell.apply {
                (layoutParams as? LinearLayout.LayoutParams)?.setMargins(0, dp(1), 0, dp(1))
            })
            rightRowsM!!.addView(strip.apply {
                (layoutParams as? LinearLayout.LayoutParams)?.setMargins(0, dp(1), 0, dp(1))
            })
        }
        // fill one strip with its real program blocks (the code that used to run eagerly
        // for every channel at build time)
        fun vFill(progRow: LinearLayout, c: org.json.JSONObject) {
            if (progRow.childCount > 0) return
            val cid = c.optString("id"); val nm = c.optString("name"); val lg = c.optString("logo")
            val progs = c.optJSONArray("progs") ?: org.json.JSONArray()
            var cursor = dayStart
            var drew = false
            for (i in 0 until progs.length()) {
                val p = progs.optJSONObject(i) ?: continue
                val s = p.optLong("s"); val e = p.optLong("e")
                if (e <= dayStart || s >= winEnd) continue
                val cs = maxOf(s, dayStart); val ce = minOf(e, winEnd)
                if (cs > cursor) progRow.addView(View(this).apply {   // gap filler
                    layoutParams = LinearLayout.LayoutParams((((cs - cursor) / 60_000L).toInt() * pxPerMin), rowH)
                })
                val cur = s <= now && e > now
                val blockW = maxOf(dp(40), (((ce - cs) / 60_000L).toInt() * pxPerMin))
                val blockText = TextView(this).apply {
                    val bt = p.optString("t"); val tm = liveFmtT(s)
                    text = android.text.SpannableString("$bt\n$tm").apply {
                        setSpan(android.text.style.ForegroundColorSpan(Color.parseColor("#9A8FE8")),
                            bt.length + 1, bt.length + 1 + tm.length, 0)
                    }
                    setTextColor(if (cur) fg else dim); textSize = 10.5f; maxLines = 2
                    ellipsize = android.text.TextUtils.TruncateAt.END
                    setPadding(dp(6), dp(4), dp(4), 0)
                }
                if (cur) {
                    // web look: current block = purple highlight + thin RED now-line at
                    // the exact current minute (AJ: "the whole playing now is just red")
                    progRow.addView(FrameLayout(this).apply {
                        background = selBg(Color.parseColor("#33285F"), 8)
                        isFocusable = true; isClickable = true
                        layoutParams = LinearLayout.LayoutParams(blockW, rowH).apply { setMargins(dp(1), 0, dp(1), 0) }
                        addView(blockText.apply { layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT) })
                        val lineX = (((now - cs) / 60_000L).toInt() * pxPerMin).coerceIn(0, blockW - dp(3))
                        addView(View(this@MainActivity).apply {
                            setBackgroundColor(Color.parseColor("#E94B6A"))
                            layoutParams = FrameLayout.LayoutParams(dp(2), MATCH_PARENT).apply { leftMargin = lineX }
                        })
                        setOnClickListener { liveTune("cklive:$cid", nm, lg, p.optString("t")) }
                    })
                } else progRow.addView(blockText.apply {
                    background = selBg(Color.parseColor("#241F3D"), 8)   // web block shade — channel cells stay darker
                    isFocusable = true; isClickable = true
                    layoutParams = LinearLayout.LayoutParams(blockW, rowH).apply { setMargins(dp(1), 0, dp(1), 0) }
                    setOnClickListener { liveTune("cklive:$cid", nm, lg, p.optString("t")) }
                })
                cursor = ce; drew = true
            }
            if (!drew) progRow.addView(TextView(this).apply {
                text = "Live programming"; setTextColor(dim); textSize = 10.5f; gravity = Gravity.CENTER_VERTICAL
                background = selBg(Color.parseColor("#16132A"), 8)
                setPadding(dp(10), 0, dp(10), 0)
                isFocusable = true; isClickable = true
                layoutParams = LinearLayout.LayoutParams(dp(360), rowH)
                setOnClickListener { liveTune("cklive:$cid", nm, lg, "") }
            })
        }
        // CHUNKED build (AJ Sep 25 "guide bigger… still load up just as quick"): the first
        // batch paints immediately, the rest streams in ~70 rows per beat behind it — the
        // whole lineup exists within ~a second without freezing the open on a 1GB stick.
        // Generation token: leaving/rebuilding the page orphans older pumps harmlessly.
        val myGen = ++liveGuideGen
        // fill strips within ~2 screens of the viewport, empty them again past ~4 — the
        // hysteresis keeps d-pad focus hops and touch flings from thrashing fill/empty.
        // A focused row is never emptied (that would kill the TV cursor mid-navigation).
        var vQueued = false
        lateinit var vSweepNow: () -> Unit
        fun vSweep() {
            if (vQueued) return
            vQueued = true
            liveUi.postDelayed({ vQueued = false; runCatching { vSweepNow() } }, 80)
        }
        vSweepNow = fun() {
            if (myGen != liveGuideGen || !rowsHolder.isAttachedToWindow) return
            var sv: android.view.ViewParent? = rowsHolder.parent
            while (sv != null && sv !is ScrollView) sv = sv.parent
            val scroller = sv as? ScrollView ?: return
            val viewH = scroller.height.takeIf { it > 0 } ?: return
            val top = scroller.scrollY
            for ((strip2, c2) in vStrips) {
                // strip top inside the scroller's content = walk the offset chain up
                var y = 0; var v: View = strip2
                while (v !== scroller) { y += v.top; v = (v.parent as? View) ?: break }
                val near = y + rowH >= top - 2 * viewH && y <= top + 3 * viewH
                val far = y + rowH < top - 4 * viewH || y > top + 5 * viewH
                if (near) runCatching { vFill(strip2, c2) }
                else if (far && strip2.childCount > 0 && !strip2.hasFocus()) strip2.removeAllViews()
            }
        }
        var builtIdx = 0
        fun pump(batch: Int) {
            if (myGen != liveGuideGen) return
            val end = minOf(builtIdx + batch, grouped.size)
            for (i in builtIdx until end) { val (h, c1) = grouped[i]; runCatching { buildEntry(h, c1) } }
            builtIdx = end
            if (builtIdx < grouped.size) liveUi.postDelayed({ runCatching { pump(70) } }, 120)
            vSweep()   // newly added shells near the viewport fill on the next beat
        }
        pump(60)
        // focus-driven TV scrolling and touch scrolling both land here; the gen guard
        // detaches this listener when the guide rebuilds (window-shared observer outlives
        // the page swap)
        lateinit var vObs: android.view.ViewTreeObserver.OnScrollChangedListener
        vObs = android.view.ViewTreeObserver.OnScrollChangedListener {
            if (myGen != liveGuideGen)
                runCatching { rowsHolder.viewTreeObserver.removeOnScrollChangedListener(vObs) }
            else vSweep()
        }
        rowsHolder.post { runCatching { rowsHolder.viewTreeObserver.addOnScrollChangedListener(vObs) }; vSweep() }
        // fresh-open safety: the page may not be attached/measured when the first sweeps
        // fire (sweep no-ops until it is) — without a scroll event nothing would refire
        // and the visible rows would sit empty. A few delayed beats cover the attach.
        for (dl in longArrayOf(300, 700, 1500, 3000)) liveUi.postDelayed({ runCatching { vSweepNow() } }, dl)
        rowsHolder.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
            // column() defaults to MATCH_PARENT width — inside this horizontal row that
            // swallowed ALL the width and left the timeline lane 0px = "everything blank"
            addView(leftColM, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
            addView(HorizontalScrollView(this@MainActivity).apply {
                isHorizontalScrollBarEnabled = false
                tag = "lane"   // the d-pad nav exempts this HSV and navigates INSIDE it
                addView(rightRowsM)
                // time ticks track the timeline as it scrolls (AJ: "how are you supposed
                // to track what time something is")
                setOnScrollChangeListener { _, x, _, _, _ ->
                    for (t in tickHsvs) t.scrollTo(x, 0)
                    // corner date follows the scroll across midnight (AJ Sep 18)
                    val d2 = java.text.SimpleDateFormat("EEE M/d", java.util.Locale.US)
                        .format(java.util.Date(dayStart + (x / pxPerMin) * 60_000L))
                    for (dc in dateCells) dc.text = d2
                }
                layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { setMargins(dp(2), 0, 0, 0) }
            })
        })
    }

    // rows must ride inside a HorizontalScrollView for the TV d-pad row-nav to reach
    // them; fillViewport = full-width row, no sideways scroll
    private fun liveRowWrap(v: View): View =
        HorizontalScrollView(this).apply { isFillViewport = true; isHorizontalScrollBarEnabled = false; addView(v) }

    // fav toggle from ANY row via long-press (AJ Sep 17: search finds it, ★ keeps it)
    private fun liveFavToggle(cid: String, on: Boolean) {
        toast(if (on) "★ Added to favorites" else "Removed from favorites")
        scope.launch {
            Http.post("${liveHost()}/live/${liveKey()}/fav?id=" +
                java.net.URLEncoder.encode(cid, "UTF-8") + "&on=" + (if (on) "1" else "0") + "&p=" + java.net.URLEncoder.encode(Store.currentProfile(this@MainActivity), "UTF-8"),
                org.json.JSONObject())
            liveGuideAt = 0
            // patch the cached favs locally so the ★ shows on the very next render — the
            // 55s guide cache made a fresh star look like it "didn't work"
            runCatching {
                val f = liveGuideJson?.optJSONArray("favs") ?: return@runCatching
                if (on) f.put(cid)
                else {
                    val keep = org.json.JSONArray()
                    for (i in 0 until f.length()) if (f.optString(i) != cid) keep.put(f.optString(i))
                    liveGuideJson?.put("favs", keep)
                }
            }
            // NO page rebuild (AJ Sep 17 "it scrolls the whole row back") — the star lands
            // on the NEXT natural render. Only the Favorites view repaints (its list
            // literally changed).
            if (liveGenre == "★ Favorites" && tab == "Live TV")
                runOnUiThread { runCatching { showMain("Live TV") } }
        }
    }

    private fun liveNowTitle(c: org.json.JSONObject, now: Long): String {
        val progs = c.optJSONArray("progs") ?: return ""
        for (i in 0 until progs.length()) {
            val p = progs.optJSONObject(i) ?: continue
            if (p.optLong("s") <= now && p.optLong("e") > now) return p.optString("t")
        }
        return ""
    }

    // one guide row from guide.json channel: logo | now + progress | next
    private fun liveRowFromGuideChannel(c: org.json.JSONObject, now: Long): View {
        val progs = c.optJSONArray("progs") ?: org.json.JSONArray()
        var nowT = ""; var nowS = 0L; var nowE = 0L; var nextT = ""; var nextS = 0L
        for (i in 0 until progs.length()) {
            val p = progs.optJSONObject(i) ?: continue
            val s = p.optLong("s"); val e = p.optLong("e")
            if (s <= now && e > now) { nowT = p.optString("t"); nowS = s; nowE = e }
            else if (s > now && nextT.isBlank()) { nextT = p.optString("t"); nextS = s }
        }
        return liveRow("cklive:" + c.optString("id"), c.optString("name"), c.optString("logo"),
            nowT, nowS, nowE, nextT, nextS, "")
    }

    private fun liveRowFromMeta(m: org.json.JSONObject): View {
        val g = m.optJSONObject("ckGuide")
        val gn = g?.optJSONObject("now"); val gx = g?.optJSONObject("next")
        val hit = m.optJSONObject("ckHit")
        val hitLine = if (hit != null)
            (if (hit.optBoolean("live")) "🔴 ON NOW: " else "📅 ") + hit.optString("t") +
                (hit.optString("when").takeIf { it.isNotBlank() }?.let { " • $it" } ?: "")
        else ""
        return liveRow(m.optString("id"), m.optString("name"), m.optString("poster"),
            gn?.optString("t") ?: "", gn?.optLong("s") ?: 0L, gn?.optLong("e") ?: 0L,
            gx?.optString("t") ?: "", gx?.optLong("s") ?: 0L, hitLine)
    }

    private fun liveRow(id: String, nm: String, logo: String, nowT: String, nowS: Long,
                        nowE: Long, nextT: String, nextS: Long, hitLine: String): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            isFocusable = true; isClickable = true
            tag = "lvfoc:$id"   // cursor-restore target after a live session ends
            background = selBg(Color.parseColor("#1C1832"), 12)
            setPadding(dp(10), dp(8), dp(10), dp(8))
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, 0, 0, dp(6)) }
            addView(ImageView(this@MainActivity).apply {
                layoutParams = LinearLayout.LayoutParams(dp(56), dp(38)).apply { setMargins(0, 0, dp(10), 0) }
                scaleType = ImageView.ScaleType.FIT_CENTER
                if (logo.isNotBlank()) load(logo)
            })
            val mid = column().apply { layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f) }
            // GOLD ★ shows fav state right on the row (AJ Sep 17 "no way to tell");
            // long-press the row toggles it either way
            val cidStar = id.removePrefix("cklive:")
            fun starText(on: Boolean): CharSequence = if (on) android.text.SpannableString("★ $nm").apply {
                setSpan(android.text.style.ForegroundColorSpan(Color.parseColor("#F5C542")), 0, 1, 0)
            } else android.text.SpannableString(nm)
            val starred = liveGuideJson?.optJSONArray("favs")?.let { f ->
                (0 until f.length()).any { f.optString(it) == cidStar } } ?: false
            val nameTv = TextView(this@MainActivity).apply {
                text = starText(starred)
                setTextColor(fg); textSize = 13.5f; maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            }
            mid.addView(nameTv)
            val now = System.currentTimeMillis()
            if (nowT.isNotBlank()) {
                mid.addView(TextView(this@MainActivity).apply {
                    text = nowT; setTextColor(dim); textSize = 11.5f; maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                })
                if (nowE > nowS) {
                    val pct = ((now - nowS).toFloat() / (nowE - nowS)).coerceIn(0f, 1f)
                    mid.addView(LinearLayout(this@MainActivity).apply {   // progress track
                        orientation = LinearLayout.HORIZONTAL; weightSum = 1f
                        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(3)).apply { setMargins(0, dp(4), dp(20), 0) }
                        setBackgroundColor(Color.parseColor("#2A2542"))
                        addView(View(this@MainActivity).apply {
                            layoutParams = LinearLayout.LayoutParams(0, dp(3), pct)
                            setBackgroundColor(Color.parseColor("#E63946"))
                        })
                    })
                }
            }
            if (hitLine.isNotBlank()) mid.addView(TextView(this@MainActivity).apply {
                text = hitLine; textSize = 11.5f; maxLines = 1
                setTextColor(if (hitLine.startsWith("🔴")) Color.parseColor("#E64545") else dim)
                ellipsize = android.text.TextUtils.TruncateAt.END
            })
            addView(mid)
            if (nextT.isNotBlank()) addView(TextView(this@MainActivity).apply {
                text = "Next: $nextT" + (if (nextS > 0) " • " + liveFmtT(nextS) else "")
                setTextColor(dim); textSize = 10.5f; maxLines = 2; maxWidth = dp(150)
                ellipsize = android.text.TextUtils.TruncateAt.END
            })
            setOnClickListener { liveTune(id, nm, logo, nowT) }
            setOnLongClickListener {
                val cur = liveGuideJson?.optJSONArray("favs")?.let { f ->
                    (0 until f.length()).any { f.optString(it) == cidStar } } ?: false
                liveFavToggle(cidStar, !cur)
                nameTv.text = starText(!cur)   // the star flips RIGHT HERE, no rerender wait
                true
            }
        }

    // TUNING SCREEN (AJ Sep 17 "loading screen … what they are going to watch"): full-screen
    // logo + "Tuning X…" + Now: <programme> while the stream url resolves; the server-side
    // proxy walks dead sources itself, so one url is enough.
    private fun liveTune(id: String, nm: String, logo: String, nowT: String) {
        val dlg = android.app.Dialog(this, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        dlg.setContentView(column().apply {
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0C0C10"))
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            if (logo.isNotBlank()) addView(ImageView(this@MainActivity).apply {
                layoutParams = LinearLayout.LayoutParams(dp(180), dp(80)).apply { setMargins(0, 0, 0, dp(16)) }
                scaleType = ImageView.ScaleType.FIT_CENTER; load(logo)
            })
            addView(android.widget.ProgressBar(this@MainActivity).apply {
                layoutParams = LinearLayout.LayoutParams(dp(38), dp(38)).apply { setMargins(0, 0, 0, dp(14)) }
            })
            addView(TextView(this@MainActivity).apply {
                text = "Tuning $nm…"; setTextColor(fg); textSize = 19f; gravity = Gravity.CENTER
            })
            if (nowT.isNotBlank()) addView(TextView(this@MainActivity).apply {
                text = "Now: $nowT"; setTextColor(dim); textSize = 14f; gravity = Gravity.CENTER
                setPadding(dp(20), dp(6), dp(20), 0)
            })
        })
        dlg.show()
        scope.launch {
            val base = liveTvAddon ?: run { dlg.dismiss(); return@launch }
            val s = Http.json("$base/stream/tv/${java.net.URLEncoder.encode(id, "UTF-8")}.json")
            val st = s?.optJSONArray("streams")
            // steady .ts hub ONLY for 24/7 loop channels (their HLS sessions reset = the
            // Buffy freeze); everything else rides HLS first — the hub feed BUFFERED on
            // live sports while plain HLS stayed smooth (AJ vs David, Sep 17)
            var u: String? = null; var uAny: String? = null
            for (i in 0 until (st?.length() ?: 0)) {
                val o = st?.optJSONObject(i) ?: continue
                val url = o.optString("url"); if (url.isBlank()) continue
                if (o.optInt("ckTs") == 1) { if (u == null) u = url } else if (uAny == null) uAny = url
            }
            val is247 = id.removePrefix("cklive:").let { it.startsWith("24-7-") || it.startsWith("en-24-7-") }
            val play = if (is247) (u ?: uAny) else (uAny ?: u)
            if (play == null) {
                runCatching { dlg.dismiss() }; toast("This channel is down right now"); return@launch
            }
            if (!dlg.isShowing) return@launch   // user backed out of the tuning screen — don't launch
            // ACCESS GATE before the player opens (AJ Sep 18: "firetv, phone, apk — all should
            // get a message when it's locked for the device limit"). Without this the player
            // just spun forever on "playback source error" with no reason. Probe the HLS url
            // (the gate is per-KEY, same on every source) so we don't pull live .ts bytes.
            val gate = Http.liveGate(uAny ?: play)
            if (gate.first == 429 || gate.first == 503 || gate.first == 403) {
                runCatching { dlg.dismiss() }
                val msg = gate.second.ifBlank { when (gate.first) {
                    429 -> "You're already watching Live TV on another device. Stop that stream to watch here, or upgrade your plan for more devices."
                    503 -> "Live TV is at full capacity right now — try again in a couple minutes."
                    else -> "Live TV isn't available on your account."
                } }
                // shown as the CouchKing panel (its own 🔒 + "Live TV locked" title over msg)
                showTopBanner(msg)
                return@launch
            }
            // pass the channel logo so the PLAYER's loading screen shows the same logo —
            // was falling back to title text ("ESPN2") then a spinner = the flicker AJ saw
            // + everything the in-player mini guide needs (guide host, addon, profile, region)
            PlayerActivity.launch(this@MainActivity, play, nm, "live", logo = logo.ifBlank { null },
                live = org.json.JSONObject()
                    .put("addon", base)
                    .put("base", "${liveHost()}/live/${liveKey()}")
                    .put("ch", id).put("region", liveRegion)
                    .put("profile", Store.currentProfile(this@MainActivity)).toString())
            liveGuideStale = true   // guide re-aligns to NOW when they back out of the player
            liveFocusId = id        // …and the cursor lands back on THIS channel's row
            liveUi.postDelayed({ runCatching { dlg.dismiss() } }, 1800)
        }
    }

    /** Top BANNER across the app (AJ Sep 18: "banner across all things when the device limit
     *  is reached") — used when Live TV is gated (device limit / capacity / no access) so the
     *  player never spins forever on a nameless "playback source error". Red bar pinned to the
     *  top, auto-clears after 8s, tap to dismiss. Consistent look on TV, phone, web + desktop. */
    private fun showTopBanner(msg: String) {
        runOnUiThread {
            runCatching {
                root.findViewWithTag<View>("ckbanner")?.let { root.removeView(it) }
                // CENTERED CouchKing-panel modal with an OK button (AJ Sep 18: "I like it in
                // the middle of the screen with an OK button"). Dim scrim behind, the app's
                // card surface + brand accent edge, lock glyph, bold title over the reason.
                val scrim = FrameLayout(this).apply {
                    tag = "ckbanner"
                    setBackgroundColor(Color.parseColor("#CC000000"))
                    isClickable = true; isFocusable = false
                    layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                }
                val okBtn = Button(this).apply {
                    text = "OK"; isAllCaps = false; setTextColor(Color.WHITE)
                    background = selBg(accent, 14, Color.WHITE); stateListAnimator = null
                    isFocusable = true
                    layoutParams = LinearLayout.LayoutParams(dp(170), WRAP_CONTENT)
                    setOnClickListener { runCatching { root.removeView(scrim) } }
                }
                val panel = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
                    background = GradientDrawable().apply {
                        setColor(card); cornerRadius = dp(20).toFloat(); setStroke(dp(1), accent)
                    }
                    elevation = dp(16).toFloat()
                    setPadding(dp(26), dp(26), dp(26), dp(20))
                    layoutParams = FrameLayout.LayoutParams(
                        (resources.displayMetrics.widthPixels * (if (isTv) 0.46 else 0.86)).toInt(),
                        WRAP_CONTENT, Gravity.CENTER)
                    addView(TextView(this@MainActivity).apply { text = "🔒"; textSize = 40f; gravity = Gravity.CENTER })
                    addView(TextView(this@MainActivity).apply {
                        text = "Live TV locked"; setTextColor(fg); textSize = 20f; gravity = Gravity.CENTER
                        setTypeface(typeface, Typeface.BOLD); setPadding(0, dp(12), 0, dp(6))
                    })
                    addView(TextView(this@MainActivity).apply {
                        text = msg; setTextColor(dim); textSize = 14f; gravity = Gravity.CENTER
                        setPadding(0, 0, 0, dp(18))
                    })
                    addView(okBtn)
                }
                scrim.addView(panel)
                scrim.setOnClickListener { runCatching { root.removeView(scrim) } }
                root.addView(scrim); scrim.bringToFront()
                okBtn.post { okBtn.requestFocus() }   // TV: OK is the focused target
            }
        }
    }

    private fun buildShelves(col: LinearLayout, which: String) {
        // (mobile inline Home search removed — the Search tab owns searching)
        buildShelvesInto(col, which)
    }

    private fun buildShelvesInto(col: LinearLayout, which: String) {
        val heroHolder = FrameLayout(this); col.addView(heroHolder)
        val top10Holder = column().apply { setPadding(dp(10), 0, dp(4), 0) }
        if (which == "Home" && (Store.addons(this).isEmpty() || Store.continueList(this).isEmpty()))
            col.addView(top10Holder)   // no CW row yet — Top 10 leads the page instead
        val rows = column().apply { setPadding(dp(10), dp(2), if (isTv) dp(26) else dp(4), dp(28)) }
        col.addView(rows)
        // sideload self-update: gold pill on Home when a newer version is published
        if (which == "Home") Updater.check(this) { upd ->
            updateOffered = upd.version
            val fresh = pendingUpdate?.version != upd.version
            pendingUpdate = upd
            attachUpdatePill()
            // MANDATORY update (AJ Sep 13): below minVersion the app blocks until updated —
            // version skew made devices sort/sync differently and bugs get re-reported per
            // device. One button, installs in place, nothing else focusable.
            if (upd.mandatory) showMandatoryUpdate(upd)
            // TV: repaint once so the rail shows the Update entry
            else if (isTv && fresh && tab == "Home") showMain()
        }
        // STORE builds can't self-update, but they CAN fall too far behind to sync right.
        // Same blocking screen — the button deep-links to the store listing instead. The
        // check rides the USER'S OWN service base at runtime; nothing is baked, the
        // binary stays neutral (a couchking URL in the store APK = account ban).
        if (which == "Home" && Dist.STORE && Store.serviceBase(this).isNotBlank()) scope.launch {
            val j = Http.json("${Store.serviceBase(this@MainActivity)}/tvapp/store-version") ?: return@launch
            val min = j.optString("minVersion", "")
            val local = packageManager.getPackageInfo(packageName, 0).versionName ?: "0"
            if (min.isNotBlank() && Updater.newer(min, local)) showStoreMandatoryUpdate()
        }
        if (which == "Home") {
            // Continue Watching only means something when you can PLAY — hidden for
            // discovery/tracker users (their app is watchlist + watched, clean and normal).
            if (Store.addons(this).isNotEmpty()) {
                val cont = Store.continueList(this)
                if (cont.isNotEmpty()) {
                    val cwHolder = column(); rows.addView(cwHolder)
                    cwRowHolder = cwHolder
                    rows.addView(top10Holder)   // Top 10 rides right under Continue Watching
                    addRow(cwHolder, "Continue Watching", cont, withProgress = true)
                    firstContentFocus = focusableOf(cwHolder)
                    // "+N new episodes" pass — badge + float fresh shows to the front
                    scope.launch {
                        val counts = HashMap<String, Int>()
                        coroutineScope {
                            cont.filter { it.type == "series" }.map { t ->
                                async { counts[t.id] = newEpisodeCount(t.id) }
                            }.forEach { it.await() }
                        }
                        if (counts.values.any { it > 0 }) {
                            // a NEW drop bumps the show to the front like a "touch" AT ITS
                            // AIR TIME — anything actually watched after that outranks it,
                            // so the row keeps following real recency on every device (the
                            // old promote-once wrote array order, which the stamp sort and
                            // the server's re-sort both ignored — AJ Sep 14). Same math as
                            // web/desktop: order key = max(watch stamp, badge'd air time).
                            cwHolder.removeAllViews()
                            addRow(cwHolder, "Continue Watching", cwOrder(cont, counts),
                                   withProgress = true, newEps = counts)
                        }
                    }
                }
            }
            // For You — Movies then Shows, right under Continue Watching (always on Home).
            // My List row removed: the Library tab owns that.
            val fyHolder = column(); rows.addView(fyHolder)
            scope.launch {
                val (fyM, fyS) = forYouRows()
                if (fyM.isNotEmpty()) addRow(fyHolder, "For You — Movies", fyM)
                if (fyS.isNotEmpty()) addRow(fyHolder, "For You — Shows", fyS)
            }
        }
        if (which == "Anime") {
            // TRUE anime (Animation genre AND Japanese origin via TMDB) — Cinemeta's
            // "Animation" genre is mostly western cartoons, which is not what this tab means.
            val animeDefs = listOf(
                Triple("Trending Anime", "tv", "popularity.desc" to ""),
                Triple("Top Rated Anime", "tv", "vote_average.desc" to "&vote_count.gte=500"),
                Triple("Anime Movies", "movie", "popularity.desc" to ""),
                Triple("New Anime", "tv", "first_air_date.desc" to "&vote_count.gte=25"),
            )
            // 2.0.82-style sequential fill, same as the shelf loop (AJ Sep 24 revert)
            scope.launch {
                for ((i, d) in animeDefs.withIndex()) {
                    val items = Discovery.animeRow(d.second, d.third.first, d.third.second)
                    if (items.isEmpty()) continue
                    if (i == 0) buildHeroPager(heroHolder, items.take(6))
                    addRow(rows, d.first, items)
                }
            }
            return
        }
        val defs = when (which) {
            "Movies" -> Discovery.MOVIE_ROWS
            "Shows" -> Discovery.SHOW_ROWS
            else -> {
                // Home = the user's own shelf line-up IN THEIR CHOSEN ORDER (Settings → Shelves).
                // For You lives as its own two pinned rows above — not part of this list.
                Store.enabledShelves(this).mapNotNull { lbl ->
                    Discovery.SHELF_CATALOG.firstOrNull { it.label == lbl && it.catalogId != "FORYOU" } }
            }
        }
        // Home hero = a rotating carousel of THIS WEEK'S trending movies + shows (Pantaflix/Netflix
        // style), independent of whichever shelf happens to be first — no more one random
        // static title ("The Whisper Man") parked on the front screen.
        if (which == "Home") scope.launch {
            val (mv, tv) = coroutineScope {
                val a = async { Discovery.tmdbRow("movie", "trending/movie/day") }
                val b = async { Discovery.tmdbRow("tv", "trending/tv/day") }
                a.await() to b.await()
            }
            val mix = ArrayList<Title>()
            for (i in 0 until maxOf(mv.size, tv.size)) {
                mv.getOrNull(i)?.let { mix.add(it) }; tv.getOrNull(i)?.let { mix.add(it) }
            }
            if (isTv) {
                val showcase = mix.take(8)
                showcase.firstOrNull()?.let { tvInfoUpdate?.invoke(it) }
                // idle showcase: rotate trending up top every 9s until someone browses;
                // browsing narrates instead, rotation resumes after 15s of stillness
                if (showcase.size > 1) {
                    var i = 0
                    lateinit var tick: Runnable
                    tick = Runnable {
                        if (tvInfoUpdate == null) return@Runnable
                        if (System.currentTimeMillis() - lastNarrateAt > 15_000) {
                            i = (i + 1) % showcase.size
                            tvInfoUpdate?.invoke(showcase[i])
                        }
                        rows.postDelayed(tick, 9_000)
                    }
                    rows.postDelayed(tick, 9_000)
                }
            } else buildHeroPager(heroHolder, mix.take(7))
            if (mix.isNotEmpty()) addTop10Row(top10Holder, "Top 10 Today", mix.take(10))
        }
        // 2.0.82-STYLE LOADING, KEPT BY REQUEST (AJ Sep 24: "the home screen rows and
        // picture loading on that version — revert to that and keep it"): rows fill IN
        // ORDER, one after the other, no gray skeleton placeholders. The parallel/skeleton
        // pass (2.0.83) is reverted; the JSON disk cache stays, so repeat opens still
        // paint quickly — the page just fills top-down like it used to.
        scope.launch {
            for ((i, r) in defs.withIndex()) {
                val items = when {
                    // "For You" on HOME: seeded by the whole library (what they play, list, and
                    // check off) — grows into a personal row automatically; trending until then
                    r.catalogId == "FORYOU" -> {
                        // the user's ADDON algorithm first (real watch history, daily re-spin);
                        // TMDB recommendation graph only as the guest fallback
                        val svc = Addons.forYou(Store.addons(this@MainActivity), profileSeg())
                        val lib = Store.continueList(this@MainActivity) + Store.watchlist(this@MainActivity) +
                                  Store.watchedTitles(this@MainActivity)
                        val mSeeds = lib.filter { it.type != "series" }.map { it.id }.distinct()
                        val sSeeds = lib.filter { it.type == "series" }.map { it.id }.distinct()
                        val recs = if (svc.isNotEmpty()) emptyList() else coroutineScope {
                            val a = async { if (mSeeds.isEmpty()) emptyList() else Discovery.forYou("movie", mSeeds) }
                            val b = async { if (sSeeds.isEmpty()) emptyList() else Discovery.forYou("tv", sSeeds) }
                            val am = a.await(); val bs = b.await()
                            val out = ArrayList<Title>()
                            for (j in 0 until maxOf(am.size, bs.size)) {
                                am.getOrNull(j)?.let { out.add(it) }; bs.getOrNull(j)?.let { out.add(it) }
                            }
                            out
                        }
                        if (svc.isNotEmpty()) svc
                        else recs.ifEmpty { Discovery.tmdbRow("movie", "trending/movie/week") }
                    }
                    // curated watch-order shelf (Marvel chrono etc.): EXACT order, never shuffled
                    r.ids != null -> Discovery.idsRow(r.type, r.ids)
                    // theme category that spans both types (Superheroes/Zombies/…): movies + shows interleaved
                    r.tmdbTv != null && r.tmdb != null -> profileMix(Discovery.tmdbBoth(r.tmdb, r.tmdbTv, pages = 2))
                    // deeper pools (more titles per row) + a per-profile daily shuffle so the
                    // same category isn't the same order every day, and differs per person
                    r.tmdb != null -> profileMix(Discovery.tmdbRow(r.tmdbKind, r.tmdb, pages = 3))
                    else -> profileMix(Discovery.catalog(r.type, r.catalogId, r.genre, pages = 2))
                }
                if (items.isEmpty()) continue
                if (i == 0 && which != "Home") buildHeroPager(heroHolder, items.take(6))
                addRow(rows, r.label, items)
            }
        }
    }

    /** Netflix's Top 10 shelf: giant outlined rank numeral tucked behind each poster. */
    private fun addTop10Row(holder: LinearLayout, labelText: String, items: List<Title>) {
        holder.addView(TextView(this).apply {
            text = labelText; setTextColor(fg); textSize = 17f
            setTypeface(typeface, Typeface.BOLD); setPadding(dp(6), dp(14), 0, dp(8))
        })
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            clipChildren = false; clipToPadding = false
            setPadding(dp(6), dp(8), dp(6), dp(8))
        }
        holder.addView(HorizontalScrollView(this).apply {
            addView(strip); isHorizontalScrollBarEnabled = false
            clipChildren = false; clipToPadding = false
            trackRowX(this, labelText)
        })
        for ((i, t) in items.withIndex()) {
            val cell = FrameLayout(this).apply {
                // two digits need the extra width or the poster eats the "0" in 10;
                // WRAP height so the title under the poster isn't clipped off
                layoutParams = LinearLayout.LayoutParams(dp(if (i == 9) 232 else 168), WRAP_CONTENT).apply { setMargins(dp(2), dp(2), dp(2), dp(4)) }
            }
            // filled ghost numeral with the soft glow (AJ preferred this over the outline look)
            cell.addView(TextView(this).apply {
                text = "${i + 1}"
                textSize = 118f
                setTypeface(Typeface.create("sans-serif-black", Typeface.BOLD))
                setTextColor(Color.parseColor("#26FFFFFF"))
                setShadowLayer(2f, 0f, 0f, Color.parseColor("#B3FFFFFF"))
                includeFontPadding = false
                letterSpacing = -0.08f
                layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.START)
            })
            cell.addView(poster(t, lazy = true).apply {
                layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.END or Gravity.BOTTOM)
            })
            strip.addView(cell)
        }
        pinRowEnds(strip)
        scheduleArtPass()
    }

    /** Deep-link a provider chip to that provider's own storefront/search for the title.
     *  The URL table lives in the flavor-split Links object — the store/amazon stub
     *  returns null so those binaries carry no provider URLs at all. */
    private fun openProvider(provider: String, title: String, fallback: String?) {
        val url = Links.providerUrl(provider, title, fallback) ?: return
        try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) } catch (_: Exception) { toast("No browser available") }
    }

    private var jumpToResults = false
    private var searchQuery = ""
    // TV d-pad: the board ScrollView key handler needs these to move UP from the top
    // results row back to the search box, and DOWN from the box into results — without
    // ever escaping to the nav rail (AJ Sep 27 "can't scroll up to the search bar / DOWN opens the home menu").
    private var searchInput: EditText? = null
    private var searchResultsHost: LinearLayout? = null

    private fun buildSearch(col: LinearLayout) {
        val body = column().apply { setPadding(dp(14), dp(8), dp(8), dp(28)) }
        col.addView(body)
        val imm = getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
        val results = column()
        // FIRESTICK search fix (AJ Sep 27): the plain field trapped the cursor in the on-screen
        // keyboard — BACK didn't dismiss it and results loaded hidden behind it. This field catches
        // BACK while the IME is up, closes the keyboard, and drops the cursor on the results.
        val input = object : EditText(this) {
            override fun onKeyPreIme(keyCode: Int, event: android.view.KeyEvent): Boolean {
                if (keyCode == android.view.KeyEvent.KEYCODE_BACK) {
                    imm.hideSoftInputFromWindow(windowToken, 0)
                    focusableOf(results)?.requestFocus()
                    return true   // consume: keyboard closes, no trap; a 2nd BACK exits search normally
                }
                return super.onKeyPreIme(keyCode, event)
            }
        }.apply {
            hint = "Search movies & shows…"; setTextColor(fg); setHintTextColor(Color.GRAY)
            background = selBg(card, 8, accent); setPadding(dp(12)); setSingleLine()
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(6), 0, dp(6)) }
            imeOptions = EditorInfo.IME_ACTION_SEARCH
        }
        body.addView(input)
        searchInput = input; searchResultsHost = results   // TV d-pad wiring (see board ScrollView)
        // ALWAYS a fresh search — opening Search from anywhere = empty box, keyboard up, ready
        // to type. No restoring the old query/results (AJ Sep 27: "should just open as a fresh
        // search and not break"). The old restore path is what left the keyboard stuck.
        searchQuery = ""
        input.isFocusableInTouchMode = true
        window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE)
        input.post {
            input.requestFocus()
            input.postDelayed({ imm.showSoftInput(input, android.view.inputmethod.InputMethodManager.SHOW_FORCED) }, 120)
            // belt-and-suspenders second shot — Fire OS occasionally eats the first one
            // while the page is still laying out (AJ Sep 26 "doesn't ALWAYS pop up")
            input.postDelayed({ imm.showSoftInput(input, android.view.inputmethod.InputMethodManager.SHOW_FORCED) }, 550)
        }
        body.addView(results)
        fun run() {
            val q = input.text.toString().trim()
            if (q.length < 2) return
            results.removeAllViews()
            results.addView(dimText("Searching…"))
            scope.launch {
                // both catalogs in parallel — sequential fetches doubled the wait
                val (movies, series, people) = coroutineScope {
                    val a = async { Discovery.search("movie", q) }
                    val b = async { Discovery.search("series", q) }
                    val c = async { Discovery.searchPeople(q) }
                    Triple(a.await(), b.await(), c.await())
                }
                results.removeAllViews()
                if (movies.isEmpty() && series.isEmpty() && people.isEmpty()) { results.addView(dimText("No results for \"$q\"")); return@launch }
                if (people.isNotEmpty()) {
                    results.addView(sectionText("People"))
                    val pstrip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                    for (ph in people) pstrip.addView(personCard(ph))
                    results.addView(horizScroll(pstrip))
                }
                if (series.isNotEmpty()) addRow(results, "Shows", series)
                if (movies.isNotEmpty()) addRow(results, "Movies", movies)
                results.post {
                    focusableOf(results)?.let { fr ->
                        if (fr.id == View.NO_ID) fr.id = View.generateViewId()
                        if (input.id == View.NO_ID) input.id = View.generateViewId()
                        input.nextFocusDownId = fr.id
                        fr.nextFocusUpId = input.id   // d-pad UP from results returns to the search box so you can search again (AJ Sep 27)
                        if (jumpToResults) { jumpToResults = false; fr.requestFocus() }
                    }
                }
            }
        }
        // Stremio-style live search: results appear as you type (debounced)
        var searchJob: kotlinx.coroutines.Job? = null
        input.doAfterTextChanged {
            searchQuery = it?.toString()?.trim() ?: ""
            searchJob?.cancel()
            searchJob = scope.launch { kotlinx.coroutines.delay(450); run() }
        }
        input.setOnEditorActionListener { _, _, _ ->
            jumpToResults = true
            run()
            imm.hideSoftInputFromWindow(input.windowToken, 0)   // done typing = keyboard gone
            true
        }
        // FIRESTICK (AJ Sep 26 "the keypad doesn't always pop up… my last search is there
        // but i can't research"): every other tab leaves the window's soft-input mode on
        // HIDDEN, and the restored-search path never flips it back — so clicking the box
        // focused it but the keypad stayed down. Clicking the box now ALWAYS raises it.
        input.setOnClickListener {
            window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE)
            input.requestFocus()
            imm.showSoftInput(input, android.view.inputmethod.InputMethodManager.SHOW_FORCED)
        }
        // FIRESTICK: d-pad UP from the results lands back on the box — raise the keyboard on focus
        // (not just click) so you can immediately type a new search (AJ Sep 27)
        if (isTv) input.setOnFocusChangeListener { _, has ->
            if (has) {
                window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE)
                imm.showSoftInput(input, android.view.inputmethod.InputMethodManager.SHOW_FORCED)
            } else {
                // Leaving the box (DOWN into results) = keyboard goes away and the sticky
                // ALWAYS_VISIBLE flag is cleared, so it can't force itself back over the
                // results — this is what left it "stuck" on reopen (AJ Sep 27).
                window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN)
                imm.hideSoftInputFromWindow(input.windowToken, 0)
            }
        }
    }

    // ---------- Library (Stremio-style: search + type filter + sorts + poster grid) ----------
    private var libFilter = "All"
    private var libSort = "Recent"

    private fun buildLibrary(col: LinearLayout) {
        val body = column().apply { setPadding(dp(12), dp(6), dp(12), dp(28)) }
        col.addView(body)
        val input = field("Search your library…")
        if (!isTv) body.addView(input)   // TV: the Search tab does searching — no bar here
        val controls = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val gridHolder = column()
        var query = ""
        fun render() {
            gridHolder.removeAllViews()
            // Library = what you ADDED, nothing else (AJ: "why is stuff I clicked play on
            // in my library?"). Continue Watching owns in-progress; watched history isn't
            // a library — the Watched/Unwatched sorts still work within your list.
            val all = Store.watchlist(this).distinctBy { it.id }
            var list = when (libFilter) {
                "Movies" -> all.filter { it.type != "series" }
                "Shows" -> all.filter { it.type == "series" }
                else -> all
            }
            if (query.isNotBlank()) list = list.filter { it.name.contains(query, true) }
            list = when (libSort) {
                "A–Z" -> list.sortedBy { it.name.lowercase() }
                "Z–A" -> list.sortedByDescending { it.name.lowercase() }
                // Watched draws from your actual watch HISTORY (movies + shows, added or not) —
                // AJ Sep 28. watchedTitles() is stored newest-watched first, so we keep that order
                // (recent → oldest) instead of re-sorting.
                "Watched" -> {
                    var w = Store.watchedTitles(this).distinctBy { it.id }
                    w = when (libFilter) {
                        "Movies" -> w.filter { it.type != "series" }
                        "Shows" -> w.filter { it.type == "series" }
                        else -> w
                    }
                    if (query.isNotBlank()) w = w.filter { it.name.contains(query, true) }
                    w
                }
                "Unwatched" -> list.filter { !Store.isWatched(this, it.id) }
                else -> list   // Recent = natural order (continue first, then most-recent adds)
            }
            if (list.isEmpty()) {
                gridHolder.addView(dimText(if (query.isBlank() && libSort !in listOf("Watched", "Unwatched"))
                    "Your library is empty. Add titles with the + on any movie or show — they'll live here."
                    else "Nothing matches"))
                return
            }
            // "All" = Movies section first, Shows underneath (AJ) — filters still narrow to one
            fun paintGrids(counts: Map<String, Int>?) {
                gridHolder.removeAllViews()
                var shown = list
                if (libSort == "New episodes" && counts != null) {
                    // a real FILTER (AJ): only shows that actually have unwatched new
                    // episodes, most new first — not the whole library re-sorted
                    shown = list.filter { (counts[it.id] ?: 0) > 0 }
                        .sortedByDescending { counts[it.id] ?: 0 }
                    if (shown.isEmpty()) {
                        gridHolder.addView(dimText("No new episodes right now — shows you track will appear here when new episodes air."))
                        return
                    }
                }
                // rows EVERYWHERE (AJ: no columns) — big filtered sets chunk into more rows
                fun rows(label: String, l: List<Title>) {
                    l.chunked(15).forEachIndexed { i, chunk ->
                        addRow(gridHolder, if (i == 0) label else "", chunk, newEps = counts)
                    }
                }
                if (libFilter == "All") {
                    val movies = shown.filter { it.type != "series" }
                    val showsL = shown.filter { it.type == "series" }
                    if (movies.isNotEmpty()) rows("Movies", movies)
                    if (showsL.isNotEmpty()) rows("Shows", showsL)
                } else rows(libFilter, shown)
            }
            paintGrids(null)
            scope.launch {
                val counts = HashMap<String, Int>()
                coroutineScope {
                    list.filter { it.type == "series" }.map { t ->
                        async { counts[t.id] = newEpisodeCount(t.id) }
                    }.forEach { it.await() }
                }
                if (counts.values.any { it > 0 } || libSort == "New episodes") paintGrids(counts)
            }
        }
        // chips repaint IN PLACE (rebuilding stole the cursor and threw it to the menu)
        fun paintControls() {
            controls.removeAllViews()
            val repaints = ArrayList<() -> Unit>()
            for (f in listOf("All", "Movies", "Shows")) {
                lateinit var chip: TextView
                fun paintChip() {
                    val active = f == libFilter
                    chip.setTextColor(if (active) fg else dim)
                    chip.setTypeface(chip.typeface, if (active) Typeface.BOLD else Typeface.NORMAL)
                    chip.background = selBg(if (active) accent else Color.parseColor("#2C2649"), 16)
                }
                chip = TextView(this).apply {
                    text = f; textSize = 14f
                    setPadding(dp(14), dp(8), dp(14), dp(8))
                    layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(4), dp(8), dp(4)) }
                    isClickable = true; isFocusable = true
                    setOnClickListener { libFilter = f; repaints.forEach { it() }; render() }
                }
                repaints.add(::paintChip); paintChip()
                controls.addView(chip)
            }
            val sorts = listOf("Recent", "New episodes", "A–Z", "Z–A", "Watched", "Unwatched")
            lateinit var sortChip: TextView
            sortChip = TextView(this).apply {
                textSize = 14f; setTextColor(fg); setTypeface(typeface, Typeface.BOLD)
                background = selBg(Color.parseColor("#2C2649"), 16)
                setPadding(dp(14), dp(8), dp(14), dp(8))
                layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(4), dp(8), dp(4)) }
                isClickable = true; isFocusable = true
                text = "↕ $libSort"
                setOnClickListener {
                    libSort = sorts[(sorts.indexOf(libSort) + 1) % sorts.size]
                    sortChip.text = "↕ $libSort"; render()
                }
            }
            controls.addView(sortChip)
            controls.post { pinRowEnds(controls) }
        }
        body.addView(horizScroll(controls))
        body.addView(gridHolder)
        input.doAfterTextChanged { query = it?.toString()?.trim() ?: ""; render() }
        paintControls(); render()
    }

    // ---------- Discover (Stremio-style): three DROPDOWNS -> type / catalog / genre ----------
    private var discType = "movie"
    private var discCatIdx = 0
    private var discGenre: String? = null
    private var discYear: Int? = null   // null = All time; else a specific release/air year

    private fun buildDiscover(col: LinearLayout) {
        val body = column().apply { setPadding(dp(12), dp(6), dp(12), dp(28)) }
        col.addView(body)
        val input = field("Search movies & shows…")   // searches BOTH types (below)
        val selRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val gridHolder = column()
        fun genresFor() = if (discType == "movie") Discovery.MOVIE_GENRES else Discovery.TV_GENRES
        val thisYear = java.util.Calendar.getInstance().get(java.util.Calendar.YEAR)
        fun cats() = if (discType == "movie") Discovery.MOVIE_CATS else Discovery.TV_CATS
        var query = ""
        fun load() {
            gridHolder.removeAllViews()
            gridHolder.addView(dimText(if (query.isBlank()) "Loading…" else "Searching…"))
            scope.launch {
                val cat = cats()[discCatIdx.coerceIn(cats().indices)]
                val kind = if (discType == "series") "tv" else "movie"
                val items = when {
                    // search hits movies AND shows together (AJ)
                    query.isNotBlank() -> Discovery.searchBoth(query)
                    cat.catalogId == "FORYOU" -> {
                        val seeds = (Store.continueList(this@MainActivity) + Store.watchlist(this@MainActivity) +
                                     Store.watchedTitles(this@MainActivity))
                            .filter { (it.type == "series") == (discType == "series") }.map { it.id }.distinct()
                        if (seeds.isEmpty()) Discovery.tmdbRow(kind, "trending/$kind/week", discGenre)
                        else Discovery.forYou(kind, seeds)
                    }
                    // YEAR filter (AJ Sep 15): Cinemeta catalogs can't year-filter, so route
                    // through TMDB discover with primary_release_year / first_air_date_year — it
                    // honors genre AND provider too. If the picked catalog is a provider/discover
                    // one, keep its filter and just add the year; otherwise a plain popularity
                    // discover scoped to the year. Accurate by construction.
                    discYear != null -> {
                        val yr = if (kind == "tv") "first_air_date_year=$discYear" else "primary_release_year=$discYear"
                        val base = cat.tmdb?.takeIf { it.startsWith("discover/") }
                            ?: "discover/$kind?sort_by=popularity.desc&vote_count.gte=40"
                        val path = base + (if ("?" in base) "&" else "?") + yr
                        profileMix(Discovery.tmdbRow(kind, path, discGenre, pages = 12))
                    }
                    // Discover digs deep: many pages, hundreds of titles per pick (AJ: way more),
                    // shuffled per profile per day so it's a fresh mix, not the same list
                    cat.tmdb != null -> profileMix(Discovery.tmdbRow(cat.tmdbKind, cat.tmdb, discGenre, pages = 12))
                    else -> profileMix(Discovery.catalog(discType, cat.catalogId, discGenre, pages = 5))
                }
                gridHolder.removeAllViews()
                if (items.isEmpty()) { gridHolder.addView(dimText(if (query.isBlank()) "Nothing here." else "No results for \"$query\"")); return@launch }
                // rows, like everywhere else (AJ: grids are stupid)
                items.chunked(15).forEachIndexed { i, chunk -> addRow(gridHolder, if (i == 0) cat.label else "", chunk) }
            }
        }
        var searchJob: kotlinx.coroutines.Job? = null
        input.doAfterTextChanged {
            query = it?.toString()?.trim() ?: ""
            searchJob?.cancel()
            searchJob = scope.launch { kotlinx.coroutines.delay(450); load() }
        }
        lateinit var paint: () -> Unit
        // picking from a dropdown repaints the row — put the cursor BACK on that dropdown
        // (the rebuild was throwing it to the side menu)
        fun repaintKeep(idx: Int) { paint(); selRow.post { selRow.getChildAt(idx)?.requestFocus() } }
        paint = {
            selRow.removeAllViews()
            selRow.addView(dropdown(if (discType == "movie") "Movies" else "TV Series") {
                pickSheet("Type", listOf("Movies", "TV Series"), if (discType == "movie") 0 else 1) {
                    // movie/TV genre sets differ — drop a now-invalid genre when the type flips
                    discType = if (it == 0) "movie" else "series"; discCatIdx = 0; discGenre = null
                    repaintKeep(0); load()
                }
            })
            selRow.addView(dropdown(cats()[discCatIdx.coerceIn(cats().indices)].label) {
                pickSheet("Catalog", cats().map { c -> c.label }, discCatIdx) { discCatIdx = it; repaintKeep(1); load() }
            })
            selRow.addView(dropdown(discGenre ?: "All genres") {
                val gs = genresFor()
                val opts = listOf("All genres") + gs
                pickSheet("Genre", opts, opts.indexOf(discGenre ?: "All genres").coerceAtLeast(0)) {
                    discGenre = if (it == 0) null else gs[it - 1]; repaintKeep(2); load()
                }
            })
            selRow.addView(dropdown(discYear?.toString() ?: "All years") {
                val years = (thisYear downTo 1950).toList()
                val opts = listOf("All years") + years.map { it.toString() }
                val cur = if (discYear == null) 0 else opts.indexOf(discYear.toString()).coerceAtLeast(0)
                pickSheet("Year", opts, cur) {
                    discYear = if (it == 0) null else years[it - 1]; repaintKeep(3); load()
                }
            })
        }
        body.addView(input)               // search box lives IN Discover now (searches movies + shows)
        body.addView(horizScroll(selRow))
        body.addView(gridHolder)
        paint(); load()
    }

    private fun dropdown(label: String, onClick: () -> Unit) = TextView(this).apply {
        text = "$label  ▾"; setTextColor(fg); textSize = 14.5f; setTypeface(typeface, Typeface.BOLD)
        background = selBg(Color.parseColor("#241F3D"), 10)
        setPadding(dp(14), dp(9), dp(14), dp(9))
        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(4), dp(10), dp(6)) }
        isClickable = true; isFocusable = true
        setOnClickListener { onClick() }
    }

    /** Stremio-style picker: scrollable menu sliding up from the bottom, ✓ on the current pick. */
    private fun pickSheet(title: String, options: List<String>, current: Int,
                          icons: List<Int?>? = null, onPick: (Int) -> Unit) {
        val d = android.app.Dialog(this)
        val col = column().apply {
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#1B1830"))
                cornerRadii = floatArrayOf(dp(18).toFloat(), dp(18).toFloat(), dp(18).toFloat(), dp(18).toFloat(), 0f, 0f, 0f, 0f)
            }
            setPadding(dp(14), dp(14), dp(14), dp(16))
        }
        col.addView(TextView(this).apply {
            text = title; setTextColor(dim); textSize = 13f; setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(8), 0, 0, dp(8))
        })
        val list = column()
        for ((i, opt) in options.withIndex()) {
            // Stremio-style row: neutral outline icon + label (icons optional so every
            // existing picker — genres, seasons, settings — renders exactly as before)
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                background = selBg(Color.TRANSPARENT, 10)
                setPadding(dp(12), dp(11), dp(12), dp(11))
                isClickable = true; isFocusable = true
                setOnClickListener { d.dismiss(); onPick(i) }
            }
            icons?.getOrNull(i)?.let { ic ->
                row.addView(ImageView(this).apply {
                    setImageResource(ic); setColorFilter(if (i == current) accent else fg)
                    layoutParams = LinearLayout.LayoutParams(dp(22), dp(22)).apply { setMargins(0, 0, dp(14), 0) }
                })
            }
            row.addView(TextView(this).apply {
                text = if (i == current) "$opt   ✓" else opt
                setTextColor(if (i == current) accent else fg); textSize = 16.5f
                setTypeface(typeface, if (i == current) Typeface.BOLD else Typeface.NORMAL)
            })
            list.addView(row)
        }
        // sheet HUGS its content (AJ: a 4-option menu filled 62% of the screen with
        // emptiness); long pickers still cap at 62% and scroll inside
        col.addView(object : ScrollView(this) {
            override fun onMeasure(w: Int, h: Int) = super.onMeasure(w,
                android.view.View.MeasureSpec.makeMeasureSpec(
                    (resources.displayMetrics.heightPixels * 0.62).toInt(),
                    android.view.View.MeasureSpec.AT_MOST))
        }.apply {
            addView(list)
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
        })
        d.setContentView(col)
        d.window?.apply {
            setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
            setGravity(Gravity.BOTTOM)
            setLayout(MATCH_PARENT, WRAP_CONTENT)
        }
        d.show()
        list.getChildAt(current.coerceIn(options.indices))?.requestFocus()
    }

    private fun selChip(label: String, active: Boolean, onClick: () -> Unit) = TextView(this).apply {
        text = label; textSize = 13.5f
        setTextColor(if (active) fg else dim)
        setTypeface(typeface, if (active) Typeface.BOLD else Typeface.NORMAL)
        background = rounded(if (active) accent else Color.parseColor("#2C2649"), dp(16))
        setPadding(dp(13), dp(7), dp(13), dp(7))
        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(4), dp(8), dp(4)) }
        isClickable = true; isFocusable = true
        setOnClickListener { onClick() }
    }

    /** 3-across poster grid (Discover + Library), instead of a single horizontal strip. */
    private fun posterGrid(holder: LinearLayout, items: List<Title>, newEps: Map<String, Int>? = null) {
        var row: LinearLayout? = null
        for ((i, t) in items.withIndex()) {
            if (i % 3 == 0) {
                row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_HORIZONTAL }
                holder.addView(row)
            }
            row!!.addView(poster(t, null, newEps?.get(t.id)))
        }
    }

    /** ids seen in a "New in Theaters" shelf (addon catalog or Discovery row) — these get
     *  the Stremio-style ribbon on their poster art everywhere they appear. */
    private val inTheatersIds = HashSet<String>()

    /** Instant placeholder: the row's label + gray tiles at poster size, so every shelf
     *  exists in the user's order and the page scrolls the moment the tab opens — the real
     *  posters swap in when that row's fetch lands (AJ Sep 24: "I should just have my rows
     *  the way I organized them and be able to scroll down instantly"). Tiles aren't
     *  focusable, so the D-pad glides past a still-loading row instead of sticking. */
    private fun skeletonRow(holder: LinearLayout, labelText: String) {
        if (labelText.isNotBlank()) holder.addView(TextView(this).apply {
            text = labelText; setTextColor(fg); textSize = if (isTv) 16f else 17f
            setTypeface(typeface, Typeface.BOLD); setPadding(dp(8), dp(14), 0, dp(6))
        })
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(6), dp(8), dp(6), dp(12))
        }
        val pw = if (isTv) dp(112) else dp(126)
        val ph = if (isTv) dp(168) else dp(189)
        repeat(8) {
            strip.addView(View(this).apply {
                layoutParams = LinearLayout.LayoutParams(pw, ph).apply { setMargins(dp(8), dp(6), dp(8), dp(6)) }
                background = rounded(card, dp(12)); alpha = 0.45f
            })
        }
        holder.addView(strip)
    }

    private fun addRow(holder: LinearLayout, labelText: String, items: List<Title>, withProgress: Boolean = false,
                       newEps: Map<String, Int>? = null) {
        if (labelText.contains("In Theaters", ignoreCase = true))
            for (t in items) if (t.type != "series") inTheatersIds.add(t.id)
        if (labelText.isNotBlank()) holder.addView(TextView(this).apply {
            text = labelText; setTextColor(fg); textSize = if (isTv) 16f else 17f
            setTypeface(typeface, Typeface.BOLD); setPadding(dp(8), dp(14), 0, dp(6))
        })
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            clipChildren = false; clipToPadding = false
            setPadding(dp(6), dp(8), dp(6), dp(12))   // zoom headroom — nothing gets cut off
        }
        holder.addView(HorizontalScrollView(this).apply {
            addView(strip); isHorizontalScrollBarEnabled = false
            clipChildren = false; clipToPadding = false
            trackRowX(this, labelText)
        })
        // 40 per row is Netflix territory — the deep fetch pools still feed the daily
        // shuffle, but nobody d-pads past 40 and every extra tile is RAM on a 1GB stick
        val wl = Store.watchlist(this).mapTo(HashSet()) { it.id }
        val watched = Store.watchedIdsPublic(this)
        for (t in items.take(60)) strip.addView(poster(t, if (withProgress) Store.cwProgress(this, t.id) else null,
            newEps?.get(t.id), lazy = true, inList = t.id in wl, isDone = t.id in watched))
        pinRowEnds(strip)
        // NO meta or image prefetch here: art is metahub-direct on focus (Stremio's way)
        // and meta loads when the info panel asks — warming 6 metas × every row at launch
        // was ~90 requests racing the posters and made "descriptions load slow"
        scheduleArtPass()
    }

    /** Continue Watching click = pick up EXACTLY where they left off, zero extra clicks
     *  (long-press still opens the menu; the show page is one click away anywhere else). */
    private fun resumeFromCw(t: Title) {
        if (isExpired()) { showDetail(t); return }   // expired → detail page shows the banner where streams go
        val sid0 = Store.cwLast(this, t.id) ?: run { showDetail(t); return }
        toast("Resuming…")
        scope.launch {
            val m = Discovery.meta(t.type, t.id)
            // ADVANCE-ON-FINISH (AJ Sep 28): if the last-played episode is already watched, resume
            // the NEXT aired episode instead of replaying the finished one from its end. Derived at
            // resume time from watched-state so it works no matter how it finished (back-out, Next,
            // or another device) — no per-exit bookkeeping to get out of sync.
            var sid = sid0
            if (t.type == "series" && m != null && Store.isWatched(this@MainActivity, sid0)) {
                val se0 = Regex("^(tt\\d+):(\\d+):(\\d+)$").find(sid0)
                if (se0 != null) {
                    val cs = se0.groupValues[2].toInt(); val ce = se0.groupValues[3].toInt()
                    val eps = m.videos.filter { it.season > 0 && it.aired }
                        .sortedWith(compareBy({ it.season }, { it.episode }))
                    val nxt = eps.dropWhile { it.season < cs || (it.season == cs && it.episode <= ce) }
                        .firstOrNull { !Store.isWatched(this@MainActivity, "${t.id}:${it.season}:${it.episode}") }
                    if (nxt != null) sid = "${t.id}:${nxt.season}:${nxt.episode}"
                    // CAUGHT UP (AJ Sep 28): finished the latest aired episode and the next one isn't
                    // out yet — don't replay the finished episode. Open the detail page (shows the
                    // air date). Once the next episode airs, this same derivation resumes IT.
                    else { showDetail(t); return@launch }
                }
            }
            val st = Addons.streams(Store.addons(this@MainActivity), t.type, sid, profileSeg()).firstOrNull()
            if (st == null) { showDetail(t); return@launch }
            // resuming from Continue Watching counts as "seen the new episodes" — clear the badge
            // here too (not just on the detail page), and it syncs to every device (AJ Sep 10)
            m?.let { if (t.type == "series") dismissNewEpsBadge(t, it) }
            val se = Regex("^tt\\d+:(\\d+):(\\d+)$").find(sid)
            val label = if (se != null) "${t.name} S${se.groupValues[1]}E${se.groupValues[2]}" else t.name
            Store.pushContinue(this@MainActivity, t)
            Store.setCwLast(this@MainActivity, t.id, sid)
            PlayerActivity.launch(this@MainActivity, Http.direct(withProfile(st.url)), label, sid,
                poster = t.poster, titleId = t.id, type = t.type, subsJson = st.subsJson,
                backdrop = m?.background ?: t.poster, logo = m?.logo)
        }
    }

    private fun poster(t: Title, pct: Int? = null, newEps: Int? = null, lazy: Boolean = false,
                       inList: Boolean? = null, isDone: Boolean? = null): View {
        val pw = if (isTv) dp(112) else dp(126)
        val ph = if (isTv) dp(168) else dp(189)
        val wrap = FrameLayout(this).apply {
            tag = "tile:" + t.id   // repaintTiles/removeTileInPlace find live tiles by this
            tileTitle[t.id] = t    // neighbor-prefetch looks the full Title up by id
            layoutParams = LinearLayout.LayoutParams(pw, ph).apply { setMargins(dp(8), dp(6), dp(8), dp(6)) }
            background = rounded(card, dp(12)); clipToOutline = true
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(v: View, o: android.graphics.Outline) = o.setRoundRect(0, 0, v.width, v.height, dp(10).toFloat())
            }
            isFocusable = true; isClickable = true; isLongClickable = true
            setOnClickListener { if (pct != null) resumeFromCw(t) else showDetail(t) }
            setOnLongClickListener { titleMenu(t); true }
            setOnFocusChangeListener { v, has ->
                // Stremio-style: the WHOLE cell (art + its title) grows together and lifts —
                // and the focused item HOLDS its spot while the row slides beneath it
                val cell: View = (v.parent as? LinearLayout)?.takeIf { it.orientation == LinearLayout.VERTICAL } ?: v
                val sc = if (isTv) 1.08f else 1.12f
                cell.animate().scaleX(if (has) sc else 1f).scaleY(if (has) sc else 1f).setDuration(120).start()
                cell.translationZ = if (has) dp(4).toFloat() else 0f
                if (has && isTv) {
                    lastContentFocus = v
                    var item: View = cell
                    while (true) {
                        val q = item.parent as? View ?: break
                        if (q.parent is HorizontalScrollView) break
                        item = q
                    }
                    ((item.parent as? View)?.parent as? HorizontalScrollView)?.let { hsv ->
                        // cursor holds its spot exactly like the episode strip — measured
                        // from the strip's direct child so Top-10's numeral frame counts too
                        hsv.smoothScrollTo((item.left - dp(28)).coerceAtLeast(0), 0)
                        (item.parent as? LinearLayout)?.let { hsv.tag = it.indexOfChild(item) }
                    }
                }
                // browsing narrates up top: TV = the fixed Stremio panel (and the ROW you're on
                // glides up beneath it); mobile = the hero
                if (has) {
                    if (isTv && tvInfoUpdate != null) {
                        lastNarrateAt = System.currentTimeMillis()
                        tvInfoUpdate?.invoke(t)
                        // warm the tiles the cursor is LIKELY to land on next (right ×2,
                        // left ×1): their backdrop + meta download while this one shows,
                        // so the next d-pad step paints from cache instead of the network
                        var pit: View = cell
                        while (true) {
                            val q = pit.parent as? View ?: break
                            if (q.parent is HorizontalScrollView) break
                            pit = q
                        }
                        (pit.parent as? LinearLayout)?.let { strip ->
                            val at = strip.indexOfChild(pit)
                            fun tileOf(x: View): Title? {
                                (x.tag as? String)?.takeIf { it.startsWith("tile:") }
                                    ?.let { return tileTitle[it.removePrefix("tile:")] }
                                if (x is android.view.ViewGroup)
                                    for (i in 0 until x.childCount) tileOf(x.getChildAt(i))?.let { return it }
                                return null
                            }
                            // warm neighbors only once the cursor RESTS (300ms):
                            // firing on EVERY d-pad step queued 3 × ~720p backdrop
                            // downloads+decodes per step on the same host+dispatcher as
                            // the visible poster tiles — d-pad flying starved tile loads
                            // and churned the memory cache (Fire OS "posters got slow")
                            v.postDelayed({
                                if (!v.hasFocus()) return@postDelayed
                                for (n in intArrayOf(at + 1, at - 1, at + 2))
                                    strip.getChildAt(n)?.let { c -> tileOf(c)?.let { tvArtPrefetch?.invoke(it) } }
                            }, 300)
                        }
                        // one row at a time: the focused row's LABEL lands flush under the
                        // panel (previous row fully hidden, next row's label peeking below)
                        var rq: View? = v
                        while (rq != null && rq !is HorizontalScrollView) rq = rq.parent as? View
                        // align on the row's LABEL: art + info own everything above, the next
                        // category's label peeks below (AJ: nothing of the row above shows)
                        val rowP = rq?.parent as? LinearLayout
                        val ri = rowP?.indexOfChild(rq) ?: -1
                        val anchor = if (ri > 0 && rowP!!.getChildAt(ri - 1) is TextView) rowP.getChildAt(ri - 1) else (rq ?: v)
                        homeScroll?.smoothScrollTo(0, (yInHomeScroll(anchor) - dp(4)).coerceAtLeast(0))
                    } else {
                        v.postDelayed({ if (v.hasFocus()) heroNarrate?.invoke(t) }, 250)
                    }
                }
            }
        }
        wrap.addView(ImageView(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT); scaleType = ImageView.ScaleType.CENTER_CROP
            // lazy tiles park the URL in the tag; the art pass loads it only when the tile
            // nears the viewport (and drops it again far away) — a 1GB stick can't hold a
            // whole board of bitmaps, and eager-loading every row is what LMK-killed us
            t.poster?.let { if (lazy) tag = it else load(tileArtUrl(it)) }
        })
        // Stremio-style "in cinemas" ribbon riding the bottom of the art (AJ: the badge
        // belongs ON the image, not as a sentence on the detail page)
        if (t.id in inTheatersIds) wrap.addView(TextView(this).apply {
            text = "🎬 IN CINEMAS"; setTextColor(Color.parseColor("#F5C518"))
            textSize = if (isTv) 9.5f else 10.5f; setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER; setBackgroundColor(Color.parseColor("#CC000000"))
            setPadding(0, dp(3), 0, dp(3))
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.BOTTOM)
        })
        // "+N": new episodes aired since they last watched this show
        newEps?.takeIf { it > 0 }?.let { n ->
            wrap.addView(TextView(this).apply {
                tag = "b:new"
                text = "+$n"; setTextColor(fg); textSize = 12f; setTypeface(typeface, Typeface.BOLD)
                background = rounded(accent, dp(10))
                setPadding(dp(7), dp(2), dp(7), dp(2))
                layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.START)
                    .apply { setMargins(dp(6), dp(6), 0, 0) }
            })
        }
        // Stremio badges: purple ✓ circle top-right = in My List; yellow eye top-left = watched.
        // Rows pass the flags in (ONE prefs parse per row) — per-tile Store lookups re-parsed
        // the whole watchlist JSON twice per tile and made board builds visibly stutter.
        if (inList ?: Store.inWatchlist(this, t.id)) wrap.addView(wlBadge())
        // drop the watched ✓ below the "+N" badge when both are on this tile, so the new-episode
        // count isn't hidden behind the check (AJ Sep 15)
        if (isDone ?: Store.isWatched(this, t.id)) wrap.addView(doneBadge(if ((newEps ?: 0) > 0) 34 else 6))
        // Stremio-style progress: faded white bar floated slightly above the bottom edge
        // Stremio-style watch bar: full-width strip flush against the poster's bottom edge,
        // dark track + solid white fill showing exactly where they left off
        pct?.takeIf { it in 2..97 }?.let { p ->
            wrap.addView(View(this).apply {
                tag = "b:bar"
                background = rounded(Color.parseColor("#59000000"), dp(2))
                layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, dp(4), Gravity.BOTTOM)
                    .apply { setMargins(dp(9), 0, dp(9), dp(9)) }
            })
            wrap.addView(View(this).apply {
                tag = "b:bar"
                background = rounded(Color.WHITE, dp(2))
                layoutParams = FrameLayout.LayoutParams(((pw - dp(18)) * p / 100).coerceAtLeast(dp(6)), dp(4),
                    Gravity.BOTTOM or Gravity.START).apply { setMargins(dp(9), 0, 0, dp(9)) }
            })
        }
        if (!Store.showTitles(this)) return wrap
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT)
            addView(wrap)
            addView(TextView(this@MainActivity).apply {
                text = t.name; setTextColor(fg); textSize = 12f; maxLines = 1
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                ellipsize = android.text.TextUtils.TruncateAt.END; gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(pw + dp(8), WRAP_CONTENT).apply { setMargins(0, dp(2), 0, dp(4)) }
            })
        }
    }

    /** For You per type: the user's addon algorithm first, TMDB recs for guests, trending last. */
    private suspend fun forYouRows(): Pair<List<Title>, List<Title>> = coroutineScope {
        val addons = Store.addons(this@MainActivity)
        val who = profileSeg()
        val svcM = async { runCatching { Addons.forYouType(addons, "movie", who) }.getOrDefault(emptyList()) }
        val svcS = async { runCatching { Addons.forYouType(addons, "series", who) }.getOrDefault(emptyList()) }
        var mv = svcM.await(); var tv = svcS.await()
        if (mv.isEmpty() || tv.isEmpty()) {
            val lib = Store.continueList(this@MainActivity) + Store.watchlist(this@MainActivity) +
                      Store.watchedTitles(this@MainActivity)
            val mSeeds = lib.filter { it.type != "series" }.map { it.id }.distinct()
            val sSeeds = lib.filter { it.type == "series" }.map { it.id }.distinct()
            if (mv.isEmpty()) mv = (if (mSeeds.isEmpty()) emptyList() else Discovery.forYou("movie", mSeeds))
                .ifEmpty { Discovery.tmdbRow("movie", "trending/movie/week") }
            if (tv.isEmpty()) tv = (if (sSeeds.isEmpty()) emptyList() else Discovery.forYou("tv", sSeeds))
                .ifEmpty { Discovery.tmdbRow("tv", "trending/tv/week") }
        }
        mv to tv
    }

    private val newEpCache = HashMap<String, Int>()
    private val newEpAirCache = HashMap<String, Long>()   // newest unwatched ep's air time

    /** CW order = newest of (your last watch stamp, a badge'd show's new-episode air time).
     *  The air date acts like a touch: front of the row the day it drops, then normal
     *  recency takes over as other things get watched. Identical rule on web/desktop, and
     *  every input (position stamps, air dates, badge dismissals) is in the synced blob —
     *  all devices compute the same order. */
    private fun cwOrder(cont: List<Title>, counts: Map<String, Int>): List<Title> =
        cont.sortedByDescending { t ->
            maxOf(Store.titleStamp(this, t.id),
                  if ((counts[t.id] ?: 0) > 0) newEpAirCache[t.id] ?: 0L else 0L)
        }

    /** Opening a show (click, not watching) clears its "+N new episodes" badge — record the
     *  latest aired episode as seen so it only returns when something newer airs. */
    private fun dismissNewEpsBadge(t: Title, m: Meta) {
        if (m.type != "series") return
        val key = m.videos.filter { it.season > 0 && it.aired }
            .maxOfOrNull { it.season * 10000 + it.episode } ?: return
        if (key > Store.newEpsBadgeKey(this, t.id)) {
            Store.markNewEpsBadgeSeen(this, t.id, key); newEpCache[t.id] = 0
            if (Store.signedIn(this)) pushState()   // clear the badge on every device (AJ Sep 10)
        }
    }

    /** How many episodes AIRED after the last one this person watched (0 = caught up). */
    private suspend fun newEpisodeCount(titleId: String): Int {
        newEpCache[titleId]?.let { return it }
        val m = Discovery.meta("series", titleId) ?: return 0
        val eps = m.videos.filter { it.season > 0 }.sortedWith(compareBy({ it.season }, { it.episode }))
        if (eps.isEmpty()) return 0
        // opening the show dismisses the badge until something newer than what you saw airs
        val latestAiredKey = eps.filter { it.aired }.maxOfOrNull { it.season * 10000 + it.episode } ?: 0
        if (latestAiredKey > 0 && Store.newEpsBadgeKey(this, titleId) >= latestAiredKey) {
            newEpCache[titleId] = 0; newEpAirCache[titleId] = 0L; return 0
        }
        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
        val fmtDay = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
        fun airTime(e: Episode): Long {
            val r = e.releasedIso ?: return 0L
            return try {
                if (r.length >= 19) fmt.parse(r.substring(0, 19))!!.time
                else fmtDay.parse(r.take(10))!!.time
            } catch (_: Exception) { 0L }
        }
        val watched = eps.filter { Store.isWatched(this, it.id) || (Store.pos(this, it.id)?.first ?: 0) > 60_000 }
        val last = watched.maxWithOrNull(compareBy({ it.season }, { it.episode }))
        if (last == null) {
            // NEVER-WATCHED library show (AJ Sep 13: "even if I haven't watched them"):
            // badge on episodes that aired AFTER the show was added — "new since you
            // saved it", searchable via Library → New episodes. No add-stamp → no badge
            // (the whole back catalog is not "new").
            val addedAt = Store.addedAt(this, titleId)
            if (addedAt <= 0) { newEpCache[titleId] = 0; newEpAirCache[titleId] = 0L; return 0 }
            val freshAdd = eps.filter { it.aired && airTime(it) > addedAt }
            val n0 = freshAdd.size.coerceAtMost(9)
            newEpCache[titleId] = n0
            newEpAirCache[titleId] = if (n0 > 0) freshAdd.maxOf { airTime(it) } else 0L
            return n0
        }
        // binging OLD seasons: everything after you is technically "new" (AJ hit +9 on
        // L&O while deep in the back catalog, nothing had aired) — the badge only means
        // something when you're caught up to the current (or previous) season
        val maxSeason = eps.filter { it.aired }.maxOfOrNull { it.season } ?: return 0
        if (last.season < maxSeason - 1) { newEpCache[titleId] = 0; newEpAirCache[titleId] = 0L; return 0 }
        val fresh = eps.filter { it.aired && (it.season > last.season || (it.season == last.season && it.episode > last.episode)) }
        val n = fresh.size.coerceAtMost(9)
        newEpCache[titleId] = n
        newEpAirCache[titleId] = if (n > 0) fresh.maxOf { airTime(it) } else 0L
        return n
    }

    /** One hero slide. pos/count > 1 adds the Netflix/Pantaflix-style dot strip. */
    /** Long-press on any poster — Stremio-style quick actions for the title. */
    private fun titleMenu(t: Title) {
        data class Opt(val label: String, val icon: Int?, val act: () -> Unit)
        val opts = ArrayList<Opt>()
        opts.add(Opt("Details", R.drawable.ic_info) { showDetail(t) })
        // NO rebuild on mutation — even refreshInPlace's restore blinked and could land a
        // hair off (async rows). Add/mark just flips the badge on the live tile; removals
        // pull the tile out of its row live. The page itself never rebuilds. (AJ)
        opts.add(Opt(if (Store.inWatchlist(this, t.id)) "Remove from Library" else "Add to Library",
                     if (Store.inWatchlist(this, t.id)) R.drawable.ic_lib_remove else R.drawable.ic_lib_add) {
            val on = Store.toggleWatchlist(this, t)
            pushState()
            toast(if (on) "Added to Library" else "Removed from Library")
            // Library = watchlist only now: removing from the list removes it from the grid
            if (!on && tab == "Library") removeTileInPlace(t.id)
            else repaintTiles(t.id)
        })
        opts.add(Opt(if (Store.isWatched(this, t.id)) "Mark as Unwatched" else "Mark as Watched",
                     if (Store.isWatched(this, t.id)) R.drawable.ic_eye_off else R.drawable.ic_eye) {
            val on = Store.toggleWatchedTitle(this, t)
            pushState()
            toast(if (on) "Marked watched" else "Marked unwatched")
            if (!on && tab == "Library" && !Store.inWatchlist(this, t.id) &&
                Store.continueList(this).none { it.id == t.id }) removeTileInPlace(t.id)
            else repaintTiles(t.id)
        })
        if (Store.continueList(this).any { it.id == t.id }) {
            // ONE option, Stremio-style (photo 11): clearing progress IS leaving
            // Continue Watching — two separate rows for that confused everyone
            opts.add(Opt("Clear Progress", R.drawable.ic_undo) {
                Store.clearProgress(this, t.id); Store.removeContinue(this, t.id)
                syncClear(t.id)
                toast("Progress cleared")
                if (!removeTileInPlace(t.id)) refreshInPlace()
            })
        }
        // current = -1: this is an ACTION menu, nothing is "selected" — the purple+✓
        // highlight is for pickers (genres, seasons) only (AJ, photo 18)
        pickSheet(t.name, opts.map { it.label }, -1, icons = opts.map { it.icon }) { i -> opts[i].act() }
    }

    private fun buildHero(holder: FrameLayout, t: Title, pos: Int = 0, count: Int = 1) {
        // fade ONLY the very first appearance — returning to Home used to blink the hero
        // in every time (AJ: "why isn't it just there")
        val firstBuild = holder.childCount == 0
        holder.removeAllViews()
        if (firstBuild) { holder.alpha = 0f; holder.animate().alpha(1f).setDuration(420).start() }
        else holder.alpha = 1f
        val h = dp(390)
        val back = ImageView(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, h); scaleType = ImageView.ScaleType.CENTER_CROP
            t.poster?.let { load(it) }
        }
        holder.addView(back)
        holder.addView(View(this).apply {   // Netflix-style 4-stop scrim: readable without murking the art
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, h)
            background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(bg, Color.parseColor("#B30B0B0F"), Color.parseColor("#330B0B0F"), Color.TRANSPARENT))
        })
        val overlay = column().apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.BOTTOM); setPadding(dp(18), 0, dp(18), dp(18))
        }
        overlay.addView(TextView(this).apply { text = t.name; setTextColor(fg); textSize = 34f; setTypeface(typeface, Typeface.BOLD) })
        val factsLine = TextView(this).apply { setTextColor(dim); textSize = 13.5f }
        overlay.addView(factsLine)
        val descLine = TextView(this).apply {
            setTextColor(Color.parseColor("#D0D0D0")); textSize = 13.5f; maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(4), dp(40), 0)
        }
        overlay.addView(descLine)
        val btns = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(10), 0, 0) }
        btns.addView(whitePill("Details") { showDetail(t) })
        // says what it does AND shows it happened (AJ: "＋ My List" never changed on tap)
        lateinit var libPill: Button
        fun libLabel() = if (Store.inWatchlist(this, t.id)) "✓ In Library" else "＋ Add to Library"
        libPill = ghostPill(libLabel()) {
            val on = Store.toggleWatchlist(this, t)
            pushState()
            libPill.text = libLabel()
            toast(if (on) "Added to Library" else "Removed from Library"); repaintTiles(t.id)
        }
        btns.addView(libPill)
        overlay.addView(btns)
        if (count > 1) {
            val dots = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dp(2), dp(8), 0, 0) }
            repeat(count) { i ->
                dots.addView(View(this).apply {
                    background = rounded(if (i == pos) fg else Color.parseColor("#59FFFFFF"), dp(3))
                    layoutParams = LinearLayout.LayoutParams(dp(if (i == pos) 18 else 6), dp(6)).apply { setMargins(0, 0, dp(5), 0) }
                })
            }
            overlay.addView(dots)
        }
        holder.addView(overlay)
        scope.launch {
            Discovery.meta(t.type, t.id)?.let { m ->
                m.background?.let { back.load(it) }
                factsLine.text = listOfNotNull(
                    m.year.ifBlank { null }, m.imdbRating.ifBlank { null }?.let { "★ $it" },
                    m.genres.take(3).joinToString(" · ").ifBlank { null }).joinToString("   ")
                descLine.text = m.description
            }
        }
    }

    private var heroFlip: ((Int) -> Unit)? = null
    private var homeScroll: ScrollView? = null
    private var homeScrollY = 0
    private var pendingContentFocus = false
    private var tvInfoUpdate: ((Title) -> Unit)? = null
    // warms a title's board backdrop + meta into cache (set by the board builder, which
    // knows the decode size — the size is part of Coil's cache key, so it must match
    // setArt). Warm meta also means the info panel's instant path fires on focus.
    private var tvArtPrefetch: ((Title) -> Unit)? = null
    // the Title behind each live tile, so the focus handler can prefetch NEIGHBORS
    // (tags only carry the id; meta needs the type too)
    private val tileTitle = HashMap<String, Title>()

    // the live Continue Watching column — rebuilt in place when the player closes, the
    // same removeAllViews+addRow move the "+N new episodes" pass already uses
    private var cwRowHolder: LinearLayout? = null
    private var cwRowSig = ""
    private fun refreshContinueRow() {
        val holder = cwRowHolder ?: return
        val cont = Store.continueList(this)
        // NEVER rebuild while the cursor is inside the row — removeAllViews would destroy
        // the focused tile and focus flies to the nav rail = "sitting on Continue Watching
        // and the Home menu opens out of nowhere" every 60s (AJ Sep 18)
        run {
            var v: View? = currentFocus
            while (v != null) { if (v === holder) return; v = v.parent as? View }
        }
        // and skip entirely when nothing changed (no pointless rebuild/jank). The signature must
        // include each tile's PROGRESS + watched state, not just its id (AJ Sep 28: "watch an
        // episode, come back to Home and it doesn't show I'm halfway until I refresh") — after
        // watching, the id set is identical and only the percent moved, so an id-only signature
        // skipped the repaint and left a stale bar.
        val sig = cont.joinToString("|") { it.id + ":" + (Store.cwProgress(this, it.id) ?: -1) +
            (if (Store.isWatched(this, it.id)) "w" else "") }
        if (sig == cwRowSig) return
        cwRowSig = sig
        holder.removeAllViews()
        // keep the new-episode bump + badges through the 60s live repaint (cache-only —
        // no network here; the full badge pass re-runs whenever Home rebuilds)
        val counts = HashMap<String, Int>()
        for (t in cont) newEpCache[t.id]?.takeIf { it > 0 }?.let { counts[t.id] = it }
        if (cont.isNotEmpty()) addRow(holder, "Continue Watching", cwOrder(cont, counts),
                                      withProgress = true, newEps = counts)
        scheduleArtPass()   // fresh tiles are lazy — load whatever landed in view
    }

    /** Player closed while an episode page is up: repaint the strip's bars IN PLACE — the
     *  bar rides only the episode they're currently on, stale ones vanish, no rebuild. */
    private fun refreshEpisodeBars() {
        fun walk(v: View) {
            val t = v.tag as? String
            if (v is FrameLayout && t?.startsWith("ep:") == true) {
                val parts = t.removePrefix("ep:").split("|")
                val tid = parts.getOrElse(0) { "" }; val eid = parts.getOrElse(1) { "" }
                val dead = ArrayList<View>()
                for (i in 0 until v.childCount) if (v.getChildAt(i).tag == "epbar") dead.add(v.getChildAt(i))
                dead.forEach { v.removeView(it) }
                // bar rules (AJ Sep 13): WATCHED episodes carry a FULL purple bar, anything
                // with progress (from the first second) carries its percent — not just cwLast
                val pct = if (Store.isWatched(this, eid)) 100
                    else Store.pos(this, eid)?.let { (pos, dur) ->
                        if (dur > 0 && pos > 1_000) (100 * pos / dur).toInt() else null } ?: -1
                if (pct >= 0) {
                    // width-0 tiles (fresh build / off-screen) used to be silently skipped
                    // and never revisited — paint after layout instead (AJ Sep 14)
                    fun paintBars() {
                        if (v.width <= 0) return
                        v.addView(View(this).apply {
                            tag = "epbar"; setBackgroundColor(Color.parseColor("#66000000"))
                            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, dp(4), Gravity.BOTTOM)
                        })
                        v.addView(View(this).apply {
                            tag = "epbar"; setBackgroundColor(accent)
                            layoutParams = FrameLayout.LayoutParams(maxOf(dp(6), v.width * pct / 100), dp(4), Gravity.BOTTOM or Gravity.START)
                        })
                    }
                    if (v.width > 0) paintBars() else v.post { paintBars() }
                }
                return
            }
            if (v is android.view.ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
        }
        if (::root.isInitialized) walk(root)
    }
    private var lastNarrateAt = 0L

    // REMOTE BACK walks backward through pages (episode → show → home) — only backing out
    // of Home actually leaves the app
    private val navStack = ArrayDeque<() -> Unit>()
    private var currentPage: (() -> Unit)? = null
    private var poppingBack = false
    /** Real history: entering a page pushes the page you were ACTUALLY on (never a guess),
     *  so BACK always returns to the exact previous screen. */
    private fun pushPage(here: () -> Unit) {
        if (!poppingBack) currentPage?.let { navStack.addLast(it) }
        poppingBack = false
        currentPage = here
    }

    // BACK restores the exact tile you left (row + position): without this, the focus
    // grab after a rebuild lands on the FIRST tile of the FIRST row, whose focus handler
    // then scrolls the page to that row — "back always jumps to the top".
    private var savedRowIdx = -1
    private var savedItemIdx = -1
    private var savedItemId: String? = null   // the exact tile's title id — survives row reorder
    private var restoreFocusAfterBack = false

    // Home's OWN remembered spot for tab switches (Home → Library → Home must land back
    // on the same tile). Separate from savedRow/ItemIdx: those get overwritten by every
    // detail-page visit on OTHER tabs while Home sits in the background.
    private var homeSavedRow = -1
    private var homeSavedItem = -1

    /** Leaving Home for another tab remembers the exact spot (scroll + tile) — coming
     *  back must land where you were, not a re-shuffled top (AJ: "not in the same spot"). */
    private fun rememberHomeSpot(dest: String) {
        if (tab != "Home" || dest == "Home") return
        homeScroll?.takeIf { it.isAttachedToWindow }?.let { homeScrollY = it.scrollY }
        // the click came FROM the rail, so currentFocus is a rail item — the tile the
        // cursor was last on is what we want back when Home returns
        if (isTv) {
            saveRowFocus(lastContentFocus?.takeIf { it.isAttachedToWindow })
            homeSavedRow = savedRowIdx; homeSavedItem = savedItemIdx
        }
    }

    // one-shot scroll restore for the NEXT showMain() — set by refreshInPlace() so a
    // library/watched mutation rebuilds the page WITHOUT jumping back to the top
    private var pendingScrollY = -1

    // MOBILE back-from-detail (AJ phone v1.7: "tap a show, back out, the whole catalog
    // scrolls back to the beginning"): the VERTICAL offset restores fine (same
    // restoreScrollPreDraw path as TV), but each row's HORIZONTAL position only came
    // back on TV — the focus restorer scrolls the remembered tile's row into place, and
    // touch has no focus. Remember every row's x by tab+label as it scrolls; addRow
    // re-applies it on the rebuilt row's first real layout.
    private val rowScrollX = HashMap<String, Int>()
    private fun trackRowX(hsv: HorizontalScrollView, labelText: String) {
        if (isTv || labelText.isBlank()) return
        val key = "$tab|$labelText"
        hsv.setOnScrollChangeListener { _, x, _, _, _ -> rowScrollX[key] = x }
        val savedX = rowScrollX[key] ?: 0
        if (savedX > 0) hsv.viewTreeObserver.addOnGlobalLayoutListener(
            object : android.view.ViewTreeObserver.OnGlobalLayoutListener {
                override fun onGlobalLayout() {
                    if (hsv.width == 0) return   // not laid out yet — keep waiting
                    hsv.viewTreeObserver.removeOnGlobalLayoutListener(this)
                    hsv.scrollTo(savedX, 0)
                }
            })
    }

    /** Rebuild the current page after a mutation (add to library, mark watched…) but land
     *  back on the SAME tile at the SAME scroll — mutations must never throw the cursor
     *  (or the scroll) back to the top of the page. */
    private fun refreshInPlace() {
        homeScroll?.takeIf { it.isAttachedToWindow }?.let { pendingScrollY = it.scrollY }
        if (isTv) { saveRowFocus(); restoreFocusAfterBack = true }
        pendingContentFocus = true
        showMain()
    }

    private fun wlBadge() = TextView(this).apply {
        tag = "b:wl"
        text = "✓"; setTextColor(fg); textSize = 12f; setTypeface(typeface, Typeface.BOLD)
        gravity = Gravity.CENTER
        background = GradientDrawable().apply { setColor(accent); shape = GradientDrawable.OVAL }
        layoutParams = FrameLayout.LayoutParams(dp(22), dp(22), Gravity.TOP or Gravity.END).apply { setMargins(0, dp(6), dp(6), 0) }
    }

    // topDp lets the caller drop the watched ✓ below a "+N new episodes" badge (they share the
    // top-left corner) so a watched show with new episodes shows BOTH, not just the check. (AJ Sep 15)
    private fun doneBadge(topDp: Int = 6) = TextView(this).apply {
        tag = "b:done"
        text = "✓"; textSize = 11f; setTextColor(fg); setTypeface(typeface, Typeface.BOLD)
        background = GradientDrawable().apply {
            setColor(Color.parseColor("#CC000000")); cornerRadius = dp(11).toFloat()
            setStroke(dp(1), Color.parseColor("#F5C518"))
        }
        setPadding(dp(5), dp(2), dp(5), dp(2))
        layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.START).apply { setMargins(dp(6), dp(topDp), 0, 0) }
    }

    /** Add/mark must JUST flip the check on the poster — no page rebuild (AJ: the rebuild
     *  was the blink + lost-spot). Repaints the badges on every on-screen tile of [id]. */
    private fun repaintTiles(id: String) {
        if (!::root.isInitialized) return
        val inList = Store.inWatchlist(this, id)
        val done = Store.isWatched(this, id)
        val hasBar = Store.cwProgress(this, id)?.let { it in 2..97 } == true
        fun walk(vg: android.view.ViewGroup) {
            for (i in 0 until vg.childCount) {
                val c = vg.getChildAt(i)
                if (c is FrameLayout && c.tag == "tile:$id") {
                    var hasNew = false
                    for (j in c.childCount - 1 downTo 0) {
                        val b = c.getChildAt(j)
                        when (b.tag) {
                            "b:new" -> hasNew = true               // keep it; just note it's there
                            "b:wl", "b:done" -> c.removeViewAt(j)
                            "b:bar" -> if (!hasBar) c.removeViewAt(j)
                        }
                    }
                    if (inList) c.addView(wlBadge())
                    if (done) c.addView(doneBadge(if (hasNew) 34 else 6))
                } else if (c is android.view.ViewGroup) walk(c)
            }
        }
        walk(root)
    }

    /** Pull one title's tile out of its row live (Library remove, CW remove) — the cursor
     *  hops to a neighbor first so focus never falls off the page. First match only: on
     *  Home that's the Continue Watching row (built first); catalog rows keep their copy. */
    private fun removeTileInPlace(id: String): Boolean {
        if (!::root.isInitialized) return false
        var removed = false
        fun hunt(vg: android.view.ViewGroup) {
            for (i in 0 until vg.childCount) {
                if (removed) return
                val c = vg.getChildAt(i)
                if (c is FrameLayout && c.tag == "tile:$id") {
                    // climb to the strip's direct child (the cell may wrap art + name)
                    var cell: View = c
                    while (true) {
                        val p = cell.parent as? android.view.ViewGroup ?: return
                        if (p is LinearLayout && p.parent is HorizontalScrollView) break
                        cell = p
                    }
                    val strip = cell.parent as LinearLayout
                    val at = strip.indexOfChild(cell)
                    if (cell.findFocus() != null)
                        (focusableOf(strip.getChildAt(if (at + 1 < strip.childCount) at + 1 else at - 1))
                            ?: railSelectedView)?.requestFocus()
                    strip.removeView(cell)
                    if (strip.childCount > 0) pinRowEnds(strip)
                    else {
                        // last tile of the row: drop the empty strip and its label with it
                        val hsv = strip.parent as View
                        (hsv.parent as? LinearLayout)?.let { rowP ->
                            val ri = rowP.indexOfChild(hsv)
                            rowP.removeView(hsv)
                            if (ri > 0 && rowP.getChildAt(ri - 1) is TextView) rowP.removeViewAt(ri - 1)
                        }
                    }
                    removed = true
                    return
                }
                if (c is android.view.ViewGroup) hunt(c)
            }
        }
        hunt(root)
        return removed
    }

    // deliberate-navigation tracking: the delayed focus grabbers exist ONLY to place the
    // INITIAL cursor — once the user has pressed any key on this page, they must never
    // steal focus (they were yanking the cursor off the nav rail back into the content)
    private var lastUserKeyAt = 0L
    private var pageShownAt = 0L
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (event.action == android.view.KeyEvent.ACTION_DOWN) lastUserKeyAt = System.currentTimeMillis()
        return super.dispatchKeyEvent(event)
    }
    private fun userNavigatedSincePageShown() = lastUserKeyAt > pageShownAt

    /** True when [v] sits anywhere under [parent] in the view tree. */
    private fun isDescendantOf(v: View?, parent: View): Boolean {
        var c: Any? = v
        while (c is View) { if (c === parent) return true; c = c.parent }
        return false
    }

    private fun collectRows(vg: android.view.ViewGroup, out: ArrayList<HorizontalScrollView>) {
        for (i in 0 until vg.childCount) {
            val c = vg.getChildAt(i)
            if (c is HorizontalScrollView) out.add(c)
            else if (c is android.view.ViewGroup) collectRows(c, out)
        }
    }

    // ---- art virtualization: how Netflix/Stremio stay smooth on weak hardware. Tiles
    // only HOLD a bitmap while their row is within a screen of the viewport (and the tile
    // within a half-screen horizontally); scrolled far away, the bitmap is dropped — the
    // disk cache brings it back instantly on return. Without this, a full board pinned
    // ~900 decoded posters in ImageViews (memoryCache.clear() can't free those), and Fire
    // OS memory-killed the app mid-scroll.
    private var artPass: Runnable? = null
    private var lastArtPassAt = 0L
    // rows whose art was already dropped while far offscreen — sweep each ONCE, not
    // on every 120ms pass (that re-walk grew linear with the shelf count = scroll jank)
    private val artSweptRows = java.util.WeakHashMap<View, Boolean>()
    private fun scheduleArtPass() {
        if (!::root.isInitialized) return
        // THROTTLE, not debounce: the old 90ms-after-last-scroll-event version meant art
        // only ever loaded once you STOPPED scrolling ("gotta keep waiting for images") —
        // Netflix fills tiles mid-scroll. Run immediately when the last pass is stale,
        // else leave exactly one trailing pass scheduled.
        val now = System.currentTimeMillis()
        if (now - lastArtPassAt > 120) {
            artPass?.let { root.removeCallbacks(it) }; artPass = null
            lastArtPassAt = now; artPassNow(); return
        }
        if (artPass != null) return
        val r = Runnable { artPass = null; lastArtPassAt = System.currentTimeMillis(); artPassNow() }
        artPass = r; root.postDelayed(r, 120)
    }

    /** The vertical scroller currently on screen — the board when it's up, else whatever
     *  page (search, library, cast) is showing. Lazy tiles outside any scroller can't
     *  exist: every page that builds rows lives in one. */
    private fun artScroller(): ScrollView? {
        homeScroll?.takeIf { it.isAttachedToWindow }?.let { return it }
        fun find(v: View): ScrollView? {
            if (v is ScrollView) return v
            if (v is android.view.ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i))?.let { return it }
            return null
        }
        return if (::root.isInitialized) find(root) else null
    }

    private fun artPassNow(aggressive: Boolean = false) {
        val sc = artScroller() ?: return
        val content = sc.getChildAt(0) as? android.view.ViewGroup ?: return
        val h = sc.height; if (h == 0) { scheduleArtPass(); return }
        val top = sc.scrollY
        fun yIn(v: View): Int {
            var y = 0; var c: View? = v
            while (c != null && c !== sc) { y += c.top; c = c.parent as? View }
            return y
        }
        val rows = ArrayList<HorizontalScrollView>(); collectRows(content, rows)
        for (hsv in rows) {
            val strip = hsv.getChildAt(0) as? android.view.ViewGroup ?: continue
            val y = yIn(hsv)
            // hysteresis: load within ±1 screen, but only RELEASE beyond ±2.5 screens —
            // when load-band == drop-band a row died the instant it left the band and had
            // to re-decode on the way back (the pop-in AJ compares to Netflix). The wider
            // corridor of small posters is a few MB — nowhere near the ~900-poster cliff.
            val keep = if (aggressive) 0 else h
            val drop = if (aggressive) 0 else h * 5 / 2
            val near = y + hsv.height > top - keep && y < top + h + keep
            if (!near) {
                if ((y + hsv.height < top - drop || y > top + h + drop) && artSweptRows[strip] != true) {
                    eachArt(strip) { dropArt(it) }
                    artSweptRows[strip] = true
                }
                continue
            }
            artSweptRows[strip] = false
            val sx = hsv.scrollX; val w = hsv.width.coerceAtLeast(1)
            for (i in 0 until strip.childCount) {
                val item = strip.getChildAt(i)
                // load a FULL screen past each edge (was half): d-pad reveals land on
                // already-loaded art; drop band widened to match so edges don't thrash
                val vis = item.right > sx - w && item.left < sx + w * 2
                eachArt(item) { iv -> if (vis) loadArt(iv) else if (item.right < sx - w * 2 || item.left > sx + w * 3) dropArt(iv) }
            }
        }
    }

    /** Tile ImageViews carry their poster URL in the tag — that's the marker. */
    private fun eachArt(v: View, f: (ImageView) -> Unit) {
        if (v is ImageView) { if ((v.tag as? String)?.startsWith("http") == true) f(v); return }
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) eachArt(v.getChildAt(i), f)
    }

    /** Stremio's real smoothness trick on sticks: TILE-sized images, not full posters.
     *  A 112dp tile needs ~200px — metahub "small" / TMDB w342 cut the bytes AND the
     *  decode work 4-10x vs medium/w500+. TV only: phone tiles are bigger + hi-dpi. */
    private fun tileArtUrl(u: String): String {
        if (!isTv) return u
        return u.replace("/poster/medium/", "/poster/small/")
            .replace("/poster/large/", "/poster/small/")
            .replace(Regex("image\\.tmdb\\.org/t/p/w(500|780|1280|original)"), "image.tmdb.org/t/p/w342")
    }

    private fun loadArt(iv: ImageView) {
        if (iv.drawable != null) return
        // back to the simple load (AJ Sep 18: the size/hardware override made pictures slow)
        (iv.tag as? String)?.let { iv.load(tileArtUrl(it)) }
    }

    private fun dropArt(iv: ImageView) {
        if (iv.drawable == null) return
        iv.dispose(); iv.setImageDrawable(null)
    }

    private fun saveRowFocus(from: View? = null) {
        savedRowIdx = -1; savedItemIdx = -1; savedItemId = null
        val sv = homeScroll ?: return
        var item: View? = from ?: currentFocus ?: return
        while (item != null) {
            val p = item.parent as? View
            if (p?.parent is HorizontalScrollView) break
            item = p
        }
        // the exact title on the tile the cursor was on — restoring BY ID lands on the same
        // show even if a row (Continue Watching, New Episodes) appeared/vanished on rebuild and
        // shifted every index below it. Index is kept only as a fallback.
        savedItemId = (item?.tag as? String)?.takeIf { it.startsWith("tile:") }?.substring(5)
        val strip = item?.parent as? LinearLayout ?: return
        val hsv = strip.parent as? HorizontalScrollView ?: return
        val rows = ArrayList<HorizontalScrollView>(); collectRows(sv, rows)
        savedRowIdx = rows.indexOf(hsv)
        savedItemIdx = strip.indexOfChild(item)
    }

    /** Find the on-screen tile for a title id (matches the "tile:<id>" tag repaintTiles uses). */
    private fun findTileById(vg: android.view.ViewGroup, id: String): View? {
        for (i in 0 until vg.childCount) {
            val c = vg.getChildAt(i)
            if (c.tag == "tile:$id") return c
            if (c is android.view.ViewGroup) findTileById(c, id)?.let { return it }
        }
        return null
    }

    private fun restoreRowFocus(content: android.view.ViewGroup): Boolean {
        // by id first (survives row reorder), then by remembered row+item index
        savedItemId?.let { id ->
            findTileById(content, id)?.let { tile ->
                if (focusableOf(tile)?.requestFocus() == true) return true
            }
        }
        if (savedRowIdx < 0) return false
        val rows = ArrayList<HorizontalScrollView>(); collectRows(content, rows)
        val strip = rows.getOrNull(savedRowIdx)?.getChildAt(0) as? android.view.ViewGroup ?: return false
        if (strip.childCount == 0) return false
        val f = focusableOf(strip.getChildAt(savedItemIdx.coerceIn(0, strip.childCount - 1))) ?: return false
        return f.requestFocus()
    }

    @Deprecated("platform back")
    override fun onBackPressed() {
        when {
            navStack.isNotEmpty() -> { pendingContentFocus = true; poppingBack = true; restoreFocusAfterBack = true; navStack.removeLast().invoke() }
            // BACK out of Live TV returns to the tab you opened it from (with the tile you left
            // re-focused), not a hard jump to Home that sometimes rendered blank (AJ Sep 26).
            tab == "Live TV" && Store.onboarded(this) -> {
                // return to the tab we came from; Home restores its own saved row/scroll (see
                // showMain), other tabs grab their first tile — either way never a blank screen.
                val back = liveTvReturnTab?.takeIf { it != "Live TV" } ?: "Home"
                liveTvReturnTab = null
                pendingContentFocus = true; showMain(back)
            }
            tab != "Home" && Store.onboarded(this) -> { pendingContentFocus = true; showMain("Home") }
            // Home: first BACK opens the menu (rail takes the cursor), second BACK leaves
            isTv && !railHasFocus() && railRef != null ->
                (railSelectedView?.takeIf { it.isAttachedToWindow }
                    ?: (railRef as? android.view.ViewGroup)?.let { focusableOf(it) })?.requestFocus()
            else -> @Suppress("DEPRECATION") super.onBackPressed()
        }
    }
    private var heroNarrate: ((Title) -> Unit)? = null

    /** The Stremio TV board surface: full-screen backdrop of the focused title, gradient
     *  scrims, info text top-left, and the rows ScrollView layered over the lower half. */
    private fun buildTvBoard(sv: ScrollView, topMargin: Int = dp(232), showText: Boolean = true): View {
        // clipChildren must stay TRUE here: Android clips a ScrollView's scrolled-away
        // content at its bounds via the PARENT's clipChildren flag — with it false, rows
        // scrolled above the board line keep drawing over the info art/description
        // (the persistent "previous row showing over what I'm on" bug; sv.clipChildren
        // on the ScrollView itself never had any effect on this)
        val surface = FrameLayout(this).apply { setBackgroundColor(bg) }
        val art = ImageView(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            scaleType = ImageView.ScaleType.CENTER_CROP
        }
        surface.addView(art)
        surface.addView(View(this).apply {   // readable left side + grounded bottom
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            background = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor("#E60C0B14"), Color.parseColor("#990C0B14"), Color.parseColor("#330C0B14")))
        })
        surface.addView(View(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(bg, Color.parseColor("#B30C0B14"), Color.TRANSPARENT, Color.TRANSPARENT))
        })
        val infoCol = column().apply {
            layoutParams = FrameLayout.LayoutParams(dp(470), WRAP_CONTENT).apply { setMargins(dp(24), dp(20), 0, 0) }
        }
        val nameV = TextView(this).apply {
            setTextColor(fg); textSize = 30f; setTypeface(typeface, Typeface.BOLD); maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val factsV = TextView(this).apply { setTextColor(fg); textSize = 13f; setPadding(0, dp(4), 0, 0) }
        val descV = TextView(this).apply {
            setTextColor(Color.parseColor("#D8D5E6")); textSize = 13f; maxLines = 4
            ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(5), 0, 0)
            setLineSpacing(0f, 1.2f)
        }
        // actors under the description while browsing (AJ) — one quiet line, no chips;
        // the clickable cast strip lives on the detail page
        val castV = TextView(this).apply {
            setTextColor(Color.parseColor("#9A94B8")); textSize = 12.5f; maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(4), 0, 0)
            visibility = View.GONE
        }
        val logoV = ImageView(this).apply {
            adjustViewBounds = true; visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, dp(64))
        }
        infoCol.addView(logoV); infoCol.addView(nameV); infoCol.addView(factsV); infoCol.addView(descV)
        infoCol.addView(castV)
        // rows FIRST, info LAST in z-order: anything that leaks upward slides UNDER the
        // info scrim instead of covering the text/art (Stremio's layering)
        surface.addView(sv, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            .apply { setMargins(0, topMargin, 0, 0) })
        if (!showText) { nameV.visibility = View.GONE; factsV.visibility = View.GONE; descV.visibility = View.GONE; castV.visibility = View.GONE }
        surface.addView(View(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, dp(236))
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(Color.parseColor("#D90C0B14"), Color.parseColor("#8C0C0B14"), Color.TRANSPARENT))
        })
        surface.addView(infoCol)
        var seq = 0
        // decode the board backdrop at 720p, not screen size: metahub "medium" IS ~720p,
        // so full-screen buffers were upscale waste — this is per-focus-step work
        val artW = resources.displayMetrics.widthPixels * 2 / 3
        val artH = resources.displayMetrics.heightPixels * 2 / 3
        // neighbor warmer (see focus handler): backdrop at the SAME size as setArt so
        // the cache key matches; meta fetch fills Discovery's cache so the info panel's
        // instant path (hit != null) fires when the cursor arrives
        tvArtPrefetch = { t ->
            val ptt = t.id.substringBefore(":")
            if (ptt.startsWith("tt")) coil.Coil.imageLoader(this).enqueue(
                coil.request.ImageRequest.Builder(this)
                    .data("https://images.metahub.space/background/medium/$ptt/img")
                    .size(artW, artH).build())
            if (Discovery.metaCached(t.type, t.id) == null) scope.launch { Discovery.meta(t.type, t.id) }
        }
        var artJob: Runnable? = null
        tvInfoUpdate = { t ->
            val my = ++seq
            // custom targets, NOT ImageView loads: the view keeps its current backdrop
            // until the NEW image is fully ready, then swaps once. (v0.73 tried
            // placeholder(art.drawable) for this — that nests every previous backdrop
            // inside the next as a crossfade layer, a chain that grew per focus until the
            // board froze on one image and Fire OS memory-killed the app.)
            fun setArt(url: String) {
                coil.Coil.imageLoader(this).enqueue(coil.request.ImageRequest.Builder(this)
                    .data(url).size(artW, artH)
                    .target(
                        onSuccess = { d -> if (my == seq) {
                            art.setImageDrawable(d)
                            art.animate().alpha(1f).setDuration(180).start()
                        } },
                        // no art for this one: brighten the old backdrop back up rather
                        // than leaving it stuck half-dimmed
                        onError = { if (my == seq) art.animate().alpha(1f).setDuration(180).start() })
                    .build())
            }
            fun applyText(mm: Meta) {
                factsV.text = listOfNotNull(
                    mm.year.ifBlank { null }, mm.runtime.ifBlank { null },
                    mm.imdbRating.ifBlank { null }?.let { "★ $it" },
                    mm.genres.take(3).joinToString(" · ").ifBlank { null }).joinToString("   ")
                descV.text = mm.description
                if (showText && mm.cast.isNotEmpty()) {
                    castV.text = "Cast: " + mm.cast.take(4).joinToString(", ")
                    castV.visibility = View.VISIBLE
                } else castV.visibility = View.GONE
            }
            // BROWSING IS TEXT-ONLY — Stremio's own trick: the board title is always plain
            // text, the fancy logo lives on the page you click INTO. Swapping text→logo on
            // every focus was the per-tile "blink" (and a logo download per d-pad step).
            nameV.text = t.name; nameV.visibility = View.VISIBLE; logoV.visibility = View.GONE
            // description shows the INSTANT you land: rows carry it from the catalog
            // (t.desc); cached meta upgrades it with facts, the fetch below fills the rest
            val hit = Discovery.metaCached(t.type, t.id)
            if (hit != null) applyText(hit) else { factsV.text = ""; descV.text = t.desc ?: ""; castV.visibility = View.GONE }
            // the old backdrop RECEDES immediately (never pops mid-read), the new one
            // fades up when ready — trailing smoothly is fine, jump-cutting isn't (AJ)
            if (art.drawable != null) art.animate().alpha(0.45f).setDuration(120).start()
            // STREMIO'S SPEED TRICK: backdrop + logo URLs derive straight from the IMDb id
            // (metahub — Stremio's own art CDN), so they start downloading IMMEDIATELY
            // instead of after a meta round-trip. size() bounds every decode to the screen,
            // and a short debounce means skimming rows only repaints text — art loads the
            // moment the cursor rests.
            val tt = t.id.substringBefore(":")
            artJob?.let { art.removeCallbacks(it) }
            val job = Runnable {
                if (my != seq) return@Runnable
                if (tt.startsWith("tt")) {
                    setArt("https://images.metahub.space/background/medium/$tt/img")
                } else if (art.drawable == null) t.poster?.let { setArt(it) }
                // meta fills the text + covers titles metahub has no art/logo for
                scope.launch {
                    Discovery.meta(t.type, t.id)?.let { mm ->
                        if (my != seq) return@let
                        applyText(mm)
                        (mm.background ?: mm.poster)?.let { u ->
                            if (!u.contains("metahub.space")) setArt(u) }
                    }
                }
            }
            artJob = job
            if (hit != null) job.run() else art.postDelayed(job, 160)
        }
        return surface
    }

    /** Y of a view inside the home ScrollView's content — for row-at-a-time alignment. */
    private fun yInHomeScroll(v: View): Int {
        val sv = homeScroll ?: return 0
        var y = 0; var c: View? = v
        while (c != null && c !== sv) { y += c.top; c = c.parent as? View }
        return y
    }

    private var railRef: View? = null
    private var firstContentFocus: View? = null
    private var railSelectedId = View.NO_ID
    private var railSelectedView: View? = null
    private fun railHasFocus(): Boolean = railRef?.findFocus() != null

    /** The focusable view inside a row cell — poster art may be wrapped in a title column. */
    private fun focusableOf(v: View?): View? {
        if (v == null) return null
        if (v.isFocusable) return v
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) focusableOf(v.getChildAt(i))?.let { return it }
        return null
    }

    /** End of a row must NOT dump focus into the next row (guard the real focusable). */
    private fun pinRowEnds(strip: LinearLayout) {
        focusableOf(strip.getChildAt(strip.childCount - 1))?.let { last ->
            if (last.id == View.NO_ID) last.id = View.generateViewId()
            last.nextFocusRightId = last.id
        }
        focusableOf(strip.getChildAt(0))?.let { first ->
            if (first.id == View.NO_ID) first.id = View.generateViewId()
            first.nextFocusLeftId = first.id   // never jump to another row
            // …but on TV, LEFT at the very edge opens the menu on the CURRENT tab (Stremio)
            if (isTv) first.setOnKeyListener { _, kc, ev ->
                if (kc == android.view.KeyEvent.KEYCODE_DPAD_LEFT && ev.action == android.view.KeyEvent.ACTION_DOWN) {
                    railSelectedView?.takeIf { it.isAttachedToWindow }?.requestFocus() != null
                } else false
            }
        }
    }
    private val lastSeasonViewed = HashMap<String, Int>()

    /** The user's CURRENT episode on a show — the cwLast pointer (the last-touched
     *  UNFINISHED episode; the exact id Continue Watching resumes). If that episode was
     *  since marked watched, step to the next unwatched AIRED one so the page opens where
     *  they'd actually pick up. Null = movie / un-started show / stale pointer. */
    private fun currentEpisode(m: Meta): Episode? {
        val sid = Store.cwLast(this, m.id) ?: return null
        val eps = m.videos.filter { it.season > 0 }
            .sortedWith(compareBy({ it.season }, { it.episode }))
        val at = eps.firstOrNull { it.id == sid } ?: return null
        if (!Store.isWatched(this, at.id)) return at
        return eps.firstOrNull {
            (it.season > at.season || (it.season == at.season && it.episode > at.episode)) &&
                it.aired && !Store.isWatched(this, it.id)
        } ?: at
    }

    /** Hero pager: auto-rotates every ~9s AND scrolls by hand — ‹ › arrows over the art
     *  (d-pad + tap friendly). A manual flip resets the auto timer; swapping tabs detaches
     *  the holder, which naturally ends the rotation (no timers to clean up). */
    private fun buildHeroPager(holder: FrameLayout, items: List<Title>) {
        if (items.isEmpty()) return
        var idx = 0
        var lastFlip = System.currentTimeMillis()
        fun arrow(sym: String, step: Int, grav: Int, show: (Int) -> Unit) = TextView(this).apply {
            text = sym; setTextColor(fg); textSize = 30f; gravity = Gravity.CENTER
            background = selBg(Color.parseColor("#33000000"), 24)
            layoutParams = FrameLayout.LayoutParams(dp(46), dp(46), grav or Gravity.CENTER_VERTICAL)
                .apply { setMargins(dp(8), 0, dp(8), 0) }
            isClickable = true; isFocusable = true
            tag = "arrow$step"
            setOnClickListener {
                val side = step
                show(idx + step)
                // rebuild destroyed this button — focus its replacement IN THE HOLDER (the
                // old it.parent is already detached, which is why focus fell to the rail)
                holder.post { holder.findViewWithTag<View>("arrow$side")?.requestFocus() }
            }
        }
        lateinit var show: (Int) -> Unit
        val swipe = android.view.GestureDetector(this,
            object : android.view.GestureDetector.SimpleOnGestureListener() {
                override fun onFling(e1: android.view.MotionEvent?, e2: android.view.MotionEvent,
                                     vx: Float, vy: Float): Boolean {
                    if (kotlin.math.abs(vx) < kotlin.math.abs(vy) || kotlin.math.abs(vx) < 800) return false
                    heroFlip?.invoke(if (vx < 0) 1 else -1)
                    return true
                }
            })
        show = { i ->
            idx = ((i % items.size) + items.size) % items.size
            lastFlip = System.currentTimeMillis()
            buildHero(holder, items[idx], idx, items.size)
            if (items.size > 1) {
                heroFlip = { d -> show(idx + d) }
                if (isTv) {   // d-pad needs a focus target; touch just swipes the art
                    holder.addView(arrow("‹", -1, Gravity.START, show))
                    holder.addView(arrow("›", +1, Gravity.END, show))
                }
                holder.addView(View(this).apply {
                    layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, dp(390))
                    isClickable = true   // must consume DOWN or the gesture never reaches us
                    var downX = 0f; var downY = 0f
                    setOnTouchListener { v, ev ->
                        when (ev.actionMasked) {
                            android.view.MotionEvent.ACTION_DOWN -> { downX = ev.x; downY = ev.y }
                            android.view.MotionEvent.ACTION_MOVE ->
                                if (kotlin.math.abs(ev.x - downX) > kotlin.math.abs(ev.y - downY) * 1.5f)
                                    v.parent.requestDisallowInterceptTouchEvent(true)
                            else -> {}
                        }
                        swipe.onTouchEvent(ev); true
                    }
                }, 1)   // above the art, below the scrim/overlay — buttons stay clickable
            }
        }
        show(0)
        // browsing rows: the focused title takes over the hero (no arrows/dots), and the
        // auto-rotation stands down while the person is actively looking around
        heroNarrate = { t ->
            lastFlip = System.currentTimeMillis() + 20_000   // hold rotation while browsing
            buildHero(holder, t, 0, 1)
        }
        if (items.size > 1) {
            lateinit var tick: Runnable
            tick = Runnable {
                if (!holder.isAttachedToWindow) return@Runnable
                // don't auto-flip out from under someone who just paged by hand
                if (System.currentTimeMillis() - lastFlip >= 8_500 && !holder.hasFocus()) show(idx + 1)
                holder.postDelayed(tick, 3_000)
            }
            holder.postDelayed(tick, 9_000)
        }
    }

    private fun whitePill(t: String, onClick: () -> Unit) = Button(this).apply {
        text = t; setTextColor(Color.BLACK); isAllCaps = false; setTypeface(typeface, Typeface.BOLD)
        background = rounded(Color.WHITE, dp(24)); setPadding(dp(22), dp(10), dp(22), dp(10))
        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(6), dp(10), dp(6)) }
        stateListAnimator = null; setOnClickListener { onClick() }
    }

    // ---------- detail (Stremio-style: full backdrop + scrim, title/facts/summary/cast) ----------
    private fun showDetail(t: Title) {
        // back lands where you left, not the top — Home keeps its sticky slot; the other
        // tabs (Library/Discover/Search) ride the one-shot restore for the same feel
        homeScroll?.takeIf { it.isAttachedToWindow }?.let {
            if (tab == "Home") homeScrollY = it.scrollY else pendingScrollY = it.scrollY
        }
        if (isTv) saveRowFocus()                       // …and on the very tile you left
        lastTitle = t
        pushPage { showDetail(t) }
        if (isTv) { showDetailTv(t); return }
        val page = FrameLayout(this).apply { setBackgroundColor(bg) }
        val back = ImageView(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            scaleType = ImageView.ScaleType.CENTER_CROP
        }
        page.addView(back)
        page.addView(View(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(bg, Color.parseColor("#E60B0B0F"), Color.parseColor("#8C0B0B0F")))
        })
        val body = column().apply { setPadding(dp(20), dp(56), dp(20), dp(30)) }
        page.addView(ScrollView(this).apply { addView(body); isFillViewport = true; isVerticalScrollBarEnabled = false })
        page.addView(iconBtn("‹") { onBackPressed() }.apply {
            // mobile: sit BELOW the status bar/notch, not under it
            layoutParams = FrameLayout.LayoutParams(dp(44), dp(44))
                .apply { setMargins(dp(12), if (isTv) dp(12) else statusBarPad(), 0, 0) }
        })
        swap(page)
        scope.launch {
            val m = Discovery.meta(t.type, t.id) ?: run { body.addView(dimText("Couldn't load details.")); return@launch }
            dismissNewEpsBadge(t, m)
            (m.background ?: m.poster)?.let { back.load(it) }
            // the show's LOGO instead of plain text when it has one (parity with the TV pages)
            if (m.logo != null) body.addView(ImageView(this@MainActivity).apply {
                adjustViewBounds = true
                layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, dp(76))
                load(m.logo)
            })
            else body.addView(TextView(this@MainActivity).apply {
                text = m.name; setTextColor(fg); textSize = 32f; setTypeface(typeface, Typeface.BOLD)
            })
            val facts = listOfNotNull(
                m.year.ifBlank { null }, m.runtime.ifBlank { null },
                m.imdbRating.ifBlank { null }?.let { "★ $it" },
            ).joinToString("   ")
            if (facts.isNotBlank()) body.addView(TextView(this@MainActivity).apply {
                text = facts; setTextColor(fg); textSize = 15f; setPadding(0, dp(6), 0, 0)
            })
            // genres are DOORWAYS, not decoration (AJ, Stremio photo 10): tap Horror →
            // Discover already filtered to Horror in this title's type
            if (m.genres.isNotEmpty()) {
                val gstrip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                for (g in m.genres.take(4)) gstrip.addView(personChip(g).apply {
                    setOnClickListener {
                        discType = if (t.type == "series") "series" else "movie"
                        discGenre = g; discCatIdx = 0
                        showMain("Discover")
                    }
                })
                body.addView(horizScroll(gstrip).apply { setPadding(0, dp(4), 0, 0) })
            }
            if (m.description.isNotBlank()) body.addView(TextView(this@MainActivity).apply {
                text = m.description; setTextColor(Color.parseColor("#E5E5E5")); setPadding(0, dp(6), 0, dp(4))
                textSize = 14.5f; setLineSpacing(0f, 1.15f); maxLines = 4
                ellipsize = android.text.TextUtils.TruncateAt.END
            })
            // Stremio-style action ICONS (monochrome circles); the label beside them narrates
            // whichever one you're hovering — "Trailer", "Add to Library", "Mark as watched"
            val actions = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(10), 0, dp(6))
            }
            val actionLabel = TextView(this@MainActivity).apply {
                setTextColor(dim); textSize = 13.5f; setPadding(dp(10), 0, 0, 0)
            }
            // REAL icons, not text glyphs — same visual language as the TV pages and the
            // title menu (AJ): clapper / library tray / eye, in monochrome circles
            fun iconAction(resOf: () -> Int, labelOf: () -> String, onClick: () -> Unit): View {
                lateinit var v: ImageView
                v = ImageView(this@MainActivity).apply {
                    setImageResource(resOf()); setColorFilter(fg)
                    scaleType = ImageView.ScaleType.CENTER
                    background = selBg(Color.parseColor("#2C2649"), 24)
                    layoutParams = LinearLayout.LayoutParams(dp(46), dp(46)).apply { setMargins(0, 0, dp(10), 0) }
                    isClickable = true; isFocusable = true
                    setOnClickListener { onClick(); v.setImageResource(resOf()); actionLabel.text = labelOf() }
                    setOnFocusChangeListener { _, has -> if (has) actionLabel.text = labelOf() }
                }
                return v
            }
            if (m.trailerYoutubeId != null)
                actions.addView(iconAction({ R.drawable.ic_trailer }, { "Trailer" }) { playTrailer(m.trailerYoutubeId, m.name) })
            actions.addView(iconAction(
                { if (Store.inWatchlist(this@MainActivity, t.id)) R.drawable.ic_lib_remove else R.drawable.ic_lib_add },
                { if (Store.inWatchlist(this@MainActivity, t.id)) "Remove from Library" else "Add to Library" }) {
                Store.toggleWatchlist(this@MainActivity, t); pushState()
            })
            // whole-show "mark watched" makes no sense on an EPISODE LIST (AJ) — movies only
            if (m.type != "series") actions.addView(iconAction(
                { if (Store.isWatched(this@MainActivity, t.id)) R.drawable.ic_eye else R.drawable.ic_eye_off },
                { if (Store.isWatched(this@MainActivity, t.id)) "Marked as watched" else "Mark as watched" }) {
                Store.toggleWatchedTitle(this@MainActivity, Title(m.id, m.type, m.name, m.poster)); pushState()
            })
            // THUMBS (AJ Sep 25): per-profile, syncs everywhere, shapes For You — up boosts
            // more-like-this, down hides it from For You for good. Both types, beside the eye.
            run {
                var upV: ImageView? = null; var downV: ImageView? = null
                val upRes = { if (Store.rating(this@MainActivity, t.id) == 1) R.drawable.ic_thumb_up_on else R.drawable.ic_thumb_up }
                val downRes = { if (Store.rating(this@MainActivity, t.id) == -1) R.drawable.ic_thumb_down_on else R.drawable.ic_thumb_down }
                upV = iconAction(upRes,
                    { if (Store.rating(this@MainActivity, t.id) == 1) "Liked — For You shows more like this" else "Thumbs up" }) {
                    Store.setRating(this@MainActivity, t.id, if (Store.rating(this@MainActivity, t.id) == 1) 0 else 1); pushState()
                    downV?.setImageResource(downRes())
                } as ImageView
                downV = iconAction(downRes,
                    { if (Store.rating(this@MainActivity, t.id) == -1) "Not for me — hidden from For You" else "Thumbs down" }) {
                    Store.setRating(this@MainActivity, t.id, if (Store.rating(this@MainActivity, t.id) == -1) 0 else -1); pushState()
                    upV?.setImageResource(upRes())
                } as ImageView
                actions.addView(upV); actions.addView(downV)
            }
            // ⬇ OFFLINE DOWNLOAD (full flavor, phones only) for MOVIES — series get theirs
            // on the episode rows. 46dp to sit level with the icon actions beside it; store
            // builds compile against the stub (ENABLED=false) and this whole branch is dead
            if (Downloads.ENABLED && !isTv && m.type != "series" && Store.addons(this@MainActivity).isNotEmpty())
                actions.addView(Downloads.button(this@MainActivity, m.id, "movie", m.name,
                    null, 0, 0, m.poster, sizeDp = 46) { u -> Http.direct(withProfile(u)) })
            actions.addView(actionLabel)
            body.addView(actions)
            // CAST near the top (matches the TV layout, AJ) — right under the actions
            if (m.cast.isNotEmpty()) {
                body.addView(sectionText("Cast"))
                val strip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                for (n in m.cast.take(12)) strip.addView(personChip(n))
                body.addView(horizScroll(strip))
            }
            if (m.director.isNotEmpty()) {
                body.addView(sectionText("Director"))
                val strip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                for (n in m.director.take(4)) strip.addView(personChip(n))
                body.addView(horizScroll(strip))
            }
            // where to watch (guests / no addon): above the seasons so it's easy to find.
            // Filled async below; empty + hidden when the user has an addon.
            val provHolder = column()
            body.addView(provHolder)
            // SERIES: episodes after the info + cast (Stremio) — cursor lands on them
            if (m.type == "series" && m.videos.isNotEmpty()) buildEpisodes(body, m)
            // STREAMS APPEAR AUTOMATICALLY (Stremio behavior) — no Play press needed.
            if (m.type != "series" && Store.addons(this@MainActivity).isNotEmpty()) {
                body.addView(sectionText("Streams"))
                val (sScroll, sHolder) = streamStrip()
                val sNote = dimText("CouchKing — finding streams…")
                body.addView(sNote)
                body.addView(sScroll)
                scope.launch {
                    val streams = Addons.streams(Store.addons(this@MainActivity), m.type, m.id, profileSeg())
                    sHolder.removeAllViews()
                    sNote.visibility = View.GONE
                    // expired (from the server response OR cached) → banner, no streams
                    if (streams.any { it.expired } || isExpired()) { sHolder.addView(expiryBanner()); return@launch }
                    if (streams.isEmpty()) { sNote.visibility = View.VISIBLE; sNote.text = "No streams found right now — try again shortly."; return@launch }
                    for (st in streams) sHolder.addView(streamRowView(st) {
                        // Continue Watching means you PLAYED it — not that you looked at the page
                        Store.pushContinue(this@MainActivity, Title(m.id, m.type, m.name, m.poster))
                        Store.setCwLast(this@MainActivity, m.id, m.id)
                        PlayerActivity.launch(this@MainActivity, Http.direct(withProfile(st.url)), m.name, m.id,
                            poster = m.poster, titleId = m.id, type = m.type, subsJson = st.subsJson,
                            logo = m.logo)
                    })
                    sHolder.getChildAt(0)?.requestFocus()
                }
            }
            // where to watch: one tappable chip PER provider, deep-linked to that provider.
            // People with their own addon don't need rent/buy pointers — their streams ARE
            // the way to watch, so the whole section stays hidden for them.
            scope.launch {
                val p = Discovery.providers(m.id.substringBefore(":"), m.type)
                // recent movie nobody can stream/rent/buy yet = it's still IN THEATERS —
                // say so (everyone, addon or not) so "no streams" reads as expected, not broken.
                // Three modes: sideload = everything, clickable. PLAY = pre-Sep23 approved
                // behavior, rent/buy storefront links only. AMAZON = everything visible but
                // as plain labels (Links stub, no click-through) — the deep-link policy is
                // about links, not words.
                val rentBuyOnly = Dist.STORE && Links.PROVIDER_CLICKS
                if (p == null || (if (rentBuyOnly) (p.rent.isEmpty() && p.buy.isEmpty())
                                  else (p.stream.isEmpty() && p.rent.isEmpty() && p.buy.isEmpty()))) {
                    if (m.type != "series" && Store.addons(this@MainActivity).isEmpty() &&
                        (m.year.take(4).toIntOrNull() ?: 0) >= java.util.Calendar.getInstance().get(java.util.Calendar.YEAR) - 1)
                        provHolder.addView(TextView(this@MainActivity).apply {
                            text = "🎬 In theaters now — home release hasn't happened yet"
                            setTextColor(Color.parseColor("#F5C518")); textSize = 15f
                            setTypeface(typeface, Typeface.BOLD); setPadding(0, dp(12), 0, dp(4))
                        })
                    return@launch
                }
                if (Store.addons(this@MainActivity).isNotEmpty()) return@launch
                // THE call-to-action for guests/tracker users (AJ): big, obvious, unmissable —
                // this app's whole answer to "ok but where do I actually watch it?"
                provHolder.addView(TextView(this@MainActivity).apply {
                    text = if (rentBuyOnly) "▶ Where to rent or buy" else "▶ Where to watch"
                    setTextColor(fg); textSize = 20f
                    setTypeface(typeface, Typeface.BOLD); setPadding(0, dp(18), 0, dp(2))
                })
                provHolder.addView(dimText(if (rentBuyOnly) "Rent or buy this title from these stores:"
                                           else "Stream, rent, or buy from these services:"))
                val strip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                fun chip(label: String, prov: String, accented: Boolean) {
                    strip.addView(TextView(this@MainActivity).apply {
                        text = label; setTextColor(fg); textSize = 16f
                        setTypeface(typeface, Typeface.BOLD)
                        background = rounded(if (accented) accent else Color.parseColor("#2C2649"), dp(22))
                        setPadding(dp(20), dp(13), dp(20), dp(13))
                        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(6), dp(10), dp(8)) }
                        isClickable = Links.PROVIDER_CLICKS; isFocusable = Links.PROVIDER_CLICKS
                        if (Links.PROVIDER_CLICKS) setOnClickListener { openProvider(prov, m.name, p.link) }
                    })
                }
                if (!rentBuyOnly) p.stream.take(4).forEach { chip(it, it, accented = true) }
                p.rent.take(4).forEach { chip("Rent · $it", it, accented = rentBuyOnly) }
                p.buy.take(4).forEach { if (it !in p.rent) chip("Buy · $it", it, accented = false) }
                provHolder.addView(horizScroll(strip))
            }
        }
    }

    /** After a local clear, wipe the server resume (ckpos) AND push the tombstone so the OTHER
     *  device drops it too. Without this a clear on the TV never reached the phone. */
    private fun syncClear(imdbId: String) {
        Ck.clearServer(this, imdbId)
        pushState()
    }

    /** Push the whole account/profile state NOW so a Library add/remove or a watched toggle
     *  lands on every other device+profile immediately, not on the next periodic sync. The
     *  merge is tombstoned (addedTs/removedTs) so a remove sticks and never resurrects. */
    private fun pushState() {
        if (Store.signedIn(this)) scope.launch {
            try { Sync.push(this@MainActivity) } catch (_: Exception) {}
        }
    }

    private fun buildEpisodes(body: LinearLayout, m: Meta) {
        body.addView(sectionText("Episodes"))
        val canPlay = Store.addons(this).isNotEmpty()
        val seasons = m.videos.map { it.season }.filter { it > 0 }.distinct().sorted()
        // TV: horizontal cards you flip through; MOBILE: vertical rows with full names,
        // descriptions and air dates (yellow when not out yet)
        val epStrip = LinearLayout(this).apply {
            orientation = if (isTv) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
            clipChildren = false; clipToPadding = false
            if (isTv) setPadding(dp(4), dp(8), dp(4), dp(8))
        }
        val epScroll: View = if (isTv) HorizontalScrollView(this).apply {
            addView(epStrip); isHorizontalScrollBarEnabled = false
            clipChildren = false; clipToPadding = false
        } else epStrip
        // Stremio: the episode you're HOVERING narrates itself up here — name + synopsis
        val focusName = TextView(this).apply {
            setTextColor(fg); textSize = 15f; setTypeface(typeface, Typeface.BOLD)
            maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val focusDesc = TextView(this).apply {
            setTextColor(dim); textSize = 12.5f; maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(1), 0, dp(6))
        }
        lateinit var repaintChips: () -> Unit
        // open ON the user's current episode (cwLast rule) — not Season 1 (AJ Sep 11);
        // the in-session return (lastSeasonViewed) still wins so BACK lands where you were
        val cwEp = currentEpisode(m)
        var current = lastSeasonViewed[m.id]?.takeIf { it in seasons }
            ?: cwEp?.season?.takeIf { it in seasons } ?: seasons.firstOrNull() ?: 0
        fun epCard(ep: Episode): View {
            val watched = Store.isWatched(this, ep.id)
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                isClickable = true; isFocusable = true; isLongClickable = true
                layoutParams = LinearLayout.LayoutParams(dp(200), WRAP_CONTENT).apply { setMargins(dp(4), dp(2), dp(4), dp(2)) }
                setPadding(dp(2))
                setOnClickListener { if (canPlay) showEpisodeDetail(m, ep) else { Store.toggleWatched(this@MainActivity, ep.id); pushState(); repaintChips() } }
                setOnLongClickListener {
                    val w = Store.isWatched(this@MainActivity, ep.id)
                    val opts = listOf(if (w) "Mark as Unwatched" else "Mark as Watched", "Clear Episode Progress")
                    pickSheet("E${ep.episode} · ${ep.name}", opts, -1, icons = listOf(if (w) R.drawable.ic_eye_off else R.drawable.ic_eye, R.drawable.ic_undo)) { i ->
                        if (i == 0) { Store.toggleWatched(this@MainActivity, ep.id); pushState() }
                        else { Store.clearPos(this@MainActivity, ep.id); syncClear(m.id); toast("Progress cleared") }
                        epReturnTo = ep.episode   // repaint lands back on THIS episode, not the start
                        repaintChips()
                    }
                    true
                }
                setOnFocusChangeListener { v, has ->
                    v.animate().scaleX(if (has) 1.06f else 1f).scaleY(if (has) 1.06f else 1f).setDuration(110).start()
                    if (has) {
                        focusName.text = "S${ep.season} E${ep.episode} · ${ep.name}"
                        focusDesc.text = ep.description.ifBlank { ep.released ?: "" }
                    }
                }
            }
            card.addView(FrameLayout(this).apply {
                tag = "ep:${m.id}|${ep.id}"   // refreshEpisodeBars repaints these live on player exit
                layoutParams = LinearLayout.LayoutParams(dp(196), dp(110))
                background = rounded(Color.parseColor("#1B1830"), dp(8)); clipToOutline = true
                addView(ImageView(this@MainActivity).apply {
                    layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    loadEpThumb(this, this@MainActivity, ep.thumbnail, watched)
                })
                if (!ep.aired) addView(ImageView(this@MainActivity).apply {
                    setImageResource(R.drawable.ic_hourglass)
                    setColorFilter(fg)
                    background = GradientDrawable().apply { setColor(Color.parseColor("#B3000000")); shape = GradientDrawable.OVAL }
                    setPadding(dp(10), dp(10), dp(10), dp(10))
                    layoutParams = FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER)
                })
                if (watched) addView(TextView(this@MainActivity).apply {
                    text = "✓"; textSize = 11f; setTextColor(fg); setTypeface(typeface, Typeface.BOLD)
                    background = GradientDrawable().apply {
                        setColor(Color.parseColor("#CC000000")); cornerRadius = dp(9).toFloat()
                        setStroke(dp(1), Color.parseColor("#F5C518"))
                    }
                    setPadding(dp(5), dp(1), dp(5), dp(1))
                    layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.END)
                        .apply { setMargins(0, dp(5), dp(5), 0) }
                })
                                run {   // AJ Sep 13: watched = FULL purple bar; any progress (1s+) = percent bar
                    val barPct = if (watched) 100
                        else Store.pos(this@MainActivity, ep.id)?.let { (pos, dur) ->
                            if (dur > 0 && pos > 1_000) (100 * pos / dur).toInt() else null } ?: -1
                    if (barPct >= 0) {
                        addView(View(this@MainActivity).apply {
                            tag = "epbar"
                            setBackgroundColor(Color.parseColor("#66000000"))
                            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, dp(4), Gravity.BOTTOM)
                        })
                        addView(View(this@MainActivity).apply {
                            tag = "epbar"
                            setBackgroundColor(accent)
                            layoutParams = FrameLayout.LayoutParams(maxOf(dp(6), dp(196) * barPct / 100), dp(4), Gravity.BOTTOM or Gravity.START)
                        })
                    }
                }
            })
            card.addView(TextView(this).apply {
                text = "${ep.episode}. ${ep.name}"
                setTextColor(if (watched) dim else fg); textSize = 13.5f; maxLines = 1
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                ellipsize = android.text.TextUtils.TruncateAt.END
                setPadding(dp(2), dp(5), dp(2), 0)
            })
            ep.released?.let { rel ->
                card.addView(TextView(this).apply {
                    text = rel
                    setTextColor(if (ep.aired) dim else Color.parseColor("#F5C518"))
                    textSize = 11f; setPadding(dp(2), dp(1), dp(2), dp(2))
                })
            }
            if (!ep.aired) card.alpha = 0.55f
            return card
        }
        fun epRowV(ep: Episode): View {
            val watched = Store.isWatched(this, ep.id)
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                isClickable = true; isFocusable = true; isLongClickable = true
                layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(3), 0, dp(3)) }
                setPadding(dp(4))
                setOnClickListener { if (canPlay) showEpisodeDetail(m, ep) else { Store.toggleWatched(this@MainActivity, ep.id); pushState(); repaintChips() } }
                setOnLongClickListener {
                    val w = Store.isWatched(this@MainActivity, ep.id)
                    val opts = listOf(if (w) "Mark as Unwatched" else "Mark as Watched", "Clear Episode Progress")
                    pickSheet("E${ep.episode} · ${ep.name}", opts, -1, icons = listOf(if (w) R.drawable.ic_eye_off else R.drawable.ic_eye, R.drawable.ic_undo)) { i ->
                        if (i == 0) { Store.toggleWatched(this@MainActivity, ep.id); pushState() }
                        else { Store.clearPos(this@MainActivity, ep.id); syncClear(m.id); toast("Progress cleared") }
                        epReturnTo = ep.episode
                        repaintChips()
                    }
                    true
                }
            }
            row.addView(FrameLayout(this).apply {
                tag = "ep:${m.id}|${ep.id}"   // refreshEpisodeBars repaints these live on player exit
                layoutParams = LinearLayout.LayoutParams(dp(118), dp(66)).apply { setMargins(0, 0, dp(10), 0) }
                background = rounded(Color.parseColor("#1B1830"), dp(6)); clipToOutline = true
                addView(ImageView(this@MainActivity).apply {
                    layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    loadEpThumb(this, this@MainActivity, ep.thumbnail, watched)
                })
                if (!ep.aired) addView(ImageView(this@MainActivity).apply {
                    setImageResource(R.drawable.ic_hourglass)
                    setColorFilter(fg)
                    background = GradientDrawable().apply { setColor(Color.parseColor("#B3000000")); shape = GradientDrawable.OVAL }
                    setPadding(dp(7), dp(7), dp(7), dp(7))
                    layoutParams = FrameLayout.LayoutParams(dp(32), dp(32), Gravity.CENTER)
                })
                if (watched) addView(TextView(this@MainActivity).apply {
                    text = "✓"; textSize = 10f; setTextColor(fg); setTypeface(typeface, Typeface.BOLD)
                    background = GradientDrawable().apply {
                        setColor(Color.parseColor("#CC000000")); cornerRadius = dp(8).toFloat()
                        setStroke(dp(1), Color.parseColor("#F5C518"))
                    }
                    setPadding(dp(4), dp(1), dp(4), dp(1))
                    layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.END)
                        .apply { setMargins(0, dp(4), dp(4), 0) }
                })
                                run {   // AJ Sep 13: watched = FULL purple bar; any progress (1s+) = percent bar
                    val barPct = if (watched) 100
                        else Store.pos(this@MainActivity, ep.id)?.let { (pos, dur) ->
                            if (dur > 0 && pos > 1_000) (100 * pos / dur).toInt() else null } ?: -1
                    if (barPct >= 0) {
                        addView(View(this@MainActivity).apply {
                            tag = "epbar"
                            setBackgroundColor(Color.parseColor("#66000000"))
                            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, dp(4), Gravity.BOTTOM)
                        })
                        addView(View(this@MainActivity).apply {
                            tag = "epbar"
                            setBackgroundColor(accent)
                            layoutParams = FrameLayout.LayoutParams(maxOf(dp(6), dp(118) * barPct / 100), dp(4), Gravity.BOTTOM or Gravity.START)
                        })
                    }
                }
            })
            val txt = column().apply { layoutParams = lp(0, WRAP_CONTENT, 1f) }
            txt.addView(TextView(this).apply {
                text = "${ep.episode}. ${ep.name}"
                setTextColor(if (watched) dim else fg); textSize = 14.5f
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            })
            ep.released?.let { rel ->
                txt.addView(TextView(this).apply {
                    text = rel
                    setTextColor(if (ep.aired) dim else Color.parseColor("#F5C518")); textSize = 11.5f
                })
            }
            if (ep.description.isNotBlank()) txt.addView(TextView(this).apply {
                text = ep.description; setTextColor(dim); textSize = 12f; maxLines = 2
                ellipsize = android.text.TextUtils.TruncateAt.END
            })
            row.addView(txt)
            // ⬇ OFFLINE DOWNLOAD (full flavor, phones only — Firestick keeps nothing): the
            // whole control (glyph states, stream resolve, toasts) lives in Downloads.kt so
            // store/amazon binaries carry none of it; the lambda hands over the SAME final
            // URL playback would use (profile swap + direct mirror)
            if (Downloads.ENABLED && !isTv && canPlay && ep.aired)
                row.addView(Downloads.button(this@MainActivity, ep.id, "series", m.name,
                    ep.name, ep.season, ep.episode, m.poster) { u -> Http.direct(withProfile(u)) })
            if (!ep.aired) row.alpha = 0.55f
            return row
        }
        fun showSeason(sn: Int) {
            current = sn
            lastSeasonViewed[m.id] = sn
            epStrip.removeAllViews()
            val list = m.videos.filter { it.season == sn }.sortedBy { it.episode }
            for (ep in list) epStrip.addView(if (isTv) epCard(ep) else epRowV(ep))
            epStrip.getChildAt(epStrip.childCount - 1)?.let { last ->
                if (last.id == View.NO_ID) last.id = View.generateViewId()
                last.nextFocusRightId = last.id
            }
            // cursor: back to the episode you just acted on, else the next unwatched (Stremio)
            if (isTv) epStrip.post {
                val ret = epReturnTo
                epReturnTo = null
                val idx = when {
                    ret != null -> list.indexOfFirst { it.episode == ret }.coerceAtLeast(0)
                    // cursor lands on the CURRENT episode when its season is showing
                    cwEp != null && cwEp.season == sn ->
                        list.indexOfFirst { it.episode == cwEp.episode }.coerceAtLeast(0)
                    else -> list.indexOfFirst { !Store.isWatched(this, it.id) }.coerceAtLeast(0)
                }
                epStrip.getChildAt(idx)?.requestFocus()
            }
        }
        if (seasons.size > 1) {
            val chips = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            repaintChips = {
                chips.removeAllViews()
                for (sn in seasons) chips.addView(TextView(this).apply {
                    text = "Season $sn"; textSize = 14f; gravity = Gravity.CENTER
                    // SELECTED season = solid accent + bold, unmissable; focus ring on top of that
                    setTextColor(if (sn == current) fg else dim)
                    setTypeface(typeface, if (sn == current) Typeface.BOLD else Typeface.NORMAL)
                    background = selBg(if (sn == current) accent else Color.parseColor("#2C2649"), 16)
                    setPadding(dp(15), dp(8), dp(15), dp(8))
                    isClickable = true; isFocusable = true
                    layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, 0, dp(8), dp(8)) }
                    setOnClickListener { showSeason(sn); repaintChips() }
                })
                showSeasonRef?.invoke()
            }
            repaintChips()
            body.addView(horizScroll(chips))
        } else repaintChips = { showSeasonRef?.invoke() }
        body.addView(focusName)
        body.addView(focusDesc)
        body.addView(epScroll)
        showSeasonRef = { showSeason(current) }
        showSeason(current)
    }

    private var showSeasonRef: (() -> Unit)? = null
    private var epReturnTo: Int? = null
    private val stripReturnEp = HashMap<String, Int>()
    private var curEpMeta: Meta? = null   // the episode-detail page currently shown (for return-from-player jump)
    private var curEpEp: Episode? = null

    // ---------- play: Stremio-style EPISODE PAGE — opens INSTANTLY (thumb, facts, description),
    // streams populate into it as the addon answers. Replaces the old toast-and-wait flow that
    // left the screen dead for the whole scrape (AJ: "you don't have anything once you click"). ----------
    private fun showEpisodeDetail(m: Meta, ep: Episode) {
        lastSeasonViewed[m.id] = ep.season
        stripReturnEp[m.id] = ep.episode   // back from streams lands on THIS episode
        curEpMeta = m; curEpEp = ep        // remembered so a return-from-player can jump to the current episode
        pushPage { showEpisodeDetail(m, ep) }
        if (isTv) { showEpisodeDetailTv(m, ep); return }
        val page = FrameLayout(this).apply { setBackgroundColor(bg) }
        val back = ImageView(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            scaleType = ImageView.ScaleType.CENTER_CROP
            (m.background ?: ep.thumbnail ?: m.poster)?.let { load(it) }
        }
        page.addView(back)
        page.addView(View(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(bg, Color.parseColor("#F20B0B0F"), Color.parseColor("#8C0B0B0F")))
        })
        val body = column().apply { setPadding(dp(20), dp(56), dp(20), dp(30)) }
        page.addView(ScrollView(this).apply { addView(body); isFillViewport = true; isVerticalScrollBarEnabled = false })
        page.addView(iconBtn("‹") { onBackPressed() }.apply {
            layoutParams = FrameLayout.LayoutParams(dp(44), dp(44))
                .apply { setMargins(dp(12), if (isTv) dp(12) else statusBarPad(), 0, 0) }
        })
        swap(page)
        // Stremio's episode page: show LOGO (or name) big, then "year · SxxEyy · air date",
        // then the episode's own description, then the streams. Clean, nothing else.
        if (m.logo != null) body.addView(ImageView(this).apply {
            adjustViewBounds = true
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, dp(64))
            load(m.logo)
        })
        else body.addView(TextView(this).apply {
            text = m.name; setTextColor(fg); textSize = 28f; setTypeface(typeface, Typeface.BOLD)
        })
        body.addView(TextView(this).apply {
            text = listOfNotNull(
                m.year.ifBlank { null },
                "S%02dE%02d".format(ep.season, ep.episode),
                ep.released, ep.name.ifBlank { null }
            ).joinToString("  ·  ")
            setTextColor(dim); textSize = 14f; setPadding(0, dp(4), 0, 0)
        })
        Store.pos(this, ep.id)?.let { (pos, dur) ->
            if (pos > 60_000) body.addView(TextView(this).apply {
                text = if (dur > 0) "Resume from ${(100 * pos / dur)}%" else "Resume where you left off"
                setTextColor(accent); textSize = 13.5f; setPadding(0, dp(4), 0, 0)
            })
        }
        if (ep.description.isNotBlank()) body.addView(TextView(this).apply {
            text = ep.description; setTextColor(Color.parseColor("#E5E5E5")); setPadding(0, dp(8), 0, dp(6))
            textSize = 14.5f; setLineSpacing(0f, 1.15f)
            maxLines = if (isTv) 4 else 6; ellipsize = android.text.TextUtils.TruncateAt.END
        })
        val wt = ghostPill("") {}
        fun paintWt() { wt.text = if (Store.isWatched(this, ep.id)) "✓ Watched" else "Mark watched" }
        wt.setOnClickListener { Store.toggleWatched(this, ep.id); paintWt() }
        paintWt(); body.addView(wt)
        body.addView(sectionText("Streams"))
        val (sScroll, sHolder) = streamStrip()
        val sNote = dimText("Finding streams…")
        body.addView(sNote)
        body.addView(sScroll)
        val label = "${m.name} S${ep.season}E${ep.episode}"
        val next = findNext(m, ep)
        scope.launch {
            // A just-aired episode is usually still CACHING (the warmer kicked it off) — so don't
            // dead-end on "no streams". Poll every 15s (up to ~3 min) and fill them in the moment
            // the download lands, so the page updates itself (AJ Sep 10). Stops if you leave.
            var streams = Addons.streams(Store.addons(this@MainActivity), m.type, ep.id, profileSeg())
            var tries = 0
            while (streams.isEmpty() && ep.aired && tries < 12 && sScroll.isAttachedToWindow) {
                sNote.visibility = View.VISIBLE
                sNote.text = "Getting this episode ready — it'll appear here in a minute or two…"
                kotlinx.coroutines.delay(15_000)
                if (!sScroll.isAttachedToWindow) return@launch
                streams = Addons.streams(Store.addons(this@MainActivity), m.type, ep.id, profileSeg())
                tries++
            }
            sHolder.removeAllViews()
            sNote.visibility = View.GONE
            if (streams.isEmpty()) {
                sNote.visibility = View.VISIBLE
                sNote.text = if (!ep.aired) "This episode hasn't aired yet."
                             else "Still getting this ready — check back in a minute."
                return@launch
            }
            for (st in streams) sHolder.addView(streamRowView(st) {
                // Continue Watching means you PLAYED it — not that you looked at the page
                Store.pushContinue(this@MainActivity, Title(m.id, m.type, m.name, m.poster))
                Store.setCwLast(this@MainActivity, m.id, ep.id)
                PlayerActivity.launch(this@MainActivity, Http.direct(withProfile(st.url)), label, ep.id,
                    nextLabel = next?.let { "${it.episode}. ${it.name}" }, nextThumb = next?.thumbnail,
                    poster = m.poster, titleId = m.id, type = "series", subsJson = st.subsJson,
                    logo = m.logo)
            })
            sHolder.getChildAt(0)?.requestFocus()
        }
    }

    // ================= STREMIO TV PAGES (v2, per AJ's spec) =================
    // Art is BEHIND the whole page AND reads clearly on the right (left gradient carries the
    // text). Info stacks top-left: name / runtime·year·imdb / genres / description / cast /
    // actions. The bottom is the work strip, LEFT-TO-RIGHT on one page: episodes for shows
    // (season chips above), streams for movies and episode pages. No page scrolling, ever.

    private fun tvPageShell(backUrl: String?, showBack: Boolean = true, onBack: () -> Unit): Triple<FrameLayout, LinearLayout, LinearLayout> {
        val page = FrameLayout(this).apply { setBackgroundColor(bg) }
        val back = ImageView(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            scaleType = ImageView.ScaleType.CENTER_CROP
            backUrl?.let { load(it) }
        }
        page.addView(back)
        page.addView(View(this).apply {   // left gradient: text side solid, art side open
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            background = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT,
                intArrayOf(Color.parseColor("#F70C0B14"), Color.parseColor("#D90C0B14"), Color.parseColor("#330C0B14"), Color.TRANSPARENT))
        })
        page.addView(View(this).apply {   // bottom scrim under the strip
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, dp(260), Gravity.BOTTOM)
            background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(bg, Color.parseColor("#CC0C0B14"), Color.TRANSPARENT))
        })
        val col = column().apply {
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            setPadding(dp(30), dp(18), dp(16), dp(12))
        }
        val info = column().apply { layoutParams = lp(dp(480), 0, 1f) }
        val bottom = column().apply { layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT) }
        col.addView(info); col.addView(bottom)
        page.addView(col)
        if (showBack) page.addView(iconBtn("‹", onBack).apply {
            layoutParams = FrameLayout.LayoutParams(dp(38), dp(38)).apply { setMargins(dp(8), dp(8), 0, 0) }
        })
        swap(page)
        return Triple(page, info, bottom)
    }

    private fun tvInfoBlock(info: LinearLayout, name: String, facts: String, genres: String,
                            desc: String, cast: String, logo: String? = null,
                            genreList: List<String> = emptyList(), typeForGenres: String? = null) {
        if (logo != null) info.addView(ImageView(this).apply {
            adjustViewBounds = true
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, dp(70)).apply { setMargins(0, dp(16), 0, 0) }
            load(logo)
        })
        else info.addView(TextView(this).apply {
            text = name; setTextColor(fg); textSize = 30f; setTypeface(typeface, Typeface.BOLD)
            maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(8), 0, 0)
        })
        if (facts.isNotBlank()) info.addView(TextView(this).apply {
            text = facts; setTextColor(fg); textSize = 13.5f; setPadding(0, dp(5), 0, 0)
        })
        // genres as DOORWAYS on TV too (AJ, Stremio photo 10): click Horror on a d-pad →
        // Discover pre-filtered to Horror in this title's type
        if (genreList.isNotEmpty()) {
            val gstrip = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(4), 0, 0) }
            for (g in genreList.take(4)) gstrip.addView(personChip(g).apply {
                textSize = 12f
                setOnClickListener {
                    discType = if (typeForGenres == "series") "series" else "movie"
                    discGenre = g; discCatIdx = 0
                    showMain("Discover")
                }
            })
            info.addView(gstrip)
        } else if (genres.isNotBlank()) info.addView(TextView(this).apply {
            text = genres; setTextColor(dim); textSize = 12.5f; setPadding(0, dp(2), 0, 0)
        })
        if (desc.isNotBlank()) info.addView(TextView(this).apply {
            text = desc; setTextColor(Color.parseColor("#DDDAEA")); setPadding(0, dp(8), 0, 0)
            textSize = 13f; setLineSpacing(0f, 1.2f); maxLines = 11
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        if (cast.isNotBlank()) info.addView(TextView(this).apply {
            text = cast; setTextColor(dim); textSize = 12f; maxLines = 2; setPadding(0, dp(8), 0, 0)
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
    }

    private fun showDetailTv(t: Title) {
        val (page, info, bottom) = tvPageShell(null, showBack = false) { onBackPressed() }
        scope.launch {
            val m = Discovery.meta(t.type, t.id) ?: run { info.addView(dimText("Couldn't load details.")); return@launch }
            dismissNewEpsBadge(t, m)
            (page.getChildAt(0) as? ImageView)?.let { iv -> (m.background ?: m.poster)?.let { iv.load(it) } }
            if (m.type == "series") {
                // STREMIO SERIES PAGE: show LOGO (fallback: name), "Name (year)", and the
                // FOCUSED EPISODE's description below — the show blurb lives on Home
                if (m.logo != null) info.addView(ImageView(this@MainActivity).apply {
                    adjustViewBounds = true
                    layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, dp(74)).apply { setMargins(0, dp(14), 0, 0) }
                    load(m.logo)
                }) else info.addView(TextView(this@MainActivity).apply {
                    text = m.name; setTextColor(fg); textSize = 30f; setTypeface(typeface, Typeface.BOLD)
                    maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(14), 0, 0)
                })
                info.addView(TextView(this@MainActivity).apply {
                    text = listOfNotNull((if (m.year.isNotBlank()) "${m.name} (${m.year})" else m.name),
                        m.imdbRating.ifBlank { null }?.let { "★ $it" }).joinToString("   ")
                    setTextColor(dim); textSize = 13f; setPadding(0, dp(6), 0, 0)
                })
            } else tvInfoBlock(info, m.name,
                listOfNotNull(m.runtime.ifBlank { null }, m.year.ifBlank { null },
                    m.imdbRating.ifBlank { null }?.let { "★ $it" }).joinToString("   "),
                m.genres.take(4).joinToString(" · "),
                m.description, "", logo = m.logo, genreList = m.genres, typeForGenres = m.type)
            if (m.cast.isNotEmpty()) {
                val strip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                for (n in m.cast.take(8)) strip.addView(personChip(n))
                info.addView(HorizontalScrollView(this@MainActivity).apply {
                    addView(strip); isHorizontalScrollBarEnabled = false
                    setPadding(0, dp(6), 0, 0)
                })
            }
            val actions = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, dp(10), 0, 0)
            }
            val actionLabel = TextView(this@MainActivity).apply { setTextColor(dim); textSize = 12.5f; setPadding(dp(8), 0, 0, 0) }
            fun icon(resOf: () -> Int, labelOf: () -> String, onClick: () -> Unit): ImageView {
                lateinit var v: ImageView
                v = ImageView(this@MainActivity).apply {
                    setImageResource(resOf()); setColorFilter(fg)
                    scaleType = ImageView.ScaleType.CENTER_INSIDE
                    setPadding(dp(13), dp(13), dp(13), dp(13))
                    background = selBg(Color.parseColor("#2C2649"), 26)
                    layoutParams = LinearLayout.LayoutParams(dp(54), dp(54)).apply { setMargins(0, 0, dp(12), 0) }
                    isClickable = true; isFocusable = true
                    setOnClickListener { onClick(); v.setImageResource(resOf()); actionLabel.text = labelOf() }
                    setOnFocusChangeListener { _, has -> if (has) actionLabel.text = labelOf() }
                }
                return v
            }
            if (m.trailerYoutubeId != null) actions.addView(icon({ R.drawable.ic_trailer }, { "Trailer" }) { playTrailer(m.trailerYoutubeId, m.name) })
            actions.addView(icon(
                { if (Store.inWatchlist(this@MainActivity, t.id)) R.drawable.ic_lib_remove else R.drawable.ic_lib_add },
                { if (Store.inWatchlist(this@MainActivity, t.id)) "Remove from Library" else "Add to Library" }) {
                Store.toggleWatchlist(this@MainActivity, t); pushState()
            })
            // whole-show "mark watched" makes no sense on an EPISODE LIST (AJ) — movies
            // only; per-episode marking lives on each episode's long-press
            if (m.type != "series") actions.addView(icon(
                { if (Store.isWatched(this@MainActivity, t.id)) R.drawable.ic_eye else R.drawable.ic_eye_off },
                { if (Store.isWatched(this@MainActivity, t.id)) "Marked as watched" else "Mark as watched" }) {
                Store.toggleWatchedTitle(this@MainActivity, Title(m.id, m.type, m.name, m.poster)); pushState()
            })
            // THUMBS (AJ Sep 25): per-profile, syncs everywhere, shapes For You
            run {
                var upV: ImageView? = null; var downV: ImageView? = null
                val upRes = { if (Store.rating(this@MainActivity, t.id) == 1) R.drawable.ic_thumb_up_on else R.drawable.ic_thumb_up }
                val downRes = { if (Store.rating(this@MainActivity, t.id) == -1) R.drawable.ic_thumb_down_on else R.drawable.ic_thumb_down }
                upV = icon(upRes,
                    { if (Store.rating(this@MainActivity, t.id) == 1) "Liked — For You shows more like this" else "Thumbs up" }) {
                    Store.setRating(this@MainActivity, t.id, if (Store.rating(this@MainActivity, t.id) == 1) 0 else 1); pushState()
                    downV?.setImageResource(downRes())
                } as ImageView
                downV = icon(downRes,
                    { if (Store.rating(this@MainActivity, t.id) == -1) "Not for me — hidden from For You" else "Thumbs down" }) {
                    Store.setRating(this@MainActivity, t.id, if (Store.rating(this@MainActivity, t.id) == -1) 0 else -1); pushState()
                    upV?.setImageResource(upRes())
                } as ImageView
                actions.addView(upV); actions.addView(downV)
            }
            actions.addView(actionLabel)
            info.addView(actions)
            // where to watch (guests / no addon) — the tracker's answer to "ok, where do I
            // actually watch it?" — was phone-only; the TV page never had it
            run {
                val provHolder = column()
                info.addView(provHolder)
                scope.launch {
                    val p = Discovery.providers(m.id.substringBefore(":"), m.type)
                    // Sideload = all+links, PLAY = rent/buy links only (pre-Sep23 approved
                    // behavior), AMAZON = all visible as plain labels (see other render site).
                    val rentBuyOnly = Dist.STORE && Links.PROVIDER_CLICKS
                    if (p == null || (if (rentBuyOnly) (p.rent.isEmpty() && p.buy.isEmpty())
                                      else (p.stream.isEmpty() && p.rent.isEmpty() && p.buy.isEmpty()))) {
                        // still theatrical: tell everyone (incl. addon users) why there's
                        // nothing to stream yet — otherwise it reads as the app being broken
                        if (m.type != "series" && Store.addons(this@MainActivity).isEmpty() &&
                            (m.year.take(4).toIntOrNull() ?: 0) >= java.util.Calendar.getInstance().get(java.util.Calendar.YEAR) - 1)
                            provHolder.addView(TextView(this@MainActivity).apply {
                                text = "🎬 In theaters now — home release hasn't happened yet"
                                setTextColor(Color.parseColor("#F5C518")); textSize = 13.5f
                                setTypeface(typeface, Typeface.BOLD); setPadding(0, dp(8), 0, dp(2))
                            })
                        return@launch
                    }
                    if (Store.addons(this@MainActivity).isNotEmpty()) return@launch
                    provHolder.addView(TextView(this@MainActivity).apply {
                        text = if (rentBuyOnly) "▶ Where to rent or buy" else "▶ Where to watch"
                        setTextColor(fg); textSize = 16f
                        setTypeface(typeface, Typeface.BOLD); setPadding(0, dp(10), 0, dp(2))
                    })
                    val strip = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
                    fun chip(label: String, prov: String, accented: Boolean) {
                        strip.addView(TextView(this@MainActivity).apply {
                            text = label; setTextColor(fg); textSize = 13.5f
                            setTypeface(typeface, Typeface.BOLD)
                            background = selBg(if (accented) accent else Color.parseColor("#2C2649"), 18)
                            setPadding(dp(14), dp(9), dp(14), dp(9))
                            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(4), dp(8), dp(4)) }
                            isClickable = Links.PROVIDER_CLICKS; isFocusable = Links.PROVIDER_CLICKS
                            if (Links.PROVIDER_CLICKS) setOnClickListener { openProvider(prov, m.name, p.link) }
                        })
                    }
                    if (!rentBuyOnly) p.stream.take(4).forEach { chip(it, it, accented = true) }
                    p.rent.take(3).forEach { chip("Rent · $it", it, accented = rentBuyOnly) }
                    p.buy.take(3).forEach { if (it !in p.rent) chip("Buy · $it", it, accented = false) }
                    provHolder.addView(horizScroll(strip))
                }
            }
            if (m.type == "series" && m.videos.isNotEmpty()) buildTvEpisodeStrip(bottom, m)
            else if (Store.addons(this@MainActivity).isNotEmpty()) buildTvStreamStrip(bottom, m, null)
        }
    }

    /** Bottom of the show page, the Stremio way: ONE continuous left-to-right strip across
     *  ALL seasons with a thin divider between them — scroll from S1 straight into S2, the
     *  season selector follows along. Chips jump-scroll; hover narrates into the info block. */
    private fun buildTvEpisodeStrip(bottom: LinearLayout, m: Meta) {
        val seasons = m.videos.map { it.season }.filter { it > 0 }.distinct().sorted()
        // open ON the user's current episode (cwLast rule) — not Season 1 (AJ Sep 11)
        val cwEp = currentEpisode(m)
        var current = lastSeasonViewed[m.id]?.takeIf { it in seasons }
            ?: cwEp?.season?.takeIf { it in seasons } ?: seasons.firstOrNull() ?: 0
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            clipChildren = false; clipToPadding = false
            setPadding(dp(2), dp(6), dp(24), dp(6))
        }
        val stripScroll = HorizontalScrollView(this).apply {
            addView(strip); isHorizontalScrollBarEnabled = false
            clipChildren = false; clipToPadding = false
        }
        val hoverName = TextView(this).apply {
            setTextColor(fg); textSize = 14.5f; setTypeface(typeface, Typeface.BOLD)
            maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val hoverDesc = TextView(this).apply {
            setTextColor(Color.parseColor("#CFCBE2")); textSize = 13.5f; maxLines = 3
            ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(0, dp(1), 0, dp(4))
        }
        val chips = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        var currentChipId = View.NO_ID
        val seasonFirstCard = HashMap<Int, View>()
        lateinit var repaintChipsT: () -> Unit
        repaintChipsT = {
            chips.removeAllViews()
            for (sn in seasons) chips.addView(TextView(this).apply {
                text = "Season $sn"; textSize = 13f; gravity = Gravity.CENTER
                setTextColor(if (sn == current) fg else dim)
                setTypeface(typeface, if (sn == current) Typeface.BOLD else Typeface.NORMAL)
                background = selBg(if (sn == current) accent else Color.parseColor("#2C2649"), 14)
                setPadding(dp(12), dp(6), dp(12), dp(6))
                isClickable = true; isFocusable = true
                if (sn == current) { id = View.generateViewId(); currentChipId = id }
                layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, 0, dp(7), dp(4)) }
                setOnClickListener {
                    current = sn; repaintChipsT()
                    seasonFirstCard[sn]?.let { c ->
                        c.requestFocus()
                        stripScroll.smoothScrollTo(c.left - dp(20), 0)
                    }
                }
            })
        }
        fun buildAll(focusSeason: Int, focusEp: Int?) {
            strip.removeAllViews(); seasonFirstCard.clear()
            var focusTarget: View? = null
            for ((si, sn) in seasons.withIndex()) {
                if (si > 0) strip.addView(View(this).apply {   // the thin season divider
                    setBackgroundColor(Color.parseColor("#4A4470"))
                    layoutParams = LinearLayout.LayoutParams(dp(2), dp(104)).apply { setMargins(dp(10), dp(6), dp(12), 0) }
                })
                val eps = m.videos.filter { it.season == sn }.sortedBy { it.episode }
                for (ep in eps) {
                    val watched = Store.isWatched(this, ep.id)
                    val card = LinearLayout(this).apply {
                        orientation = LinearLayout.VERTICAL
                        isClickable = true; isFocusable = true; isLongClickable = true
                        layoutParams = LinearLayout.LayoutParams(dp(206), WRAP_CONTENT).apply { setMargins(dp(5), dp(2), dp(5), dp(2)) }
                        setOnClickListener { showEpisodeDetail(m, ep) }
                        setOnLongClickListener {
                            val w = Store.isWatched(this@MainActivity, ep.id)
                            val opts = listOf(if (w) "Mark as Unwatched" else "Mark as Watched", "Clear Episode Progress")
                            pickSheet("E${ep.episode} · ${ep.name}", opts, -1, icons = listOf(if (w) R.drawable.ic_eye_off else R.drawable.ic_eye, R.drawable.ic_undo)) { i ->
                                if (i == 0) { Store.toggleWatched(this@MainActivity, ep.id); pushState() }
                                else { Store.clearPos(this@MainActivity, ep.id); syncClear(m.id); toast("Progress cleared") }
                                buildAll(ep.season, ep.episode)
                            }
                            true
                        }
                        setOnFocusChangeListener { v, has ->
                            v.animate().scaleX(if (has) 1.06f else 1f).scaleY(if (has) 1.06f else 1f).setDuration(110).start()
                            v.translationZ = if (has) dp(4).toFloat() else 0f
                            if (has) {
                                hoverName.text = "S${ep.season} E${ep.episode} · ${ep.name}"
                                hoverDesc.text = ep.description.ifBlank { ep.released ?: "" }
                                if (current != ep.season) { current = ep.season; repaintChipsT() }
                                v.nextFocusUpId = currentChipId
                                stripScroll.smoothScrollTo((v.left - dp(28)).coerceAtLeast(0), 0)
                            }
                        }
                    }
                    card.addView(FrameLayout(this).apply {
                        tag = "ep:${m.id}|${ep.id}"   // refreshEpisodeBars repaints these live on player exit
                        layoutParams = LinearLayout.LayoutParams(dp(202), dp(114))
                        background = rounded(Color.parseColor("#1B1830"), dp(7)); clipToOutline = true
                        addView(ImageView(this@MainActivity).apply {
                            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
                            scaleType = ImageView.ScaleType.CENTER_CROP
                            loadEpThumb(this, this@MainActivity, ep.thumbnail, watched)
                        })
                        if (!ep.aired) addView(ImageView(this@MainActivity).apply {
                            setImageResource(R.drawable.ic_hourglass); setColorFilter(fg)
                            background = GradientDrawable().apply { setColor(Color.parseColor("#B3000000")); shape = GradientDrawable.OVAL }
                            setPadding(dp(8), dp(8), dp(8), dp(8))
                            layoutParams = FrameLayout.LayoutParams(dp(38), dp(38), Gravity.CENTER)
                        })
                        addView(TextView(this@MainActivity).apply {
                            text = "E%02d".format(ep.episode)
                            setTextColor(fg); textSize = 12f; setTypeface(typeface, Typeface.BOLD)
                            setShadowLayer(6f, 0f, 0f, Color.BLACK)
                            background = GradientDrawable().apply { setColor(Color.parseColor("#99000000")); cornerRadius = dp(6).toFloat() }
                            setPadding(dp(6), dp(1), dp(6), dp(1))
                            layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.END)
                                .apply { setMargins(0, dp(5), dp(5), 0) }
                        })
                        // gold EYE on watched thumbs — the Stremio badge AJ pointed at (photo 9).
                        // ONE indicator only: the ✓ badge that used to stack on top of this eye
                        // (same top-left corner) was removed — a watched ep showed both at once.
                        if (watched) addView(ImageView(this@MainActivity).apply {
                            setImageResource(R.drawable.ic_eye)
                            setColorFilter(Color.parseColor("#F5C518"))
                            background = GradientDrawable().apply { setColor(Color.parseColor("#99000000")); shape = GradientDrawable.OVAL }
                            setPadding(dp(5), dp(5), dp(5), dp(5))
                            layoutParams = FrameLayout.LayoutParams(dp(26), dp(26), Gravity.TOP or Gravity.START)
                                .apply { setMargins(dp(5), dp(5), 0, 0) }
                        })
                                                run {   // AJ Sep 13: watched = FULL purple bar; any progress (1s+) = percent bar
                            val barPct = if (watched) 100
                                else Store.pos(this@MainActivity, ep.id)?.let { (pos, dur) ->
                                    if (dur > 0 && pos > 1_000) (100 * pos / dur).toInt() else null } ?: -1
                            if (barPct >= 0) {
                                addView(View(this@MainActivity).apply {
                                    tag = "epbar"
                                    setBackgroundColor(Color.parseColor("#66000000"))
                                    layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, dp(4), Gravity.BOTTOM)
                                })
                                addView(View(this@MainActivity).apply {
                                    tag = "epbar"
                                    setBackgroundColor(accent)
                                    layoutParams = FrameLayout.LayoutParams(maxOf(dp(6), dp(202) * barPct / 100), dp(4), Gravity.BOTTOM or Gravity.START)
                                })
                            }
                        }
                    })
                    card.addView(TextView(this).apply {
                        text = "${ep.episode}. ${ep.name}"
                        setTextColor(if (watched) dim else fg); textSize = 13.5f; maxLines = 1
                        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                        ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(dp(2), dp(4), dp(2), 0)
                    })
                    ep.released?.let { rel ->
                        card.addView(TextView(this).apply {
                            text = rel
                            setTextColor(if (ep.aired) dim else Color.parseColor("#F5C518")); textSize = 10.5f
                            setPadding(dp(2), dp(1), dp(2), dp(2))
                        })
                    }
                    if (!ep.aired) card.alpha = 0.55f
                    if (seasonFirstCard[sn] == null) seasonFirstCard[sn] = card
                    if (ep.season == focusSeason && (focusEp == null && focusTarget == null && !watched || focusEp == ep.episode))
                        focusTarget = card
                    strip.addView(card)
                }
            }
            pinRowEnds(strip)
            strip.post {
                val target = focusTarget ?: seasonFirstCard[focusSeason] ?: strip.getChildAt(0)
                target?.requestFocus()
                target?.let { stripScroll.post { stripScroll.smoothScrollTo(it.left - dp(20), 0) } }
            }
        }
        repaintChipsT()
        chips.post { pinRowEnds(chips) }
        bottom.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER
            clipChildren = false; clipToPadding = false
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
            addView(HorizontalScrollView(this@MainActivity).apply {
                addView(chips.apply { setPadding(dp(4), dp(4), dp(4), dp(4)); clipChildren = false; clipToPadding = false })
                isHorizontalScrollBarEnabled = false
                clipChildren = false; clipToPadding = false
            })
        })
        bottom.addView(hoverName)
        bottom.addView(hoverDesc)
        bottom.addView(stripScroll)
        buildAll(current, stripReturnEp.remove(m.id) ?: cwEp?.episode?.takeIf { cwEp.season == current })
    }

    /** Bottom strip of streams, LEFT-TO-RIGHT, cursor on the best one. */
    private fun buildTvStreamStrip(bottom: LinearLayout, m: Meta, ep: Episode?) {
        val note = dimText("Finding streams…")
        bottom.addView(note)
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER
            clipChildren = false; clipToPadding = false
            setPadding(dp(2), dp(4), dp(2), dp(8))
            minimumWidth = resources.displayMetrics.widthPixels - dp(120)   // sit centered
        }
        bottom.addView(HorizontalScrollView(this).apply {
            addView(strip); isHorizontalScrollBarEnabled = false
            clipChildren = false; clipToPadding = false
        })
        val sid = ep?.id ?: m.id
        val label = if (ep != null) "${m.name} S${ep.season}E${ep.episode}" else m.name
        scope.launch {
            var streams = Addons.streams(Store.addons(this@MainActivity), m.type, sid, profileSeg())
            // expired (server marker OR cached) → banner where streams go, stop here
            if (streams.any { it.expired } || isExpired()) {
                note.visibility = View.GONE; strip.removeAllViews(); strip.addView(expiryBanner()); return@launch
            }
            // just-aired episodes are usually still caching — poll and fill them in when the
            // download lands instead of dead-ending on "no streams" (AJ Sep 10). Skip the poll
            // if the service is unreachable (that's a network problem, not a warming one).
            val aired = ep?.aired ?: true
            var reachable = true
            if (streams.isEmpty() && aired) {
                reachable = Store.addons(this@MainActivity).firstOrNull()
                    ?.let { Http.json("${it.url}/manifest.json") != null } ?: false
                var tries = 0
                while (streams.isEmpty() && reachable && tries < 12 && strip.isAttachedToWindow) {
                    note.visibility = View.VISIBLE
                    note.text = "Getting this ready — it'll appear here in a minute or two…"
                    kotlinx.coroutines.delay(15_000)
                    if (!strip.isAttachedToWindow) return@launch
                    streams = Addons.streams(Store.addons(this@MainActivity), m.type, sid, profileSeg())
                    tries++
                }
            }
            note.visibility = View.GONE
            if (streams.isEmpty()) {
                note.visibility = View.VISIBLE
                note.text = when {
                    ep != null && !ep.aired -> "This episode hasn't aired yet."
                    reachable -> "Still getting this ready — check back in a minute."
                    else -> "This device can't reach the streaming service — check its Wi-Fi/DNS (try DNS 1.1.1.1 in network settings)."
                }
                Addons.debugNoStreams(this@MainActivity, Store.addons(this@MainActivity), m.type, sid)
                return@launch
            }
            for (st in streams) strip.addView(streamRowView(st) {
                Store.pushContinue(this@MainActivity, Title(m.id, m.type, m.name, m.poster))
                Store.setCwLast(this@MainActivity, m.id, sid)
                PlayerActivity.launch(this@MainActivity, Http.direct(withProfile(st.url)), label, sid,
                    poster = m.poster, titleId = m.id, type = m.type, subsJson = st.subsJson,
                    backdrop = m.background ?: ep?.thumbnail ?: m.poster, logo = m.logo)
            })
            pinRowEnds(strip)
            strip.getChildAt(0)?.requestFocus()
        }
    }

    private fun showEpisodeDetailTv(m: Meta, ep: Episode) {
        val (_, info, bottom) = tvPageShell(m.background ?: ep.thumbnail ?: m.poster, showBack = false) { onBackPressed() }
        tvInfoBlock(info, m.name,
            listOfNotNull(m.year.ifBlank { null }, "S%02dE%02d".format(ep.season, ep.episode),
                ep.released, ep.name.ifBlank { null }).joinToString("  ·  "),
            "",
            ep.description,
            if (m.cast.isEmpty()) "" else "Cast: " + m.cast.take(6).joinToString(", "),
            logo = m.logo)
        Store.pos(this, ep.id)?.let { (pos, dur) ->
            if (pos > 60_000) info.addView(TextView(this).apply {
                text = if (dur > 0) "Resume from ${(100 * pos / dur)}%" else "Resume where you left off"
                setTextColor(accent); textSize = 12.5f; setPadding(0, dp(8), 0, 0)
            })
        }
        buildTvStreamStrip(bottom, m, ep)
    }

    /** One tappable stream card — streams lay out LEFT TO RIGHT, best first (AJ/Stremio-style).
     *  ckNotice cards (AJ Sep 16: "why is that a clickable stream") are INFO BANNERS — the
     *  "hasn't aired yet / nothing found" message rendered flat, not clickable, not focusable. */
    private fun streamRowView(st: Stream, onClick: () -> Unit): View = column().apply {
        if (st.notice) {
            background = selBg(Color.parseColor("#171426"), 10)
            setPadding(dp(17), dp(14), dp(17), dp(14))
            layoutParams = LinearLayout.LayoutParams(dp(360), WRAP_CONTENT).apply { setMargins(0, dp(6), dp(12), dp(6)) }
            isClickable = false; isFocusable = false
            addView(TextView(this@MainActivity).apply {
                text = st.name.replace("\n", " "); setTextColor(dim); textSize = 15f
                maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
            })
            if (st.title.isNotBlank()) addView(TextView(this@MainActivity).apply {
                text = st.title; setTextColor(fg); textSize = 15f; maxLines = 3
            })
            return@apply
        }
        background = selBg(Color.parseColor("#241F3D"), 10)
        setPadding(dp(17), dp(14), dp(17), dp(14))
        layoutParams = LinearLayout.LayoutParams(dp(320), WRAP_CONTENT).apply { setMargins(0, dp(6), dp(12), dp(6)) }
        isClickable = true; isFocusable = true
        addView(TextView(this@MainActivity).apply {
            text = st.name.replace("\n", " "); setTextColor(fg); textSize = 17f; setTypeface(typeface, Typeface.BOLD)
            maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
        })
        if (st.title.isNotBlank()) addView(TextView(this@MainActivity).apply {
            text = st.title; setTextColor(dim); textSize = 13.5f; maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        setOnClickListener { onClick() }
    }

    /** Horizontal, focus-safe strip for the stream cards. */
    private fun streamStrip(): Pair<HorizontalScrollView, LinearLayout> {
        val strip = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        return HorizontalScrollView(this).apply { addView(strip); isHorizontalScrollBarEnabled = false } to strip
    }

    private fun findNext(m: Meta, ep: Episode): Episode? =
        m.videos.filter { it.season == ep.season && it.episode > ep.episode }.minByOrNull { it.episode }
            ?: m.videos.filter { it.season > ep.season }
                .sortedWith(compareBy({ it.season }, { it.episode })).firstOrNull()

    /** Binge chain: natural end honors the Autoplay setting; "Play now" on the card always goes. */
    private fun playNextOf(m: Meta, ep: Episode?, manual: Boolean) {
        if (ep == null) return
        if (!manual && !Store.autoplayNext(this)) return
        val next = findNext(m, ep) ?: return
        val addons = Store.addons(this)
        if (addons.isEmpty()) return
        scope.launch {
            val streams = Addons.streams(addons, m.type, next.id, profileSeg()).filter { !it.notice }
            if (streams.isEmpty()) return@launch   // next ep unaired/empty -> binge ends cleanly
            val label = "${m.name} S${next.season}E${next.episode}"
            Store.pushContinue(this@MainActivity, Title(m.id, m.type, m.name, m.poster))
            Store.setCwLast(this@MainActivity, m.id, next.id)
            val after = findNext(m, next)
            PlayerActivity.onAdvance = { man -> runOnUiThread { playNextOf(m, next, man) } }
            PlayerActivity.launch(this@MainActivity, streams[0].url, label, next.id,
                nextLabel = after?.let { "${it.episode}. ${it.name}" }, nextThumb = after?.thumbnail,
                logo = m.logo)
        }
    }

    /** Stremio-style person page: tap any cast/director name -> their movies and shows. */
    private fun showPerson(name: String) {
        pushPage { showPerson(name) }
        val col = column().apply { setPadding(dp(12), dp(10), dp(6), dp(28)) }
        if (!isTv) col.addView(iconBtn("‹") { onBackPressed() })
        col.addView(bigText(name, 26f))
        val holder = column()
        col.addView(holder)
        holder.addView(dimText("Loading filmography…"))
        if (isTv) {
            // the filmography narrates like everywhere else: focused title takes the screen
            col.setPadding(col.paddingLeft, col.paddingTop, col.paddingRight,
                resources.displayMetrics.heightPixels)   // same headroom as the board tabs
            val sv = ScrollView(this).apply {
                addView(col); isFillViewport = true; isVerticalScrollBarEnabled = false
                setBackgroundColor(Color.TRANSPARENT)
                clipChildren = true; clipToPadding = true
                setPadding(0, 0, 0, 0)
            }
            homeScroll = sv
            swap(buildTvBoard(sv))
        } else swap(scroll(col))
        scope.launch {
            val p = Discovery.person(name)
            holder.removeAllViews()
            if (p == null || (p.movies.isEmpty() && p.shows.isEmpty())) {
                holder.addView(dimText("Couldn't find titles for $name")); return@launch
            }
            if (p.shows.isNotEmpty()) addRow(holder, "Shows", p.shows)
            if (p.movies.isNotEmpty()) addRow(holder, "Movies", p.movies)
        }
    }

    /** Round face + name + role — tap for the filmography. */
    private fun personCard(p: Discovery.PersonHit): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
        isClickable = true; isFocusable = true
        layoutParams = LinearLayout.LayoutParams(dp(96), WRAP_CONTENT).apply { setMargins(dp(4), dp(4), dp(4), dp(4)) }
        setOnClickListener { showPerson(p.name) }
        setOnFocusChangeListener { v, has ->
            v.animate().scaleX(if (has) 1.1f else 1f).scaleY(if (has) 1.1f else 1f).setDuration(110).start()
        }
        addView(ImageView(this@MainActivity).apply {
            layoutParams = LinearLayout.LayoutParams(dp(76), dp(76))
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = GradientDrawable().apply { setColor(Color.parseColor("#2C2649")); shape = GradientDrawable.OVAL }
            clipToOutline = true
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(v0: View, o: android.graphics.Outline) = o.setOval(0, 0, v0.width, v0.height)
            }
            p.photo?.let { load(it) }
        })
        addView(TextView(this@MainActivity).apply {
            text = p.name; setTextColor(fg); textSize = 11.5f; maxLines = 2; gravity = Gravity.CENTER
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        addView(TextView(this@MainActivity).apply {
            text = p.role; setTextColor(dim); textSize = 10f; gravity = Gravity.CENTER
        })
    }

    private fun personChip(name: String) = TextView(this).apply {
        text = name; setTextColor(fg); textSize = 13.5f
        background = rounded(Color.parseColor("#2C2649"), dp(16))
        setPadding(dp(13), dp(8), dp(13), dp(8))
        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, 0, dp(8), dp(4)) }
        isClickable = true; isFocusable = true
        setOnClickListener { showPerson(name) }
        setOnFocusChangeListener { v, has -> v.setBackgroundColor(if (has) Color.parseColor("#40FFFFFF") else Color.TRANSPARENT) }
    }

    /** Trailers play in OUR player: resolve the stream on-device (Stremio-style — the
     *  viewer's home IP passes YouTube's bot-wall that blocks servers) and hand it to
     *  PlayerActivity. No ?i= in the URL means Ck.parse stays null, so resume/progress/
     *  sync never fire for a trailer. Extraction failure: MOBILE falls back to an in-app
     *  WebView embed (Sep 13 — never bounce to the YouTube app); Fire TV keeps the
     *  YouTube-app handoff because its WebView throws "video player configuration error". */
    private fun playTrailer(ytId: String, title: String? = null) {
        Thread {
            val direct = try { Trailers.resolve(ytId) } catch (_: Exception) { null }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                // Sep 13 late: the old Fire TV embed "video player configuration error" was
                // the missing-origin bug (embed URL loaded bare) — fixed in TrailerActivity,
                // so BOTH platforms now stay in-app; the YouTube-app handoff only fires if
                // the WebView activity itself can't start
                if (direct != null) PlayerActivity.launch(this, direct,
                    if (title.isNullOrBlank()) "Trailer" else "$title — Trailer", "")
                else playTrailerEmbed(ytId)
            }
        }.start()
    }

    /** Mobile in-app embed fallback — stays inside CouchKing even when extraction fails. */
    private fun playTrailerEmbed(ytId: String) {
        try { startActivity(Intent(this, TrailerActivity::class.java).putExtra("ytId", ytId)) }
        catch (_: Exception) { playTrailerExternal(ytId) }
    }

    /** Fallback: hand off to the YouTube app (Firestick + mobile both have it) — the old
     *  in-app WebView embed threw "video player configuration error" on Fire TV.
     *  Flavor-split: the store/amazon Links stub never launches out (and carries none of
     *  the YouTube package names), so store trailers are strictly in-app. */
    private fun playTrailerExternal(ytId: String) {
        if (!Links.openTrailerExternal(this, ytId)) toast("Couldn't open the trailer")
    }

    // ---------- settings (Stremio-style: user card + iconed sections + value rows) ----------
    private fun showSettings() {
        navStack.clear(); navStack.addLast { showMain() }
        currentPage = { showSettings() }; poppingBack = false
        val col = column().apply { setPadding(dp(16), if (isTv) dp(16) else statusBarPad(), dp(16), dp(16)) }
        val top = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        top.addView(iconBtn("‹") { showMain() })
        top.addView(TextView(this).apply {
            text = "  Settings"; setTextColor(fg); textSize = 24f; setTypeface(typeface, Typeface.BOLD)
        })
        col.addView(top)

        // user card — avatar circle + who you are (Stremio's account header)
        val email = Store.account(this)
        val userCard = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = rounded(card, dp(14)); setPadding(dp(14))
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(10), 0, dp(6)) }
        }
        userCard.addView(TextView(this).apply {
            text = (email.firstOrNull()?.uppercaseChar() ?: 'G').toString()
            setTextColor(fg); textSize = 22f; setTypeface(typeface, Typeface.BOLD); gravity = Gravity.CENTER
            background = rounded(accent, dp(26))
            layoutParams = LinearLayout.LayoutParams(dp(52), dp(52)).apply { setMargins(0, 0, dp(14), 0) }
        })
        val who = column()
        who.addView(TextView(this).apply {
            text = if (email.isBlank()) "Guest" else email; setTextColor(fg); textSize = 17f; setTypeface(typeface, Typeface.BOLD)
        })
        who.addView(TextView(this).apply {
            val dleft = Store.accessDaysLeft(this@MainActivity)
            val hasExp = email.isNotBlank() && Store.accessExpiry(this@MainActivity).isNotBlank()
            text = when {
                email.isBlank() -> "Tap to sign in"
                dleft > 3650 -> "Lifetime access"
                // ≤ 0 days = EXPIRED/REVOKED — no ambiguous "expires today" (AJ Sep 18:
                // revoked should read as gone, not like they still have access today)
                hasExp && dleft <= 0 -> "⛔ Subscription expired — renew to keep watching"
                hasExp -> "Access through ${Store.accessExpiry(this@MainActivity)} · $dleft days left"
                else -> "Signed in"
            }
            setTextColor(if (email.isNotBlank() && Store.accessExpiry(this@MainActivity).isNotBlank() && Store.accessDaysLeft(this@MainActivity) <= 0) Color.parseColor("#E2574C") else dim)
            textSize = 13f
        })
        userCard.addView(who, lp(0, WRAP_CONTENT, 1f))
        if (email.isBlank()) userCard.setOnClickListener { showSignIn() }
        userCard.isClickable = email.isBlank(); userCard.isFocusable = true
        col.addView(userCard)
        if (email.isNotBlank()) {
            col.addView(settingRow2("", "Sync library now", "") {
                toast("Syncing…"); scope.launch { Sync.pullMerge(this@MainActivity); toast("Library synced") }
            })
            col.addView(settingRow2("", "Sign out", "") {
                // park EVERYTHING under this email first (profiles, addons, every
                // profile's continue/library) so signing back in restores it even if
                // the server can't be reached at that moment
                Store.stashAccount(this)
                // addons leave with the account: signed-out = discovery + tracker ONLY
                // (no streams, no Continue Watching, no player settings)
                Store.setAccount(this, ""); Store.setToken(this, "")
                Store.clearAddons(this)
                // the library leaves with the account (it's safe on the server and pulls
                // back at next sign-in) — a guest after sign-out starts CLEAN, and no other
                // email ever sees this account's Continue Watching / For You / library
                Store.clearContentState(this)
                // Live TV leaves with the account TOO — clear it NOW, not on the next refresh.
                // A guest was still able to keep tuning on the just-signed-out key until the app
                // was restarted (AJ Sep 18: "signed out, guest, still let me watch live tv").
                liveTvOn = false; liveTvAddon = null; liveTvCatId = ""
                Http.dropCache()                 // the tv manifest was cached — drop it so the tab can't re-light
                if (tab == "Live TV") tab = "Home"
                toast("Signed out"); profilePicked = false; profileGate()
            })
            col.addView(settingRow2("", "Delete account", "") {
                val d = android.app.AlertDialog.Builder(this)
                    .setTitle("Delete account?")
                    .setMessage("This permanently deletes your account and synced library on the server. Your watch data on this device stays unless you clear the app.")
                    .setPositiveButton("Delete") { _, _ ->
                        scope.launch {
                            val ok = Sync.deleteAccount(this@MainActivity)
                            if (!ok) { toast("Couldn't delete — check your connection"); return@launch }
                            Store.dropStash(this@MainActivity, Store.account(this@MainActivity))
                            Store.setAccount(this@MainActivity, ""); Store.setToken(this@MainActivity, "")
                            Store.clearAddons(this@MainActivity)
                            Store.clearContentState(this@MainActivity)
                            toast("Account deleted")
                            showSettings()
                        }
                    }
                    .setNegativeButton("Cancel", null)
                    .create()
                d.show()
            })
        }

        // Stremio-style: Settings is a HUB of category pages, not one huge scroll.
        col.addView(sectionText("SETTINGS"))
        col.addView(settingRow2("", "Shelves", "${Store.enabledShelves(this).size} shelves") { showShelfPicker() })
        col.addView(settingRow2("", "Reorder shelves", "Set the order they show on Home") { showShelfReorder() })
        col.addView(settingRow2("", "Blur unwatched episode images", if (Store.blurUnwatched(this)) "On" else "Off") {
            Store.setBlurUnwatched(this, !Store.blurUnwatched(this)); showSettings()
        })
        col.addView(settingRow2("", "Show titles under posters", if (Store.showTitles(this)) "On" else "Off") {
            Store.setShowTitles(this, !Store.showTitles(this)); showSettings()
        })
        // Player settings only exist when there's something to PLAY — until an addon is
        // added this app is a discovery + watch tracker, and the settings say so too.
        if (Store.addons(this).isNotEmpty()) {
            col.addView(settingRow2("", "Player", "") { showPlayerSettings() })
        }
        // Addons are an open account feature (Stremio-style): every signed-in user sees the
        // section; guests get a sign-in prompt inside. Who can actually stream = the addon
        // server's key check, never anything hidden in this app.
        col.addView(settingRow2("", "Addons",
            if (Store.signedIn(this)) "${Store.addons(this).size} added" else "sign in to add") { showAddons() })
        col.addView(settingRow2("", "Legal & About", "") { showAbout() })
        swap(scroll(col))
        // silent service-assignment refresh: an addon assigned after sign-in installs the
        // next time Settings opens (nobody ever pastes anything)
        if (Store.signedIn(this)) scope.launch {
            val before = Store.accessExpiry(this@MainActivity) to Store.accessDaysLeft(this@MainActivity)
            Addons.access(this@MainActivity, Store.account(this@MainActivity))?.let { acc ->
                Store.setAccessStatus(this@MainActivity, acc.expires, acc.daysLeft)
                val assigned = acc.assignedAddon
                if (assigned != null && Store.addons(this@MainActivity).isEmpty()) {
                    val nm = runCatching { Addons.probe(assigned)?.name }.getOrNull() ?: Dist.DEFAULT_ADDON_NAME
                    Store.addAddon(this@MainActivity, Addon(assigned, nm))
                    runCatching { detectLiveTv() }   // tab appears now, not on next relaunch
                    showSettings()
                } else if (before != acc.expires to acc.daysLeft) showSettings()   // expiry line just changed
            }
        }
    }

    /** Player page (subtitles / audio / playback) — only reachable when an addon is added. */
    private fun showPlayerSettings() {
        navStack.addLast { showSettings() }
        val col = column().apply { setPadding(dp(16)) }
        col.addView(iconBtn("‹") { onBackPressed() })
        col.addView(bigText("Player", 24f))
        col.addView(sectionText("SUBTITLES"))
        // live sample (Stremio-style): shows exactly what the options below produce
        col.addView(FrameLayout(this).apply {
            background = rounded(Color.BLACK, dp(10))
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(110)).apply { setMargins(0, dp(6), 0, dp(6)) }
            addView(TextView(this@MainActivity).apply {
                text = "This is what subtitles will look like"
                textSize = 15f * Store.subScale(this@MainActivity)
                setTextColor(Color.WHITE)
                if (Store.subOutline(this@MainActivity)) setShadowLayer(5f, 0f, 0f, Color.BLACK)
                if (Store.subBg(this@MainActivity)) setBackgroundColor(Color.parseColor("#B3000000"))
                setPadding(dp(8), dp(2), dp(8), dp(2))
                layoutParams = FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT,
                    Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM)
                    .apply { setMargins(0, 0, 0, dp(when (Store.subPos(this@MainActivity)) { 2 -> 46; 1 -> 26; else -> 10 })) }
            })
        })
        val sizes = listOf("Small" to 0.8f, "Normal" to 1.0f, "Large" to 1.3f, "Huge" to 1.6f)
        val curSize = sizes.firstOrNull { it.second == Store.subScale(this) } ?: sizes[1]
        col.addView(settingRow2("", "Subtitle size", curSize.first) {
            val next = sizes[(sizes.indexOf(curSize) + 1) % sizes.size]
            Store.setSubScale(this, next.second); showPlayerSettings()
        })
        // ONE switch (AJ: "either English or off, cmon") — appearance/audio prefs still
        // exist with sensible defaults (outline on, no box, normal position, English
        // audio), they just don't get settings rows anymore.
        col.addView(settingRow2("", "Subtitles", if (Store.subLang(this) == "off") "Off" else "English") {
            Store.setSubLang(this, if (Store.subLang(this) == "en") "off" else "en"); showPlayerSettings()
        })
        col.addView(sectionText("PLAYBACK"))
        col.addView(settingRow2("", "Autoplay next episode", if (Store.autoplayNext(this)) "On" else "Off") {
            Store.setAutoplayNext(this, !Store.autoplayNext(this)); showPlayerSettings()
        })
        col.addView(settingRow2("", "Seek step", "${Store.seekStepSec(this)}s") {
            val steps = listOf(5, 10, 15, 30)
            Store.setSeekStepSec(this, steps[(steps.indexOf(Store.seekStepSec(this)) + 1) % steps.size])
            showPlayerSettings()
        })
        swap(scroll(col))
    }

    private fun showAbout() {
        navStack.addLast { showSettings() }
        val col = column().apply { setPadding(dp(16)) }
        col.addView(iconBtn("‹") { onBackPressed() })
        col.addView(bigText("Legal & About", 24f))
        col.addView(settingRow2("", "Terms & Conditions", "") { showTerms() })
        col.addView(settingRow2("", "Privacy Policy", "") { showPrivacy() })
        col.addView(settingRow2("", "Version", try { packageManager.getPackageInfo(packageName, 0).versionName ?: "?" } catch (_: Exception) { "?" }) {})
        swap(scroll(col))
    }

    /** Home-shelf picker: grouped sections of pill chips that flip IN PLACE (no focus jump).
     *  For You is always on, so it doesn't appear here. */
    // Debounced save+push for shelves — the local save shows instantly on Home, the push (500ms
    // after the last change) carries the change to the account so the 60s live pull can't revert
    // it and every other device (TV/phone/web/desktop) gets it. (AJ Sep 15)
    private fun persistShelves(order: List<String>, jobRef: (kotlinx.coroutines.Job) -> Unit) {
        Store.setEnabledShelves(this, order.toList())
        jobRef(scope.launch { kotlinx.coroutines.delay(500); pushState() })
    }

    // Settings → "Shelves": pick which rows are on (numbered as you enable them). Reordering has
    // its OWN screen (showShelfReorder). onDone != null = first-run right after creating a
    // profile: the new profile only PICKS shelves here and can reorder later in Settings. (AJ Sep 15)
    private fun showShelfPicker(onDone: (() -> Unit)? = null) {
        if (onDone == null) navStack.addLast { showSettings() }
        val col = column().apply { setPadding(dp(16), if (isTv) dp(16) else statusBarPad(), dp(16), dp(16)) }
        if (onDone == null) col.addView(iconBtn("‹") { onBackPressed() })
        col.addView(bigText(if (onDone != null) "Pick your shelves" else "Shelves", 24f))
        col.addView(dimText("Turn rows on or off — the number shows where each one lands on Home. For You is always on." +
            (if (onDone != null) " You can reorder them later in Settings." else " Reorder them in Settings → Reorder shelves.")))
        val order = Store.enabledShelves(this).filter { lbl -> Discovery.SHELF_CATALOG.any { it.label == lbl && it.catalogId != "FORYOU" } }.toMutableList()
        var pushJob: kotlinx.coroutines.Job? = null
        fun persist() = persistShelves(order) { pushJob?.cancel(); pushJob = it }
        val chipPainters = ArrayList<() -> Unit>()
        fun repaintChips() = chipPainters.forEach { it() }
        fun chip(row: Discovery.Row): View {
            lateinit var paint: () -> Unit
            val v = TextView(this).apply {
                textSize = 14.5f; gravity = Gravity.CENTER
                setPadding(dp(10), dp(12), dp(10), dp(12))
                maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
                isClickable = true; isFocusable = true
                layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { setMargins(dp(3), dp(3), dp(3), dp(3)) }
            }
            paint = {
                val idx = order.indexOf(row.label); val on = idx >= 0
                v.text = if (on) "${idx + 1}. ${row.label}" else row.label   // numbered as you pick
                v.setTextColor(if (on) fg else dim)
                v.setTypeface(v.typeface, if (on) Typeface.BOLD else Typeface.NORMAL)
                v.background = selBg(if (on) accent else Color.parseColor("#241F3D"), 14)
            }
            v.setOnClickListener {
                if (row.label in order) order.remove(row.label) else order.add(row.label)
                persist(); repaintChips()   // renumber every chip in place
            }
            paint(); chipPainters.add(paint)
            return v
        }
        fun section(title: String, rows: List<Discovery.Row>) {
            if (rows.isEmpty()) return
            col.addView(sectionText(title))
            var line: LinearLayout? = null
            for ((i, r) in rows.withIndex()) {
                if (i % 2 == 0) { line = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; weightSum = 2f }; col.addView(line) }
                line!!.addView(chip(r))
            }
            if (rows.size % 2 == 1) line!!.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(0, 0, 1f) })
        }
        val providers = setOf("Netflix", "Hulu", "Disney+", "Max", "Prime Video", "Apple TV+", "Paramount+", "Peacock")
        val channels = setOf("Hallmark", "Hallmark New", "Hallmark Series", "Hallmark Christmas Movies",
            "Anime", "Anime Movies",
            "Marvel: Release Order", "Marvel: Chronological", "Marvel Movies", "Marvel Series", "X-Men Movies")
        val moods = setOf("Christmas Movies", "Halloween Movies", "Date Night", "True Crime",
            "Based on a True Story", "Classics", "90s Throwbacks", "Kids Movies", "Kids TV",
            "Superheroes", "Zombies", "Time Travel", "Feel-Good", "Tearjerkers",
            "Summer Blockbusters", "Fantasy Worlds", "War Movies", "Musicals", "Cozy Mystery Series")
        val genres = setOf("Action", "Comedy", "Horror", "Sci-Fi", "Romance", "Thriller",
            "Drama Series", "Crime Series", "Reality", "Documentary", "Family", "Westerns", "Mystery")
        val all = Discovery.SHELF_CATALOG.filter { it.catalogId != "FORYOU" }
        section("POPULAR & NEW", all.filter { it.label !in providers && it.label !in channels && it.label !in genres && it.label !in moods })
        section("MOODS & SEASONS", all.filter { it.label in moods })
        section("STREAMING SERVICES", all.filter { it.label in providers })
        section("CHANNELS & ANIME", all.filter { it.label in channels })
        section("GENRES", all.filter { it.label in genres })
        if (onDone != null) col.addView(pill("Start watching") { onDone() })
        else col.addView(settingRow2("", "Reorder shelves", "Arrange the order they show on Home") { showShelfReorder() })
        swap(scroll(col))
    }

    // Settings → "Reorder shelves": arrange enabled rows with ▲ ▼. The WHOLE row lights up when
    // focused so it's obvious which one you're moving, each row is numbered, and the change syncs
    // to every device. Easy for the d-pad (TV, where most people watch). (AJ Sep 15)
    private fun showShelfReorder() {
        navStack.addLast { showSettings() }
        val col = column().apply { setPadding(dp(16), if (isTv) dp(16) else statusBarPad(), dp(16), dp(16)) }
        col.addView(iconBtn("‹") { onBackPressed() })
        col.addView(bigText("Reorder shelves", 24f))
        col.addView(dimText("Move a shelf with ▲ ▼ — the whole row highlights so you know which one. This is the order they show on Home."))
        val order = Store.enabledShelves(this).filter { lbl -> Discovery.SHELF_CATALOG.any { it.label == lbl && it.catalogId != "FORYOU" } }.toMutableList()
        var pushJob: kotlinx.coroutines.Job? = null
        fun persist() = persistShelves(order) { pushJob?.cancel(); pushJob = it }
        val holder = column()
        fun render() {
            holder.removeAllViews()
            if (order.isEmpty()) { holder.addView(dimText("No shelves on yet — add some in Settings → Shelves.")); return }
            for ((i, label) in order.withIndex()) {
                holder.addView(LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(14), dp(11), dp(8), dp(11))
                    setAddStatesFromChildren(true)   // row shows its ▲/▼ child's focus = whole-row highlight
                    background = selBg(Color.parseColor("#241F3D"), 12)
                    layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(4), 0, dp(4)) }
                    addView(TextView(this@MainActivity).apply {
                        text = "${i + 1}.  $label"; setTextColor(fg); textSize = 15f
                        maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
                        layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
                    })
                    fun moveBtn(sym: String, on: Boolean, act: () -> Unit) = TextView(this@MainActivity).apply {
                        text = sym; textSize = 20f; gravity = Gravity.CENTER
                        setTextColor(if (on) fg else Color.parseColor("#443E66"))
                        setPadding(dp(16), dp(6), dp(16), dp(6)); background = selBg(Color.TRANSPARENT, 10)
                        isFocusable = on; isClickable = on
                        if (on) setOnClickListener { act() }
                    }
                    addView(moveBtn("▲", i > 0) {
                        java.util.Collections.swap(order, i, i - 1); persist(); render()
                        holder.post { runCatching { (holder.getChildAt(i - 1) as android.view.ViewGroup).let { it.getChildAt(it.childCount - 2) }.requestFocus() } }
                    })
                    addView(moveBtn("▼", i < order.size - 1) {
                        java.util.Collections.swap(order, i, i + 1); persist(); render()
                        holder.post { runCatching { (holder.getChildAt(i + 1) as android.view.ViewGroup).let { it.getChildAt(it.childCount - 1) }.requestFocus() } }
                    })
                })
            }
        }
        col.addView(holder); render()
        swap(scroll(col))
    }

    private fun showAddons() {
        val col = column().apply { setPadding(dp(16)) }
        col.addView(iconBtn("\u2039") { onBackPressed() })
        col.addView(bigText("Addons", 24f))

        if (!Store.signedIn(this)) {
            col.addView(dimText("Sign in to add addons and start streaming."))
            col.addView(pill("Sign in") { showSignIn() })
            swap(scroll(col)); return
        }

        // official built-ins (AJ Sep 13) — always active, not removable, Stremio-style listing
        col.addView(sectionText("OFFICIAL — BUILT IN"))
        col.addView(settingRow("Cinemeta", "Movie & show info · built in") {})
        col.addView(settingRow("OpenSubtitles v3", "Subtitles · built in") {})
        // Stremio-style: a plain list of your addons + a field to add one. The access code
        // from a welcome email just goes in this same field — nothing special to explain.
        col.addView(sectionText("YOUR ADDONS"))
        val installed = Store.addons(this)
        if (installed.isEmpty()) col.addView(dimText("Paste your addon code or URL below to start streaming."))
        for (a in installed) col.addView(settingRow(a.name, "Tap to remove") { Store.removeAddon(this, a.url); showAddons() })

        val input = field("Addon code or URL")
        col.addView(input)
        col.addView(pill("Add") {
            val v = input.text.toString().trim()
            if (v.isBlank()) { toast("Enter your addon code or URL"); return@pill }
            toast("Adding\u2026")
            scope.launch {
                // primary path: treat it as a service the account joins (installs the addon
                // assigned to this email — the key rides along, nobody pastes it)
                Store.setServiceBase(this@MainActivity, v)
                val r = Sync.joinService(this@MainActivity)
                if (r.ok) {
                    Sync.pullMerge(this@MainActivity)   // brings down your synced profiles + library
                    checkAccessThen {
                        if (Store.addons(this@MainActivity).isEmpty())
                            toast("Connected \u2014 you'll be enabled shortly")
                        else toast("Added")
                        // your real profiles just synced \u2014 show "Who's watching" if any exist
                        if (Store.profiles(this@MainActivity).isNotEmpty()) { profilePicked = false; profileGate() }
                        else showAddons()
                    }
                    return@launch
                }
                // fallback: a plain addon manifest URL (power users)
                Store.setServiceBase(this@MainActivity, "")
                val a = Addons.probe(v)
                if (a != null) { Store.addAddon(this@MainActivity, a); toast("Added")
                    runCatching { detectLiveTv() } }   // tab appears now, not on next relaunch
                else toast("Couldn't add that \u2014 check the code or URL")
                showAddons()
            }
        })

        col.addView(sectionText("OFFICIAL"))
        for (a in Store.OFFICIAL) col.addView(settingRow(a.name, "Included", {}))
        swap(scroll(col))
    }

    /** Ask the service whether this account is granted; auto-install its assigned addon. */
    private fun checkAccessThen(after: () -> Unit) {
        scope.launch {
            Addons.access(this@MainActivity, Store.account(this@MainActivity))?.let { acc ->
                Store.setAccessStatus(this@MainActivity, acc.expires, acc.daysLeft)
                val assigned = acc.assignedAddon
                if (assigned != null && Store.addons(this@MainActivity).isEmpty()) {
                    val nm = runCatching { Addons.probe(assigned)?.name }.getOrNull() ?: Dist.DEFAULT_ADDON_NAME
                    Store.addAddon(this@MainActivity, Addon(assigned, nm))
                    runCatching { detectLiveTv() }   // tab appears now, not on next relaunch
                }
            }
            after()
        }
    }

    // ---------- view helpers ----------
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun column() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
        clipChildren = false; clipToPadding = false
    }
    private fun scroll(v: View) = ScrollView(this).apply {
        addView(v); setBackgroundColor(bg); isFillViewport = true
        isVerticalScrollBarEnabled = false   // Stremio: no scrollbar rails anywhere
        clipChildren = false; clipToPadding = false
    }
    private fun horizScroll(v: View) = HorizontalScrollView(this).apply { addView(v); isHorizontalScrollBarEnabled = false }
    private fun lp(w: Int, h: Int, weight: Float) = LinearLayout.LayoutParams(w, h, weight)
    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply { setColor(color); cornerRadius = radius.toFloat() }

    /** Focus-first background: normal fill, but a bright ring + lift the moment it's focused —
     *  you can ALWAYS see where the cursor is on a TV remote. Used by every interactive view. */
    private fun selBg(color: Int, radius: Int, ring: Int = Color.WHITE): android.graphics.drawable.Drawable =
        android.graphics.drawable.StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), GradientDrawable().apply {
                setColor(if (color == Color.TRANSPARENT) Color.parseColor("#33FFFFFF") else color)
                cornerRadius = dp(radius).toFloat(); setStroke(dp(2), ring)
            })
            addState(intArrayOf(android.R.attr.state_pressed), GradientDrawable().apply {
                setColor(Color.parseColor("#4DFFFFFF")); cornerRadius = dp(radius).toFloat()
            })
            addState(intArrayOf(), GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() })
        }
    private fun bigText(t: String, size: Float) = TextView(this).apply { text = t; setTextColor(fg); textSize = size; setTypeface(typeface, Typeface.BOLD); setPadding(0, dp(8), 0, dp(6)) }

    /** Brand wordmark, site-style: "Couch" purple #a855f7 + "King" white #f0f0f5 —
     *  the same split the website nav has always used. */
    private fun brandSpan(text: String = "CouchKing"): CharSequence {
        val cut = text.indexOf("king", ignoreCase = true).takeIf { it > 0 } ?: return text
        val s = android.text.SpannableString(text)
        s.setSpan(android.text.style.ForegroundColorSpan(Color.parseColor("#A855F7")), 0, cut, 0)
        s.setSpan(android.text.style.ForegroundColorSpan(Color.parseColor("#F0F0F5")), cut, text.length, 0)
        return s
    }
    private fun dimText(t: String) = TextView(this).apply { text = t; setTextColor(dim); setPadding(0, dp(4), 0, dp(4)) }
    private fun sectionText(t: String) = TextView(this).apply { text = t; setTextColor(fg); textSize = 16f; setTypeface(typeface, Typeface.BOLD); setPadding(0, dp(14), 0, dp(6)) }
    private fun field(hintText: String) = EditText(this).apply {
        hint = hintText; setTextColor(fg); setHintTextColor(Color.GRAY)
        background = selBg(card, 8, accent); setPadding(dp(12)); setSingleLine()
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(6), 0, dp(6)) }
    }
    private fun pill(t: String, onClick: () -> Unit) = Button(this).apply {
        text = t; setTextColor(fg); isAllCaps = false; background = selBg(accent, 24); setPadding(dp(20), dp(10), dp(20), dp(10))
        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(6), dp(10), dp(6)) }
        stateListAnimator = null; setOnClickListener { onClick() }
    }
    private fun ghostPill(t: String, onClick: () -> Unit) = Button(this).apply {
        text = t; setTextColor(fg); isAllCaps = false
        background = selBg(Color.parseColor("#2C2649"), 24)
        setPadding(dp(20), dp(10), dp(20), dp(10))
        layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { setMargins(0, dp(6), dp(10), dp(6)) }
        stateListAnimator = null; setOnClickListener { onClick() }
    }
    private fun iconBtn(t: String, onClick: () -> Unit) = Button(this).apply {
        text = t; setTextColor(fg); textSize = 18f; isAllCaps = false; background = selBg(Color.parseColor("#2C2649"), 20)
        layoutParams = LinearLayout.LayoutParams(dp(44), dp(44)); stateListAnimator = null; setOnClickListener { onClick() }
    }
    /** Stremio-style settings row: icon · label · value · chevron. */
    private fun settingRow2(icon: String, head: String, value: String, onClick: () -> Unit): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = rounded(card, dp(10)); setPadding(dp(14), dp(13), dp(14), dp(13))
            isClickable = true; isFocusable = true
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(4), 0, dp(4)) }
            if (icon.isNotBlank()) addView(TextView(this@MainActivity).apply { text = icon; textSize = 17f; setPadding(0, 0, dp(12), 0) })
            addView(TextView(this@MainActivity).apply { text = head; setTextColor(fg); textSize = 16f }, lp(0, WRAP_CONTENT, 1f))
            if (value.isNotBlank()) addView(TextView(this@MainActivity).apply { text = value; setTextColor(dim); textSize = 14f; setPadding(0, 0, dp(8), 0) })
            addView(TextView(this@MainActivity).apply { text = "›"; setTextColor(dim); textSize = 18f })
            setOnClickListener { onClick() }
            setOnFocusChangeListener { v, has -> v.background = rounded(if (has) Color.parseColor("#2C2649") else card, dp(10)) }
        }

    private fun settingRow(head: String, sub: String, onClick: () -> Unit): View = column().apply {
        background = rounded(card, dp(10)); setPadding(dp(14)); isClickable = true; isFocusable = true
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { setMargins(0, dp(5), 0, dp(5)) }
        addView(TextView(this@MainActivity).apply { text = head; setTextColor(fg); textSize = 17f })
        if (sub.isNotBlank()) addView(TextView(this@MainActivity).apply { text = sub; setTextColor(dim); textSize = 13f })
        setOnClickListener { onClick() }
    }
    private fun toast(t: String) = Toast.makeText(this, t, Toast.LENGTH_SHORT).show()
}
