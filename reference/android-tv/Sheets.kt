package app.mediaboard

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** CouchKing panels — in-house replacements for stock AlertDialogs, so the player pickers
 *  and download prompts look like the rest of the app (same panel color, rounded corners,
 *  purple accent and focus rings as the Discover/episode sheets) instead of an Android
 *  settings dialog. */
object Sheets {
    private val panel = Color.parseColor("#1B1830")
    private val card = Color.parseColor("#2C2649")
    private val fg = Color.WHITE
    private val dim = Color.parseColor("#A9A5C0")
    private val accent = Color.parseColor("#7B5BF5")
    private val red = Color.parseColor("#E5484D")

    private fun dp(a: Activity, v: Int) = (v * a.resources.displayMetrics.density).toInt()

    private fun rounded(a: Activity, color: Int, r: Int) =
        GradientDrawable().apply { setColor(color); cornerRadius = dp(a, r).toFloat() }

    private fun selBg(a: Activity, color: Int, r: Int): StateListDrawable =
        StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), GradientDrawable().apply {
                setColor(if (color == Color.TRANSPARENT) Color.parseColor("#33FFFFFF") else color)
                cornerRadius = dp(a, r).toFloat(); setStroke(dp(a, 2), Color.WHITE)
            })
            addState(intArrayOf(android.R.attr.state_pressed), GradientDrawable().apply {
                setColor(Color.parseColor("#4DFFFFFF")); cornerRadius = dp(a, r).toFloat()
            })
            addState(intArrayOf(), GradientDrawable().apply {
                setColor(color); cornerRadius = dp(a, r).toFloat()
            })
        }

    private fun column(a: Activity) = LinearLayout(a).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
    }

    /** Bottom sheet, single choice: the current option is purple with a trailing ✓. */
    fun pick(a: Activity, title: String, options: List<String>, current: Int,
             onPick: (Int) -> Unit) {
        val d = Dialog(a)
        val col = column(a).apply {
            background = GradientDrawable().apply {
                setColor(panel)
                cornerRadii = floatArrayOf(dp(a, 18).toFloat(), dp(a, 18).toFloat(),
                    dp(a, 18).toFloat(), dp(a, 18).toFloat(), 0f, 0f, 0f, 0f)
            }
            setPadding(dp(a, 14), dp(a, 14), dp(a, 14), dp(a, 16))
        }
        col.addView(TextView(a).apply {
            text = title.uppercase(); setTextColor(dim); textSize = 12.5f
            setTypeface(typeface, Typeface.BOLD); letterSpacing = 0.08f
            setPadding(dp(a, 10), 0, 0, dp(a, 8))
        })
        val list = column(a)
        for ((i, opt) in options.withIndex()) {
            val row = LinearLayout(a).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                background = selBg(a, Color.TRANSPARENT, 10)
                setPadding(dp(a, 12), dp(a, 11), dp(a, 12), dp(a, 11))
                isClickable = true; isFocusable = true
                setOnClickListener { d.dismiss(); onPick(i) }
            }
            row.addView(TextView(a).apply {
                text = opt
                setTextColor(if (i == current) accent else fg); textSize = 16.5f
                setTypeface(typeface, if (i == current) Typeface.BOLD else Typeface.NORMAL)
                layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
            })
            if (i == current) row.addView(TextView(a).apply {
                text = "✓"; setTextColor(accent); textSize = 16.5f
                setTypeface(typeface, Typeface.BOLD)
            })
            list.addView(row)
        }
        // hug short lists; long ones cap at 62% of the screen and scroll inside
        col.addView(object : ScrollView(a) {
            override fun onMeasure(w: Int, h: Int) = super.onMeasure(w,
                View.MeasureSpec.makeMeasureSpec(
                    (a.resources.displayMetrics.heightPixels * 0.62).toInt(),
                    View.MeasureSpec.AT_MOST))
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
        list.getChildAt(current.coerceIn(0, options.size - 1))?.requestFocus()
    }

    /** Centered confirm card with a real filled button (purple; red for deletes). */
    fun confirm(a: Activity, title: String, message: String? = null, positive: String = "OK",
                danger: Boolean = false, onYes: () -> Unit) {
        val d = Dialog(a)
        val col = column(a).apply {
            background = rounded(a, panel, 18)
            setPadding(dp(a, 22), dp(a, 20), dp(a, 22), dp(a, 16))
        }
        col.addView(TextView(a).apply {
            text = title; setTextColor(fg); textSize = 17.5f
            setTypeface(typeface, Typeface.BOLD)
        })
        message?.let {
            col.addView(TextView(a).apply {
                text = it; setTextColor(dim); textSize = 14f
                setPadding(0, dp(a, 8), 0, 0)
            })
        }
        val buttons = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END
            setPadding(0, dp(a, 18), 0, 0)
        }
        fun btn(label: String, bg: Int, color: Int, bold: Boolean, onClick: () -> Unit) =
            TextView(a).apply {
                text = label; setTextColor(color); textSize = 14.5f; gravity = Gravity.CENTER
                setTypeface(typeface, if (bold) Typeface.BOLD else Typeface.NORMAL)
                background = selBg(a, bg, 10)
                setPadding(dp(a, 18), dp(a, 9), dp(a, 18), dp(a, 9))
                layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT)
                    .apply { setMargins(dp(a, 8), 0, 0, 0) }
                isClickable = true; isFocusable = true
                setOnClickListener { onClick() }
            }
        buttons.addView(btn("Cancel", Color.TRANSPARENT, dim, false) { d.dismiss() })
        val yes = btn(positive, if (danger) red else accent, fg, true) { d.dismiss(); onYes() }
        buttons.addView(yes)
        col.addView(buttons)
        d.setContentView(col)
        d.window?.apply {
            setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
            setLayout(minOf((a.resources.displayMetrics.widthPixels * 0.86).toInt(),
                dp(a, 400)), WRAP_CONTENT)
        }
        d.show()
        yes.requestFocus()
    }
}
