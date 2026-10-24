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
import android.widget.TextClock
import android.widget.TextView
import android.widget.Toast
import java.util.Calendar
import java.util.Locale
import kotlin.concurrent.thread

/**
 * CouchKing home screen for the onn 4K Google TV, styled after the CouchKing app's own Home:
 * a full-screen hero rotating through today's trending titles, a row of the four kept apps,
 * and a "Top 10 Today" shelf with giant outlined rank numerals.
 * The UI is built in code so the launcher has no library dependencies.
 */
class HomeActivity : Activity() {

    private data class App(val pkg: String, val label: String, val accent: Int)

    private val apps = listOf(
        App(COUCHKING, "CouchKing", GOLD),
        App("com.google.android.youtube.tv", "YouTube", 0xFFFF3B3B.toInt()),
        App("com.spotify.tv.android", "Spotify", 0xFF1ED760.toInt()),
        App("com.esaba.downloader", "Downloader", 0xFFFF8A1E.toInt()),
    )

    private val appTiles = mutableListOf<FrameLayout>()
    private val topTiles = mutableListOf<FrameLayout>()
    private var titles: List<Title> = emptyList()
    private var lastApp = 0
    private var lastTop = 0
    private var heroIndex = 0
    private var browsingTop10 = false

    private lateinit var heroBack: ImageView
    private lateinit var heroFront: ImageView
    private lateinit var heroInfo: LinearLayout
    private lateinit var heroBadge: TextView
    private lateinit var heroTitle: TextView
    private lateinit var heroMeta: TextView
    private lateinit var heroOverview: TextView
    private lateinit var heroCta: TextView
    private lateinit var greeting: TextView
    private lateinit var settingsButton: TextView
    private lateinit var topLabel: TextView
    private lateinit var topScroll: HorizontalScrollView
    private lateinit var topRow: LinearLayout

    // Idle showcase, like the app: rotate the hero every 9s until someone browses the Top 10.
    private val rotate = object : Runnable {
        override fun run() {
            if (!browsingTop10 && titles.isNotEmpty()) showHero((heroIndex + 1) % titles.size)
            heroInfo.postDelayed(this, 9_000)
        }
    }

