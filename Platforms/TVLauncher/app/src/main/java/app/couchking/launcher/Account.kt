package app.couchking.launcher

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

data class Profile(val id: String, val name: String, val avatar: String)

/** A Continue Watching / My List entry from the synced CouchKing state. */
data class Entry(
    val imdbId: String,
    val type: String,          // "movie" or "series" (Cinemeta types, as the state stores them)
    val name: String,
    val poster: String?,
    val progress: Double,      // 0…1, Continue Watching only
    val resumeKey: String,     // "tt1:2:5" for a show's last episode, the id for a movie
    val order: Long,
)

data class Library(val profiles: List<Profile>, val profile: Profile?, val continueWatching: List<Entry>, val watchlist: List<Entry>)

/** Hero details for a library title, from Cinemeta (the CouchKing app's metadata source). */
data class MetaDetails(val background: String?, val description: String, val year: String, val rating: String)

/**
 * The person's CouchKing account, read-only: the same GET /tvapp/state blob every CouchKing
 * client syncs (profiles + states[pid] with continue / watchlist / positions / cwlast).
 * The launcher never pushes state back, so it can't disturb the app's library.
 */
object Account {
    private const val SERVICE = "https://couchking.app"
    private const val PREFS = "account"

    fun email(ctx: Context) = prefs(ctx).getString("email", "") ?: ""
    fun signedIn(ctx: Context) = !prefs(ctx).getString("token", "").isNullOrEmpty()

    /** Handed over by couchking-tv-setup.sh (it signs in on the Mac; the TV never sees a password). */
    fun save(ctx: Context, email: String, token: String) {
        val changed = email != email(ctx)
        prefs(ctx).edit().apply {
            putString("email", email)
            putString("token", token)
            if (changed) { remove("state"); remove("pid") }
        }.apply()
    }

    fun signOut(ctx: Context) = prefs(ctx).edit().clear().apply()

    fun profileId(ctx: Context) = prefs(ctx).getString("pid", "") ?: ""
    fun setProfileId(ctx: Context, pid: String) = prefs(ctx).edit().putString("pid", pid).apply()

    fun cachedState(ctx: Context): JSONObject? =
        prefs(ctx).getString("state", null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    /** Blocking; call off the main thread. Null on network failure; signs out on a revoked token. */
    fun fetchState(ctx: Context): JSONObject? {
        val e = enc(email(ctx))
        val t = enc(prefs(ctx).getString("token", "") ?: "")
        if (t.isEmpty()) return null
        return try {
            val conn = URL("$SERVICE/tvapp/state?e=$e&t=$t").openConnection() as HttpURLConnection
            conn.connectTimeout = 8000
            conn.readTimeout = 10000
            conn.setRequestProperty("Accept", "application/json")
            conn.setRequestProperty("X-CK-Model", "CouchKing Home (${android.os.Build.MODEL})")
            val code = conn.responseCode
            if (code == 401 || code == 403) { signOut(ctx); return null }
            if (code != 200) return null
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            conn.disconnect()
            JSONObject(body).also { prefs(ctx).edit().putString("state", body).apply() }
        } catch (e: Exception) {
            null
        }
    }

    fun library(ctx: Context, state: JSONObject?): Library = parseLibrary(state, profileId(ctx))

    /** [pid] is the remembered profile; the first profile is used when it's gone or unset. */
    fun parseLibrary(state: JSONObject?, pid: String): Library {
        if (state == null) return Library(emptyList(), null, emptyList(), emptyList())
        val profiles = state.optJSONArray("profiles").objects().mapNotNull { o ->
            val id = o.optString("id")
            if (id.isEmpty()) null else Profile(id, o.optString("name", "Profile"), o.optString("avatar"))
        }
        val profile = profiles.firstOrNull { it.id == pid } ?: profiles.firstOrNull()
        // No profiles = a legacy single-profile account whose lists live at the root.
        val ps = profile?.let { state.optJSONObject("states")?.optJSONObject(it.id) } ?: state

        val positions = ps.optJSONObject("positions")
        val cwlast = ps.optJSONObject("cwlast")
        val watched = ps.optJSONArray("watchedIds").strings().toSet()

        val cw = ps.optJSONArray("continue").objects().mapNotNull { o ->
            val id = o.optString("id").ifEmpty { return@mapNotNull null }
            val type = o.optString("type", "movie")
            if (type == "movie" && id in watched) return@mapNotNull null
            val key = cwlast?.optString(id)?.ifEmpty { null } ?: id
            var progress = 0.0
            var order = o.optLong("ts")
            positions?.optString(key)?.split("|")?.let { p ->
                val pos = p.getOrNull(0)?.toDoubleOrNull()
                val dur = p.getOrNull(1)?.toDoubleOrNull()
                if (pos != null && dur != null && dur > 0) progress = (pos / dur).coerceAtMost(1.0)
                order = maxOf(order, p.getOrNull(2)?.toLongOrNull() ?: 0)
            }
            entry(o, type, progress, key, order)
        }.sortedByDescending { it.order }

        val wl = ps.optJSONArray("watchlist").objects().mapNotNull { o ->
            val id = o.optString("id").ifEmpty { return@mapNotNull null }
            entry(o, o.optString("type", "movie"), 0.0, id, 0)
        }
        return Library(profiles, profile, cw, wl)
    }

    /** Blocking. Cinemeta meta for the hero; null when unreachable. */
    fun details(type: String, imdbId: String): MetaDetails? = try {
        val conn = URL("https://v3-cinemeta.strem.io/meta/$type/${enc(imdbId)}.json").openConnection() as HttpURLConnection
        conn.connectTimeout = 8000
        conn.readTimeout = 8000
        val m = JSONObject(conn.inputStream.bufferedReader().use { it.readText() }).getJSONObject("meta")
        conn.disconnect()
        MetaDetails(
            background = m.optString("background").ifEmpty { null },
            description = m.optString("description"),
            year = m.optString("releaseInfo").ifEmpty { m.optString("year") },
            rating = m.optString("imdbRating"),
        )
    } catch (e: Exception) {
        null
    }

    private fun entry(o: JSONObject, type: String, progress: Double, key: String, order: Long) = Entry(
        imdbId = o.optString("id"),
        type = type,
        name = o.optString("name"),
        poster = o.optString("poster").ifEmpty { null },
        progress = progress,
        resumeKey = key,
        order = order,
    )

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")
    private fun JSONArray?.objects() = if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }
    private fun JSONArray?.strings() = if (this == null) emptyList() else (0 until length()).map { optString(it) }
}
