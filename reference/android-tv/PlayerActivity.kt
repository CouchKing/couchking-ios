package app.mediaboard

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.KeyEvent
import android.view.View
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.doOnPreDraw
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.NextRenderersFactory
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * The full CouchKing Player, ported whole from the standalone app: custom controller,
 * episode drawer with season tabs, learned skip-intro, credits-timed next-up card with
 * prefetched instant switching, caching-placeholder patience, frame-rate matching,
 * ffmpeg audio fallback, stats overlay, clock + ends-at, cross-device resume.
 */
@SuppressLint("UnsafeOptInUsageError")
class PlayerActivity : Activity() {

    private lateinit var playerView: PlayerView
    private lateinit var screenSubs: androidx.media3.ui.SubtitleView
    private var player: ExoPlayer? = null
    private val scope = CoroutineScope(Dispatchers.Main + Job())
    private val ui = Handler(Looper.getMainLooper())

    // Episode context parsed from the service stream URL (?i=&s=&e=) — self-configuring.
    private var ctx: Ck.StreamCtx? = null
    private var episodes: List<Ck.Episode> = emptyList()
    private var showName: String = ""

    private lateinit var clockText: TextView
    private lateinit var endsText: TextView
    // LIVE TV (AJ Sep 24: "doesn't say LIVE in the corner … just 2 of the same times"):
    // at the live edge position == duration, so the time row read as nonsense. Web already
    // shows 🔴 LIVE + clock — native mirrors it (badge replaces times/seek, no "Ends at").
    private var liveMode = false
    private lateinit var titleText: TextView
    private lateinit var nextBtn: View
    private lateinit var listBtn: View
    private lateinit var episodePanel: View
    private lateinit var episodeRecycler: RecyclerView
    private lateinit var episodeStatus: TextView
    private lateinit var seasonTabs: android.widget.LinearLayout
    private lateinit var seasonTabsScroll: View
    private var shownSeason: Int? = null
    private lateinit var nextUpPanel: View
    private lateinit var nextUpText: TextView
    private lateinit var subSidePanel: View
    private lateinit var subSideList: android.widget.LinearLayout
    // LIVE TV mini guide (AJ Sep 26): web player's Guide panel, native — see setupLiveUi()
    private lateinit var liveGuidePanel: View
    private lateinit var liveGuideList: android.widget.LinearLayout
    private var liveAddon = ""          // addon base → /stream/tv/{id}.json for channel hops
    private var liveBase = ""           // {host}/live/{key} → guide.json / games.json / fav
    private var liveChId = ""           // channel currently ON (cklive:… id)
    private var liveProf = ""           // profile the favs belong to
    private var liveReg = ""            // "" = USA
    private var lvGuideJson: org.json.JSONObject? = null
    private var lvGuideAt = 0L
    private var liveTuning = false
    private val lvRowPainters = mutableListOf<() -> Unit>()
    // panel liveness (AJ Sep 26 "the whole mini guide will update with whats playing?"):
    // now-lines re-derive from the loaded listings every minute IN PLACE (no rebuild, no
    // focus jump, no size change — the panel NEVER shifts); every OPEN refetches fresh
    private val lvNowUpdaters = mutableListOf<() -> Unit>()
    private var lvTickGen = 0
    private lateinit var statsText: TextView
    private var nextUpCountdown: Runnable? = null
    private lateinit var skipIntroBtn: android.widget.Button
    private var creditsLeadMs = 65_000L
    private var learnedCredits = false
    private var lastSubCueMs = -1L
    private var introFrom = -1L
    private var introTo = -1L
    private var introHandled = false
    private var recapFrom = -1L
    private var recapTo = -1L
    private var recapHandled = false
    private val afterCredits = mutableListOf<Pair<Long, Long>>()
    private var pendingAfterSeek = -1L
    private var skipMode = "intro"
    private var pendingIntroFrom: Long? = null
    private var pendingIntroTo: Long? = null
    private var pendingIntroAt = 0L
    private var squelchIntroObserve = false
    private var lastSkipPressAt = 0L
    private var prefetchedNext: Ck.Resolved? = null
    private var prefetchedAt = 0L
    private var prefetching = false
    private var prefetchRetryAt = 0L
    private var placeholderMode = false
    private var placeholderCheckAt = 0L
    // "ARE YOU STILL WATCHING?" (AJ Sep 25: "if 2 episodes go past with 0 button inputs…
    // so it doesn't just continue through all night — but I don't want it popping up any
    // other time on accident"). epTouched flips on ANY key or touch and resets when an
    // episode starts; an episode that plays END-TO-END with zero inputs bumps idleEps,
    // any touched episode zeroes it. Only the natural-end auto-advance path ever checks
    // it, so pausing, seeking, picking subs, or clicking Play Now can never summon it.
    private var idleEps = 0
    private var epTouched = false
    private var stillWatchingDialog: android.app.Dialog? = null
    // OFFLINE PLAY (full flavor; Downloads is a compile-time-false stub on store builds):
    // the media is a local file and everything the network normally supplies — subtitles,
    // intro/credits windows — rode in on the intent, captured at download time. Every
    // network fetch this player does on startup is skipped when this is set.
    private var offlinePlay = false
    private var currentUrl: String? = null
    private var currentSubs: List<Ck.Sub> = emptyList()
    // controller chrome state mirrored from the visibility listener — BACK handling needs
    // a deterministic answer even mid show/hide animation (isControllerFullyVisible is
    // false while animating, which made a BACK press vanish into nothing)
    private var chromeUp = false

