package app.couchking.launcher

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.provider.Settings
import android.text.format.DateFormat
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextClock
import android.widget.TextView
import android.widget.Toast
import java.util.Calendar

/**
 * CouchKing home screen for the onn 4K Google TV: a clock and four big D-pad tiles.
 * The UI is built in code so the launcher has no library dependencies.
 */
class HomeActivity : Activity() {

    private data class App(val pkg: String, val label: String, val accent: Int)

    private val apps = listOf(
        App("app.mediaboard", "CouchKing", GOLD),
        App("com.google.android.youtube.tv", "YouTube", 0xFFFF3B3B.toInt()),
        App("com.spotify.tv.android", "Spotify", 0xFF1ED760.toInt()),
        App("com.esaba.downloader", "Downloader", 0xFFFF8A1E.toInt()),
    )

    private val tiles = mutableListOf<LinearLayout>()
    private lateinit var settingsButton: TextView
    private lateinit var greeting: TextView
    private var lastFocused = 0

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
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        refreshTiles()
        greeting.removeCallbacks(greetingTick)
        greetingTick.run()
        tiles.getOrNull(lastFocused)?.requestFocus()
    }

    override fun onPause() {
        super.onPause()
        greeting.removeCallbacks(greetingTick)
    }

    // Home must never be left with BACK; swallow it whether it comes as a key or a callback.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK) return true
        return super.dispatchKeyEvent(event)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Intentionally empty: this is the home screen.
    }

    private fun buildUi(): View {
        val root = FrameLayout(this)

        // Soft violet glow in the top-right corner, over the window's purple gradient.
        root.addView(View(this).apply {
            background = GradientDrawable().apply {
                gradientType = GradientDrawable.RADIAL_GRADIENT
                gradientRadius = dp(520).toFloat()
                setGradientCenter(0.85f, 0.1f)
                colors = intArrayOf(0x557B5BF5, 0x007B5BF5)
            }
        }, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(56), dp(36), dp(56), dp(28))
        }
        root.addView(column, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        column.addView(buildHeader(), LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        column.addView(View(this), LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))

        column.addView(text("Your apps", 15f, MUTED, bold = true).apply {
            letterSpacing = 0.18f
            isAllCaps = true
            setPadding(dp(8), 0, 0, dp(10))
        })

        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            clipChildren = false
            clipToPadding = false
        }
        apps.forEachIndexed { i, app ->
            val tile = buildTile(app, i)
            tiles += tile
            row.addView(tile, LinearLayout.LayoutParams(0, dp(236), 1f).apply {
                marginStart = dp(10); marginEnd = dp(10)
            })
        }
        column.clipChildren = false
        column.addView(row, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        column.addView(View(this), LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        column.addView(buildFooter(), LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        wireFocus()
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
        wordmark.addView(text("♛", 40f, GOLD), LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply {
            marginEnd = dp(12)
        })
        wordmark.addView(text("CouchKing", 38f, Color.WHITE, bold = true).apply { letterSpacing = 0.02f })
        wordmark.addView(text(" TV", 38f, GOLD, bold = true))
        brand.addView(wordmark)
        greeting = text(greetingText(), 18f, MUTED).apply { setPadding(dp(4), dp(2), 0, 0) }
        brand.addView(greeting)
        header.addView(brand, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))

        val clockBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.END
        }
        clockBox.addView(TextClock(this).apply {
            format12Hour = "h:mm"
            format24Hour = "HH:mm"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 84f)
            setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            includeFontPadding = false
        })
        clockBox.addView(TextClock(this).apply {
            format12Hour = "EEEE, MMMM d"
            format24Hour = "EEEE, MMMM d"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setTextColor(GOLD)
            gravity = Gravity.END
        })
        if (!DateFormat.is24HourFormat(this)) {
            clockBox.addView(TextClock(this).apply {
                format12Hour = "a"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTextColor(MUTED)
                isAllCaps = true
                gravity = Gravity.END
            })
        }
        header.addView(clockBox, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        return header
    }

    private fun buildTile(app: App, index: Int): LinearLayout {
        val tile = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            isFocusable = true
            isFocusableInTouchMode = true
            isClickable = true
            tag = app
            background = tileBackground(focused = false, accent = app.accent)
            setPadding(dp(14), dp(14), dp(14), dp(14))
            elevation = dp(2).toFloat()
        }

        val art = ImageView(this).apply {
            id = View.generateViewId()
            scaleType = ImageView.ScaleType.FIT_CENTER
            adjustViewBounds = false
        }
        tile.addView(art, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))

        tile.addView(View(this).apply {
            background = GradientDrawable().apply {
                cornerRadius = dp(2).toFloat()
                setColor(app.accent)
            }
        }, LinearLayout.LayoutParams(dp(28), dp(4)).apply { topMargin = dp(12); bottomMargin = dp(8) })

        tile.addView(text(app.label, 22f, Color.WHITE, bold = true))
        tile.addView(text("", 13f, MUTED))

        tile.setOnClickListener { launch(app) }
        tile.setOnFocusChangeListener { v, hasFocus ->
            if (hasFocus) lastFocused = index
            v.animate()
                .scaleX(if (hasFocus) 1.08f else 1f)
                .scaleY(if (hasFocus) 1.08f else 1f)
                .translationZ(if (hasFocus) dp(18).toFloat() else 0f)
                .setDuration(160)
                .start()
            v.background = tileBackground(hasFocus, app.accent)
            ((v as LinearLayout).getChildAt(2) as TextView).setTextColor(if (hasFocus) GOLD else Color.WHITE)
        }
        return tile
    }

    private fun buildFooter(): View {
        val footer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(8), 0)
        }
        footer.addView(text("◀ ▶  choose     ●  open", 15f, MUTED), LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))

        settingsButton = text("⚙  Settings", 16f, Color.WHITE, bold = true).apply {
            isFocusable = true
            isFocusableInTouchMode = true
            isClickable = true
            setPadding(dp(22), dp(10), dp(22), dp(10))
            background = pill(false)
            setOnFocusChangeListener { v, hasFocus ->
                v.background = pill(hasFocus)
                (v as TextView).setTextColor(if (hasFocus) BG_DEEP else Color.WHITE)
            }
            setOnClickListener {
                tryStart(Intent(Settings.ACTION_SETTINGS), "Settings")
            }
        }
        footer.addView(settingsButton)
        return footer
    }

    private fun wireFocus() {
        tiles.forEach { tile ->
            tile.id = View.generateViewId()
            tile.nextFocusUpId = tile.id
        }
        settingsButton.id = View.generateViewId()
        tiles.forEachIndexed { i, tile ->
            tile.nextFocusLeftId = tiles[if (i == 0) 0 else i - 1].id
            tile.nextFocusRightId = tiles[if (i == tiles.lastIndex) i else i + 1].id
            tile.nextFocusDownId = settingsButton.id
        }
        settingsButton.nextFocusUpId = tiles.last().id
        settingsButton.nextFocusDownId = settingsButton.id
        settingsButton.nextFocusRightId = settingsButton.id
        settingsButton.nextFocusLeftId = tiles.first().id
    }

    /** Re-read install state each time Home comes back, so a disabled app shows as unavailable. */
    private fun refreshTiles() {
        for (tile in tiles) {
            val app = tile.tag as App
            val art = tile.getChildAt(0) as ImageView
            val status = tile.getChildAt(3) as TextView
            val installed = launchIntentFor(app.pkg) != null
            art.setImageDrawable(artFor(app.pkg))
            tile.alpha = if (installed) 1f else 0.45f
            status.text = if (installed) "" else "Not installed"
        }
    }

    private fun artFor(pkg: String): Drawable? {
        val pm = packageManager
        return try {
            pm.getApplicationBanner(pkg) ?: pm.getApplicationIcon(pkg)
        } catch (e: PackageManager.NameNotFoundException) {
            getDrawable(R.drawable.ic_crown)
        }
    }

    private fun launchIntentFor(pkg: String): Intent? =
        packageManager.getLaunchIntentForPackage(pkg)
            ?: packageManager.getLeanbackLaunchIntentForPackage(pkg)

    private fun launch(app: App) {
        val intent = launchIntentFor(app.pkg)
        if (intent == null) {
            Toast.makeText(this, "${app.label} isn't installed", Toast.LENGTH_SHORT).show()
            return
        }
        tryStart(intent, app.label)
    }

    private fun tryStart(intent: Intent, label: String) {
        try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            Toast.makeText(this, "Couldn't open $label", Toast.LENGTH_SHORT).show()
        }
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
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        val part = when (hour) {
            in 5..11 -> "Good morning"
            in 12..16 -> "Good afternoon"
            in 17..21 -> "Good evening"
            else -> "Late night"
        }
        return "$part, your Majesty"
    }

    private fun tileBackground(focused: Boolean, accent: Int) = GradientDrawable().apply {
        cornerRadius = dp(22).toFloat()
        if (focused) {
            orientation = GradientDrawable.Orientation.TOP_BOTTOM
            colors = intArrayOf(CARD_HI, CARD)
            setStroke(dp(3), GOLD)
        } else {
            setColor(CARD)
            setStroke(dp(1), (accent and 0x00FFFFFF) or 0x33000000)
        }
    }

    private fun pill(focused: Boolean) = GradientDrawable().apply {
        cornerRadius = dp(40).toFloat()
        if (focused) setColor(GOLD) else {
            setColor(CARD)
            setStroke(dp(1), 0x33FFFFFF)
        }
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
        private const val GOLD = 0xFFF5C518.toInt()
        private const val MUTED = 0xFFA9A5C0.toInt()
        private const val CARD = 0xFF241F3D.toInt()
        private const val CARD_HI = 0xFF2C2649.toInt()
        private const val BG_DEEP = 0xFF1B1830.toInt()
    }
}
