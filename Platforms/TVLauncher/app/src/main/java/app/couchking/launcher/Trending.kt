package app.couchking.launcher

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** One trending movie or show, as the CouchKing app's Home hero / Top 10 shows them. */
data class Title(
    val tmdbId: Int,
    val type: String,        // "movie" or "tv"
    val name: String,
    val year: String,
    val rating: Double,
    val overview: String,
    val backdrop: String?,
    val poster: String?,
)

/** TMDB "trending today" — the same source and public key the CouchKing app uses. */
object Trending {
    private const val TMDB_KEY = "b05e998c589bf1393c1059bd1d4c5895"
    private const val URL_TODAY = "https://api.themoviedb.org/3/trending/all/day?api_key=$TMDB_KEY"
    private const val PREFS = "trending"
    private const val MAX_AGE_MS = 3 * 60 * 60 * 1000L

    /** Last good list, so Home is never empty while offline or still loading. */
    fun cached(ctx: Context): List<Title> =
        parse(ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("json", null))

    fun isStale(ctx: Context): Boolean =
        System.currentTimeMillis() - ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong("at", 0) > MAX_AGE_MS

    /** Blocking; call off the main thread. Returns null on any network failure. */
    fun fetch(ctx: Context): List<Title>? = try {
        val conn = URL(URL_TODAY).openConnection() as HttpURLConnection
        conn.connectTimeout = 8000
        conn.readTimeout = 8000
        val body = conn.inputStream.bufferedReader().use { it.readText() }
        conn.disconnect()
        val list = parse(body)
        if (list.isNotEmpty()) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("json", body).putLong("at", System.currentTimeMillis()).apply()
        }
        list
    } catch (e: Exception) {
        null
    }

    private fun parse(json: String?): List<Title> {
        if (json.isNullOrBlank()) return emptyList()
        val results = runCatching { JSONObject(json).getJSONArray("results") }.getOrNull() ?: return emptyList()
        val out = ArrayList<Title>()
        for (i in 0 until results.length()) {
            val o = results.optJSONObject(i) ?: continue
            val type = o.optString("media_type")
            if (type != "movie" && type != "tv") continue
            val backdrop = o.optString("backdrop_path").ifBlank { null } ?: continue
            out += Title(
                tmdbId = o.optInt("id"),
                type = type,
                name = o.optString("title").ifBlank { o.optString("name") },
                year = o.optString("release_date").ifBlank { o.optString("first_air_date") }.take(4),
                rating = o.optDouble("vote_average", 0.0),
                overview = o.optString("overview"),
                backdrop = "https://image.tmdb.org/t/p/w1280$backdrop",
                poster = o.optString("poster_path").ifBlank { null }?.let { "https://image.tmdb.org/t/p/w342$it" },
            )
        }
        return out
    }
}