    /** Phones/tablets: true immersive fullscreen — status + nav bars gone, swipe peeks them. */
    private fun goImmersive() {
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(android.view.WindowInsets.Type.statusBars() or android.view.WindowInsets.Type.navigationBars())
                it.systemBarsBehavior = android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else @Suppress("DEPRECATION") {
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) goImmersive()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        CrashGuard.install(this)
        try { goImmersive() } catch (_: Exception) {}
        // KEEP THE SCREEN AWAKE while the player is up (AJ Sep 18: "even though I have Live TV
        // playing my phone keeps trying to go to sleep"). playerView.keepScreenOn (a VIEW flag)
        // is reset by media3's PlayerView on every buffering pass — a live HLS stream rebuffers
        // constantly, so it kept lapsing and the phone dozed. A WINDOW flag can't be reset by
        // the view and holds for the whole player session (cleared automatically on finish).
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_player)
        playerView = findViewById(R.id.player_view)
        // SCREEN-ANCHORED SUBTITLES (AJ Sep 13: "changing the aspect ratio cuts off the
        // subtitles, I hate it"): the built-in SubtitleView lives inside the video frame, so
        // Fill/Zoom crops it off-screen with the picture. This overlay is a sibling of the
        // PlayerView — anchored to the SCREEN, identical in every scale mode.
        screenSubs = androidx.media3.ui.SubtitleView(this).apply {
            layoutParams = android.widget.FrameLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT)
        }
        (playerView.parent as? android.view.ViewGroup)?.let { pv ->
            pv.addView(screenSubs, pv.indexOfChild(playerView) + 1)
        }
        playerView.subtitleView?.visibility = View.GONE
        applyScale()   // restore the user's chosen screen fit (Fit / Fill / Stretch)
        clockText = findViewById(R.id.clock)
        endsText = findViewById(R.id.ends_at)
        titleText = findViewById(R.id.video_title)
        nextBtn = findViewById(R.id.btn_next)
        listBtn = findViewById(R.id.btn_episodes)
        episodePanel = findViewById(R.id.episode_panel)
        episodeRecycler = findViewById(R.id.episode_recycler)
        episodeStatus = findViewById(R.id.episode_status)
        seasonTabs = findViewById(R.id.season_tabs)
        seasonTabsScroll = findViewById(R.id.season_tabs_scroll)
        nextUpPanel = findViewById(R.id.next_up_panel)
        nextUpText = findViewById(R.id.next_up_text)
        subSidePanel = findViewById(R.id.sub_side_panel)
        subSideList = findViewById(R.id.sub_side_list)
        liveGuidePanel = findViewById(R.id.live_guide_panel)
        liveGuideList = findViewById(R.id.live_guide_list)
        episodeRecycler.layoutManager = LinearLayoutManager(this)

        statsText = findViewById(R.id.stats_text)
        // D-pad left/right on the bar: fixed 10s per press (media3 default is duration/20)
        playerView.findViewById<androidx.media3.ui.DefaultTimeBar>(androidx.media3.ui.R.id.exo_progress)
            ?.setKeyTimeIncrement(Store.seekStepSec(this) * 1000L)
        liveMode = intent?.getStringExtra("id") == "live"
        if (liveMode) {
            // live channel: times + seek bar are meaningless — 🔴 LIVE badge in their row
            // (web-player parity; the top-overlay clock already covers "what time is it")
            listOf(androidx.media3.ui.R.id.exo_position, androidx.media3.ui.R.id.exo_duration,
                androidx.media3.ui.R.id.exo_progress, androidx.media3.ui.R.id.exo_rew,
                androidx.media3.ui.R.id.exo_ffwd)
                .forEach { playerView.findViewById<View>(it)?.visibility = View.GONE }
            findViewById<View>(R.id.btn_speed)?.let { (it.parent as? View ?: it).visibility = View.GONE }
            (playerView.findViewById<View>(androidx.media3.ui.R.id.exo_position)?.parent
                as? android.view.ViewGroup)?.addView(TextView(this).apply {
                    text = "🔴 LIVE"; setTextColor(android.graphics.Color.WHITE); textSize = 14f
                    setPadding(0, 0, (8 * resources.displayMetrics.density).toInt(), 0)
                }, 0)
        }
        val topOverlay = findViewById<View>(R.id.top_overlay)
        playerView.setControllerVisibilityListener(
            PlayerView.ControllerVisibilityListener { v ->
                // ALL player chrome appears and disappears together (AJ)
                topOverlay.visibility = v
                chromeUp = v == View.VISIBLE
                // AJ Sep 15: land the cursor ON THE SEEK BAR when the controls come up, so
                // LEFT/RIGHT scrubs the instant the bar appears (center still toggles play/pause
                // — see the onTimeBar branch in dispatchKeyEvent). Falls back to play/pause if the
                // time bar isn't there yet.
                // …UNLESS the captions panel is open — it owns the cursor then, and letting
                // the controller grab the seek bar is exactly what yanked focus off the
                // caption rows (AJ Sep 15: "cursor goes back to the scroll bar").
                val subOpen = (::subSidePanel.isInitialized && subSidePanel.visibility == View.VISIBLE) ||
                    (::liveGuidePanel.isInitialized && liveGuidePanel.visibility == View.VISIBLE)
                if (v == View.VISIBLE && isTvDevice && !subOpen)
                    (playerView.findViewById<View>(androidx.media3.ui.R.id.exo_progress)
                        ?.takeIf { it.visibility == View.VISIBLE }   // live hides the seek bar
                        ?: playerView.findViewById<View>(androidx.media3.ui.R.id.exo_play_pause))?.requestFocus()
            })
        // the CC button opens OUR picker: media3's built-in "None" only clears the track
        // overrides and never disables the text renderer, so with a preferred subtitle
        // language set, "off" silently re-selected a track and never stuck
        findViewById<View>(R.id.btn_subs)?.setOnClickListener { showSubtitleSidePanel() }
        findViewById<View>(R.id.btn_audio)?.setOnClickListener { showAudioPicker() }
        findViewById<View>(R.id.btn_speed)?.setOnClickListener { showSpeedPicker() }
        // (AJ verdict on the labeled row: "you might not need words but it looks stupid" —
        // back to clean centered icons; all the new pickers stay)
        findViewById<View>(R.id.btn_back)?.setOnClickListener { @Suppress("DEPRECATION") onBackPressed() }
        nextBtn.setOnClickListener { playNext(auto = false) }
        listBtn.setOnClickListener { toggleEpisodePanel() }
        findViewById<View>(R.id.btn_info)?.setOnClickListener {
            statsText.visibility = if (statsText.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        }
        findViewById<View>(R.id.btn_subsize)?.setOnClickListener { cycleSubSize() }
        findViewById<View>(R.id.btn_scale)?.setOnClickListener { cycleScale() }
        // Pop-out (Picture-in-Picture) — MOBILE ONLY, never the Firestick/TV UI. (Casting on
        // Android is handled by the phone's own screen mirroring / Smart View, not in-app. AJ Sep 27.)
        if (!isTvDevice) {
            val pipOk = android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
                packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)
            if (pipOk) findViewById<View>(R.id.btn_pip)?.apply {
                visibility = View.VISIBLE
                setOnClickListener { runCatching { enterPip() } }
            }
        }
        // live channels: Next/Episodes make no sense — those two slots become ★ Favorite
        // and Guide (the mini guide panel). Must run AFTER the default click wiring above.
        if (liveMode) setupLiveUi()
        // center transport = play/pause (both) + ±10s skip. On TV drop the skip buttons —
        // the remote already fast-forwards, leaving just the center play/pause (AJ).
        if (isTvDevice) {
            findViewById<View>(androidx.media3.ui.R.id.exo_rew)?.visibility = View.GONE
            findViewById<View>(androidx.media3.ui.R.id.exo_ffwd)?.visibility = View.GONE
        }
        findViewById<View>(R.id.next_up_cancel).setOnClickListener { hideNextUp() }
        findViewById<View>(R.id.next_up_play).setOnClickListener { playNext(auto = false) }
        skipIntroBtn = findViewById(R.id.btn_skip_intro)
        skipIntroBtn.setOnClickListener {
            // one button, two jobs (Sep 13): during a chapter-verified recap window it reads
            // "Skip Recap" and jumps past the recap; otherwise it's the intro skip as ever
            if (skipMode == "aftercredits" && pendingAfterSeek > 0) {
                squelchIntroObserve = true
                player?.seekTo(pendingAfterSeek)
                ui.post { squelchIntroObserve = false }
            } else if (skipMode == "recap" && recapTo > 0) {
                squelchIntroObserve = true
                player?.seekTo(recapTo)
                ui.post { squelchIntroObserve = false }
                recapHandled = true
            } else {
                if (introTo > 0) {
                    squelchIntroObserve = true
                    player?.seekTo(introTo)
                    ui.post { squelchIntroObserve = false }
                    lastSkipPressAt = android.os.SystemClock.elapsedRealtime()
                }
                introHandled = true
            }
            skipIntroBtn.visibility = View.GONE
            playerView.requestFocus()
        }

        buildLoadingScreen()
        val url = intent?.data?.toString() ?: intent?.getStringExtra("url")
        if (url == null) { finish(); return }
        start(url, intent?.getStringExtra("title"))
        // update prompt inside the player (sideload builds only; Updater no-ops for stores)
        val upd = findViewById<android.widget.Button>(R.id.btn_player_update)
        Updater.check(this) { u ->
            upd.text = "⬆ Update to v${u.version} — press to install"
            upd.visibility = View.VISIBLE
            upd.setOnClickListener {
                player?.pause()
                Updater.downloadAndInstall(this, u) { s -> upd.text = s }
            }
            ui.postDelayed({ if (upd.text.startsWith("⬆")) upd.visibility = View.GONE }, 15_000)
        }
    }

    // Stremio-style loading screen: the title's art + name + spinner over black while the
    // stream spins up; fades out on the first READY state.
    private var loadingOverlay: View? = null

    private fun buildLoadingScreen(liveLogo: String? = null, liveTitle: String? = null) {
        // a fast channel hop can stack a new overlay on one still fading/waiting — the buried
        // one then survives underneath showing the OLD channel's logo (AJ Sep 26). One overlay, ever.
        loadingOverlay?.let { (it.parent as? android.view.ViewGroup)?.removeView(it); loadingOverlay = null }
        val rootV = playerView.parent as? android.widget.FrameLayout ?: return
        // retune (liveTitle != null): logo/title come EXPLICITLY from the clicked guide row —
        // never from the launch intent, which holds the first channel of the session
        val retune = liveTitle != null
        val ov = android.widget.FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            layoutParams = android.widget.FrameLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT)
        }
        if (!retune) intent?.getStringExtra("backdrop")?.let { bd ->
            ov.addView(android.widget.ImageView(this).apply {
                layoutParams = android.widget.FrameLayout.LayoutParams(
                    android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT)
                scaleType = android.widget.ImageView.ScaleType.CENTER_CROP; alpha = 0.35f
                coil.Coil.imageLoader(this@PlayerActivity).enqueue(
                    coil.request.ImageRequest.Builder(this@PlayerActivity).data(bd).target(this).build())
            })
        }
        val col = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER
            layoutParams = android.widget.FrameLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT)
        }
        val d = resources.displayMetrics.density
        val logoUrl = (if (retune) liveLogo else intent?.getStringExtra("logo"))?.ifBlank { null }
        val pulseTarget: View = if (logoUrl != null) {
            // Stremio's loading: just the show's logo, breathing, over the dimmed art
            android.widget.ImageView(this).apply {
                adjustViewBounds = true
                scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
                layoutParams = android.widget.LinearLayout.LayoutParams(
                    (320 * d).toInt(), (120 * d).toInt())
                coil.Coil.imageLoader(this@PlayerActivity).enqueue(
                    coil.request.ImageRequest.Builder(this@PlayerActivity).data(logoUrl).target(this).build())
            }
        } else TextView(this).apply {
            text = liveTitle ?: intent?.getStringExtra("title") ?: ""
            setTextColor(0xFFFFFFFF.toInt()); textSize = 26f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = android.view.Gravity.CENTER
            setShadowLayer(8f, 0f, 0f, 0xFF000000.toInt())
        }
        col.addView(pulseTarget)
        android.animation.ObjectAnimator.ofFloat(pulseTarget, "alpha", 1f, 0.3f).apply {
            duration = 800
            repeatCount = android.animation.ValueAnimator.INFINITE
            repeatMode = android.animation.ValueAnimator.REVERSE
        }.start()
        if (logoUrl == null) col.addView(android.widget.ProgressBar(this).apply {
            layoutParams = android.widget.LinearLayout.LayoutParams(
                (56 * d).toInt(), (56 * d).toInt())
                .apply { topMargin = (18 * d).toInt() }
        })
        ov.addView(col)
        rootV.addView(ov)
        loadingOverlay = ov
    }

    private fun hideLoadingScreen() {
        loadingOverlay?.let { ov ->
            loadingOverlay = null
            ov.animate().alpha(0f).setDuration(350).withEndAction {
                (ov.parent as? android.view.ViewGroup)?.removeView(ov)
            }.start()
        }
    }

    private fun start(url: String, intentTitle: String?) {
        ctx = Ck.parse(url)
        offlinePlay = Downloads.ENABLED && intent?.getBooleanExtra("offline", false) == true
        // season packs sometimes hand URLs without s/e — the launcher's id ("tt:1:2") is
        // authoritative; without this, E2 inherited E1's resume key AND its server position
        val idExtra = intent?.getStringExtra("id") ?: ""
        Regex("^(tt\\d+):(\\d+):(\\d+)$").find(idExtra)?.let { mm ->
            val c = ctx
            if (c == null || c.season == null)
                ctx = Ck.StreamCtx(c?.site, c?.subKey, mm.groupValues[1],
                    mm.groupValues[2].toInt(), mm.groupValues[3].toInt(), c?.title ?: intentTitle, c?.user)
        }
        // offline MOVIES: a file:// URL carries no ?i=, so ctx would stay null and every
        // position write would silently no-op — synthesize a bare-imdb ctx so Store.pos
        // uses the SAME key as online plays (positions sync out once the phone's back on
        // the internet; the beacons themselves already fail silently without a network)
        if (offlinePlay && ctx == null && Regex("^tt\\d+$").matches(idExtra))
            ctx = Ck.StreamCtx(null, null, idExtra, null, null, intentTitle, null)
        ctx?.let { Ck.saveKey(this, it) }
        // the episode actually on screen IS the show's continue pointer (AJ Sep 10) — keep it
        // fresh here and on every in-player switch so "Resume" never lands on a stale episode.
        ctx?.let { if (it.season != null) Store.setCwLast(this, it.imdbId, it.epId) }
        // after-credits scene check (AJ Sep 13): TMDB's stinger keywords are community-kept
        // and accurate — near the credits we tell the viewer to keep watching
        stingerShown = false; stingerKind = null
        if (!offlinePlay) ctx?.let { c -> if (c.season == null) scope.launch {
            stingerKind = runCatching { Discovery.movieStinger(c.imdbId) }.getOrNull()
        } }
        titleText.text = ctx?.title ?: intentTitle ?: ""
        // addon-delivered subs (server-matched) first, then OpenSubtitles v3 extras — capped
        // at 1.5s so the fetch can never delay first frame noticeably
        val addonSubs = ArrayList<Ck.Sub>()
        try {
            val sj = org.json.JSONArray(intent?.getStringExtra("subs") ?: "[]")
            for (i in 0 until sj.length()) {
                val o = sj.getJSONObject(i)
                if (o.optString("url").isNotBlank())
                    addonSubs.add(Ck.Sub(o.getString("url"), o.optString("name", "English")))
            }
        } catch (_: Exception) {}
        val resume = Ck.resumeFor(this, ctx?.epId ?: intent?.getStringExtra("id") ?: url)
        val c = ctx
        if (offlinePlay) {
            // downloaded .srt files sideload straight off disk; NO v3Subs/serverState
            // fetch — this path must reach first frame instantly in airplane mode
            val local = (intent?.getStringArrayListExtra("subPaths") ?: arrayListOf())
                .mapIndexed { i, p -> Ck.Sub(Uri.fromFile(java.io.File(p)).toString(),
                    "English (downloaded ${i + 1})") }
            initPlayer(url, resumeMs = resume, subs = local)
            // intro/credits windows were learned AT DOWNLOAD TIME and ride the intent —
            // they replace the serverState fetch initPlayer skips for offline plays
            introFrom = intent?.getLongExtra("introFrom", -1L)?.takeIf { it > 0 } ?: -1L
            introTo = intent?.getLongExtra("introTo", -1L)?.takeIf { it > 0 } ?: -1L
            intent?.getStringExtra("afterCreditsList")?.split(",")?.forEach { w ->
                val ft = w.split(":"); val f = ft.getOrNull(0)?.toLongOrNull(); val t = ft.getOrNull(1)?.toLongOrNull()
                if (f != null && t != null && t > f) afterCredits.add(f to t)
            }
            (intent?.getLongExtra("credits", 0L) ?: 0L).takeIf { it > 0 }?.let {
                creditsLeadMs = (it + 5_000).coerceIn(20_000, 240_000); learnedCredits = true
            }
            // the drawer/Next-Up still work when the device HAPPENS to be online (Cinemeta
            // fetch); offline it fails quietly and the buttons just don't light up
            loadEpisodes()
            return
        }
        scope.launch {
            val extra = if (c != null) kotlinx.coroutines.withTimeoutOrNull(1500) {
                withContext(Dispatchers.IO) { Ck.v3Subs(c.imdbId, c.season, c.episode) }
            } ?: emptyList() else emptyList()
            // v3 extras that duplicate a ranked URL are dropped — same feed, same file
            initPlayer(url, resumeMs = resume,
                subs = addonSubs + extra.filter { e -> addonSubs.none { a -> a.url == e.url } })
            loadEpisodes()
        }
    }

    // names of the sideloaded (addon/OpenSubtitles) tracks — the picker uses this to
    // order the list: in-video tracks first, then these, keeping the addon's rank order
    private var sideSubNames: Set<String> = emptySet()

    private fun initPlayer(url: String, resumeMs: Long, subs: List<Ck.Sub> = emptyList()) {
        sideSubNames = subs.map { it.name }.toSet()
        // Save + sync the OUTGOING episode before switching.
        releasePlayer(saveResume = true)
        // Hardware decoding first, ffmpeg software fallback (EAC3/DTS on non-Dolby devices).
        val renderers = object : NextRenderersFactory(this@PlayerActivity) {
            override fun buildAudioSink(
                context: Context, enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean
            ): androidx.media3.exoplayer.audio.AudioSink {
                // No Dolby passthrough: we decode to PCM in-app so playback speed works
                // everywhere. But we must advertise the REAL device/AVR capabilities — pinning
                // DEFAULT (stereo-only) force-downmixed every 5.1 track to 2.0, which is why
                // surround sounded wrong on some streams. getCapabilities() lets multichannel
                // PCM pass out to the receiver over HDMI while STILL decoding (speed intact).
                return androidx.media3.exoplayer.audio.DefaultAudioSink.Builder(context)
                    .setEnableFloatOutput(enableFloatOutput)
                    .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                    .setAudioCapabilities(
                        androidx.media3.exoplayer.audio.AudioCapabilities.getCapabilities(context))
                    .build()
            }
        }
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)
        // Subtitles: white text, thin outline, no background box (on the screen-anchored view).
        screenSubs.setStyle(CaptionStyleCompat(
            0xFFFFFFFF.toInt(),
            if (Store.subBg(this)) 0xB3000000.toInt() else 0x00000000,
            0x00000000,
            if (Store.subOutline(this)) CaptionStyleCompat.EDGE_TYPE_OUTLINE else CaptionStyleCompat.EDGE_TYPE_NONE,
            0xFF000000.toInt(), null))
        screenSubs.setBottomPaddingFraction(
            when (Store.subPos(this)) { 2 -> 0.26f; 1 -> 0.16f; else -> 0.08f })
        screenSubs.setApplyEmbeddedStyles(false)
        applySubScale()
        val seekMs = Store.seekStepSec(this) * 1000L
        // FIRE TV SNAPPINESS: media3's default waits 2500ms of buffer before it starts a video,
        // 5000ms after a rebuffer — that's the "laggy when you load it up / switch episodes"
        // stall. Netflix/Stremio start almost instantly by beginning on a tiny buffer, then
        // filling. Start on ~1s (2s after a stall) while still keeping a healthy 30-50s working
        // buffer so mid-play doesn't stutter. prioritizeTimeOverSize = start on wall-clock, not
        // a byte count (a 4K stream needs far fewer ms to look ready).
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(30_000, 50_000, 1_000, 2_000)
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        val p = ExoPlayer.Builder(this, renderers)
            .setLoadControl(loadControl)
            .setVideoChangeFrameRateStrategy(C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS)
            .setSeekBackIncrementMs(seekMs).setSeekForwardIncrementMs(seekMs)
            .build()
        // Honor the app's Player settings (subs on/off, preferred audio); English default,
        // MULTi files start on the English track, all switchable in the controller.
        // Subs auto-enable ONLY when an English/eng-labeled track exists — undetermined/
        // "unknown" tracks are NEVER auto-selected (a Chinese track labeled "unknown" was
        // getting picked on titles with no English subs); no English = subs start OFF.
        val subsOff = Store.subLang(this) == "off"
        val audioPref = Store.audioLang(this)
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setPreferredTextLanguage(if (subsOff) null else "en")
            .setSelectUndeterminedTextLanguage(false)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, subsOff)
            .setPreferredAudioLanguage(if (audioPref == "orig") null else audioPref)
            .build()
        player = p
        playerView.player = p
        playerView.keepScreenOn = true

        val mi = MediaItem.Builder().setUri(url).setSubtitleConfigurations(subs.map {
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(it.url))
                .setMimeType(MimeTypes.APPLICATION_SUBRIP)
                .setLanguage("en").setLabel(it.name).build()
        }).build()
        p.setMediaItem(mi)
        p.addListener(object : Player.Listener {
            override fun onCues(cueGroup: androidx.media3.common.text.CueGroup) {
                screenSubs.setCues(cueGroup.cues)   // feed the screen-anchored overlay
            }
            override fun onTracksChanged(tracks: androidx.media3.common.Tracks) { matchFrameRate() }
            override fun onTrackSelectionParametersChanged(params: androidx.media3.common.TrackSelectionParameters) {
                // the CC button's choice STICKS across episodes and sessions (AJ):
                // picking "None" remembers subs-off; picking a track remembers subs-on
                val off = params.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)
                if (off != (Store.subLang(this@PlayerActivity) == "off"))
                    Store.setSubLang(this@PlayerActivity, if (off) "off" else "en")
            }
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_READY) { hideLoadingScreen(); maybeDetectPlaceholder() }
                if (state == Player.STATE_ENDED) onEnded()
            }
            override fun onPlayerError(error: PlaybackException) {
                Toast.makeText(this@PlayerActivity,
                    "Playback error: " + (error.message ?: "unknown"), Toast.LENGTH_LONG).show()
            }
            override fun onPositionDiscontinuity(
                old: Player.PositionInfo, new: Player.PositionInfo, reason: Int
            ) {
                // a manual forward jump early in an episode = a human skipping the intro
                if (squelchIntroObserve || reason != Player.DISCONTINUITY_REASON_SEEK) return
                val jump = new.positionMs - old.positionMs
                val now = android.os.SystemClock.elapsedRealtime()
                if (jump in 2_000..240_000 && now - lastSkipPressAt < 45_000
                    && introFrom >= 0 && new.positionMs < 600_000) {
                    pendingIntroFrom = introFrom
                    pendingIntroTo = new.positionMs
                    pendingIntroAt = now
                    lastSkipPressAt = now
                } else if (old.positionMs < 600_000 && jump in 20_000..240_000) {
                    pendingIntroFrom = old.positionMs
                    pendingIntroTo = new.positionMs
                    pendingIntroAt = now
                } else if (jump < 0 && pendingIntroTo != null && now - pendingIntroAt < 45_000) {
                    val from = pendingIntroFrom ?: 0
                    if (new.positionMs > from + 15_000 && new.positionMs < (pendingIntroTo ?: 0)) {
                        pendingIntroTo = new.positionMs
                    } else if (new.positionMs <= from) {
                        pendingIntroFrom = null; pendingIntroTo = null
                    }
                }
            }
        })
        if (resumeMs > 15_000) p.seekTo(resumeMs)
        sessionStartPos = if (resumeMs > 15_000) resumeMs else 0L
        // the episode THIS player is actually playing (AJ Sep 18 false-finish): on an
        // episode switch, playEpisode sets the global ctx to the NEXT episode BEFORE
        // releasePlayer saves the outgoing one — so releasePlayer/markWatched were
        // stamping the finished episode's "watched" onto the one you just started.
        // playerCtx is pinned here, when the player for THIS episode is created.
        playerCtx = ctx
        p.prepare()
        p.play()
        tickers()
        creditsLeadMs = 65_000L; learnedCredits = false; lastSubCueMs = -1L
        introFrom = -1L; introTo = -1L; introHandled = false
        recapFrom = -1L; recapTo = -1L; recapHandled = false; skipMode = "intro"
        afterCredits.clear(); pendingAfterSeek = -1L
        placeholderMode = false; placeholderCheckAt = 0L
        currentUrl = url; currentSubs = subs
        val forCtx = ctx
        // per-episode-exact credits from the SRT's last cue
        if (subs.isNotEmpty()) scope.launch {
            val cue = withContext(Dispatchers.IO) { Ck.lastSrtCueMs(subs.first().url) }
            if (ctx === forCtx && cue > 0) lastSubCueMs = cue
        }
        // offline plays NEVER hit the resume endpoint — the intro/credits/position extras
        // captured at download time stand in (start() applies them right after this call)
        if (!offlinePlay) scope.launch {
            val st = withContext(Dispatchers.IO) { Ck.serverState(this@PlayerActivity, forCtx) }
                ?: return@launch
            if (ctx !== forCtx) return@launch
            st.optLong("credits").let {
                if (it > 0) { creditsLeadMs = (it + 5_000).coerceIn(20_000, 240_000); learnedCredits = true }
            }
            introFrom = st.optLong("introFrom", -1L)
            introTo = st.optLong("introTo", -1L)
            recapFrom = st.optLong("recapFrom", -1L)
            recapTo = st.optLong("recapTo", -1L)
            afterCredits.clear()
            st.optString("afterCreditsList", "").split(",").forEach { w ->
                val ft = w.split(":"); val f = ft.getOrNull(0)?.toLongOrNull(); val t = ft.getOrNull(1)?.toLongOrNull()
                if (f != null && t != null && t > f) afterCredits.add(f to t)
            }
            // cross-device resume: whichever device is FURTHER into the episode wins
            val sPos = st.optLong("pos"); val sDur = st.optLong("dur")
            val sameEp = st.optString("s") == (forCtx?.season?.toString() ?: "")
                    && st.optString("e") == (forCtx?.episode?.toString() ?: "")
            player?.let { pp ->
                val ahead = sPos > pp.currentPosition + 60_000
                if (sameEp && sPos > 60_000 && sDur - sPos > 120_000
                    && (resumeMs <= 15_000 || ahead)) {
                    squelchIntroObserve = true
                    pp.seekTo(sPos)
                    ui.post { squelchIntroObserve = false }
                    Toast.makeText(this@PlayerActivity, "Resuming where you left off", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    /** Just Player-style refresh-rate switch: pick the display mode closest to the video fps. */
    private fun matchFrameRate() = try { matchFrameRateInner() } catch (_: Exception) {}
    private fun matchFrameRateInner() {
        val fmt: Format = player?.videoFormat ?: return
        val fps = fmt.frameRate
        if (fps <= 0f) return
        @Suppress("DEPRECATION") val display: Display = windowManager.defaultDisplay ?: return
        val modes = display.supportedModes ?: return
        val current = display.mode
        var best: Display.Mode? = null
        var bestScore = Float.MAX_VALUE
        for (m in modes) {
            if (m.physicalWidth != current.physicalWidth || m.physicalHeight != current.physicalHeight) continue
            val r = m.refreshRate
            val mult = (r / fps).roundToLong().coerceAtLeast(1)
            val score = abs(r - fps * mult)
            if (score < bestScore - 0.01f || (abs(score - bestScore) < 0.01f && r > (best?.refreshRate ?: 0f))) {
                bestScore = score; best = m
            }
        }
        val target = best ?: return
        if (target.modeId != current.modeId && bestScore < 1f) {
            val lp = window.attributes
            lp.preferredDisplayModeId = target.modeId
            window.attributes = lp
        }
    }

    // ---- clock + "ends at" + credits-time next-up (never interrupts) ----
    private val fmt = SimpleDateFormat("h:mm a", Locale.US)
    private var nextUpShownFor: String? = null
    private val ticker = object : Runnable {
        override fun run() {
            clockText.text = fmt.format(Date())
            val p = player
            // live: a rolling HLS window reports a "duration", so "Ends 3:47 PM" showed
            // garbage — the clock alone is the truth for live
            if (p != null && p.duration > 0 && !liveMode) {
                val remaining = ((p.duration - p.currentPosition) / p.playbackParameters.speed).toLong()
                endsText.text = "Ends " + fmt.format(Date(System.currentTimeMillis() + remaining))
                endsText.visibility = if (placeholderMode) View.INVISIBLE else View.VISIBLE
                if (placeholderMode) {
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (now >= placeholderCheckAt) {
                        placeholderCheckAt = now + 20_000
                        val url = currentUrl; val cctx = ctx
                        if (url != null) scope.launch {
                            val still = withContext(Dispatchers.IO) { Ck.landsOnPlaceholder(url) }
                            if (!still && placeholderMode && ctx === cctx) {
                                placeholderMode = false
                                initPlayer(url, Ck.resumeFor(this@PlayerActivity, cctx?.epId ?: url), currentSubs)
                            }
                        }
                    }
                }
                val lead = currentLeadMs(p)
                val epKey = ctx?.epId
                // show Next-Up once we're into credits — by time-remaining OR by having crossed
                // the credits point (belt-and-suspenders so it never fails to pop up, AJ Sep 10)
                if (!placeholderMode && epKey != null && ctx?.season != null
                    && (remaining in 1..lead || p.currentPosition >= finishPointMs(p))
                    && nextUpShownFor != epKey && nextEpisode() != null) {
                    nextUpShownFor = epKey
                    showNextUpCard()
                }
                if (!placeholderMode && ctx?.season != null && remaining in 1..300_000) prefetchNext()
                // recap first (it sits before the intro): chapter-verified windows ONLY
                val inRecap = !placeholderMode && !recapHandled && recapFrom >= 0 && recapTo > recapFrom
                    && p.currentPosition in recapFrom..(recapTo - 2_000)
                val inIntro = !placeholderMode && !introHandled && introFrom >= 0 && introTo > introFrom
                    && p.currentPosition in introFrom..(introTo - 2_000)
                // after-credits (AJ Sep 16): during the credits, before a known post-credit scene,
                // a button that jumps straight to it — auto-focused like Skip Intro / Next-Up.
                val acPos = p.currentPosition
                val nextAc = afterCredits.firstOrNull { it.first > acPos + 1_500 }
                val prevEnd = afterCredits.filter { it.second <= acPos }.maxOfOrNull { it.second } ?: -1L
                val acFloor = if (nextAc != null) maxOf(finishPointMs(p), nextAc.first - 90_000L, prevEnd) else Long.MAX_VALUE
                val inAfter = !placeholderMode && nextAc != null && acPos >= acFloor && acPos < nextAc.first - 1_500
                if (inAfter) pendingAfterSeek = nextAc!!.first
                if (inRecap || inIntro || inAfter) {
                    skipMode = if (inRecap) "recap" else if (inAfter) "aftercredits" else "intro"
                    val acLabel = if (afterCredits.size > 1) "After credits ▶ (${afterCredits.indexOf(nextAc) + 1}/${afterCredits.size})" else "After credits ▶"
                    skipIntroBtn.text = when (skipMode) { "recap" -> "Skip Recap ⏭"; "aftercredits" -> acLabel; else -> "Skip Intro ⏭" }
                    if (skipIntroBtn.visibility != View.VISIBLE) {
                        skipIntroBtn.alpha = 0f
                        skipIntroBtn.translationY = 12f * resources.displayMetrics.density
                        skipIntroBtn.visibility = View.VISIBLE
                        skipIntroBtn.animate().alpha(1f).translationY(0f).setDuration(220)
                            .setInterpolator(android.view.animation.DecelerateInterpolator()).start()
                        // requestFocus() silently fails when the view hasn't been laid out this
                        // frame — post it so it lands after layout. Without this a single miss left
                        // OK bound to play/pause for the whole window (AJ Sep 21: "sometimes it
                        // pauses instead and I gotta scroll over to it").
                        skipIntroBtn.post {
                            if (skipIntroBtn.visibility == View.VISIBLE && !skipIntroBtn.hasFocus())
                                skipIntroBtn.requestFocus()
                        }
                    } else if (!skipIntroBtn.hasFocus() && !playerView.isControllerFullyVisible
                               && currentFocus.let { it == null || it === playerView || isInside(playerView, it) }) {
                        // still inside the skip window but focus never took (or drifted back to the
                        // video surface): re-grab so OK skips, not pauses. Guarded so we never yank
                        // focus off a control the user deliberately moved to.
                        skipIntroBtn.requestFocus()
                    }
                } else if (skipIntroBtn.visibility == View.VISIBLE) {
                    val hadFocus = skipIntroBtn.hasFocus()
                    skipIntroBtn.visibility = View.GONE
                    if (hadFocus) playerView.requestFocus()
                    if (skipMode == "recap") { if (recapTo > 0 && p.currentPosition >= recapTo - 2_000) recapHandled = true }
                    else if (skipMode == "aftercredits") { /* stateless: next stinger offered by position */ }
                    else if (p.currentPosition >= introTo - 2_000) introHandled = true
                }
            } else endsText.visibility = View.INVISIBLE
            if (statsText.visibility == View.VISIBLE) updateStats()
            // account heartbeat: first report ~20s in, then every 30s while playing
            beatCount++
            player?.let { pp ->
                if (pp.isPlaying && pp.duration > 0 && !placeholderMode) {
                    val ep = ctx?.epId
                    // INSTANT start-stamp (AJ Sep 13: "1 second, 2 seconds or half a second —
                    // if it starts to play it should sync"): the moment ANY episode begins,
                    // stamp its position locally AND push the account blob, so every other
                    // device immediately derives this episode as the resume target.
                    if (ep != null && ep != stampedStartEp) {
                        stampedStartEp = ep
                        Ck.saveResume(this@PlayerActivity, ep, maxOf(pp.currentPosition, 500), pp.duration)
                        Ck.homeStale = true
                        if (Store.signedIn(this@PlayerActivity))
                            Thread { try { kotlinx.coroutines.runBlocking { Sync.push(this@PlayerActivity) } } catch (_: Exception) {} }.start()
                    }
                    // zombie guard (AJ Sep 24): a stick stuck "playing" GoT with a frozen
                    // position heartbeated a fresh stamp every 30s for over a DAY — and that
                    // always-newest stamp pinned GoT to the front of CW on every device.
                    // No movement since the last beat = no save, no report, no push.
                    val moved = pp.currentPosition != lastBeatPos
                    if (ep != null && ep != firstReportedEp && pp.currentPosition >= 20_000) {
                        firstReportedEp = ep
                        Ck.reportServer(this@PlayerActivity, ctx, pp.currentPosition, pp.duration)
                    } else if (beatCount % 30 == 0 && moved) {
                        Ck.reportServer(this@PlayerActivity, ctx, pp.currentPosition, pp.duration)
                    }
                    // LIVE cross-device pickup (AJ): the local resume bar updates every 30s
                    // and the account blob rides up every 90s — opening the phone mid-episode
                    // shows where the TV is, not where last night ended
                    if (beatCount % 30 == 0 && pp.currentPosition >= 1_000 && moved) {
                        lastBeatPos = pp.currentPosition
                        Ck.saveResume(this@PlayerActivity, ctx?.epId, pp.currentPosition, pp.duration)
                    }
                    if (beatCount % 90 == 0 && Store.signedIn(this@PlayerActivity) && moved)
                        Thread { try { kotlinx.coroutines.runBlocking { Sync.push(this@PlayerActivity) } } catch (_: Exception) {} }.start()
                    // after-credits nudge: once, ~4 min from the end of a stinger movie
                    if (stingerKind != null && !stingerShown && ctx?.season == null
                        && pp.duration - pp.currentPosition in 1..240_000) {
                        stingerShown = true
                        val where = if (stingerKind == "during") "during the credits" else "after the credits"
                        android.widget.Toast.makeText(this@PlayerActivity,
                            "🎬 This movie has a scene $where — keep watching!",
                            android.widget.Toast.LENGTH_LONG).show()
                    }
                }
            }
            // PiP: flip the 3rd button to Next the moment we cross into the endgame (and back) so
            // Next appears without the viewer pressing anything (AJ Sep 28).
            if (inPip) {
                val pe = player
                val ne = pe != null && pe.duration > 0 && pe.currentPosition >= finishPointMs(pe)
                if (ne != lastPipNearEnd) { lastPipNearEnd = ne; refreshPipActions() }
            }
            ui.postDelayed(this, 1000)
        }
    }
    private var beatCount = 0
    private var lastBeatPos = -1L   // zombie guard: only a MOVING position beats/saves
    private var firstReportedEp: String? = null
    private var stampedStartEp: String? = null
    private var stingerKind: String? = null
    private var stingerShown = false
    private fun tickers() { ui.removeCallbacks(ticker); ui.post(ticker) }

    @Suppress("DEPRECATION")
    private fun updateStats() {
        val p = player ?: return
        val v = p.videoFormat; val a = p.audioFormat
        val hz = windowManager.defaultDisplay?.refreshRate ?: 0f
        val dropped = p.videoDecoderCounters?.droppedBufferCount ?: 0
        statsText.text = buildString {
            if (v != null) {
                append("${v.width}×${v.height}")
                if (v.frameRate > 0) append("  •  %.3f fps".format(v.frameRate))
                append("\nvideo: ").append(v.sampleMimeType?.removePrefix("video/") ?: "?")
            }
            if (a != null) append("\naudio: ").append(a.sampleMimeType?.removePrefix("audio/") ?: "?")
                .append("  ${a.channelCount}ch")
            append("\ndisplay: %.2f Hz".format(hz))
            append("\ndropped frames: $dropped")
        }
    }

    // ---- watched tracking: the tracker half of the app learns from real playback ----
    private var sessionStartPos = 0L
    private var playerCtx: Ck.StreamCtx? = null   // the episode the CURRENT player is playing

    /** How long before the end the credits start: learned per show → subtitle last-cue → 65s
     *  default, capped to the episode length. Drives BOTH the Next-Up card and the watched
     *  cutoff so they always agree. */
    private fun currentLeadMs(p: ExoPlayer): Long {
        val subsLead = if (lastSubCueMs > 0) p.duration - lastSubCueMs - 2_000 else -1L
        val lead = when {
            // last spoken line = content's over = where credits start. Pop Next-Up HERE so it's
            // already up the moment the episode ends, not deep in the credits (AJ Sep 10).
            subsLead in 15_000..300_000 -> subsLead
            learnedCredits -> creditsLeadMs
            else -> 90_000L                     // no signal: 90s before end (was 65s — too late)
        }
        return lead.coerceIn(0, p.duration)
    }
    /** Position where the episode/movie is "basically over" (credits rolling). AJ Sep 10: only the
     *  REAL end counts as watched — a few minutes left keeps the resume bar. Floored at 80%.
     *  CAP (AJ Sep 28): also bounded to 90% for movies / 92% for shows. Without this a long-credits
     *  movie's finish point sat near the file end (~98%), so it never marked watched and never left
     *  Continue Watching. A detected credits point (dialogue end / learned / chapter) that lands
     *  EARLIER than the cap still wins; the cap only stops us waiting through minutes of credits. */
    private fun finishPointMs(p: ExoPlayer): Long {
        val cap = p.duration * (if (ctx?.season != null) 92 else 90) / 100
        return (p.duration - currentLeadMs(p)).coerceIn(p.duration * 80 / 100, cap)
    }

    private fun markWatchedIfDone(p: ExoPlayer, force: Boolean = false, useCtx: Ck.StreamCtx? = null) {
        if (placeholderMode || p.duration <= 0) return
        if (!force && p.currentPosition < finishPointMs(p)) return
        // NOT watched if you barely played it: a bogus near-end landing + immediate back, OR a
        // short/broken/wrong stream that hits STATE_ENDED a minute in (AJ Sep 15: "finished an
        // episode at 4% and says watched"). The old guard let that through — it exempted anything
        // near the *file* end, but a short file's end IS 4% of the real episode. Now the exemption
        // is "you RESUMED near the end and finished the last bit" (high sessionStartPos), which is
        // the only legit <2-min sit-down. Starting near the top + <2 min played = never watched.
        if (p.currentPosition - sessionStartPos < 120_000 && sessionStartPos < 120_000) return
        val c = useCtx ?: playerCtx ?: ctx
        if (c?.season != null) {
            Store.setWatched(this, c.epId, true)
            // the SHOW lands on the Library "Watched" shelf only once you're CAUGHT UP (finished the
            // latest aired episode) — AJ Sep 28: "don't mark a show watched after one episode". A
            // mid-run episode just marks that episode; it stays in Continue Watching to resume next.
            if (isCaughtUp(c)) {
                val stid = intent?.getStringExtra("titleId") ?: c.imdbId
                Store.markWatchedTitle(this, Title(stid, "series",
                    intent?.getStringExtra("title") ?: (c.title ?: stid),
                    intent?.getStringExtra("poster")))
            }
        } else {
            val tid = intent?.getStringExtra("titleId") ?: c?.imdbId ?: return
            Store.markWatchedTitle(this, Title(tid,
                intent?.getStringExtra("type") ?: "movie",
                intent?.getStringExtra("title") ?: (c?.title ?: tid),
                intent?.getStringExtra("poster")))
            // a FINISHED movie leaves Continue Watching (AJ: only on a real finish —
            // shows stay, since "watched E5" still means "resume the series")
            Store.removeContinue(this, tid)
            Store.clearProgress(this, tid)
        }
        Ck.homeStale = true
        // OFFLINE items honor the Downloads tab's "Auto-delete watched" toggle — the space
        // comes back the moment the credits roll (no-op stub on store builds)
        if (Downloads.ENABLED && offlinePlay)
            Downloads.watchedOffline(this, ctx?.epId ?: intent?.getStringExtra("id") ?: "")
    }

    // ---- episodes / next-up ----
    private var epLoading = false
    private fun loadEpisodes() {
        val c = ctx
        if (c?.season == null) {
            // live sessions repurposed these as ★ Favorite / Guide — keep them on screen
            if (!(liveMode && liveBase.isNotBlank())) { hideWithLabel(nextBtn); hideWithLabel(listBtn) }
            return
        }
        if (epLoading) return
        epLoading = true
        scope.launch {
            var meta: Pair<String, List<Ck.Episode>>? = null
            for (attempt in 1..3) {
                meta = withContext(Dispatchers.IO) { Ck.fetchSeries(c.imdbId) }
                if (meta != null && meta.second.isNotEmpty()) break
                kotlinx.coroutines.delay(1500)
            }
            epLoading = false
            if (meta != null && meta.second.isNotEmpty()) {
                showName = meta.first
                episodes = meta.second
                episodeStatus.visibility = View.GONE
                val ep = episodes.find { it.season == c.season && it.episode == c.episode }
                titleText.text = buildString {
                    append(showName)
                    append(String.format(Locale.US, " S%02dE%02d", c.season, c.episode))
                    if (!ep?.name.isNullOrBlank()) append(" — ").append(ep!!.name)
                }
                buildSeasonTabs()
                showSeason(c.season)
            } else if (episodePanel.visibility == View.VISIBLE) {
                episodeStatus.text = "Couldn't load the episode list — check internet, then reopen"
                episodeStatus.visibility = View.VISIBLE
            }
        }
    }

    private fun nextEpisode(): Ck.Episode? {
        val c = ctx ?: return null
        val idx = episodes.indexOfFirst { it.season == c.season && it.episode == c.episode }
        if (idx < 0) return null
        return episodes.drop(idx + 1).firstOrNull { it.aired }
    }

    private fun playNext(auto: Boolean) {
        if (!auto) idleEps = 0   // a human clicked — the still-watching chain starts over
        // a human advancing during the endgame marks where credits start for this show
        if (!auto) player?.let { p ->
            if (p.duration > 0) {
                val rem = p.duration - p.currentPosition
                if (rem in 5_000..300_000)
                    Ck.reportServer(this, ctx, p.currentPosition, p.duration, credits = rem)
            }
        }
        // Advancing marks THIS episode watched — but ONLY when you actually finished it.
        // auto-advance always comes from STATE_ENDED (real end); a manual "Next" counts only
        // if you're past the credits point. Tapping Next at 4% (skipping ahead, or a
        // wrong-episode grab) must NOT paint a full purple bar + ✓ on an episode you barely
        // started (AJ Sep 14). "clicking next never marked it watched" stays fixed for the
        // normal end-of-episode case.
        val p0 = player
        val finished = auto || (p0 != null && p0.duration > 0 && p0.currentPosition >= finishPointMs(p0))
        ctx?.let { c ->
            if (c.season != null && finished) {
                Store.setWatched(this, c.epId, true)
                // show → Library "Watched" shelf only once CAUGHT UP (latest aired episode) — AJ Sep 28
                if (isCaughtUp(c)) {
                    val stid = intent?.getStringExtra("titleId") ?: c.imdbId
                    Store.markWatchedTitle(this, Title(stid, "series",
                        intent?.getStringExtra("title") ?: (c.title ?: stid),
                        intent?.getStringExtra("poster")))
                }
                Ck.homeStale = true
                player?.let { p -> if (p.duration > 0)
                    Ck.reportServer(this, c, p.duration, p.duration) }   // pct=100 → server "finished"
                if (Store.signedIn(this)) Thread {
                    try { kotlinx.coroutines.runBlocking { Sync.push(this@PlayerActivity) } } catch (_: Exception) {}
                }.start()
            }
        }
        hideNextUp()
        val nxt = nextEpisode()
        if (nxt == null) {
            if (!auto) Toast.makeText(this, "No next episode yet", Toast.LENGTH_SHORT).show()
            return
        }
        playEpisode(nxt)
    }

    /** Resolve the upcoming episode ahead of time; playEpisode() switches with the URL
     *  already in hand instead of showing "Loading next episode". */
    private fun prefetchNext() {
        if (prefetching) return
        val now = android.os.SystemClock.elapsedRealtime()
        if (now < prefetchRetryAt) return
        val c = ctx ?: return
        val nxt = nextEpisode() ?: return
        prefetchedNext?.let { if (it.ctx.season == nxt.season && it.ctx.episode == nxt.episode
            && now - prefetchedAt < 30 * 60_000) return }
        prefetching = true
        scope.launch {
            val res = withContext(Dispatchers.IO) { Ck.resolveEpisode(this@PlayerActivity, c, nxt) }
            prefetching = false
            if (ctx !== c) return@launch
            if (res != null) {
                prefetchedNext = res
                prefetchedAt = android.os.SystemClock.elapsedRealtime()
            } else prefetchRetryAt = android.os.SystemClock.elapsedRealtime() + 60_000
        }
    }

    private fun playEpisode(ep: Ck.Episode) {
        val c = ctx ?: return
        Ck.playerAdvancedShow = c.imdbId   // back-out lands on the CURRENT episode, not where playback began (AJ Sep 27)
        epTouched = false   // fresh episode, fresh still-watching slate
        episodePanel.visibility = View.GONE
        val pf = prefetchedNext
        if (pf != null && pf.ctx.season == ep.season && pf.ctx.episode == ep.episode
            && android.os.SystemClock.elapsedRealtime() - prefetchedAt < 30 * 60_000) {
            prefetchedNext = null
            ctx = pf.ctx
            pf.ctx.let { if (it.season != null) Store.setCwLast(this, it.imdbId, it.epId) }
            titleText.text = buildString {
                append(showName)
                append(String.format(Locale.US, " S%02dE%02d", ep.season, ep.episode))
                if (ep.name.isNotBlank()) append(" — ").append(ep.name)
            }
            initPlayer(pf.url, Ck.resumeFor(this, pf.ctx.epId), pf.subs)
            buildSeasonTabs()
            showSeason(ep.season)
            return
        }
        prefetchedNext = null
        titleText.text = "Loading S%02dE%02d…".format(ep.season, ep.episode)
        scope.launch {
            val res = withContext(Dispatchers.IO) { Ck.resolveEpisode(this@PlayerActivity, c, ep) }
            if (res == null) {
                Toast.makeText(this@PlayerActivity, "Couldn't get that episode — try again in a minute", Toast.LENGTH_LONG).show()
                loadEpisodes()
                return@launch
            }
            ctx = res.ctx
            res.ctx.let { if (it.season != null) Store.setCwLast(this@PlayerActivity, it.imdbId, it.epId) }
            titleText.text = buildString {
                append(showName)
                append(String.format(Locale.US, " S%02dE%02d", ep.season, ep.episode))
                if (ep.name.isNotBlank()) append(" — ").append(ep.name)
            }
            initPlayer(res.url, Ck.resumeFor(this@PlayerActivity, res.ctx.epId), res.subs)
            buildSeasonTabs()
            showSeason(ep.season)
        }
    }

    /** One chip per season across the top of the drawer. Hidden for single-season shows. */
    private fun buildSeasonTabs() {
        val seasons = episodes.map { it.season }.distinct().sorted()
        seasonTabsScroll.visibility = if (seasons.size > 1) View.VISIBLE else View.GONE
        seasonTabs.removeAllViews()
        val pad = (10 * resources.displayMetrics.density).toInt()
        for (s in seasons) {
            val b = android.widget.Button(this)
            b.text = "Season $s"
            b.isAllCaps = false
            b.textSize = 15f
            b.tag = s
            b.setBackgroundResource(R.drawable.ep_focus_bg)
            b.setPadding(pad * 2, pad, pad * 2, pad)
            b.setOnClickListener { showSeason(s) }
            val lp = android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.marginEnd = (8 * resources.displayMetrics.density).toInt()
            seasonTabs.addView(b, lp)
        }
    }

    private fun showSeason(season: Int?) {
        val c = ctx ?: return
        if (episodes.isEmpty()) return
        shownSeason = season ?: episodes.first().season
        val list = episodes.filter { it.season == shownSeason }
        episodeRecycler.adapter = EpisodeAdapter(list, c) { chosen -> playEpisode(chosen) }
        for (i in 0 until seasonTabs.childCount) {
            val b = seasonTabs.getChildAt(i) as android.widget.Button
            b.setTextColor(if (b.tag == shownSeason) 0xFF7B5BF5.toInt() else 0xFFFFFFFF.toInt())
        }
        val idx = list.indexOfFirst { it.season == c.season && it.episode == c.episode }
        if (idx >= 0) episodeRecycler.scrollToPosition(idx)
    }

    /** Hide a control AND its caption (the TV bar wraps each button with a small label). */
    private fun hideWithLabel(v: View) {
        // each control is a CKCell = [caption TextView, ImageButton]; hide the whole cell so a
        // disabled control (movies have no Next/Episodes) doesn't leave its word floating.
        val p = v.parent as? android.widget.LinearLayout
        if (p != null && p.childCount == 2 && (p.getChildAt(0) is TextView || p.getChildAt(1) is TextView))
            p.visibility = View.GONE
        else v.visibility = View.GONE
    }

    private fun showNextUpCard() {
        val nxt = nextEpisode() ?: return
        nextUpText.text = "S%dE%d%s".format(nxt.season, nxt.episode,
            if (nxt.name.isNotBlank()) " · " + nxt.name else "")
        val thumb = findViewById<android.widget.ImageView>(R.id.next_up_thumb)
        val seenIt = ctx?.let { c ->
            Store.isWatched(this, "${c.imdbId}:${nxt.season}:${nxt.episode}") } ?: false
        applyUnwatchedBlur(thumb, this, watched = seenIt)
        val softBlur = Store.blurUnwatched(this) && !seenIt && android.os.Build.VERSION.SDK_INT < 31
        if (nxt.thumb != null) coil.Coil.imageLoader(this).enqueue(
            coil.request.ImageRequest.Builder(this).data(nxt.thumb)
                .transformations(listOfNotNull(
                    coil.transform.RoundedCornersTransformation(8f * resources.displayMetrics.density),
                    if (softBlur) BlurTransformation() else null))
                .target(thumb).build())
        else thumb.setImageDrawable(null)
        nextUpPanel.setOnClickListener { playNext(auto = false) }
        thumb.setOnClickListener { playNext(auto = false) }
        nextUpPanel.animate().cancel()
        nextUpPanel.alpha = 0f
        nextUpPanel.translationX = 0f
        nextUpPanel.visibility = View.VISIBLE
        // the player's control bar behind the card steals draws/input — with it gone,
        // Play Now and Dismiss are the only live targets (AJ Sep 13: "hard to click play now")
        playerView.hideController()
        val play = findViewById<View>(R.id.next_up_play)
        nextUpPanel.post {
            nextUpPanel.translationX = nextUpPanel.width.toFloat() + 24f
            nextUpPanel.animate().translationX(0f).alpha(1f).setDuration(300)
                .setInterpolator(android.view.animation.DecelerateInterpolator(2f)).start()
            play.requestFocus()
        }
    }

    /** The 30s/5-min caching clip must never masquerade as the episode. */
    private fun maybeDetectPlaceholder() {
        val p = player ?: return
        if (placeholderMode) return
        val d = p.duration
        if (d !in 29_000..31_000 && d !in 295_000..305_000) return
        val url = currentUrl ?: return
        val forCtx = ctx
        scope.launch {
            val ph = withContext(Dispatchers.IO) { Ck.landsOnPlaceholder(url) }
            if (ph && ctx === forCtx && player != null) {
                placeholderMode = true
                titleText.text = "⏳ Getting this episode ready — it starts by itself when done"
                Toast.makeText(this@PlayerActivity,
                    "Still caching — hang tight, it'll start automatically", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun onEnded() {
        if (placeholderMode) {  // loop the waiting screen; the real episode is coming
            player?.seekTo(0); player?.play(); return
        }
        player?.let { markWatchedIfDone(it, force = true) }
        Ck.clearResume(this, ctx?.epId)
        if (ctx?.season == null) return  // movies: never auto-advance
        if (nextEpisode() == null) return
        // reached the real end: auto-advance if enabled, otherwise make sure the Next-Up
        // button is on screen so it's never missing at the end/in credits (AJ Sep 10)
        if (!Store.autoplayNext(this)) { showNextUpCard(); return }
        // still-watching gate: this episode ran end-to-end — untouched grows the idle
        // chain, touched resets it. Two full hands-off episodes = ask before the third.
        if (epTouched) idleEps = 0 else idleEps++
        if (idleEps >= 2) { showStillWatching(); return }
        playNext(auto = true)
    }

    /** Netflix-style overnight guard (AJ Sep 25). Only reachable from the natural-end
     *  auto-advance after 2 whole episodes with zero inputs — never from pause, seek,
     *  manual Next, or any other path. No answer for 5 minutes = stop playback and leave
     *  (the stream shouldn't run to an empty couch all night). */
    private fun showStillWatching() {
        stillWatchingDialog?.let { runCatching { it.dismiss() } }
        val dp = { v: Int -> (v * resources.displayMetrics.density).toInt() }
        fun rounded(color: Int, r: Int) = android.graphics.drawable.GradientDrawable().apply {
            setColor(color); cornerRadius = dp(r).toFloat() }
        fun selBg(color: Int, r: Int) = android.graphics.drawable.StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), android.graphics.drawable.GradientDrawable().apply {
                setColor(color); cornerRadius = dp(r).toFloat()
                setStroke(dp(2), android.graphics.Color.WHITE) })
            addState(intArrayOf(), rounded(color, r))
        }
        val d = android.app.Dialog(this)
        stillWatchingDialog = d
        var answered = false
        val col = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(android.graphics.Color.parseColor("#1B1830"))
                cornerRadius = dp(22).toFloat()
                setStroke(dp(1), android.graphics.Color.parseColor("#2C2649"))
            }
            setPadding(dp(30), dp(24), dp(30), dp(20))
        }
        col.addView(TextView(this).apply {   // the crown — it's CouchKing (AJ Sep 25)
            text = "\uD83D\uDC51"; textSize = 30f
            gravity = android.view.Gravity.CENTER
            setPadding(0, 0, 0, dp(8))
        })
        col.addView(TextView(this).apply {
            text = "Are you still watching?"
            setTextColor(android.graphics.Color.WHITE); textSize = 18.5f
            gravity = android.view.Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        ctx?.title?.takeIf { it.isNotBlank() }?.let { t ->
            col.addView(TextView(this).apply {
                text = t; setTextColor(android.graphics.Color.parseColor("#A9A5C0")); textSize = 14f
                gravity = android.view.Gravity.CENTER
                setPadding(0, dp(6), 0, 0)
            })
        }
        fun btn(label: String, bgColor: Int, onClick: () -> Unit) = TextView(this).apply {
            text = label; setTextColor(android.graphics.Color.WHITE); textSize = 15f
            gravity = android.view.Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = selBg(bgColor, 26)   // pill, CouchKing-style
            setPadding(dp(18), dp(12), dp(18), dp(12))
            isClickable = true; isFocusable = true
            layoutParams = android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT).apply { setMargins(0, dp(10), 0, 0) }
            setOnClickListener { onClick() }
        }
        val keep = btn("Keep watching", android.graphics.Color.parseColor("#7B5BF5")) {
            answered = true; idleEps = 0; epTouched = false
            runCatching { d.dismiss() }
            playNext(auto = true)
        }
        col.addView(keep)
        col.addView(btn("I'm done for now", android.graphics.Color.parseColor("#2C2649")) {
            answered = true
            runCatching { d.dismiss() }
            finish()
        })
        col.addView(TextView(this).apply {
            text = "No answer in 5 minutes and we'll tuck the stream in for the night \uD83D\uDE34"
            setTextColor(android.graphics.Color.parseColor("#6A6590")); textSize = 11.5f
            gravity = android.view.Gravity.CENTER
            setPadding(0, dp(12), 0, 0)
        })
        d.setContentView(col)
        d.setCancelable(true)
        // BACK on the prompt = they're awake but undecided: keep the Next-Up card up so
        // the show doesn't march on by itself, and the chain starts over
        d.setOnDismissListener {
            stillWatchingDialog = null
            if (!answered && !isFinishing) { idleEps = 0; runCatching { showNextUpCard() } }
        }
        d.window?.apply {
            setBackgroundDrawable(android.graphics.drawable.ColorDrawable(android.graphics.Color.TRANSPARENT))
            setLayout(dp(360), android.view.ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        runCatching { d.show(); keep.requestFocus() } .onFailure { playNext(auto = true) }
        // walked away: shut it down after 5 minutes instead of streaming to an empty room
        ui.postDelayed({
            if (stillWatchingDialog === d && !answered) {
                answered = true
                runCatching { d.dismiss() }
                Ck.stillWatchTimedOut = true   // MainActivity.onResume -> profile picker
                if (!isFinishing) finish()
            }
        }, 5 * 60_000L)
    }

    private fun hideNextUp() {
        val hadFocus = currentFocus?.let { isInside(nextUpPanel, it) } == true
        if (nextUpPanel.visibility == View.VISIBLE) {
            nextUpPanel.animate().translationX(nextUpPanel.width.toFloat() + 24f).alpha(0f)
                .setDuration(160).withEndAction { nextUpPanel.visibility = View.GONE }.start()
        }
        nextUpCountdown?.let { ui.removeCallbacks(it) }
        // dismissing hands the D-pad straight back to the player (AJ Sep 10: "click dismiss
        // and they can move around") — focus must not die inside the hidden card
        if (hadFocus) playerView.requestFocus()
    }

    private data class SubTrack(val label: String, val group: androidx.media3.common.Tracks.Group?, val track: Int)

    /** Ranked, English-first subtitle options with a leading "None (off)". Shared by the
     *  bottom-sheet picker and the live side panel.
     *  ENGLISH ONLY, BEST FIRST (AJ Sep 14): in-video track first (cut for this exact release =
     *  best sync), its SDH second, then the ranked OpenSubtitles list in the addon's order.
     *  Forced/foreign tracks hidden — unless the file has no English at all, then everything
     *  shows rather than an empty menu. */
    private fun subtitleOptions(p: ExoPlayer): List<SubTrack> {
        data class Ranked(val label: String, val group: androidx.media3.common.Tracks.Group, val track: Int, val rank: Int)
        val ccRe = Regex("""\bcc\b""")
        val all = ArrayList<Ranked>()
        for (g in p.currentTracks.groups) {
            if (g.type != C.TRACK_TYPE_TEXT) continue
            for (i in 0 until g.length) {
                val f = g.getTrackFormat(i)
                val label = f.label
                    ?: f.language?.let { lang -> java.util.Locale(lang).displayLanguage.ifBlank { lang } }
                    ?: "Unknown"
                val low = label.lowercase()
                val eng = f.language?.startsWith("en") == true || low.contains("english") || low == "sdh"
                val forced = low.contains("forced") || (f.selectionFlags and C.SELECTION_FLAG_FORCED) != 0
                val rank = when {
                    !eng || forced -> 9
                    sideSubNames.contains(label) -> 2
                    low.contains("sdh") || low.contains("hearing") || ccRe.containsMatchIn(low) -> 1
                    else -> 0
                }
                all.add(Ranked(label, g, i, rank))
            }
        }
        val usable = all.filter { it.rank < 9 }.ifEmpty { all }
        val out = ArrayList<SubTrack>()
        out.add(SubTrack("None (off)", null, -1))
        usable.sortedBy { it.rank }.forEach { out.add(SubTrack(it.label, it.group, it.track)) }
        return out
    }

    /** Apply one option to the running player (null group = text renderer off — the only thing
     *  that actually sticks; clearing overrides alone lets the preferred language re-pick). */
    private fun applySubtitle(o: SubTrack) {
        val p = player ?: return
        val b = p.trackSelectionParameters.buildUpon().clearOverridesOfType(C.TRACK_TYPE_TEXT)
        if (o.group == null) b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        else {
            b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            b.addOverride(androidx.media3.common.TrackSelectionOverride(o.group.mediaTrackGroup, o.track))
        }
        p.trackSelectionParameters = b.build()
    }

    private fun currentSubIndex(opts: List<SubTrack>): Int {
        val p = player ?: return 0
        val off = p.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)
        return if (off) 0
            else opts.indexOfFirst { it.group?.isTrackSelected(it.track) == true }.coerceAtLeast(0)
    }

    /** LIVE captions side panel (AJ Sep 15): a slim list pinned to the right that STAYS OPEN as
     *  you pick — the chosen track plays immediately so you can watch the on-screen captions and
     *  find the one that lines up, without diving back into a menu each time. BACK closes it. */
    private fun showSubtitleSidePanel() {
        val p = player ?: return
        val opts = subtitleOptions(p)
        if (opts.size <= 1) { flashLabel("No captions available yet — give it a sec"); return }
        subSideList.removeAllViews()
        var current = currentSubIndex(opts)
        val rows = ArrayList<android.widget.LinearLayout>()
        fun paint() = rows.forEachIndexed { i, row ->
            val sel = i == current
            (row.getChildAt(0) as TextView).apply {
                setTextColor(if (sel) android.graphics.Color.parseColor("#B9A6FF") else android.graphics.Color.WHITE)
                setTypeface(typeface, if (sel) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
            }
            row.getChildAt(1).visibility = if (sel) View.VISIBLE else View.INVISIBLE
        }
        opts.forEachIndexed { i, o ->
            val row = android.widget.LinearLayout(this).apply {
                orientation = android.widget.LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                isFocusable = true; isClickable = true
                setBackgroundResource(R.drawable.ep_focus_bg)
                val pad = (12 * resources.displayMetrics.density).toInt()
                setPadding(pad, pad, pad, pad)
                addView(TextView(this@PlayerActivity).apply {
                    text = o.label; textSize = 15f; setTextColor(android.graphics.Color.WHITE); maxLines = 2
                    layoutParams = android.widget.LinearLayout.LayoutParams(0,
                        android.view.ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                })
                addView(TextView(this@PlayerActivity).apply {
                    text = "✓"; textSize = 15f; setTextColor(android.graphics.Color.parseColor("#B9A6FF"))
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                })
                setOnClickListener { current = i; applySubtitle(o); paint(); subSideList.tag = this }
            }
            rows.add(row); subSideList.addView(row)
        }
        paint()
        playerView.hideController()
        playerView.useController = false   // NOTHING may pop over the captions panel (AJ Sep 18)
        subSidePanel.visibility = View.VISIBLE
        // The panel just flipped GONE→VISIBLE with rows added THIS frame — they aren't laid
        // out yet, so an immediate (or even post()) requestFocus() no-ops and Android's
        // focus-recovery drops the cursor onto the seek bar. doOnPreDraw fires AFTER layout,
        // so the row can actually take focus. Belt-and-suspenders with the listener guard
        // above that stops the controller stealing it back. (AJ Sep 15)
        val target = rows.getOrNull(current) ?: rows.firstOrNull()
        subSideList.tag = target
        target?.doOnPreDraw { it.requestFocus() }
    }

    private fun hideSubSidePanel() {
        playerView.useController = true    // give the controls back
        subSidePanel.visibility = View.GONE
        // BACK out of captions goes straight to clean video — requestFocus() alone makes the
        // PlayerView pop its controller chrome back up, so hide it right after. (AJ)
        playerView.requestFocus()
        playerView.hideController()
        playerView.post { playerView.hideController() }
    }

    // ==== LIVE TV mini guide (AJ Sep 26: "click guide while im watching and have like a
    // mini guide on the right like on the web version but a little better") — 🔴 Live Now,
    // ★ Favorites, ↻ Continue Watching, then the whole lineup, each under its own
    // color-coded section band so you can TELL the rows apart (his web complaint). Tuning
    // keeps the panel open (captions-panel behavior) for easy channel hopping; BACK closes.

    private fun setupLiveUi() {
        val inf = runCatching { org.json.JSONObject(intent?.getStringExtra("live") ?: "") }.getOrNull() ?: return
        liveAddon = inf.optString("addon"); liveBase = inf.optString("base")
        liveChId = inf.optString("ch"); liveProf = inf.optString("profile"); liveReg = inf.optString("region")
        if (liveBase.isBlank() || liveAddon.isBlank()) return   // Stremio/deep-link path: no guide context
        relabelCell(nextBtn, "Favorite")
        (nextBtn as? android.widget.ImageButton)?.setImageResource(R.drawable.ic_star)
        nextBtn.setOnClickListener {
            val cid = liveChId.removePrefix("cklive:")
            liveFavToggle(cid, !isLiveFav(cid))
        }
        relabelCell(listBtn, "Guide")
        (listBtn as? android.widget.ImageButton)?.setImageResource(R.drawable.ic_list)
        listBtn.setOnClickListener { showLiveGuidePanel() }
        // prefetch so the ★ paints right and the first Guide press opens instantly
        scope.launch { liveGuideFetch(); paintFavBtn() }
    }

    /** Swap the caption of a control cell (phone: caption ABOVE icon; TV: label BELOW). */
    private fun relabelCell(btn: View, label: String) {
        btn.contentDescription = label
        val cell = btn.parent as? android.view.ViewGroup ?: return
        for (i in 0 until cell.childCount) (cell.getChildAt(i) as? TextView)?.let { it.text = label; return }
    }

    private suspend fun liveGuideFetch(): org.json.JSONObject? {
        if (lvGuideJson != null && System.currentTimeMillis() - lvGuideAt < 55_000) return lvGuideJson
        val d = Http.json("$liveBase/guide.json?p=" + java.net.URLEncoder.encode(liveProf, "UTF-8") +
            (if (liveReg.isNotBlank()) "&r=$liveReg" else ""))
        if (d != null && (d.optJSONArray("channels")?.length() ?: 0) > 0) {
            lvGuideJson = d; lvGuideAt = System.currentTimeMillis()
        }
        return lvGuideJson
    }

    private fun isLiveFav(cid: String): Boolean = lvGuideJson?.optJSONArray("favs")?.let { f ->
        (0 until f.length()).any { f.optString(it) == cid } } ?: false

    private fun paintFavBtn() {
        if (liveBase.isBlank()) return
        val on = isLiveFav(liveChId.removePrefix("cklive:"))
        (nextBtn as? android.widget.ImageButton)?.apply {
            setImageResource(if (on) R.drawable.ic_star_on else R.drawable.ic_star)
            // CKButton's style tints every icon white — the gold ★ needs its own tint
            imageTintList = android.content.res.ColorStateList.valueOf(
                if (on) 0xFFF5C542.toInt() else 0xFFFFFFFF.toInt())
        }
    }

    private fun liveFavToggle(cid: String, on: Boolean) {
        flashLabel(if (on) "★ Added to favorites" else "Removed from favorites")
        scope.launch {
            Http.post("$liveBase/fav?id=" + java.net.URLEncoder.encode(cid, "UTF-8") +
                "&on=" + (if (on) "1" else "0") +
                "&p=" + java.net.URLEncoder.encode(liveProf, "UTF-8"), org.json.JSONObject())
            Ck.liveDirty = true   // the Live TV page refetches favs when we get back
            // patch the cached favs so every ★ repaints instantly (55s guide cache)
            runCatching {
                val f = lvGuideJson?.optJSONArray("favs") ?: return@runCatching
                if (on) f.put(cid) else {
                    val keep = org.json.JSONArray()
                    for (i in 0 until f.length()) if (f.optString(i) != cid) keep.put(f.optString(i))
                    lvGuideJson?.put("favs", keep)
                }
            }
            paintFavBtn()
            for (pt in lvRowPainters) runCatching { pt() }
        }
    }

    private fun showLiveGuidePanel() {
        playerView.hideController()
        playerView.useController = false   // the panel owns the cursor (captions-panel rule)
        liveGuidePanel.visibility = View.VISIBLE
        liveGuideList.removeAllViews()
        liveGuideList.addView(TextView(this).apply {
            text = "Loading the guide…"; setTextColor(0xFF9B93C0.toInt()); textSize = 13f
            val pad = (10 * resources.displayMetrics.density).toInt(); setPadding(pad, pad, pad, pad)
        })
        scope.launch {
            // every OPEN = fresh favs/recent/games (AJ Sep 26) — only a quick re-toggle
            // (<15s) rides the cache so mashing the button can't hammer the server
            if (System.currentTimeMillis() - lvGuideAt > 15_000) lvGuideAt = 0
            val gd = liveGuideFetch()
            val games = Http.json("$liveBase/games.json")
            if (liveGuidePanel.visibility != View.VISIBLE) return@launch   // BACKed out mid-fetch
            renderLiveGuide(gd, games)
            // tick the now-lines every minute while the panel is up — programs roll over
            // in place, nothing rebuilds, the cursor never moves
            val gen = ++lvTickGen
            fun tick() {
                ui.postDelayed({
                    if (gen != lvTickGen || liveGuidePanel.visibility != View.VISIBLE) return@postDelayed
                    for (u in lvNowUpdaters) runCatching { u() }
                    tick()
                }, 60_000)
            }
            tick()
        }
    }

    private fun hideLiveGuidePanel() {
        lvTickGen++   // stop the now-line ticker
        playerView.useController = true
        liveGuidePanel.visibility = View.GONE
        playerView.requestFocus()
        playerView.hideController()
        playerView.post { playerView.hideController() }
    }

    /** What's on `chan` RIGHT NOW, from the listings already in memory. */
    private fun lvNowOf(chan: org.json.JSONObject): String {
        val progs = chan.optJSONArray("progs") ?: return ""
        val now = System.currentTimeMillis()
        for (i in 0 until progs.length()) {
            val p = progs.optJSONObject(i) ?: continue
            if (p.optLong("s") <= now && p.optLong("e") > now) return p.optString("t")
        }
        return ""
    }


    /** Section band: color-coded left bar + faint tinted background + colored uppercase
     *  label — the "how do I tell where continue watching stops" fix. */
    private fun lvHeader(label: String, color: Int): View {
        val d = resources.displayMetrics.density
        return android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor((color and 0xFFFFFF) or 0x26000000)   // the section color, faint
                cornerRadius = 8 * d
            }
            layoutParams = android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(0, (12 * d).toInt(), 0, (4 * d).toInt()) }
            addView(View(this@PlayerActivity).apply {
                setBackgroundColor(color)
                layoutParams = android.widget.LinearLayout.LayoutParams(
                    (4 * d).toInt(), (15 * d).toInt()).apply { setMargins((6 * d).toInt(), 0, (8 * d).toInt(), 0) }
            })
            addView(TextView(this@PlayerActivity).apply {
                text = label.uppercase(Locale.US)
                setTextColor(color); textSize = 12f; letterSpacing = 0.06f
                setTypeface(android.graphics.Typeface.DEFAULT_BOLD)
                setPadding(0, (6 * d).toInt(), 0, (6 * d).toInt())
            })
        }
    }

    /** One guide row: channel/game name + what's on, ★ if faved, ▶ marker on the channel
     *  you're watching. OK tunes it (panel stays open), long-OK toggles ★. */
    private fun lvChanRow(chid: String, nm: String, logoU: String, nowLine: String, liveNow: Boolean,
                          chan: org.json.JSONObject? = null): View {
        val d = resources.displayMetrics.density
        val cid = chid.removePrefix("cklive:")
        val nameTv = TextView(this).apply {
            textSize = 14f; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
        }
        // now-line is ALWAYS in the row (GONE when idle) so a programme that starts while
        // the panel is open can appear on the minute tick without any rebuild
        val nowTv = TextView(this).apply {
            textSize = 11.5f; maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(if (liveNow) 0xFFE64545.toInt() else 0xFF9B93C0.toInt())
        }
        // ALWAYS one line tall, even blank — a now-line appearing on the minute tick must
        // never change the row's height (the panel stays exactly where you scrolled it)
        fun setNow(s: String) { nowTv.text = s }
        setNow(nowLine)
        if (chan != null) lvNowUpdaters.add { setNow(lvNowOf(chan)) }
        val row = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            isFocusable = true; isClickable = true
            setBackgroundResource(R.drawable.ep_focus_bg)
            setPadding((10 * d).toInt(), (7 * d).toInt(), (10 * d).toInt(), (7 * d).toInt())
            addView(nameTv)
            addView(nowTv)
            setOnClickListener {
                if (chid == liveChId) flashLabel("You're watching this channel")
                else liveRetune(chid, nm, logoU, if (liveNow) "" else nowLine)
            }
            setOnLongClickListener { liveFavToggle(cid, !isLiveFav(cid)); true }
        }
        val paint = {
            val watching = chid == liveChId
            val star = isLiveFav(cid)
            val label = (if (watching) "▶ " else "") + (if (star) "★ " else "") + nm
            nameTv.text = android.text.SpannableString(label).apply {
                if (star) {
                    val i = if (watching) 2 else 0
                    setSpan(android.text.style.ForegroundColorSpan(0xFFF5C542.toInt()), i, i + 1, 0)
                }
            }
            nameTv.setTextColor(if (watching) 0xFFB9A6FF.toInt() else 0xFFFFFFFF.toInt())
            nameTv.setTypeface(if (watching) android.graphics.Typeface.DEFAULT_BOLD else android.graphics.Typeface.DEFAULT)
        }
        paint(); lvRowPainters.add(paint)
        return row
    }

    private fun renderLiveGuide(gd: org.json.JSONObject?, games: org.json.JSONObject?) {
        lvRowPainters.clear(); lvNowUpdaters.clear()
        liveGuideList.removeAllViews()
        if (gd == null) {
            liveGuideList.addView(TextView(this).apply {
                text = "Couldn't load the guide — check your connection and reopen it."
                setTextColor(0xFF9B93C0.toInt()); textSize = 13f
            })
            return
        }
        var focusTarget: View? = null
        fun addRow(v: View) { liveGuideList.addView(v); if (focusTarget == null) focusTarget = v }
        // 🔴 LIVE NOW — games on right now, same region rules as the page banner
        val want = if (liveReg.isBlank()) "US" else liveReg
        val sports = games?.optJSONArray("sports")
        val liveGames = ArrayList<Pair<org.json.JSONObject, String>>()
        for (i in 0 until (sports?.length() ?: 0)) {
            val sp = sports?.optJSONObject(i) ?: continue
            val sport = sp.optString("sport"); val emoji = sp.optString("emoji")
            val lg = sp.optJSONArray("live") ?: continue
            for (j in 0 until lg.length()) {
                val g = lg.optJSONObject(j) ?: continue
                val ok = if (sport == "Fútbol") want == "UK" else g.optString("rg", "US") == want
                if (ok && g.optString("chid").isNotBlank()) liveGames.add(g to emoji)
            }
        }
        if (liveGames.isNotEmpty()) {
            liveGuideList.addView(lvHeader("🔴 Live now", 0xFFE64545.toInt()))
            for ((g, emoji) in liveGames) addRow(lvChanRow(g.optString("chid"),
                (if (emoji.isNotBlank()) "$emoji " else "") + g.optString("t"),
                g.optString("logo"), "🔴 LIVE • " + g.optString("ch"), liveNow = true))
        }
        val chans = gd.optJSONArray("channels") ?: org.json.JSONArray()
        val byId = HashMap<String, org.json.JSONObject>()
        for (i in 0 until chans.length()) chans.optJSONObject(i)?.let { byId[it.optString("id")] = it }
        // ★ FAVORITES
        val favSet = HashSet<String>()
        gd.optJSONArray("favs")?.let { for (i in 0 until it.length()) favSet.add(it.optString(i)) }
        val favCh = gd.optJSONArray("favChannels") ?: org.json.JSONArray()
        if (favCh.length() > 0) {
            liveGuideList.addView(lvHeader("★ Favorites", 0xFFF5C542.toInt()))
            for (i in 0 until favCh.length()) favCh.optJSONObject(i)?.let { c ->
                addRow(lvChanRow("cklive:" + c.optString("id"), c.optString("name"),
                    c.optString("logo"), lvNowOf(c), liveNow = false, chan = c))
            }
        }
        // ↻ CONTINUE WATCHING (favs excluded — they're already pinned above, web parity).
        // Hops picked up on the next OPEN (every open refetches) — never inserted live,
        // the open panel must not move (AJ Sep 26).
        val rec = gd.optJSONArray("recent") ?: org.json.JSONArray()
        val recCh = (0 until rec.length()).mapNotNull { byId[rec.optString(it)] }
            .filter { !favSet.contains(it.optString("id")) }
        if (recCh.isNotEmpty()) {
            liveGuideList.addView(lvHeader("↻ Continue watching", 0xFF4EC9B0.toInt()))
            for (c in recCh) addRow(lvChanRow("cklive:" + c.optString("id"), c.optString("name"),
                c.optString("logo"), lvNowOf(c), liveNow = false, chan = c))
        }
        // the rest of the lineup, one purple band per section
        var lastSec = ""
        for (i in 0 until chans.length()) {
            val c = chans.optJSONObject(i) ?: continue
            val sec = c.optString("section").ifBlank { c.optString("genre").ifBlank { "More channels" } }
            if (sec != lastSec) { lastSec = sec; liveGuideList.addView(lvHeader(sec, 0xFFB9A6FF.toInt())) }
            addRow(lvChanRow("cklive:" + c.optString("id"), c.optString("name"),
                c.optString("logo"), lvNowOf(c), liveNow = false, chan = c))
        }
        // cursor onto the first row once it's actually laid out (same trick as captions)
        if (isTvDevice) focusTarget?.doOnPreDraw { it.requestFocus() }
    }

    /** Tune a channel WITHOUT leaving the player: fetch its stream, swap in place, keep the
     *  panel open. The page's cursor/refresh state follows via Ck.liveFocus/liveDirty. */
    private fun liveRetune(chid: String, nm: String, logoU: String, nowT: String) {
        if (liveTuning) return
        liveTuning = true
        flashLabel("Tuning $nm…")
        scope.launch {
            try {
                val s = Http.json("$liveAddon/stream/tv/" +
                    java.net.URLEncoder.encode(chid, "UTF-8") + ".json")
                val st = s?.optJSONArray("streams")
                // same source pick as the page: steady .ts hub only for 24/7 loops, HLS first
                // for everything else (the hub feed buffered on live sports, Sep 17)
                var ts: String? = null; var hls: String? = null
                for (i in 0 until (st?.length() ?: 0)) {
                    val o = st?.optJSONObject(i) ?: continue
                    val u2 = o.optString("url"); if (u2.isBlank()) continue
                    if (o.optInt("ckTs") == 1) { if (ts == null) ts = u2 } else if (hls == null) hls = u2
                }
                val is247 = chid.removePrefix("cklive:").let { it.startsWith("24-7-") || it.startsWith("en-24-7-") }
                val play = if (is247) (ts ?: hls) else (hls ?: ts)
                if (play == null) { flashLabel("That channel is down right now"); return@launch }
                liveChId = chid
                Ck.liveFocus = chid; Ck.liveDirty = true
                intent?.putExtra("title", nm); intent?.putExtra("logo", logoU)
                intent?.removeExtra("backdrop")
                // logo/title ride EXPLICITLY into the loading screen — reading them back off
                // the intent showed the session's FIRST channel's logo on every hop (AJ Sep 26)
                buildLoadingScreen(liveLogo = logoU, liveTitle = nm)
                // the tuning overlay lands on top of everything — the open guide must stay
                // usable OVER it so back-to-back channel hops work (AJ: "easily switch")
                if (liveGuidePanel.visibility == View.VISIBLE) liveGuidePanel.bringToFront()
                start(play, nm)
                paintFavBtn()
                // ▶ marker repaints in place; NOTHING is inserted/removed — the panel must
                // never shift under the cursor (AJ Sep 26 "it should stay in place wherever
                // I scrolled"). ↻ Continue watching picks the hop up on the next open (fresh).
                for (pt in lvRowPainters) runCatching { pt() }
            } finally { liveTuning = false }
        }
    }

    // ---- subtitle size — cycles and remembers (same setting as the Settings page) ----
    private val subScales = listOf(1f to "Normal", 1.3f to "Large", 1.6f to "Huge", 2.0f to "Giant", 0.8f to "Small", 0.65f to "Tiny")
    private fun applySubScale() {
        screenSubs.setFractionalTextSize(0.0533f * Store.subScale(this))
    }
    private fun showAudioPicker() {
        val p = player ?: return
        data class Opt(val label: String, val group: androidx.media3.common.Tracks.Group, val track: Int)
        val opts = ArrayList<Opt>()
        for (g in p.currentTracks.groups) {
            if (g.type != C.TRACK_TYPE_AUDIO) continue
            for (i in 0 until g.length) {
                val f = g.getTrackFormat(i)
                val lang = f.language?.let { l -> java.util.Locale(l).displayLanguage.ifBlank { l } }
                val ch = f.channelCount.takeIf { it > 0 }?.let { c ->
                    if (c >= 6) "5.1" else if (c >= 2) "Stereo" else "Mono" }
                opts.add(Opt(listOfNotNull(f.label ?: lang ?: "Track ${opts.size + 1}", ch)
                    .joinToString("  ·  "), g, i))
            }
        }
        if (opts.size < 2) { Toast.makeText(this, "Only one audio track", Toast.LENGTH_SHORT).show(); return }
        val cur = opts.indexOfFirst { it.group.isTrackSelected(it.track) }.coerceAtLeast(0)
        Sheets.pick(this, "Audio", opts.map { it.label }, cur) { i ->
            val o = opts[i]
            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                .addOverride(androidx.media3.common.TrackSelectionOverride(o.group.mediaTrackGroup, o.track))
                .build()
        }
    }

    private val speeds = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f)
    private fun showSpeedPicker() {
        val p = player ?: return
        val cur = speeds.indexOfFirst { kotlin.math.abs(it - p.playbackParameters.speed) < 0.01f }
            .let { if (it >= 0) it else 2 }
        Sheets.pick(this, "Speed", speeds.map { if (it == 1f) "Normal" else "${it}x" }, cur) { i ->
            p.setPlaybackSpeed(speeds[i])
        }
    }

    // Fit = letterbox (default, no crop); Fill = crop-to-fill so the picture uses the whole
    // screen (fixes AJ's "doesn't fill the screen"); Stretch = distort to fill. The choice is
    // remembered per install and re-applied to every video (applyScale() on player setup).
    private val scaleModes = listOf(
        androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT to "Fit",
        androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM to "Fill (crop)",
        androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FILL to "Stretch")
    private fun applyScale() {
        val saved = Store.scaleMode(this)
        playerView.resizeMode = scaleModes.firstOrNull { it.first == saved }?.first
            ?: androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
    }
    private fun cycleScale() {
        val idx = scaleModes.indexOfFirst { it.first == playerView.resizeMode }
        val next = scaleModes[(idx + 1).mod(scaleModes.size)]
        playerView.resizeMode = next.first
        Store.setScaleMode(this, next.first)
        flashLabel("Screen: ${next.second}")
    }

    // Instant on-screen pill for the cyclers — Android TOASTS QUEUE, so fast presses
    // showed a size many steps behind the actual setting (AJ Sep 14); this single view
    // just updates in place and fades.
    private var flashView: android.widget.TextView? = null
    private val flashHide = Runnable {
        flashView?.animate()?.alpha(0f)?.setDuration(150)
            ?.withEndAction { flashView?.visibility = View.GONE }?.start()
    }
    private fun flashLabel(msg: String) {
        val d = resources.displayMetrics.density
        if (flashView == null) {
            flashView = android.widget.TextView(this).apply {
                setTextColor(android.graphics.Color.WHITE); textSize = 16f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                background = android.graphics.drawable.GradientDrawable().apply {
                    setColor(android.graphics.Color.parseColor("#E61B1830"))
                    cornerRadius = 24 * d
                }
                setPadding((18 * d).toInt(), (10 * d).toInt(), (18 * d).toInt(), (10 * d).toInt())
            }
            findViewById<android.view.ViewGroup>(android.R.id.content).addView(flashView,
                android.widget.FrameLayout.LayoutParams(
                    android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
                    android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
                    android.view.Gravity.TOP or android.view.Gravity.CENTER_HORIZONTAL
                ).apply { topMargin = (56 * d).toInt() })
        }
        flashView!!.apply {
            animate().cancel(); removeCallbacks(flashHide)
            text = msg; alpha = 1f; visibility = View.VISIBLE
            postDelayed(flashHide, 900)
        }
    }

    private fun cycleSubSize() {
        val cur = Store.subScale(this)
        val idx = subScales.indexOfFirst { it.first == cur }
        val next = subScales[(idx + 1).mod(subScales.size)]
        Store.setSubScale(this, next.first)
        applySubScale()
        flashLabel("Subtitles: ${next.second}")
    }

    private fun toggleEpisodePanel() {
        if (episodePanel.visibility == View.VISIBLE) episodePanel.visibility = View.GONE
        else {
            episodePanel.visibility = View.VISIBLE
            if (episodes.isEmpty()) {
                episodeStatus.text = "Loading episodes…"
                episodeStatus.visibility = View.VISIBLE
                loadEpisodes()
            } else if (shownSeason != ctx?.season) showSeason(ctx?.season)
            focusCurrentEpisode()
        }
    }

    /** Cursor lands ON the current episode's row when the drawer opens. */
    private fun focusCurrentEpisode() {
        val c = ctx ?: return
        episodeRecycler.post {
            val list = episodes.filter { it.season == shownSeason }
            val idx = list.indexOfFirst { it.season == c.season && it.episode == c.episode }
            val vh = if (idx >= 0) episodeRecycler.findViewHolderForAdapterPosition(idx) else null
            (vh?.itemView ?: episodeRecycler).requestFocus()
        }
    }

    /** OK/center with no UI on screen = play/pause immediately. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // any real key press = someone's holding the remote (still-watching chain resets)
        if (event.action == KeyEvent.ACTION_DOWN) epTouched = true
        // TV BACK is handled HERE, before any child (controller buttons, time bar, media3
        // internals) can swallow the press — one press, deterministic: an overlay up
        // (next-up card / episode drawer / controller chrome) -> clear it; nothing up ->
        // leave the player immediately, back to the details page you came from.
        if (event.keyCode == KeyEvent.KEYCODE_BACK && isTvDevice) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                when {
                    subSidePanel.visibility == View.VISIBLE -> hideSubSidePanel()
                    liveGuidePanel.visibility == View.VISIBLE -> hideLiveGuidePanel()
                    nextUpPanel.visibility == View.VISIBLE -> hideNextUp()
                    episodePanel.visibility == View.VISIBLE -> episodePanel.visibility = View.GONE
                    playerView.isControllerFullyVisible || chromeUp -> playerView.hideController()
                    else -> finish()
                }
            }
            return true
        }
        // NEXT-UP FOCUS TRAP (AJ Sep 10): while the card is up the D-pad lives INSIDE it —
        // Next Episode and Dismiss are the ONLY reachable things (focus used to wander into
        // the controls behind the card and getting back was a fight). Any arrow toggles
        // between the two buttons; OK with focus elsewhere = Next Episode (the default).
        if (isTvDevice && nextUpPanel.visibility == View.VISIBLE && event.action == KeyEvent.ACTION_DOWN) {
            val play = findViewById<View>(R.id.next_up_play)
            val cancel = findViewById<View>(R.id.next_up_cancel)
            val inCard = currentFocus?.let { isInside(nextUpPanel, it) } == true
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> {
                    if (!inCard) play?.requestFocus()
                    else (if (currentFocus === play) cancel else play)?.requestFocus()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                    if (!inCard) { playNext(auto = false); return true }
                    // focus is on a card button — let the normal click path fire it
                }
            }
        }
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { togglePlayPause(); return true }
                KeyEvent.KEYCODE_MEDIA_PLAY -> { player?.play(); return true }
                KeyEvent.KEYCODE_MEDIA_PAUSE -> { player?.pause(); playerView.showController(); return true }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                    val focusInOverlay = currentFocus?.let { f ->
                        isInside(nextUpPanel, f) || isInside(episodePanel, f)
                            || isInside(subSidePanel, f)   // OK on a caption row = SELECT it, never play/pause (AJ Sep 18)
                            || isInside(liveGuidePanel, f) // OK on a guide row = TUNE it, same deal
                            || f.id == R.id.btn_skip_intro } == true
                    val onTimeBar = currentFocus is androidx.media3.ui.DefaultTimeBar
                    if ((!playerView.isControllerFullyVisible && !focusInOverlay) || onTimeBar) {
                        togglePlayPause(); return true
                    }
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchTouchEvent(ev: android.view.MotionEvent): Boolean {
        // any tap/scrub on phones = someone's there (still-watching chain resets)
        epTouched = true
        return super.dispatchTouchEvent(ev)
    }

    private fun isInside(parent: View, v: View): Boolean {
        var cur: android.view.ViewParent? = v.parent
        while (cur != null) { if (cur === parent) return true; cur = cur.parent }
        return false
    }

    private fun togglePlayPause() {
        val p = player ?: return
        if (p.isPlaying) { p.pause(); playerView.showController() }
        else { p.play(); playerView.hideController() }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            when {
                subSidePanel.visibility == View.VISIBLE -> { hideSubSidePanel(); return true }
                liveGuidePanel.visibility == View.VISIBLE -> { hideLiveGuidePanel(); return true }
                nextUpPanel.visibility == View.VISIBLE -> { hideNextUp(); return true }
                episodePanel.visibility == View.VISIBLE -> { episodePanel.visibility = View.GONE; return true }
                // TV only: back peels the controller first (d-pad has no other way out).
                // Phones exit in ONE press — hiding chrome there made back feel broken.
                isTvDevice && playerView.isControllerFullyVisible -> { playerView.hideController(); return true }
            }
        }
        if (keyCode == KeyEvent.KEYCODE_MEDIA_NEXT) { playNext(auto = false); return true }
        return super.onKeyDown(keyCode, event)
    }

    @Deprecated("gesture-nav back path (phones)")
    override fun onBackPressed() {
        when {
            subSidePanel.visibility == View.VISIBLE -> { hideSubSidePanel(); return }
            liveGuidePanel.visibility == View.VISIBLE -> { hideLiveGuidePanel(); return }
            nextUpPanel.visibility == View.VISIBLE -> { hideNextUp(); return }
            episodePanel.visibility == View.VISIBLE -> { episodePanel.visibility = View.GONE; return }
            isTvDevice && playerView.isControllerFullyVisible -> { playerView.hideController(); return }
        }
        @Suppress("DEPRECATION") super.onBackPressed()
    }

    /** After finishing an episode and backing out (not tapping Next), point Continue Watching at
     *  the NEXT episode with NO saved position — so the tile's progress bar renders BLANK/fresh
     *  instead of stuck full at the end of the episode you just finished (AJ Sep 28). A next
     *  episode not yet aired still gets the fresh pointer (tap → detail page with the air date);
     *  a fully-watched series leaves Continue Watching. If the episode list hasn't loaded, do
     *  nothing and let resume-time derivation sort it out. */
    /** A show earns the Library "Watched" shelf only when the episode just finished is the CURRENT
     *  LAST episode in the list (the newest — nothing after it). Rationale (AJ Sep 28): 7/8 with the
     *  finale not out = not watched (E8 is after it); joined at S5 and watched to the finale = watched
     *  (the finale is the last episode — earlier episodes not watched HERE doesn't matter); when a
     *  NEW season airs, later episodes now exist → the show resurfaces via its new-episode badge
     *  (which keys off watched EPISODES, never this show flag). Conservative (false) if not loaded. */
    private fun isCaughtUp(rc: Ck.StreamCtx): Boolean {
        if (episodes.isEmpty()) return false
        return episodes.dropWhile { !(it.season == rc.season && it.episode == rc.episode) }
            .drop(1).isEmpty()
    }

    private fun advanceCwPointer(rc: Ck.StreamCtx) {
        if (episodes.isEmpty()) return
        val titleId = intent?.getStringExtra("titleId") ?: rc.imdbId
        val after = episodes.dropWhile { !(it.season == rc.season && it.episode == rc.episode) }.drop(1)
        val nxt = after.firstOrNull { !Store.isWatched(this, "$titleId:${it.season}:${it.episode}") }
        if (nxt != null) Store.setCwLast(this, titleId, "$titleId:${nxt.season}:${nxt.episode}")
        else Store.removeContinue(this, titleId)   // whole series watched → leaves Continue Watching
    }

    private fun releasePlayer(saveResume: Boolean = true) {
        player?.let { p ->
            if (placeholderMode) { p.release(); player = null; return }  // waiting screen: no history
            // 500ms floor, was 15s (AJ Sep 13): ANY started playback must survive as a
            // position — a 2-second peek at the next episode IS the new resume point
            // rc = the episode THIS player belongs to (not the global ctx, which may have
            // already advanced to the next episode) — see playerCtx note (AJ Sep 18)
            val rc = playerCtx ?: ctx
            if (saveResume && p.duration > 0 && p.currentPosition in 500 until finishPointMs(p)) {
                Ck.saveResume(this, rc?.epId, p.currentPosition, p.duration)
                Ck.reportServer(this, rc, p.currentPosition, p.duration,
                    introFrom = pendingIntroFrom, introTo = pendingIntroTo)
                Ck.homeStale = true   // Home repaints the moved progress bar on return (AJ Sep 28)
            } else if (saveResume && p.duration > 0 && p.currentPosition >= finishPointMs(p)) {
                markWatchedIfDone(p, force = true, useCtx = rc)
                Ck.reportServer(this, rc, p.duration, p.duration,
                    introFrom = pendingIntroFrom, introTo = pendingIntroTo)
                if (rc?.season != null) advanceCwPointer(rc)
            }
            pendingIntroFrom = null; pendingIntroTo = null
            p.release()
        }
        player = null
    }

    /** singleTop: a stream/episode launched while this player is already top-of-stack is
     *  delivered HERE — without this override Android silently DROPPED the intent, so
     *  picking a different stream looked like "it wouldn't load the other stream".
     *  Treat it exactly like a fresh launch: save the outgoing episode, swap streams. */
    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        if (intent == null) return
        setIntent(intent)
        val url = intent.data?.toString() ?: intent.getStringExtra("url") ?: return
        hideNextUp()
        episodePanel.visibility = View.GONE
        prefetchedNext = null
        episodes = emptyList(); shownSeason = null; showName = ""
        hideLoadingScreen()   // a still-up overlay from the previous launch must not stack
        buildLoadingScreen()
        start(url, intent.getStringExtra("title"))
    }

    override fun onPause() {
        super.onPause()
        // Entering pop-out (PiP) also fires onPause — but playback must KEEP GOING in the
        // floating window, so don't touch the player while we're in PiP.
        if (inPip) return
        // HOME press / TV sleep mid-episode: save + report NOW. onDestroy may never run
        // (Fire OS kills the cached process silently), which lost whole binge sessions —
        // the Firestick had the progress, the account never did (Sep 3, David's Y:TLM).
        player?.let { p ->
            if (!isFinishing && !placeholderMode && p.duration > 0 && p.currentPosition >= 15_000) {
                // Watched only once credits roll (the learned/subtitle credits point, AJ Sep 10:
                // "we need the real end"). Before it → keep a resume point so the bar shows how
                // much is left; in the credits → count it watched (no resume dumped in credits).
                if (p.currentPosition < finishPointMs(p)) {
                    Ck.saveResume(this, ctx?.epId, p.currentPosition, p.duration)
                    Ck.reportServer(this, ctx, p.currentPosition, p.duration)
                } else markWatchedIfDone(p, force = true)
                Ck.homeStale = true
            }
            p.pause()
        }
        releaseIfFinishing()
        // and the account blob rides up with it — a binge that ends inside the player
        // must sync without ever visiting the home screen again
        if (Store.signedIn(this)) Thread {
            try { kotlinx.coroutines.runBlocking { Sync.push(this@PlayerActivity) } } catch (_: Exception) {}
        }.start()
    }
    private fun releaseIfFinishing() { if (isFinishing) releasePlayer() }
    override fun onStop() {
        super.onStop()
        // Closing the PiP window (X) stops the activity while it's still in PiP — don't linger
        // playing audio in the background; finish so playback actually stops (AJ Sep 27).
        if (inPip && !isChangingConfigurations) {
            runCatching { releasePlayer(saveResume = true) }
            if (!isFinishing) finish()
            return
        }
        // LIVE TV: fully STOP streaming the instant the player leaves the screen (home press,
        // app switch, backing out). A paused live .ts keeps its TCP socket OPEN, so the server
        // never sees it close and the account's device slot stays held — that was why
        // switching devices "took way longer than 90s" (AJ Sep 18). Releasing closes the
        // connection → the slot frees immediately. Live has no resume, so we finish outright.
        // VOD is untouched (keeps its player for instant resume on return).
        if (intent?.getStringExtra("id") == "live" && !isChangingConfigurations) {
            runCatching { releasePlayer(saveResume = false) }
            if (!isFinishing) finish()
        }
    }
    override fun onDestroy() {
        pipReceiver?.let { runCatching { unregisterReceiver(it) } }; pipReceiver = null
        releasePlayer()
        ui.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    // ---- Pop-out (Picture-in-Picture), mobile only ----
    private val inPip get() =
        android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N && isInPictureInPictureMode

    private val pipToggleAction = "app.mediaboard.PIP_TOGGLE"
    private val pipBackAction = "app.mediaboard.PIP_BACK"
    private val pipFwdAction = "app.mediaboard.PIP_FWD"
    private val pipNextAction = "app.mediaboard.PIP_NEXT"
    private var pipReceiver: android.content.BroadcastReceiver? = null

    private fun pipAction(req: Int, iconRes: Int, title: String, action: String): android.app.RemoteAction {
        val icon = android.graphics.drawable.Icon.createWithResource(this, iconRes)
        val pi = android.app.PendingIntent.getBroadcast(this, req,
            android.content.Intent(action).setPackage(packageName),
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE)
        return android.app.RemoteAction(icon, title, title, pi)
    }

    /** PiP window params (exactly 3 actions — the common phone limit): -10s / play-pause / +10s.
     *  Near the end of a show WITH a next episode, the 3rd slot becomes Next so it's reachable
     *  without a (usually-unavailable) 4th slot (AJ Sep 28). The play/pause icon tracks
     *  playWhenReady (the play INTENT), not isPlaying — otherwise a seek's brief buffering flips it
     *  to a Play icon while it's actually still playing. */
    private fun buildPipParams(): android.app.PictureInPictureParams {
        val playing = player?.playWhenReady == true
        val pp = pipAction(1, if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            if (playing) "Pause" else "Play", pipToggleAction)
        val back = pipAction(2, android.R.drawable.ic_media_rew, "-10s", pipBackAction)
        val p = player
        val nearEnd = p != null && p.duration > 0 && p.currentPosition >= finishPointMs(p)
        val third = if (ctx?.season != null && nearEnd && nextEpisode() != null)
            pipAction(4, android.R.drawable.ic_media_next, "Next", pipNextAction)
        else pipAction(3, android.R.drawable.ic_media_ff, "+10s", pipFwdAction)
        val f = player?.videoFormat
        val ratio = if (f != null && f.width > 0 && f.height > 0)
            android.util.Rational(f.width, f.height) else android.util.Rational(16, 9)
        return android.app.PictureInPictureParams.Builder()
            .setAspectRatio(ratio).setActions(listOf(back, pp, third)).build()
    }
    private var lastPipNearEnd = false

    private fun refreshPipActions() {
        if (inPip && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O)
            runCatching { setPictureInPictureParams(buildPipParams()) }
    }

    private fun enterPip() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
        runCatching { enterPictureInPictureMode(buildPipParams()) }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            // strip all chrome — the floating window shows video only
            playerView.useController = false
            playerView.hideController()
            findViewById<View>(R.id.top_overlay)?.visibility = View.GONE
            // the play/pause button on the PiP window sends this broadcast back to us
            if (pipReceiver == null) {
                pipReceiver = object : android.content.BroadcastReceiver() {
                    override fun onReceive(c: Context?, i: android.content.Intent?) {
                        val p = player ?: return
                        when (i?.action) {
                            pipToggleAction -> { if (p.isPlaying) p.pause() else p.play() }
                            pipBackAction -> p.seekTo((p.currentPosition - 10_000).coerceAtLeast(0))
                            pipFwdAction -> p.seekTo((p.currentPosition + 10_000)
                                .coerceAtMost(if (p.duration > 0) p.duration else Long.MAX_VALUE))
                            pipNextAction -> { if (ctx?.season != null && nextEpisode() != null) playNext(auto = false) }
                            else -> return
                        }
                        refreshPipActions()
                    }
                }
                val filter = android.content.IntentFilter().apply {
                    addAction(pipToggleAction); addAction(pipBackAction)
                    addAction(pipFwdAction); addAction(pipNextAction)
                }
                if (android.os.Build.VERSION.SDK_INT >= 33)
                    registerReceiver(pipReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                else @Suppress("UnspecifiedRegisterReceiverFlag") registerReceiver(pipReceiver, filter)
            }
            refreshPipActions()
        } else {
            playerView.useController = true
            pipReceiver?.let { runCatching { unregisterReceiver(it) } }
            pipReceiver = null
        }
    }

    private val isTvDevice by lazy {
        (getSystemService(UI_MODE_SERVICE) as android.app.UiModeManager).currentModeType ==
            android.content.res.Configuration.UI_MODE_TYPE_TELEVISION
    }

    companion object {
        /** Legacy hook from the pre-port player — the ported player binges on its own. */
        var onAdvance: ((Boolean) -> Unit)? = null

        fun launch(ctx: Context, url: String, title: String, id: String,
                   nextLabel: String? = null, nextThumb: String? = null,
                   poster: String? = null, titleId: String? = null, type: String? = null,
                   subsJson: String? = null, backdrop: String? = null, logo: String? = null,
                   live: String? = null) =
            ctx.startActivity(Intent(ctx, PlayerActivity::class.java)
                .putExtra("url", url).putExtra("title", title).putExtra("id", id)
                .putExtra("nextLabel", nextLabel).putExtra("nextThumb", nextThumb)
                .putExtra("poster", poster).putExtra("titleId", titleId).putExtra("type", type)
                .putExtra("subs", subsJson).putExtra("backdrop", backdrop).putExtra("logo", logo)
                .putExtra("live", live))
    }
}
