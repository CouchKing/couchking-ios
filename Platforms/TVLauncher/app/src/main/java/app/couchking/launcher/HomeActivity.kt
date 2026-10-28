package app.couchking.launcher

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.ViewOutlineProvider
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextClock
import android.widget.TextView
import android.widget.Toast
import java.util.Calendar
import java.util.Locale
import kotlin.concurrent.thread

/**
 * CouchKing home screen for the onn 4K Google TV, styled after the CouchKing app's own Home:
 * a full-screen hero, then shelves — the four kept apps, the signed-in profile's Continue
 * Watching and My List (read from the CouchKing account), and a Top 10 Today with giant
 * outlined rank numerals. The UI is built in code so the launcher has no library dependencies.
 */
class HomeActivity : Activity() {

    private data class App(val pkg: String, val label: String, val accent: Int)

    /** What the hero shows for the focused (or rotating) item. */
    private data class Hero(
        val key: String,
        val badge: String,
        val title: String,
        val meta: String,
        val overview: String,
        val backdrop: String?,
        val cta: String,
    )

    /** One poster on a shelf. */
    private class Card(
        val title: String,
        val poster: String?,
        val rank: Int? = null,
        val progress: Double? = null,
        val chip: String? = null,
        val hero: () -> Hero,
        val open: () -> Unit,
    )

    /** A focus row: the header, the apps shelf, or a poster shelf. */
    private class Row(val tiles: List<View>, var view: View?) {
        var last = 0
    }

    private val apps = listOf(
        App(COUCHKING, "CouchKing", GOLD),
        App("com.google.android.youtube.tv", "YouTube", 0xFFFF3B3B.toInt()),
        App("com.spotify.tv.android", "Spotify", 0xFF1ED760.toInt()),
        App("com.esaba.downloader", "Downloader", 0xFFFF8A1E.toInt()),
    )

    private var titles: List<Title> = emptyList()
    private var library = Library(emptyList(), null, emptyList(), emptyList())
    private val details = HashMap<String, MetaDetails?>()
    private var rows: List<Row> = emptyList()
    private lateinit var headerRow: Row
    private lateinit var appRow: Row
    private var heroIndex = -1
    private var heroKey = ""
    private var browsing = false   // focus is on a title, so the hero follows it instead of rotating

    private lateinit var heroBack: ImageView
    private lateinit var heroFront: ImageView
    private lateinit var heroInfo: LinearLayout
    private lateinit var heroBadge: TextView
    private lateinit var heroTitle: TextView
    private lateinit var heroMeta: TextView
    private lateinit var heroOverview: TextView
    private lateinit var heroCta: TextView
    private lateinit var greeting: TextView
    private lateinit var profileChip: TextView
    private lateinit var settingsButton: TextView
    private lateinit var shelves: LinearLayout
    private lateinit var shelfScroll: ScrollView

    // Idle showcase, like the app: rotate trending in the hero every 9s until someone browses.
    private val rotate = object : Runnable {
        override fun run() {
            if (!browsing && titles.isNotEmpty()) showTrending((heroIndex + 1) % titles.size)
            heroInfo.postDelayed(this, 9_000)
        }
    }

    private val greetingTick = object : Runnable {
        override fun run() {
            greeting.text = greetingText()
            greeting.postDelayed(this, 60_000)
        }
    }