    private val greetingTick = object : Runnable {
        override fun run() {
            greeting.text = greetingText()
            greeting.postDelayed(this, 60_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())
        hideSystemBars()
        setTitles(Trending.cached(this))
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
        if (currentFocus == null) appTiles.getOrNull(lastApp)?.requestFocus()
    }

    override fun onPause() {
        super.onPause()
        greeting.removeCallbacks(greetingTick)
        heroInfo.removeCallbacks(rotate)
    }

    // ---------------------------------------------------------------- keys

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Home must never be left with BACK.
        if (event.keyCode == KeyEvent.KEYCODE_BACK) return true
        if (event.action == KeyEvent.ACTION_DOWN) {
            val f = currentFocus
            val inApps = f in appTiles
            val inTop = f in topTiles
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_DOWN -> when {
                    f === settingsButton -> return focus(appTiles.getOrNull(lastApp))
                    inApps -> return focus(topTiles.getOrNull(lastTop)) || true
                    inTop -> return true
                }
                KeyEvent.KEYCODE_DPAD_UP -> when {
                    inTop -> return focus(appTiles.getOrNull(lastApp))
                    inApps -> return focus(settingsButton)
                    f === settingsButton -> return true
                }
                KeyEvent.KEYCODE_DPAD_LEFT -> when {
                    f === appTiles.firstOrNull() || f === topTiles.firstOrNull() || f === settingsButton -> return true
                }
                KeyEvent.KEYCODE_DPAD_RIGHT -> when {
                    f === appTiles.lastOrNull() || f === topTiles.lastOrNull() || f === settingsButton -> return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Intentionally empty: this is the home screen.
    }

    private fun focus(v: View?): Boolean = v?.requestFocus() ?: false

    // ---------------------------------------------------------------- layout

    private fun buildUi(): View {
        val root = FrameLayout(this).apply { setBackgroundColor(BG_DEEP) }

        // Hero backdrop: two stacked images that crossfade.
        heroBack = heroImage().also { root.addView(it, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)) }
        heroFront = heroImage().also { root.addView(it, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)) }

        // Scrims keep text readable over any backdrop.
        root.addView(scrim(GradientDrawable.Orientation.LEFT_RIGHT, 0xF21B1830.toInt(), 0x991B1830.toInt(), 0x001B1830),
            FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        root.addView(scrim(GradientDrawable.Orientation.BOTTOM_TOP, 0xFF0E0C1A.toInt(), 0xCC1B1830.toInt(), 0x001B1830),
            FrameLayout.LayoutParams(MATCH_PARENT, dp(380), Gravity.BOTTOM))
        root.addView(scrim(GradientDrawable.Orientation.TOP_BOTTOM, 0xB30E0C1A.toInt(), 0x400E0C1A, 0x000E0C1A),
            FrameLayout.LayoutParams(MATCH_PARENT, dp(120), Gravity.TOP))

        root.addView(buildHeader(), FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.TOP).apply {
            setMargins(dp(48), dp(24), dp(48), 0)
        })
        root.addView(buildHeroInfo(), FrameLayout.LayoutParams(dp(500), WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
            setMargins(dp(48), dp(88), 0, 0)
        })

        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            clipChildren = false
            clipToPadding = false
            setPadding(dp(48), 0, 0, dp(18))
        }
        bottom.addView(buildAppRow(), LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        topLabel = sectionLabel("Top 10 Today on CouchKing").apply { setPadding(dp(4), dp(14), 0, 0) }
        bottom.addView(topLabel)
        topRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            clipChildren = false
            clipToPadding = false
            setPadding(0, dp(4), dp(48), dp(4))
        }
        topScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            clipChildren = false
            clipToPadding = false
            isFocusable = false
            addView(topRow)
        }
        bottom.addView(topScroll, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(bottom, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.BOTTOM))

        root.addView(text("Trending data: TMDB", 10f, 0x80A9A5C0.toInt()),
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

        settingsButton = text("⚙", 22f, Color.WHITE).apply {
            gravity = Gravity.CENTER
            isFocusable = true
            isClickable = true
            background = circle(false)
            setOnFocusChangeListener { v, has ->
                v.background = circle(has)
                (v as TextView).setTextColor(if (has) BG_DEEP else Color.WHITE)
            }
            setOnClickListener { tryStart(Intent(Settings.ACTION_SETTINGS), "Settings") }
        }
        header.addView(settingsButton, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginStart = dp(20) })
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

    private fun buildAppRow(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            clipChildren = false
            clipToPadding = false
            setPadding(0, dp(4), 0, dp(4))
        }
        apps.forEachIndexed { i, app ->
            val tile = FrameLayout(this).apply {
                isFocusable = true
                isClickable = true
                tag = app
                background = card(false, app.accent)
                clipToOutline = true
                outlineProvider = rounded(dp(14))
                setPadding(dp(3), dp(3), dp(3), dp(3))
            }
            tile.addView(ImageView(this).apply { scaleType = ImageView.ScaleType.CENTER_CROP },
                FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            tile.addView(text(app.label, 15f, Color.WHITE, bold = true).apply {
                setShadowLayer(8f, 0f, 1f, Color.BLACK)
                setPadding(dp(10), 0, dp(10), dp(6))
            }, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.START))
            tile.setOnClickListener { launch(app) }
            tile.setOnFocusChangeListener { v, has ->
                if (has) {
                    lastApp = i
                    browsingTop10 = false
                    heroCta.text = "●  Open ${app.label}"
                }
                grow(v, has, 1.1f)
                v.background = card(has, app.accent)
            }
            appTiles += tile
            row.addView(tile, LinearLayout.LayoutParams(dp(160), dp(90)).apply { marginEnd = dp(18) })
        }
        return row
    }

    /** Netflix-style Top 10 shelf: a giant outlined rank numeral tucked behind each poster. */
    private fun buildTopRow() {
        topRow.removeAllViews()
        topTiles.clear()
        val top = titles.take(10)
        topLabel.visibility = if (top.isEmpty()) View.GONE else View.VISIBLE
        topScroll.visibility = topLabel.visibility
        top.forEachIndexed { i, t ->
            val rank = (i + 1).toString()
            val item = FrameLayout(this).apply {
                isFocusable = true
                isClickable = true
                clipChildren = false
            }
            val numeral = text(rank, 88f, MUTED, bold = true).apply {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = dp(2).toFloat()
                includeFontPadding = false
                typeface = Typeface.create("sans-serif-black", Typeface.BOLD)
            }
            item.addView(numeral, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.START).apply {
                bottomMargin = -dp(14)
            })
            val poster = FrameLayout(this).apply {
                clipToOutline = true
                outlineProvider = rounded(dp(10))
                background = GradientDrawable().apply { setColor(CARD) }
            }
            val img = ImageView(this).apply { scaleType = ImageView.ScaleType.CENTER_CROP }
            poster.addView(img, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            Images.into(img, t.poster)
            item.addView(poster, FrameLayout.LayoutParams(dp(78), dp(117), Gravity.END or Gravity.CENTER_VERTICAL))

            item.setOnClickListener { watchOnCouchKing(t) }
            item.setOnFocusChangeListener { _, has ->
                if (has) {
                    lastTop = i
                    browsingTop10 = true
                    showHero(titles.indexOf(t))
                }
                grow(poster, has, 1.12f)
                poster.foreground = if (has) GradientDrawable().apply {
                    cornerRadius = dp(10).toFloat()
                    setStroke(dp(3), GOLD)
                } else null
                numeral.setTextColor(if (has) GOLD else MUTED)
            }
            topTiles += item
            val width = if (rank.length > 1) dp(156) else dp(126)
            topRow.addView(item, LinearLayout.LayoutParams(width, dp(128)).apply { marginEnd = dp(8) })
        }
    }

    // ---------------------------------------------------------------- data

    private fun refreshTrending() {
        thread(isDaemon = true) {
            val fresh = Trending.fetch(applicationContext) ?: return@thread
            runOnUiThread { if (!isDestroyed) setTitles(fresh) }
        }
    }

    private fun setTitles(list: List<Title>) {
        val focusedTop = currentFocus in topTiles
        titles = list
        buildTopRow()
        if (titles.isEmpty()) showBrandHero() else showHero(0)
        if (focusedTop) focus(topTiles.getOrNull(lastTop.coerceAtMost(topTiles.lastIndex)) ?: appTiles[lastApp])
    }

    private fun showHero(index: Int) {
        val t = titles.getOrNull(index) ?: return
        if (index == heroIndex && heroTitle.text.toString() == t.name) return
        heroIndex = index
        val rank = index + 1
        heroBadge.text = if (rank <= 10) "#$rank TRENDING TODAY" else "TRENDING TODAY"
        heroTitle.text = t.name
        heroMeta.text = listOfNotNull(
            t.year.ifBlank { null },
            if (t.type == "tv") "Series" else "Movie",
            if (t.rating > 0) "★ " + String.format(Locale.US, "%.1f", t.rating) else null,
        ).joinToString("   ·   ")
        heroOverview.text = t.overview
        if (browsingTop10) heroCta.text = "●  Watch on CouchKing"
        heroInfo.alpha = 0f
        heroInfo.animate().alpha(1f).setDuration(350).start()

        val url = t.backdrop ?: return
        Images.load(url) { bmp ->
            if (bmp == null || heroIndex != index) return@load
            // Crossfade: the new backdrop fades in on top, then becomes the bottom layer.
            heroFront.setImageBitmap(bmp)
            heroFront.alpha = 0f
            heroFront.animate().alpha(1f).setDuration(700).withEndAction {
                heroBack.setImageBitmap(bmp)
                heroFront.alpha = 0f
            }.start()
        }
        Images.prefetch(titles.getOrNull((index + 1) % titles.size)?.backdrop)
    }

    /** Offline before the first fetch: show the CouchKing crown instead of an empty hero. */
    private fun showBrandHero() {
        heroBack.setImageDrawable(null)
        heroFront.setImageDrawable(null)
        heroBadge.text = "COUCHKING"
        heroTitle.text = "Movies & shows, all yours"
        heroMeta.text = "Trending titles appear here once the TV is online"
        heroOverview.text = "Open CouchKing to pick up where you left off."
        heroCta.text = "●  Open CouchKing"
    }

    // ---------------------------------------------------------------- apps

    /** Re-read install state each time Home comes back, so a disabled app shows as unavailable. */
    private fun refreshAppTiles() {
        for (tile in appTiles) {
            val app = tile.tag as App
            val art = tile.getChildAt(0) as ImageView
            val label = tile.getChildAt(1) as TextView
            val installed = launchIntentFor(app.pkg) != null
            val banner = bannerFor(app.pkg)
            if (banner != null) {
                art.scaleType = ImageView.ScaleType.CENTER_CROP
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
    private fun watchOnCouchKing(t: Title) {
        val intent = launchIntentFor(COUCHKING)
            ?: return Toast.makeText(this, "CouchKing isn't installed", Toast.LENGTH_SHORT).show()
        intent.putExtra("ck_tmdb_id", t.tmdbId)
            .putExtra("ck_type", t.type)
            .putExtra("ck_title", t.name)
        tryStart(intent, "CouchKing")
    }

    private fun tryStart(intent: Intent, label: String) {
        try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            Toast.makeText(this, "Couldn't open $label", Toast.LENGTH_SHORT).show()
        }
    }

    // ---------------------------------------------------------------- helpers

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
        return "$part, your Majesty"
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
        setPadding(dp(4), 0, 0, dp(4))
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
