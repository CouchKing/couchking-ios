package app.couchking.launcher

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.widget.ImageView
import java.net.HttpURLConnection
import java.net.URL
import java.util.WeakHashMap
import java.util.concurrent.Executors

/** Tiny image loader: 4 download threads + a memory cache sized to 1/8 of the heap. */
object Images {
    private val pool = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())
    private val pending = WeakHashMap<ImageView, String>()
    private val cache = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 8 / 1024).toInt()) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount / 1024
    }

    /** Delivers the bitmap (or null on failure) on the main thread. */
    fun load(url: String, done: (Bitmap?) -> Unit) {
        cache.get(url)?.let { done(it); return }
        pool.execute {
            val bmp = try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 10000
                conn.inputStream.use { BitmapFactory.decodeStream(it) }.also { conn.disconnect() }
            } catch (e: Exception) {
                null
            }
            main.post {
                if (bmp != null) cache.put(url, bmp)
                done(bmp)
            }
        }
    }

    /** Loads into a view, ignoring results that arrive after the view was re-bound. */
    fun into(view: ImageView, url: String?) {
        if (url == null) { pending.remove(view); view.setImageDrawable(null); return }
        pending[view] = url
        load(url) { bmp -> if (pending[view] == url && bmp != null) view.setImageBitmap(bmp) }
    }

    fun prefetch(url: String?) { if (url != null) load(url) {} }
}