    // Continue Watching moves while people watch on other devices; re-pull every 5 minutes.
    private val accountTick = object : Runnable {
        override fun run() {
            refreshAccount()
            shelves.postDelayed(this, 5 * 60_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())
        hideSystemBars()
        handleAccountIntent(intent)
        titles = Trending.cached(this)
        library = Account.library(this, Account.cachedState(this))
        rebuildShelves()
        showIdleHero()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAccountIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        refreshAppTiles()
        if (titles.isEmpty() || Trending.isStale(this)) refreshTrending()
        greeting.removeCallbacks(greetingTick)
        greetingTick.run()
        heroInfo.removeCallbacks(rotate)
        heroInfo.postDelayed(rotate, 9_000)
        shelves.removeCallbacks(accountTick)
        accountTick.run()
        if (currentFocus == null) focusRow(appRow)
    }

    override fun onPause() {
        super.onPause()
        greeting.removeCallbacks(greetingTick)
        heroInfo.removeCallbacks(rotate)
        shelves.removeCallbacks(accountTick)
    }

    /**
     * couchking-tv-setup.sh signs in on the Mac and hands the token over with
     * `am start --es ck_email … --es ck_token …`; `--ez ck_signout true` forgets it.
     */
    private fun handleAccountIntent(i: Intent?) {
        i ?: return
        if (i.getBooleanExtra("ck_signout", false)) {
            Account.signOut(this)
            library = Account.library(this, null)
            if (::shelves.isInitialized) rebuildShelves()
        }
        val email = i.getStringExtra("ck_email")
        val token = i.getStringExtra("ck_token")
        if (!email.isNullOrBlank() && !token.isNullOrBlank()) {
            Account.save(this, email.trim().lowercase(Locale.US), token.trim())
            Toast.makeText(this, "Signed in to CouchKing as $email", Toast.LENGTH_LONG).show()
            refreshAccount()
        }
        i.removeExtra("ck_token")
    }

    // ---------------------------------------------------------------- keys

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Home must never be left with BACK.
        if (event.keyCode == KeyEvent.KEYCODE_BACK) return true
        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)
        val f = currentFocus ?: return super.dispatchKeyEvent(event)
        val r = rows.indexOfFirst { f in it.tiles }
        if (r < 0) return super.dispatchKeyEvent(event)
        val row = rows[r]
        val i = row.tiles.indexOf(f)
        // All D-pad moves are explicit so focus never jumps somewhere surprising.
        when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> { rows.getOrNull(r - 1)?.let { focusRow(it) }; return true }
            KeyEvent.KEYCODE_DPAD_DOWN -> { rows.getOrNull(r + 1)?.let { focusRow(it) }; return true }
            KeyEvent.KEYCODE_DPAD_LEFT -> { row.tiles.getOrNull(i - 1)?.requestFocus(); return true }
            KeyEvent.KEYCODE_DPAD_RIGHT -> { row.tiles.getOrNull(i + 1)?.requestFocus(); return true }
        }
        return super.dispatchKeyEvent(event)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Intentionally empty: this is the home screen.
    }

    private fun focusRow(row: Row) {
        row.tiles.getOrNull(row.last.coerceIn(0, maxOf(0, row.tiles.lastIndex)))?.requestFocus()
    }

    /** Netflix-style: the focused shelf slides to the top of the shelf area. */
    private fun onRowFocused(row: Row, index: Int) {
        row.last = index
        val target = if (row === appRow) 0 else row.view?.top ?: 0
        shelfScroll.post { shelfScroll.smoothScrollTo(0, target) }
    }

    // ---------------------------------------------------------------- layout

    private fun buildUi(): View {
        val root = FrameLayout(this).apply { setBackgroundColor(BG_DEEP) }

        // Hero backdrop: two stacked images that crossfade.
        heroBack = heroImage().also { root.addView(it, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)) }
        heroFront = heroImage().also { root.addView(it, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)) }

        // Scrims keep text readable over any backdrop.
        root.addView(scrim(GradientDrawable.Orientation.LEFT_RIGHT, 0xF21B1830.toInt(), 0x991B1830.toInt(), 0x001B1830),
            FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        root.addView(scrim(GradientDrawable.Orientation.BOTTOM_TOP, 0xFF0E0C1A.toInt(), 0xE61B1830.toInt(), 0x001B1830),
            FrameLayout.LayoutParams(MATCH_PARENT, dp(330), Gravity.BOTTOM))
        root.addView(scrim(GradientDrawable.Orientation.TOP_BOTTOM, 0xB30E0C1A.toInt(), 0x400E0C1A, 0x000E0C1A),
            FrameLayout.LayoutParams(MATCH_PARENT, dp(120), Gravity.TOP))

        root.addView(buildHeroInfo(), FrameLayout.LayoutParams(dp(520), WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
            setMargins(dp(48), dp(84), 0, 0)
        })

        shelves = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            clipChildren = false
            clipToPadding = false
            setPadding(0, dp(6), 0, dp(220))   // tail room so the last shelf can reach the top
        }
        shelfScroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            isFocusable = false
            clipChildren = false
            clipToPadding = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(shelves)
        }
        root.addView(shelfScroll, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT).apply { topMargin = dp(248) })

        appRow = Row(buildAppTiles(), null)
        root.addView(buildHeader(), FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.TOP).apply {
            setMargins(dp(48), dp(22), dp(48), 0)
        })

        root.addView(text("Trending data: TMDB · Details: Cinemeta", 10f, 0x80A9A5C0.toInt()),
            FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.END).apply {
                setMargins(0, 0, dp(16), dp(6))
            })
        return root
    }

    private fun buildHeader(): View {
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val brand = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val wordmark = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        wordmark.addView(text("♛", 30f, GOLD), LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply {
            marginEnd = dp(10)
        })
        wordmark.addView(text("CouchKing", 28f, Color.WHITE, bold = true))
        wordmark.addView(text(" TV", 28f, GOLD, bold = true))
        brand.addView(wordmark)
        greeting = text(greetingText(), 14f, MUTED).apply { setPadding(dp(2), 0, 0, 0) }
        brand.addView(greeting)
        header.addView(brand, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))

        val clockBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.END
        }
        clockBox.addView(TextClock(this).apply {
            format12Hour = "h:mm a"
            format24Hour = "HH:mm"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 34f)
            setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            includeFontPadding = false
            gravity = Gravity.END
        })
        clockBox.addView(TextClock(this).apply {
            format12Hour = "EEEE, MMMM d"
            format24Hour = "EEEE, MMMM d"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(GOLD)
            gravity = Gravity.END
        })
        header.addView(clockBox, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))

        // Who's watching: shows the CouchKing profile whose shelves are on screen; OK switches.
        profileChip = text("", 15f, Color.WHITE, bold = true).apply {
            gravity = Gravity.CENTER
            isFocusable = true
            isClickable = true
            setPadding(dp(16), 0, dp(16), 0)
            background = pill(false)
            visibility = View.GONE
            setOnFocusChangeListener { v, has ->
                v.background = pill(has)
                (v as TextView).setTextColor(if (has) BG_DEEP else Color.WHITE)
                if (has) onRowFocused(headerRow, 0)
            }
            setOnClickListener { nextProfile() }
        }
        header.addView(profileChip, LinearLayout.LayoutParams(WRAP_CONTENT, dp(44)).apply { marginStart = dp(20) })

        settingsButton = text("⚙", 22f, Color.WHITE).apply {
            gravity = Gravity.CENTER
            isFocusable = true
            isClickable = true
            background = circle(false)
            setOnFocusChangeListener { v, has ->
                v.background = circle(has)
                (v as TextView).setTextColor(if (has) BG_DEEP else Color.WHITE)
                if (has) onRowFocused(headerRow, headerRow.tiles.indexOf(v))
            }
            setOnClickListener { tryStart(Intent(Settings.ACTION_SETTINGS), "Settings") }
        }
        header.addView(settingsButton, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginStart = dp(12) })
        headerRow = Row(listOf(settingsButton), null)
        return header
    }

    private fun buildHeroInfo(): View {
        heroInfo = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        heroBadge = text("", 11f, BG_DEEP, bold = true).apply {
            letterSpacing = 0.12f
            setPadding(dp(10), dp(3), dp(10), dp(3))
            background = GradientDrawable().apply { cornerRadius = dp(4).toFloat(); setColor(GOLD) }
        }
        heroInfo.addView(heroBadge, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        heroTitle = text("", 34f, Color.WHITE, bold = true).apply {
            ellipsize = TextUtils.TruncateAt.END
            setShadowLayer(12f, 0f, 2f, 0xCC000000.toInt())
            setPadding(0, dp(6), 0, 0)
        }
        heroInfo.addView(heroTitle)
        heroMeta = text("", 14f, GOLD, bold = true)
        heroInfo.addView(heroMeta)
        heroOverview = text("", 14f, 0xFFE4E1F0.toInt()).apply {
            isSingleLine = false
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setLineSpacing(0f, 1.15f)
            setPadding(0, dp(6), 0, 0)
        }
        heroInfo.addView(heroOverview)
        heroCta = text("", 13f, MUTED, bold = true).apply { setPadding(0, dp(8), 0, 0) }
        heroInfo.addView(heroCta)
        return heroInfo
    }

    private fun buildAppTiles(): List<View> = apps.mapIndexed { i, app ->
        FrameLayout(this).apply {
            isFocusable = true
            isClickable = true
            tag = app
            background = card(false, app.accent)
            clipToOutline = true
            outlineProvider = rounded(dp(14))
            setPadding(dp(3), dp(3), dp(3), dp(3))
            addView(ImageView(this@HomeActivity).apply { scaleType = ImageView.ScaleType.CENTER_CROP },
                FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            addView(text(app.label, 15f, Color.WHITE, bold = true).apply {
                setShadowLayer(8f, 0f, 1f, Color.BLACK)
                setPadding(dp(10), 0, dp(10), dp(6))
            }, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.START))
            setOnClickListener { launch(app) }
            setOnFocusChangeListener { v, has ->
                if (has) {
                    onRowFocused(appRow, i)
                    browsing = false
                    heroCta.text = "●  Open ${app.label}"
                }
                grow(v, has, 1.1f)
                v.background = card(has, app.accent)
            }
        }
    }

    // ---------------------------------------------------------------- shelves

    /** Rebuilds every shelf from the current data, keeping focus on the same shelf + position. */
    private fun rebuildShelves() {
        val old = rows.firstOrNull { currentFocus in it.tiles }
        val oldLabel = old?.view?.tag
        val keep = old?.last ?: 0

        refreshHeader()
        shelves.removeAllViews()
        shelves.addView(shelf("Your apps", appRow.tiles, dp(160), dp(90), dp(18)))
        val built = mutableListOf(headerRow, appRow)

        val profileName = library.profile?.name?.let { "$it's" } ?: "Your"
        val cw = library.continueWatching.take(20).map { e -> libraryCard(e, inProgress = true) }
        val wl = library.watchlist.take(20).map { e -> libraryCard(e, inProgress = false) }
        val top = titles.take(10).mapIndexed { i, t ->
            Card(t.name, t.poster, rank = i + 1, hero = { trendingHero(t, i) }, open = { watchOnCouchKing(t) })
        }
        for ((label, cards) in listOf(
            "Continue Watching" to cw,
            "$profileName List" to wl,
            "Top 10 Today on CouchKing" to top,
        )) {
            if (cards.isEmpty()) continue
            val tiles = ArrayList<View>()
            val row = Row(tiles, null)
            cards.forEachIndexed { i, c -> tiles += posterTile(c, row, i) }
            row.view = shelf(label, tiles, 0, 0, 0)
            shelves.addView(row.view)
            built += row
        }
        rows = built

        if (!browsing && (heroKey.isEmpty() || heroKey == "brand")) showIdleHero()
        if (old == null) return
        val target = when {
            oldLabel != null -> rows.firstOrNull { it.view?.tag == oldLabel } ?: appRow
            old === appRow -> appRow
            else -> headerRow
        }
        target.last = keep.coerceAtMost(maxOf(0, target.tiles.lastIndex))
        focusRow(target)
    }

    private fun shelf(label: String, tiles: List<View>, w: Int, h: Int, gap: Int): View {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            clipChildren = false
            clipToPadding = false
            tag = label
            setPadding(0, 0, 0, dp(10))
        }
        box.addView(sectionLabel(label).apply { setPadding(dp(52), 0, 0, dp(4)) })
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            clipChildren = false
            clipToPadding = false
            setPadding(dp(48), dp(6), dp(48), dp(6))
        }
        tiles.forEach { t ->
            (t.parent as? LinearLayout)?.removeView(t)
            val lp = if (w > 0) LinearLayout.LayoutParams(w, h).apply { marginEnd = gap }
            else t.layoutParams as LinearLayout.LayoutParams
            row.addView(t, lp)
        }
        box.addView(HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            clipChildren = false
            clipToPadding = false
            isFocusable = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(row)
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        return box
    }

    /** A poster with optional giant rank numeral (Top 10), progress bar and episode chip. */
    private fun posterTile(c: Card, row: Row, index: Int): View {
        val item = FrameLayout(this).apply {
            isFocusable = true
            isClickable = true
            clipChildren = false
            setOnClickListener { c.open() }
        }
        var numeral: TextView? = null
        if (c.rank != null) {
            numeral = text(c.rank.toString(), 88f, MUTED, bold = true)
            item.addView(numeral.apply {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = dp(2).toFloat()
                includeFontPadding = false
                typeface = Typeface.create("sans-serif-black", Typeface.BOLD)
            }, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.START).apply {
                bottomMargin = -dp(14)
            })
        }
        val poster = FrameLayout(this).apply {
            clipToOutline = true
            outlineProvider = rounded(dp(10))
            background = GradientDrawable().apply { setColor(CARD) }
        }
        val img = ImageView(this).apply { scaleType = ImageView.ScaleType.CENTER_CROP }
        poster.addView(img, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        Images.into(img, c.poster)
        if (c.chip != null) {
            poster.addView(text(c.chip, 10f, Color.WHITE, bold = true).apply {
                setPadding(dp(6), dp(2), dp(6), dp(2))
                background = GradientDrawable().apply { cornerRadius = dp(4).toFloat(); setColor(0xCC0E0C1A.toInt()) }
            }, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
                setMargins(dp(5), dp(5), 0, 0)
            })
        }
        if (c.progress != null && c.progress > 0) {
            poster.addView(View(this).apply { setBackgroundColor(0x99000000.toInt()) },
                FrameLayout.LayoutParams(MATCH_PARENT, dp(4), Gravity.BOTTOM))
            poster.addView(View(this).apply { setBackgroundColor(GOLD) },
                FrameLayout.LayoutParams((dp(78) * c.progress.coerceIn(0.04, 1.0)).toInt(), dp(4), Gravity.BOTTOM or Gravity.START))
        }
        if (c.poster == null) {
            poster.addView(text(c.title, 12f, Color.WHITE, bold = true).apply {
                isSingleLine = false
                maxLines = 4
                gravity = Gravity.CENTER
                setPadding(dp(6), 0, dp(6), 0)
            }, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.CENTER))
        }
        item.addView(poster, FrameLayout.LayoutParams(dp(78), dp(117), Gravity.END or Gravity.CENTER_VERTICAL))
        val width = when {
            c.rank == null -> dp(78)
            c.rank >= 10 -> dp(156)
            else -> dp(126)
        }
        item.layoutParams = LinearLayout.LayoutParams(width, dp(128)).apply { marginEnd = dp(if (c.rank == null) 16 else 8) }
        item.setOnFocusChangeListener { _, has ->
            if (has) {
                onRowFocused(row, index)
                browsing = true
                showHero(c.hero())
            }
            grow(poster, has, 1.12f)
            poster.foreground = if (has) GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setStroke(dp(3), GOLD)
            } else null
            numeral?.setTextColor(if (has) GOLD else MUTED)
        }
        return item
    }

    private fun libraryCard(e: Entry, inProgress: Boolean): Card {
        val ep = episodeLabel(e.resumeKey)
        return Card(
            title = e.name,
            poster = e.poster,
            progress = if (inProgress) e.progress else null,
            chip = if (inProgress) ep else null,
            hero = { libraryHero(e, inProgress) },
            open = { openLibraryTitle(e) },
        )
    }

    // ---------------------------------------------------------------- hero

    private fun trendingHero(t: Title, index: Int): Hero {
        val rank = index + 1
        return Hero(
            key = "tmdb:${t.tmdbId}",
            badge = if (rank <= 10) "#$rank TRENDING TODAY" else "TRENDING TODAY",
            title = t.name,
            meta = listOfNotNull(
                t.year.ifBlank { null },
                if (t.type == "tv") "Series" else "Movie",
                if (t.rating > 0) "★ " + String.format(Locale.US, "%.1f", t.rating) else null,
            ).joinToString("   ·   "),
            overview = t.overview,
            backdrop = t.backdrop,
            cta = if (browsing) "●  Watch on CouchKing" else heroCta.text.toString(),
        )
    }

    private fun libraryHero(e: Entry, inProgress: Boolean): Hero {
        val d = details[e.imdbId]
        if (!details.containsKey(e.imdbId)) loadDetails(e)
        val ep = episodeLabel(e.resumeKey)
        val pct = (e.progress * 100).toInt()
        return Hero(
            key = "imdb:${e.imdbId}",
            badge = if (inProgress) "CONTINUE WATCHING" else "ON YOUR LIST",
            title = e.name,
            meta = listOfNotNull(
                d?.year?.ifBlank { null },
                if (e.type == "series") "Series" else "Movie",
                d?.rating?.ifBlank { null }?.let { "★ $it" },
                ep,
                if (inProgress && pct in 1..99) "$pct% watched" else null,
            ).joinToString("   ·   "),
            overview = d?.description ?: "",
            backdrop = d?.background,
            cta = if (inProgress) "●  Resume on CouchKing" else "●  Watch on CouchKing",
        )
    }

    private fun loadDetails(e: Entry) {
        details[e.imdbId] = null
        thread(isDaemon = true) {
            val d = Account.details(e.type, e.imdbId) ?: return@thread
            runOnUiThread {
                details[e.imdbId] = d
                // Still looking at this title? Fill in the backdrop + synopsis now.
                if (heroKey == "imdb:${e.imdbId}") {
                    val inProgress = library.continueWatching.any { it.imdbId == e.imdbId }
                    showHero(libraryHero(e, inProgress), force = true)
                }
            }
        }
    }

    private fun showTrending(index: Int) {
        val t = titles.getOrNull(index) ?: return
        heroIndex = index
        showHero(trendingHero(t, index))
        Images.prefetch(titles.getOrNull((index + 1) % titles.size)?.backdrop)
    }

    /** The resting hero: trending when we have it, else the person's own next watch, else the brand. */
    private fun showIdleHero() {
        when {
            titles.isNotEmpty() -> showTrending(0)
            library.continueWatching.isNotEmpty() -> showHero(libraryHero(library.continueWatching[0], true))
            else -> showHero(Hero(
                key = "brand",
                badge = "COUCHKING",
                title = "Movies & shows, all yours",
                meta = "Trending titles appear here once the TV is online",
                overview = "Open CouchKing to pick up where you left off.",
                backdrop = null,
                cta = "●  Open CouchKing",
            ))
        }
    }

    private fun showHero(h: Hero, force: Boolean = false) {
        if (h.key == heroKey && !force) return
        val fade = h.key != heroKey
        heroKey = h.key
        heroBadge.text = h.badge
        heroTitle.text = h.title
        heroMeta.text = h.meta
        heroOverview.text = h.overview
        heroCta.text = h.cta
        if (fade) {
            heroInfo.alpha = 0f
            heroInfo.animate().alpha(1f).setDuration(350).start()
        }
        if (h.backdrop == null) {
            if (fade) {
                heroFront.animate().alpha(0f).setDuration(400).start()
                heroBack.setImageDrawable(null)
            }
            return
        }
        val key = h.key
        Images.load(h.backdrop) { bmp ->
            if (bmp == null || heroKey != key) return@load
            // Crossfade: the new backdrop fades in on top, then becomes the bottom layer.
            heroFront.animate().cancel()
            heroFront.setImageBitmap(bmp)
            heroFront.alpha = 0f
            heroFront.animate().alpha(1f).setDuration(700).withEndAction {
                heroBack.setImageBitmap(bmp)
                heroFront.alpha = 0f
            }.start()
        }
    }

    // ---------------------------------------------------------------- data

    private fun refreshTrending() {
        thread(isDaemon = true) {
            val fresh = Trending.fetch(applicationContext) ?: return@thread
            runOnUiThread {
                if (isDestroyed) return@runOnUiThread
                titles = fresh
                rebuildShelves()
                if (!browsing) showTrending(0)
            }
        }
    }

    private fun refreshAccount() {
        if (!Account.signedIn(this)) { refreshHeader(); return }
        thread(isDaemon = true) {
            val state = Account.fetchState(applicationContext)
            runOnUiThread {
                if (isDestroyed) return@runOnUiThread
                library = Account.library(this, state ?: Account.cachedState(this))
                rebuildShelves()
            }
        }
    }

    private fun nextProfile() {
        val ps = library.profiles
        if (ps.size < 2) return
        val next = ps[(ps.indexOfFirst { it.id == library.profile?.id } + 1) % ps.size]
        Account.setProfileId(this, next.id)
        library = Account.library(this, Account.cachedState(this))
        rebuildShelves()
        profileChip.requestFocus()
        Toast.makeText(this, "Now showing ${next.name}'s shelves", Toast.LENGTH_SHORT).show()
    }

    private fun refreshHeader() {
        val p = library.profile
        if (p != null) {
            val face = p.avatar.ifBlank { p.name.take(1).uppercase() }
            profileChip.text = if (library.profiles.size > 1) "$face  ${p.name}  ▾" else "$face  ${p.name}"
            profileChip.visibility = View.VISIBLE
            headerRow = Row(listOf(profileChip, settingsButton), null).also { it.last = headerRow.last }
        } else {
            profileChip.visibility = View.GONE
            headerRow = Row(listOf(settingsButton), null)
        }
        greeting.text = greetingText()
    }

    // ---------------------------------------------------------------- apps

    /** Re-read install state each time Home comes back, so a disabled app shows as unavailable. */
    private fun refreshAppTiles() {
        for (tile in appRow.tiles) {
            tile as FrameLayout
            val app = tile.tag as App
            val art = tile.getChildAt(0) as ImageView
            val label = tile.getChildAt(1) as TextView
            val installed = launchIntentFor(app.pkg) != null
            val banner = bannerFor(app.pkg)
            if (banner != null) {
                art.scaleType = ImageView.ScaleType.CENTER_CROP
                art.setPadding(0, 0, 0, 0)
                art.setImageDrawable(banner)
            } else {
                // No TV banner: centered icon (or the crown) with the name underneath.
                art.scaleType = ImageView.ScaleType.CENTER_INSIDE
                art.setPadding(0, dp(12), 0, dp(26))
                art.setImageDrawable(iconFor(app.pkg))
            }
            label.visibility = if (banner == null || !installed) View.VISIBLE else View.GONE
            label.text = if (installed) app.label else "${app.label} · not installed"
            tile.alpha = if (installed) 1f else 0.45f
        }
    }

    private fun bannerFor(pkg: String): Drawable? = try {
        packageManager.getApplicationBanner(pkg)
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    private fun iconFor(pkg: String): Drawable? = try {
        packageManager.getApplicationIcon(pkg)
    } catch (e: PackageManager.NameNotFoundException) {
        getDrawable(R.drawable.ic_crown)
    }

    private fun launchIntentFor(pkg: String): Intent? =
        packageManager.getLaunchIntentForPackage(pkg)
            ?: packageManager.getLeanbackLaunchIntentForPackage(pkg)

    private fun launch(app: App) {
        val intent = launchIntentFor(app.pkg)
            ?: return Toast.makeText(this, "${app.label} isn't installed", Toast.LENGTH_SHORT).show()
        tryStart(intent, app.label)
    }

    /**
     * Opens CouchKing. The extras name the chosen title so CouchKing can jump straight to it
     * once it reads them; until then it simply opens to its Home.
     */
    private fun watchOnCouchKing(t: Title) = openCouchKing {
        putExtra("ck_tmdb_id", t.tmdbId)
        putExtra("ck_type", if (t.type == "tv") "series" else "movie")
        putExtra("ck_title", t.name)
    }

    private fun openLibraryTitle(e: Entry) = openCouchKing {
        putExtra("ck_imdb_id", e.imdbId)
        putExtra("ck_type", e.type)
        putExtra("ck_title", e.name)
        putExtra("ck_resume", e.resumeKey)
        library.profile?.let { putExtra("ck_profile", it.id) }
    }

    private fun openCouchKing(extras: Intent.() -> Unit) {
        val intent = launchIntentFor(COUCHKING)
            ?: return Toast.makeText(this, "CouchKing isn't installed", Toast.LENGTH_SHORT).show()
        tryStart(intent.apply(extras), "CouchKing")
    }

    private fun tryStart(intent: Intent, label: String) {
        try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            Toast.makeText(this, "Couldn't open $label", Toast.LENGTH_SHORT).show()
        }
    }

    // ---------------------------------------------------------------- helpers

    /** "tt123:2:5" → "S2 E5"; a movie id → null. */
    private fun episodeLabel(key: String): String? {
        val p = key.split(":")
        return if (p.size >= 3) "S${p[1]} E${p[2]}" else null
    }

    private fun hideSystemBars() {
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
        }
    }

    private fun greetingText(): String {
        val part = when (Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) {
            in 5..11 -> "Good morning"
            in 12..16 -> "Good afternoon"
            in 17..21 -> "Good evening"
            else -> "Late night"
        }
        return "$part, ${library.profile?.name ?: "your Majesty"}"
    }

    private fun grow(v: View, focused: Boolean, scale: Float) {
        v.animate()
            .scaleX(if (focused) scale else 1f)
            .scaleY(if (focused) scale else 1f)
            .translationZ(if (focused) dp(16).toFloat() else 0f)
            .setDuration(160)
            .start()
    }

    private fun heroImage() = ImageView(this).apply { scaleType = ImageView.ScaleType.CENTER_CROP }

    private fun scrim(orientation: GradientDrawable.Orientation, vararg colors: Int) =
        View(this).apply { background = GradientDrawable(orientation, colors) }

    private fun sectionLabel(s: String) = text(s, 13f, MUTED, bold = true).apply {
        letterSpacing = 0.16f
        isAllCaps = true
    }

    private fun card(focused: Boolean, accent: Int) = GradientDrawable().apply {
        cornerRadius = dp(14).toFloat()
        setColor(CARD)
        if (focused) setStroke(dp(3), GOLD) else setStroke(dp(1), (accent and 0x00FFFFFF) or 0x55000000)
    }

    private fun circle(focused: Boolean) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        if (focused) setColor(GOLD) else {
            setColor(0x66241F3D)
            setStroke(dp(1), 0x44FFFFFF)
        }
    }

    private fun pill(focused: Boolean) = GradientDrawable().apply {
        cornerRadius = dp(22).toFloat()
        if (focused) setColor(GOLD) else {
            setColor(0x66241F3D)
            setStroke(dp(1), 0x44FFFFFF)
        }
    }

    private fun rounded(radius: Int) = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) =
            outline.setRoundRect(0, 0, view.width, view.height, radius.toFloat())
    }

    private fun text(s: String, sp: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = s
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setTextColor(color)
        if (bold) typeface = Typeface.create("sans-serif", Typeface.BOLD)
        isSingleLine = true
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val COUCHKING = "app.mediaboard"
        private const val GOLD = 0xFFF5C518.toInt()
        private const val MUTED = 0xFFA9A5C0.toInt()
        private const val CARD = 0xFF241F3D.toInt()
        private const val BG_DEEP = 0xFF1B1830.toInt()
    }
}
