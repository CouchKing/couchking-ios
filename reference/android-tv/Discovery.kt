package app.mediaboard

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import org.json.JSONArray
import org.json.JSONObject

/**
 * Discovery = the heart of the app. Metadata comes from Cinemeta, Stremio's free public
 * catalog service — no API key, no account, nothing service-specific. This is what lets the
 * app open straight into browsable movies/shows for a guest, with ratings, cast, director,
 * genres, runtime, summary and trailers, before any addon is ever added.
 *
 * Rent/buy/stream availability comes from TMDB watch-providers (public metadata; links go
 * to the providers' own storefronts via JustWatch pages).
 */
object Discovery {
    private const val CINEMETA = "https://v3-cinemeta.strem.io"
    private const val TMDB_KEY = "b05e998c589bf1393c1059bd1d4c5895"

    /** A home row: a Cinemeta catalog, optionally genre-filtered. */
    suspend fun catalog(type: String, id: String, genre: String? = null, pages: Int = 1): List<Title> = coroutineScope {
        // Cinemeta paginates by &skip=N (100 per page) — pull several for long shelves.
        // Each page returns null ONLY when Cinemeta couldn't be reached (vs an empty list when
        // it answered with nothing) — that lets us tell "shelf is genuinely empty" (leave it,
        // normal behavior) from "Cinemeta is down" (fall back to TMDB).
        val pageResults = (0 until pages).map { pg ->
            async {
                val g = if (genre != null) "genre=$genre&" else ""
                val skip = if (pg == 0) "" else "${g}skip=${pg * 100}"
                val seg = when {
                    genre != null && pg == 0 -> "/genre=$genre"
                    skip.isNotBlank() -> "/$skip"
                    else -> ""
                }
                val url = "$CINEMETA/catalog/$type/$id$seg.json"
                val o = Http.jsonCached(url) ?: return@async null   // null = Cinemeta unreachable
                val arr = o.optJSONArray("metas") ?: return@async emptyList<Title>()
                (0 until arr.length()).map { Title.from(arr.getJSONObject(it)) }
            }
        }.map { it.await() }
        // Cinemeta answered at least one page → normal path, unchanged (even if the shelf is empty).
        if (pageResults.any { it != null })
            return@coroutineScope pageResults.filterNotNull().flatten().distinctBy { it.id }
        // Cinemeta (Cloudflare) unreachable on this device — rebuild the shelf from TMDB
        // (CloudFront) so browse rows still fill. Only the plain Popular/Top-Rated/genre shelves
        // route through here; the tmdb= provider rows never touched Cinemeta to begin with.
        val kind = if (type == "series") "tv" else "movie"
        val path = when {
            genre != null       -> "discover/$kind?sort_by=popularity.desc&vote_count.gte=40"
            id == "imdbRating"  -> "$kind/top_rated"
            else                -> "$kind/popular"
        }
        tmdbRow(kind, path, genre = genre, pages = pages)
    }

    /** Full-text search over Cinemeta, with a TMDB fallback when Cinemeta can't be reached
     *  (Cloudflare block) — a genuine "no results" (Cinemeta answered, found nothing) still
     *  returns empty, so working devices are unaffected. */
    suspend fun search(type: String, query: String): List<Title> {
        val q = java.net.URLEncoder.encode(query.trim(), "UTF-8")
        // Cinemeta gets 2.5s, not its full 15s connect + 20s read — a flaky Cloudflare
        // moment used to hang the whole search screen ("sometimes searching takes too
        // long", AJ Sep 26). Past the cap TMDB answers instead; a late Cinemeta reply
        // still lands in the cache for the next keystroke.
        val o = kotlinx.coroutines.withTimeoutOrNull(2_500) {
            Http.jsonCached("$CINEMETA/catalog/$type/top/search=$q.json")
        }
        if (o == null) {
            val kind = if (type == "series") "tv" else "movie"
            val r = Http.jsonCached("https://api.themoviedb.org/3/search/$kind?query=$q&api_key=$TMDB_KEY&include_adult=false")
            return tmdbTitles(kind, arr(r, "results"))
        }
        val arr = o.optJSONArray("metas") ?: return emptyList()
        return (0 until arr.length()).map { Title.from(arr.getJSONObject(it)) }
    }

    private val metaCache = HashMap<String, Meta?>()

    /** Full detail for one title — cached per session so info panels paint instantly. */
    suspend fun meta(type: String, id: String): Meta? {
        val ck = "$type:$id"
        if (metaCache.containsKey(ck)) return metaCache[ck]
        val o = Http.jsonCached("$CINEMETA/meta/$type/$id.json")
        val metaObj = o?.optJSONObject("meta")
        if (metaObj == null) {
            // Cinemeta unreachable — strem.io is blocked or flaky on some networks (a Fire TV
            // reviewer saw "couldn't load details" on EVERY title while the TMDB-sourced Home
            // rows still loaded fine, because Home uses TMDB and detail used Cinemeta only).
            // Rebuild the whole detail from TMDB so the page never dies on Cinemeta alone.
            // Not cached on failure, so it retries once the network can reach Cinemeta again.
            val fb = if (id.startsWith("tt")) metaFromTmdb(type, id) else null
            if (fb != null) metaCache[ck] = fb
            return fb
        }
        var m = Meta.from(metaObj)
        // Cinemeta sometimes carries a junk numeric name ("The Last House" came back as
        // "11817") — an all-digits title is never right; TMDB knows the real one
        if (m.name.isNotBlank() && m.name.all { it.isDigit() } && id.startsWith("tt")) {
            val f = Http.jsonCached("https://api.themoviedb.org/3/find/$id?external_source=imdb_id&api_key=$TMDB_KEY")
            val fixed = f?.optJSONArray(if (type == "series") "tv_results" else "movie_results")
                ?.optJSONObject(0)?.let { it.optString("title").ifBlank { it.optString("name") } }
            if (!fixed.isNullOrBlank()) m = m.copy(name = fixed)
        }
        // Sep 13 (Bleach TYBW): metahub episode stills 404 for some shows — every episode tile
        // painted blank. One HEAD probe decides; on a miss swap in TMDB stills. TMDB may model
        // the show under different season numbering (TYBW = "Bleach season 2", absolute), so
        // episodes match by air date (exact, then ±1 day for JP-vs-US dates), then by name,
        // then ordinally when both lists are the same length.
        if (type == "series" && id.startsWith("tt") && m.videos.isNotEmpty()) {
            val probe = m.videos.firstOrNull { it.thumbnail != null }?.thumbnail
            if (probe != null && probe.contains("episodes.metahub.space") && !headOk(probe)) {
                val stills = tmdbStills(id, m.name)
                if (stills.isNotEmpty()) m = m.copy(videos = matchStills(m.videos, stills))
            }
        }
        metaCache[ck] = m
        return m
    }

    /** Full detail rebuilt entirely from TMDB — the fallback when Cinemeta can't be reached
     *  (region block / outage). Mirrors the fields Meta.from() pulls from Cinemeta so the
     *  detail page renders identically. Home already proves TMDB is reachable on the same
     *  network, so this keeps the app working when strem.io is the only thing that's down. */
    private suspend fun metaFromTmdb(type: String, imdbId: String): Meta? {
        val kind = if (type == "series") "tv" else "movie"
        val f = Http.jsonCached("https://api.themoviedb.org/3/find/$imdbId?external_source=imdb_id&api_key=$TMDB_KEY")
        val tid = f?.optJSONArray(if (kind == "tv") "tv_results" else "movie_results")
            ?.optJSONObject(0)?.optInt("id")?.takeIf { it > 0 } ?: return null
        val d = Http.jsonCached("https://api.themoviedb.org/3/$kind/$tid?api_key=$TMDB_KEY&append_to_response=credits,videos")
            ?: return null

        val name = d.optString(if (kind == "tv") "name" else "title")
            .ifBlank { d.optString(if (kind == "tv") "original_name" else "original_title") }
        if (name.isBlank()) return null

        val firstYr = d.optString(if (kind == "tv") "first_air_date" else "release_date").take(4)
        val year = if (kind == "tv" && firstYr.length == 4) {
            val lastYr = d.optString("last_air_date").take(4)
            when (d.optString("status")) {
                "Ended", "Canceled" -> if (lastYr.length == 4 && lastYr != firstYr) "$firstYr–$lastYr" else firstYr
                else -> "$firstYr–"
            }
        } else firstYr

        val runMin = if (kind == "tv") (d.optJSONArray("episode_run_time")?.optInt(0, 0) ?: 0)
                     else d.optInt("runtime", 0)
        val vote = d.optDouble("vote_average", 0.0)

        val credits = d.optJSONObject("credits")
        val cast = arr(credits, "cast").take(15).mapNotNull { it.optString("name").ifBlank { null } }
        val director = if (kind == "movie")
            arr(credits, "crew").filter { it.optString("job") == "Director" }
                .mapNotNull { it.optString("name").ifBlank { null } }
        else arr(d, "created_by").mapNotNull { it.optString("name").ifBlank { null } }

        val vids = arr(d.optJSONObject("videos"), "results")
        val yt = (vids.firstOrNull { it.optString("site") == "YouTube" && it.optString("type") == "Trailer" }
            ?: vids.firstOrNull { it.optString("site") == "YouTube" })?.optString("key")?.ifBlank { null }

        return Meta(
            id = imdbId, type = type, name = name, year = year,
            runtime = if (runMin > 0) "$runMin min" else "",
            imdbRating = if (vote > 0) String.format(java.util.Locale.US, "%.1f", vote) else "",
            genres = arr(d, "genres").mapNotNull { it.optString("name").ifBlank { null } },
            cast = cast, director = director,
            description = d.optString("overview"),
            poster = d.optString("poster_path").ifBlank { null }?.let { "https://image.tmdb.org/t/p/w500$it" },
            background = d.optString("backdrop_path").ifBlank { null }?.let { "https://image.tmdb.org/t/p/original$it" },
            logo = null, trailerYoutubeId = yt,
            videos = if (kind == "tv") tmdbEpisodes(imdbId, tid, d) else emptyList(),
        )
    }

    /** Every aired/upcoming episode of a TMDB show, as app Episode rows keyed by the
     *  "tt123:S:E" stream id the player expects. Seasons pulled in parallel. Specials
     *  (season 0) skipped to match Cinemeta's main episode list. */
    private suspend fun tmdbEpisodes(imdbId: String, tvId: Int, show: JSONObject): List<Episode> = coroutineScope {
        val seasons = show.optJSONArray("seasons")
        val nums = (0 until (seasons?.length() ?: 0))
            .mapNotNull { seasons!!.getJSONObject(it).optInt("season_number", -1).takeIf { n -> n > 0 } }
        // UTC on both: parse anchors the +29h aired math to a fixed zone, and format must
        // match or a UTC-midnight date displays as the previous evening in US timezones
        val relFmt = java.text.SimpleDateFormat("MMM d, yyyy", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
        val inFmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
        nums.map { sn ->
            async {
                val sj = Http.jsonCached("https://api.themoviedb.org/3/tv/$tvId/season/$sn?api_key=$TMDB_KEY")
                    ?: return@async emptyList<Episode>()
                arr(sj, "episodes").mapNotNull { eo ->
                    val en = eo.optInt("episode_number", -1)
                    if (en < 0) return@mapNotNull null
                    val air = eo.optString("air_date")
                    var relStr: String? = null; var aired = true
                    if (air.length == 10) try {
                        val dt = inFmt.parse(air)
                        // TMDB's air_date is the bare US CALENDAR date — midnight-local said
                        // "aired" a full day early (AJ Sep 24: Stuart E10 badged the morning of
                        // air day, ep really unlocks overnight). Cinemeta's timestamps for the
                        // same episodes are consistently air_date + 1 day @ 05:00 UTC (1am ET),
                        // so only count a date-only episode aired after that moment.
                        if (dt != null) {
                            aired = dt.time + 29 * 3600_000L <= System.currentTimeMillis()
                            relStr = relFmt.format(dt)
                        }
                    } catch (_: Exception) {}
                    val sp = eo.optString("still_path")
                    Episode(
                        id = "$imdbId:$sn:$en", season = sn, episode = en,
                        name = eo.optString("name"),
                        thumbnail = if (sp.isNotBlank()) "https://image.tmdb.org/t/p/w500$sp" else null,
                        description = eo.optString("overview"),
                        released = relStr, aired = aired, releasedIso = air.ifBlank { null })
                }
            }
        }.flatMap { it.await() }.sortedWith(compareBy({ it.season }, { it.episode }))
    }

    /** One TMDB episode (flat, all seasons in air order) for the metahub-404 fallback. */
    private data class TmdbEp(val date: String, val name: String, val still: String)

    private suspend fun tmdbStills(imdbId: String, showName: String): List<TmdbEp> {
        val out = ArrayList<TmdbEp>()
        try {
            var tv = Http.jsonCached("https://api.themoviedb.org/3/find/$imdbId?external_source=imdb_id&api_key=$TMDB_KEY")
                ?.optJSONArray("tv_results")?.optJSONObject(0)?.optInt("id") ?: 0
            if (tv <= 0 && showName.isNotBlank()) {   // TYBW: no direct imdb mapping on TMDB
                val q = java.net.URLEncoder.encode(showName, "UTF-8")
                tv = Http.jsonCached("https://api.themoviedb.org/3/search/tv?query=$q&api_key=$TMDB_KEY")
                    ?.optJSONArray("results")?.optJSONObject(0)?.optInt("id") ?: 0
            }
            if (tv <= 0) return out
            val show = Http.jsonCached("https://api.themoviedb.org/3/tv/$tv?api_key=$TMDB_KEY") ?: return out
            val seasons = show.optJSONArray("seasons") ?: return out
            for (i in 0 until seasons.length()) {
                val sn = seasons.getJSONObject(i).optInt("season_number", -1)
                if (sn <= 0) continue
                val sj = Http.jsonCached("https://api.themoviedb.org/3/tv/$tv/season/$sn?api_key=$TMDB_KEY") ?: continue
                val eps = sj.optJSONArray("episodes") ?: continue
                for (j in 0 until eps.length()) {
                    val eo = eps.getJSONObject(j)
                    val sp = eo.optString("still_path")
                    out.add(TmdbEp(eo.optString("air_date"), eo.optString("name"),
                                   if (sp.isNotBlank()) "https://image.tmdb.org/t/p/w500$sp" else ""))
                }
            }
        } catch (_: Exception) {}
        return out
    }

    private fun matchStills(videos: List<Episode>, tmdb: List<TmdbEp>): List<Episode> {
        val byDate = tmdb.filter { it.still.isNotEmpty() && it.date.length == 10 }.groupBy { it.date }
        val byName = tmdb.filter { it.still.isNotEmpty() && it.name.isNotBlank() }
            .groupBy { it.name.trim().lowercase() }.filterValues { it.size == 1 }
        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        fun shiftDay(d: String, by: Int): String? = try {
            fmt.format(java.util.Date(fmt.parse(d)!!.time + by * 86400000L))
        } catch (_: Exception) { null }
        // ordinal fallback compares regular episodes only — season-0 specials would shift it
        val sameLen = videos.count { it.season > 0 } == tmdb.size
        var ord = -1
        return videos.map { e ->
            if (e.season > 0) ord++
            val iso = e.releasedIso?.take(10)
            var still: String? = null
            if (iso != null) {
                still = byDate[iso]?.firstOrNull()?.still
                    ?: shiftDay(iso, 1)?.let { byDate[it]?.firstOrNull()?.still }
                    ?: shiftDay(iso, -1)?.let { byDate[it]?.firstOrNull()?.still }
            }
            if (still == null) still = byName[e.name.trim().lowercase()]?.firstOrNull()?.still
            if (still == null && sameLen && e.season > 0) still = tmdb[ord].still.ifBlank { null }
            if (still != null) e.copy(thumbnail = still) else e
        }
    }

    /** After/during-credits stinger for a movie (TMDB community keywords, very reliable for
     *  the Marvel class). Returns "after", "during", or null. Cached per session. */
    private val stingerCache = HashMap<String, String?>()
    suspend fun movieStinger(imdbId: String): String? {
        if (stingerCache.containsKey(imdbId)) return stingerCache[imdbId]
        var v: String? = null
        try {
            val f = Http.jsonCached("https://api.themoviedb.org/3/find/$imdbId?external_source=imdb_id&api_key=$TMDB_KEY")
            val mid = f?.optJSONArray("movie_results")?.optJSONObject(0)?.optInt("id") ?: 0
            if (mid > 0) {
                val kw = Http.jsonCached("https://api.themoviedb.org/3/movie/$mid/keywords?api_key=$TMDB_KEY")
                val arr = kw?.optJSONArray("keywords")
                if (arr != null) for (i in 0 until arr.length()) {
                    when (arr.getJSONObject(i).optString("name")) {
                        "aftercreditsstinger" -> { v = "after" }
                        "duringcreditsstinger" -> if (v == null) v = "during"
                    }
                }
            }
        } catch (_: Exception) {}
        stingerCache[imdbId] = v
        return v
    }

    private suspend fun headOk(url: String): Boolean =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            try {
                val c = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                c.requestMethod = "HEAD"; c.connectTimeout = 3000; c.readTimeout = 3000
                val ok = c.responseCode in 200..299
                c.disconnect(); ok
            } catch (_: Exception) { false }
        }

    /** Instant cache peek (no suspend): the TV board paints synchronously on a hit, so a
     *  tile you've focused before — or one a row prefetched — never "fixes itself" late. */
    fun metaCached(type: String, id: String): Meta? = metaCache["$type:$id"]

    /** "Where to watch" for the detail page: streaming / rent / buy names + a link. */
    data class Providers(val stream: List<String>, val rent: List<String>, val buy: List<String>, val link: String?)

    private val provCache = HashMap<String, Providers?>()

    suspend fun providers(imdbId: String, type: String): Providers? {
        provCache[imdbId]?.let { return it }
        if (provCache.containsKey(imdbId)) return null
        val kind = if (type == "series") "tv" else "movie"
        val found = Http.jsonCached("https://api.themoviedb.org/3/find/$imdbId?api_key=$TMDB_KEY&external_source=imdb_id")
        val tmdbId = found?.optJSONArray(if (kind == "tv") "tv_results" else "movie_results")
            ?.optJSONObject(0)?.optInt("id") ?: run { provCache[imdbId] = null; return null }
        val o = Http.jsonCached("https://api.themoviedb.org/3/$kind/$tmdbId/watch/providers?api_key=$TMDB_KEY")
        val us = o?.optJSONObject("results")?.optJSONObject("US") ?: run { provCache[imdbId] = null; return null }
        fun names(key: String): List<String> {
            val a = us.optJSONArray(key) ?: return emptyList()
            return (0 until a.length()).mapNotNull { a.optJSONObject(it)?.optString("provider_name")?.ifBlank { null } }.distinct()
        }
        val p = Providers(names("flatrate"), names("rent"), names("buy"), us.optString("link").ifBlank { null })
        provCache[imdbId] = p
        return p
    }

    // ---- TMDB-backed: true anime shelves + person (cast/director) filmographies ----
    private val imdbCache = HashMap<String, String?>()

    private suspend fun imdbFor(kind: String, tmdbId: Int): String? {
        val ck = "$kind:$tmdbId"
        if (imdbCache.containsKey(ck)) return imdbCache[ck]
        val o = Http.jsonCached("https://api.themoviedb.org/3/$kind/$tmdbId/external_ids?api_key=$TMDB_KEY")
        val id = o?.optString("imdb_id")?.takeIf { it.startsWith("tt") }
        imdbCache[ck] = id
        return id
    }

    /** TMDB result objects -> app Titles (imdb-keyed so detail/meta/streams all work). */
    private suspend fun tmdbTitles(kind: String, results: List<JSONObject>, limit: Int = 60): List<Title> = coroutineScope {
        results.take(limit).map { o ->
            async {
                val imdb = imdbFor(kind, o.optInt("id")) ?: return@async null
                val poster = o.optString("poster_path").ifBlank { null }?.let { "https://image.tmdb.org/t/p/w342$it" }
                val name = o.optString(if (kind == "tv") "name" else "title")
                if (name.isBlank()) null else Title(imdb, if (kind == "tv") "series" else "movie", name, poster,
                    desc = o.optString("overview").ifBlank { null })
            }
        }.mapNotNull { it.await() }
    }

    private fun arr(o: JSONObject?, key: String): List<JSONObject> {
        val a = o?.optJSONArray(key) ?: return emptyList()
        return (0 until a.length()).mapNotNull { a.optJSONObject(it) }
    }

    /** Genuinely-anime shelf: Animation genre AND Japanese origin, via TMDB discover. */
    suspend fun animeRow(kind: String, sort: String, extra: String = ""): List<Title> {
        val o = Http.jsonCached("https://api.themoviedb.org/3/discover/$kind?api_key=$TMDB_KEY" +
            "&with_genres=16&with_origin_country=JP&sort_by=$sort$extra")
        return tmdbTitles(kind, arr(o, "results"))
    }

    /** Generic TMDB shelf (provider rows, now-playing, certified-fresh …) -> imdb Titles. */
    suspend fun tmdbRow(kind: String, pathAndParams: String, genre: String? = null, pages: Int = 1): List<Title> = coroutineScope {
        var path = pathAndParams
        if (genre != null) {
            val gid = (if (kind == "tv") TMDB_GENRE_TV else TMDB_GENRE_MOVIE)[genre]
            // TMDB's trending/ endpoint silently IGNORES with_genres (AJ: "trending horror"
            // listed Toy Story) — a genre-filtered trending row must go through discover,
            // which honors it; recent-popularity sort ≈ the same shelf, honestly filtered
            if (gid != null) path = if (path.startsWith("trending/")) {
                "discover/$kind?sort_by=popularity.desc&vote_count.gte=40&with_genres=$gid"
            } else path + (if ("?" in path) "&" else "?") + "with_genres=$gid"
        }
        val sep = if ("?" in path) "&" else "?"
        (1..pages).map { pg ->
            async {
                val o = Http.jsonCached("https://api.themoviedb.org/3/$path${sep}api_key=$TMDB_KEY&page=$pg")
                tmdbTitles(kind, arr(o, "results"))
            }
        }.flatMap { it.await() }.distinctBy { it.id }
    }

    private val TMDB_GENRE_MOVIE = mapOf("Action" to 28, "Adventure" to 12, "Animation" to 16,
        "Comedy" to 35, "Crime" to 80, "Documentary" to 99, "Drama" to 18, "Family" to 10751,
        "Fantasy" to 14, "History" to 36, "Horror" to 27, "Music" to 10402, "Mystery" to 9648,
        "Romance" to 10749, "Sci-Fi" to 878, "Thriller" to 53, "War" to 10752, "Western" to 37)
    // TV uses TMDB's real TV taxonomy (different from movies). Movie-style aliases kept at the
    // bottom so any existing shelf that passed "Sci-Fi"/"Action"/etc. for a TV row still resolves.
    private val TMDB_GENRE_TV = mapOf(
        "Action & Adventure" to 10759, "Animation" to 16, "Comedy" to 35, "Crime" to 80,
        "Documentary" to 99, "Drama" to 18, "Family" to 10751, "Kids" to 10762,
        "Mystery" to 9648, "Reality" to 10764, "Sci-Fi & Fantasy" to 10765, "Soap" to 10766,
        "Talk" to 10767, "War & Politics" to 10768, "Western" to 37,
        "Action" to 10759, "Adventure" to 10759, "Fantasy" to 10765, "Sci-Fi" to 10765, "War" to 10768)

    // Ordered genre labels for Discover's Genre dropdown — each maps to a real TMDB id above, so
    // the filter is ACCURATE. Movie and TV have different genre sets; the dropdown adapts.
    val MOVIE_GENRES = listOf("Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary",
        "Drama", "Family", "Fantasy", "History", "Horror", "Music", "Mystery", "Romance",
        "Sci-Fi", "Thriller", "War", "Western")
    val TV_GENRES = listOf("Action & Adventure", "Animation", "Comedy", "Crime", "Documentary",
        "Drama", "Family", "Kids", "Mystery", "Reality", "Sci-Fi & Fantasy", "Soap", "Talk",
        "War & Politics", "Western")

    /** A theme shelf that spans both media types: pull the movie query AND the tv query and
     *  interleave them, so "Superheroes"/"Zombies"/etc. show movies AND shows. (AJ Sep 15) */
    suspend fun tmdbBoth(movieQuery: String, tvQuery: String, pages: Int = 2): List<Title> = coroutineScope {
        val m = async { tmdbRow("movie", movieQuery, pages = pages) }
        val t = async { tmdbRow("tv", tvQuery, pages = pages) }
        val mv = m.await(); val tv = t.await()
        val out = ArrayList<Title>()
        for (i in 0 until maxOf(mv.size, tv.size)) { mv.getOrNull(i)?.let { out.add(it) }; tv.getOrNull(i)?.let { out.add(it) } }
        out.distinctBy { it.id }
    }

    /** Search BOTH movies and series, interleaved (Discover: "search movies and shows"). */
    suspend fun searchBoth(query: String): List<Title> = coroutineScope {
        val m = async { search("movie", query) }
        val s = async { search("series", query) }
        val mv = m.await(); val sv = s.await()
        val out = ArrayList<Title>()
        for (i in 0 until maxOf(mv.size, sv.size)) { mv.getOrNull(i)?.let { out.add(it) }; sv.getOrNull(i)?.let { out.add(it) } }
        out.distinctBy { it.id }
    }

    /** "For You": TMDB recommendation graph seeded by what's actually in the user's library.
     *  Ranked by CONSENSUS (AJ Sep 10) — a title recommended by several of the things you've
     *  watched is a better personal pick than one broadly-popular hit, so we count how many of
     *  your seeds point at each candidate and sort by that first, popularity only as a tiebreak.
     *  Caller passes the strongest signals first (watched / most-played), and we use up to 8. */
    suspend fun forYou(kind: String, seedImdbs: List<String>): List<Title> = coroutineScope {
        val recLists = seedImdbs.distinct().take(8).map { imdb ->
            async {
                val f = Http.jsonCached("https://api.themoviedb.org/3/find/$imdb?api_key=$TMDB_KEY&external_source=imdb_id")
                val id = f?.optJSONArray(if (kind == "tv") "tv_results" else "movie_results")?.optJSONObject(0)?.optInt("id")
                    ?: return@async emptyList()
                arr(Http.jsonCached("https://api.themoviedb.org/3/$kind/$id/recommendations?api_key=$TMDB_KEY"), "results")
            }
        }.map { it.await() }
        val seedIds = seedImdbs.toHashSet()
        val votes = HashMap<Int, Int>(); val best = LinkedHashMap<Int, org.json.JSONObject>()
        for (lst in recLists) {
            val once = HashSet<Int>()
            for (o in lst) {
                val id = o.optInt("id")
                if (id != 0 && once.add(id)) {
                    votes[id] = (votes[id] ?: 0) + 1        // how many of your titles recommend it
                    best.putIfAbsent(id, o)
                }
            }
        }
        val ranked = best.values.sortedWith(
            compareByDescending<org.json.JSONObject> { votes[it.optInt("id")] ?: 0 }
                .thenByDescending { it.optDouble("popularity", 0.0) })
        // don't recommend things already in the library (imdb id match after resolve)
        tmdbTitles(kind, ranked).filter { it.id !in seedIds }
    }

    /** True "in theaters now": discover with a primary_release_date window instead of
     *  TMDB's now_playing — now_playing counts anniversary RE-releases (1984 Terminator,
     *  Harry Potter fathom events) as currently in theaters. Primary release date only
     *  belongs to the original run. */
    private fun nowPlaying(): String {
        val df = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        val gte = df.format(java.util.Date(System.currentTimeMillis() - 75L * 86400_000))
        val lte = df.format(java.util.Date(System.currentTimeMillis() + 3L * 86400_000))
        return "discover/movie?sort_by=popularity.desc&with_release_type=3|2&region=US&vote_count.gte=3" +
            "&primary_release_date.gte=$gte&primary_release_date.lte=$lte"
    }

    /** Stremio-style Discover catalogs: one dropdown's worth per type. */
    val MOVIE_CATS = listOf(
        Row("Popular", "movie", "top"),
        Row("Trending", "movie", "", tmdb = "trending/movie/week", tmdbKind = "movie"),
        Row("For You", "movie", "FORYOU"),
        Row("New", "movie", "year"),
        Row("Top Rated", "movie", "imdbRating"),
        Row("New in Theaters", "movie", "", tmdb = nowPlaying(), tmdbKind = "movie"),
        Row("🍅 Certified Fresh", "movie", "", tmdb = "discover/movie?vote_average.gte=7.4&vote_count.gte=300&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("Netflix", "movie", "", tmdb = prov("movie", "8"), tmdbKind = "movie"),
        Row("Hulu", "movie", "", tmdb = prov("movie", "15"), tmdbKind = "movie"),
        Row("Max", "movie", "", tmdb = prov("movie", "1899"), tmdbKind = "movie"),
        Row("Prime Video", "movie", "", tmdb = prov("movie", "9"), tmdbKind = "movie"),
        Row("Apple TV+", "movie", "", tmdb = prov("movie", "350"), tmdbKind = "movie"),
        Row("Disney+", "movie", "", tmdb = prov("movie", "337"), tmdbKind = "movie"),
        Row("Paramount+", "movie", "", tmdb = prov("movie", "2303|2616|531"), tmdbKind = "movie"),
        Row("Peacock", "movie", "", tmdb = prov("movie", "386"), tmdbKind = "movie"),
    )
    val TV_CATS = listOf(
        Row("Popular", "series", "top"),
        Row("Trending", "series", "", tmdb = "trending/tv/week", tmdbKind = "tv"),
        Row("For You", "series", "FORYOU"),
        Row("New", "series", "year"),
        Row("Top Rated", "series", "imdbRating"),
        Row("New Shows", "series", "", tmdb = "discover/tv?sort_by=first_air_date.desc&vote_count.gte=25", tmdbKind = "tv"),
        Row("Anime", "series", "", tmdb = "discover/tv?with_genres=16&with_origin_country=JP&sort_by=popularity.desc", tmdbKind = "tv"),
        Row("Netflix", "series", "", tmdb = prov("tv", "8"), tmdbKind = "tv"),
        Row("Hulu", "series", "", tmdb = prov("tv", "15"), tmdbKind = "tv"),
        Row("Max", "series", "", tmdb = prov("tv", "1899"), tmdbKind = "tv"),
        Row("Prime Video", "series", "", tmdb = prov("tv", "9"), tmdbKind = "tv"),
        Row("Apple TV+", "series", "", tmdb = prov("tv", "350"), tmdbKind = "tv"),
        Row("Disney+", "series", "", tmdb = prov("tv", "337"), tmdbKind = "tv"),
        Row("Paramount+", "series", "", tmdb = prov("tv", "2303|2616|531"), tmdbKind = "tv"),
        Row("Peacock", "series", "", tmdb = prov("tv", "386"), tmdbKind = "tv"),
    )

    /** Stremio-style person page: who they are + what they've been in (acting or directing). */
    data class Person(val name: String, val movies: List<Title>, val shows: List<Title>)

    data class PersonHit(val name: String, val photo: String?, val role: String)

    /** Face + name matches for a typed query — real people search, not just text chips. */
    suspend fun searchPeople(query: String): List<PersonHit> {
        val q = java.net.URLEncoder.encode(query.trim(), "UTF-8")
        val o = Http.jsonCached("https://api.themoviedb.org/3/search/person?api_key=$TMDB_KEY&query=$q") ?: return emptyList()
        return arr(o, "results").sortedByDescending { it.optDouble("popularity", 0.0) }
            .mapNotNull {
                val n = it.optString("name").ifBlank { null } ?: return@mapNotNull null
                PersonHit(n,
                    it.optString("profile_path").ifBlank { null }?.let { p -> "https://image.tmdb.org/t/p/w185$p" },
                    if (it.optString("known_for_department") == "Directing") "Director" else "Actor")
            }.distinctBy { it.name }.take(8)
    }

    suspend fun person(name: String): Person? {
        val q = java.net.URLEncoder.encode(name.trim(), "UTF-8")
        val s = Http.jsonCached("https://api.themoviedb.org/3/search/person?api_key=$TMDB_KEY&query=$q")
        val hit = arr(s, "results").firstOrNull() ?: return null
        val c = Http.jsonCached("https://api.themoviedb.org/3/person/${hit.optInt("id")}/combined_credits?api_key=$TMDB_KEY")
            ?: return null
        val credits = (arr(c, "cast") + arr(c, "crew").filter { it.optString("job") == "Director" })
            .distinctBy { it.optString("media_type") + it.optInt("id") }
            .sortedByDescending { it.optDouble("popularity", 0.0) }
        return coroutineScope {
            val movies = async { tmdbTitles("movie", credits.filter { it.optString("media_type") == "movie" }, 14) }
            val shows = async { tmdbTitles("tv", credits.filter { it.optString("media_type") == "tv" }, 14) }
            Person(hit.optString("name", name), movies.await(), shows.await())
        }
    }

    // Netflix-style shelves per top-level tab. Provider ids: Netflix 8, Hulu 15, Disney+ 337,
    // Paramount+ 2303|2616|531, Max 1899, Prime 9, AppleTV+ 350, Peacock 386 (TMDB, US region).
    private fun prov(kind: String, ids: String) =
        "discover/$kind?with_watch_providers=$ids&watch_region=US&sort_by=popularity.desc"

    val HOME_ROWS = listOf(
        Row("Popular Movies", "movie", "top"),
        Row("Popular Series", "series", "top"),
        Row("New in Theaters", "movie", "", tmdb = nowPlaying(), tmdbKind = "movie"),
        Row("🍅 Certified Fresh", "movie", "", tmdb = "discover/movie?vote_average.gte=7.4&vote_count.gte=300&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("Netflix", "series", "", tmdb = prov("tv", "8"), tmdbKind = "tv"),
        Row("Prime Video", "movie", "", tmdb = prov("movie", "9"), tmdbKind = "movie"),
        Row("Disney+", "series", "", tmdb = prov("tv", "337"), tmdbKind = "tv"),
        Row("Top Rated", "movie", "imdbRating"),
        Row("Action", "movie", "top", "Action"),
        Row("Drama", "series", "top", "Drama"),
        Row("Comedy", "movie", "top", "Comedy"),
    )
    val MOVIE_ROWS = listOf(
        Row("Popular", "movie", "top"),
        Row("New in Theaters", "movie", "", tmdb = nowPlaying(), tmdbKind = "movie"),
        Row("🍅 Certified Fresh", "movie", "", tmdb = "discover/movie?vote_average.gte=7.4&vote_count.gte=300&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("Top Rated", "movie", "imdbRating"),
        Row("Netflix", "movie", "", tmdb = prov("movie", "8"), tmdbKind = "movie"),
        Row("Prime Video", "movie", "", tmdb = prov("movie", "9"), tmdbKind = "movie"),
        Row("Max", "movie", "", tmdb = prov("movie", "1899"), tmdbKind = "movie"),
        Row("Apple TV+", "movie", "", tmdb = prov("movie", "350"), tmdbKind = "movie"),
        Row("Action", "movie", "top", "Action"),
        Row("Comedy", "movie", "top", "Comedy"),
        Row("Horror", "movie", "top", "Horror"),
        Row("Sci-Fi", "movie", "top", "Sci-Fi"),
        Row("Thriller", "movie", "top", "Thriller"),
        Row("Romance", "movie", "top", "Romance"),
        Row("Documentary", "movie", "top", "Documentary"),
    )
    val SHOW_ROWS = listOf(
        Row("Popular", "series", "top"),
        Row("New Shows", "series", "", tmdb = "discover/tv?sort_by=first_air_date.desc&vote_count.gte=25", tmdbKind = "tv"),
        Row("Top Rated", "series", "imdbRating"),
        Row("Netflix", "series", "", tmdb = prov("tv", "8"), tmdbKind = "tv"),
        Row("Hulu", "series", "", tmdb = prov("tv", "15"), tmdbKind = "tv"),
        Row("Disney+", "series", "", tmdb = prov("tv", "337"), tmdbKind = "tv"),
        Row("Max", "series", "", tmdb = prov("tv", "1899"), tmdbKind = "tv"),
        Row("Paramount+", "series", "", tmdb = prov("tv", "2303|2616|531"), tmdbKind = "tv"),
        Row("Apple TV+", "series", "", tmdb = prov("tv", "350"), tmdbKind = "tv"),
        Row("Peacock", "series", "", tmdb = prov("tv", "386"), tmdbKind = "tv"),
        Row("Drama", "series", "top", "Drama"),
        Row("Comedy", "series", "top", "Comedy"),
        Row("Crime", "series", "top", "Crime"),
        Row("Sci-Fi", "series", "top", "Sci-Fi"),
        Row("Reality", "series", "top", "Reality-TV"),
    )
    data class Row(val label: String, val type: String, val catalogId: String, val genre: String? = null,
                   val tmdb: String? = null, val tmdbKind: String = "movie",
                   // when set, this shelf pulls BOTH movies (tmdb) AND shows (tmdbTv) and
                   // interleaves them — for theme categories (Superheroes, Zombies…) that
                   // aren't a single media type. Label-specified ones (…Movies / …TV) leave
                   // this null and stay one type. (AJ Sep 15)
                   val tmdbTv: String? = null,
                   // curated shelf: an EXACT ordered imdb-id list (Marvel chronological etc.) —
                   // rendered as-is, never shuffled (order IS the content, AJ Sep 10)
                   val ids: List<String>? = null)

    /** Curated row: resolve each imdb id to a Title, PRESERVING list order. Lists may MIX
     *  movies and series (Marvel timeline, AJ Sep 10) — try the row's type first, then the
     *  other kind, so one list can interleave films and shows in watch order. */
    suspend fun idsRow(type: String, ids: List<String>): List<Title> = coroutineScope {
        val other = if (type == "series") "movie" else "series"
        ids.map { id -> async {
            (meta(type, id) ?: meta(other, id))?.let { return@async Title(it.id, it.type, it.name, it.poster) }
            // Cinemeta doesn't know far-future titles yet (VisionQuest, Oct 2026) but TMDB
            // does — the tile still shows in watch order; clicking it gets the standard
            // unaired/coming-soon treatment (AJ Sep 17: "unreleased stuff should be on there")
            val f = Http.jsonCached("https://api.themoviedb.org/3/find/$id?external_source=imdb_id&api_key=$TMDB_KEY")
                ?: return@async null
            val mv = f.optJSONArray("movie_results")?.optJSONObject(0)
            val tv = f.optJSONArray("tv_results")?.optJSONObject(0)
            val hit = mv ?: tv ?: return@async null
            Title(id, if (mv != null) "movie" else "series",
                  hit.optString("title").ifBlank { hit.optString("name") },
                  hit.optString("poster_path").takeIf { it.isNotBlank() }
                      ?.let { "https://image.tmdb.org/t/p/w342$it" })
        } }.mapNotNull { it.await() }
    }

    // ---- curated watch-order lists (AJ Sep 10) — every id VERIFIED (Cinemeta/TMDB; the
    // check caught a wrong Loki id and a swapped Ms. Marvel/She-Hulk, so never skip it) ----
    // MCU MOVIES + SHOWS MIXED by actual RELEASE/premiere date, Iron Man (2008) →
    // Fantastic Four: First Steps (2025). Series ride at their season-1 premiere slot.
    val MCU_RELEASE = listOf(
        "tt0371746",  // Iron Man
        "tt0800080",  // The Incredible Hulk
        "tt1228705",  // Iron Man 2
        "tt0800369",  // Thor
        "tt0458339",  // Captain America: The First Avenger
        "tt0848228",  // The Avengers
        "tt1300854",  // Iron Man 3
        "tt1981115",  // Thor: The Dark World
        "tt1843866",  // Captain America: The Winter Soldier
        "tt2015381",  // Guardians of the Galaxy
        "tt2395427",  // Avengers: Age of Ultron
        "tt0478970",  // Ant-Man
        "tt3498820",  // Captain America: Civil War
        "tt1211837",  // Doctor Strange
        "tt3896198",  // Guardians of the Galaxy Vol. 2
        "tt2250912",  // Spider-Man: Homecoming
        "tt3501632",  // Thor: Ragnarok
        "tt1825683",  // Black Panther
        "tt4154756",  // Avengers: Infinity War
        "tt5095030",  // Ant-Man and the Wasp
        "tt4154664",  // Captain Marvel
        "tt4154796",  // Avengers: Endgame
        "tt6320628",  // Spider-Man: Far From Home
        "tt9140560",  // WandaVision (Jan 2021)
        "tt9208876",  // The Falcon and the Winter Soldier (Mar 2021)
        "tt9140554",  // Loki (Jun 2021)
        "tt3480822",  // Black Widow (Jul 2021)
        "tt10168312", // What If...? (Aug 2021)
        "tt9376612",  // Shang-Chi (Sep 2021)
        "tt9032400",  // Eternals (Nov 2021)
        "tt10160804", // Hawkeye (Nov 2021)
        "tt10872600", // Spider-Man: No Way Home (Dec 2021)
        "tt10234724", // Moon Knight (Mar 2022)
        "tt9419884",  // Doctor Strange in the Multiverse of Madness (May 2022)
        "tt10857164", // Ms. Marvel (Jun 2022)
        "tt10648342", // Thor: Love and Thunder (Jul 2022)
        "tt10857160", // She-Hulk: Attorney at Law (Aug 2022)
        "tt9114286",  // Black Panther: Wakanda Forever (Nov 2022)
        "tt10954600", // Ant-Man and the Wasp: Quantumania (Feb 2023)
        "tt6791350",  // Guardians of the Galaxy Vol. 3 (May 2023)
        "tt13157618", // Secret Invasion (Jun 2023)
        "tt10676048", // The Marvels (Nov 2023)
        "tt13966962", // Echo (Jan 2024)
        "tt6263850",  // Deadpool & Wolverine (Jul 2024)
        "tt15571732", // Agatha All Along (Sep 2024)
        "tt14513804", // Captain America: Brave New World (Feb 2025)
        "tt18923754", // Daredevil: Born Again (Mar 2025)
        "tt20969586", // Thunderbolts* (May 2025)
        "tt13623126", // Ironheart (Jun 2025)
        "tt10676052", // The Fantastic Four: First Steps (Jul 2025)
        // newer + UPCOMING (AJ Sep 17: unreleased belongs on the watch-order shelves too —
        // ids TMDB+Cinemeta verified Sep 17; VisionQuest is TMDB-only until Cinemeta adds it)
        "tt16027014", // Marvel Zombies (Sep 2025)
        "tt21066182", // Wonder Man (Jan 2026)
        "tt22084616", // Spider-Man: Brand New Day (Jul 2026)
        "tt23112594", // VisionQuest (Oct 2026, upcoming)
        "tt21357150", // Avengers: Doomsday (Dec 2026, upcoming)
        "tt21361444") // Avengers: Secret Wars (Dec 2027, upcoming)
    // MCU MOVIES + SHOWS MIXED by STORY timeline (the Disney+ official ordering):
    // WWII (First Avenger) → the multiverse era
    val MCU_CHRONO = listOf(
        "tt0458339",  // Captain America: The First Avenger (1943)
        "tt4154664",  // Captain Marvel (1995)
        "tt0371746",  // Iron Man
        "tt1228705",  // Iron Man 2
        "tt0800080",  // The Incredible Hulk
        "tt0800369",  // Thor
        "tt0848228",  // The Avengers
        "tt1300854",  // Iron Man 3
        "tt1981115",  // Thor: The Dark World
        "tt1843866",  // Captain America: The Winter Soldier
        "tt2015381",  // Guardians of the Galaxy
        "tt3896198",  // Guardians of the Galaxy Vol. 2
        "tt2395427",  // Avengers: Age of Ultron
        "tt0478970",  // Ant-Man
        "tt3498820",  // Captain America: Civil War
        "tt3480822",  // Black Widow
        "tt1825683",  // Black Panther
        "tt2250912",  // Spider-Man: Homecoming
        "tt1211837",  // Doctor Strange
        "tt3501632",  // Thor: Ragnarok
        "tt5095030",  // Ant-Man and the Wasp
        "tt4154756",  // Avengers: Infinity War
        "tt4154796",  // Avengers: Endgame
        "tt6320628",  // Spider-Man: Far From Home
        "tt9140560",  // WandaVision
        "tt9208876",  // The Falcon and the Winter Soldier
        "tt9376612",  // Shang-Chi and the Legend of the Ten Rings
        "tt9032400",  // Eternals
        "tt10872600", // Spider-Man: No Way Home
        "tt10160804", // Hawkeye
        "tt9140554",  // Loki
        "tt10168312", // What If...?
        "tt10234724", // Moon Knight
        "tt9419884",  // Doctor Strange in the Multiverse of Madness
        "tt10857164", // Ms. Marvel
        "tt10648342", // Thor: Love and Thunder
        "tt10857160", // She-Hulk: Attorney at Law
        "tt9114286",  // Black Panther: Wakanda Forever
        "tt13157618", // Secret Invasion
        "tt10954600", // Ant-Man and the Wasp: Quantumania
        "tt6791350",  // Guardians of the Galaxy Vol. 3
        "tt10676048", // The Marvels
        "tt13966962", // Echo
        "tt6263850",  // Deadpool & Wolverine
        "tt15571732", // Agatha All Along
        "tt14513804", // Captain America: Brave New World
        "tt18923754", // Daredevil: Born Again
        "tt20969586", // Thunderbolts*
        "tt13623126", // Ironheart
        "tt10676052", // The Fantastic Four: First Steps
        "tt16027014", // Marvel Zombies (alternate-timeline animated — rides at the end)
        "tt21066182", // Wonder Man
        "tt22084616", // Spider-Man: Brand New Day
        "tt23112594", // VisionQuest (upcoming)
        "tt21357150", // Avengers: Doomsday (upcoming)
        "tt21361444") // Avengers: Secret Wars (upcoming)
    // X-Men film series by release: X-Men (2000) → The New Mutants, + Deadpool & Wolverine
    val XMEN_RELEASE = listOf(
        "tt0120903", "tt0290334", "tt0376994", "tt0458525", "tt1270798", "tt1430132",
        "tt1877832", "tt1431045", "tt3385516", "tt3315342", "tt5463162", "tt6565702",
        "tt4682266", "tt6263850")

    /** Every shelf the HOME screen can show — users toggle them in Settings ("fully
     *  customizable"). Order here = display order. */
    val SHELF_CATALOG: List<Row> = listOf(
        Row("Coming Soon", "movie", "", tmdb = "movie/upcoming", tmdbKind = "movie"),
        Row("Trending Today", "movie", "", tmdb = "trending/movie/day", tmdbKind = "movie"),
        Row("Christmas Movies", "movie", "", tmdb = "discover/movie?with_keywords=207317&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("Halloween Movies", "movie", "", tmdb = "discover/movie?with_keywords=3335&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("Date Night", "movie", "", tmdb = "discover/movie?with_genres=10749,35&sort_by=popularity.desc&vote_count.gte=200", tmdbKind = "movie",
            tmdbTv = "discover/tv?with_genres=35&sort_by=popularity.desc&vote_count.gte=100"),
        // moods & vibes (AJ Sep 10: "more genres moods and seasons") — keyword ids verified:
        // 9715 superhero, 12377 zombie, 4379 time travel
        Row("Superheroes", "movie", "", tmdb = "discover/movie?with_keywords=9715&sort_by=popularity.desc&vote_count.gte=100", tmdbKind = "movie",
            tmdbTv = "discover/tv?with_keywords=9715&sort_by=popularity.desc&vote_count.gte=20"),
        Row("Zombies", "movie", "", tmdb = "discover/movie?with_keywords=12377&sort_by=popularity.desc&vote_count.gte=50", tmdbKind = "movie",
            tmdbTv = "discover/tv?with_keywords=12377&sort_by=popularity.desc&vote_count.gte=15"),
        Row("Time Travel", "movie", "", tmdb = "discover/movie?with_keywords=4379&sort_by=popularity.desc&vote_count.gte=100", tmdbKind = "movie",
            tmdbTv = "discover/tv?with_keywords=4379&sort_by=popularity.desc&vote_count.gte=15"),
        Row("Feel-Good", "movie", "", tmdb = "discover/movie?with_genres=35,10751&sort_by=popularity.desc&vote_count.gte=300", tmdbKind = "movie",
            tmdbTv = "discover/tv?with_genres=35,10751&sort_by=popularity.desc&vote_count.gte=100"),
        Row("Tearjerkers", "movie", "", tmdb = "discover/movie?with_genres=18,10749&sort_by=vote_average.desc&vote_count.gte=500", tmdbKind = "movie",
            tmdbTv = "discover/tv?with_genres=18&sort_by=vote_average.desc&vote_count.gte=200"),
        Row("Summer Blockbusters", "movie", "", tmdb = "discover/movie?with_genres=28,12&sort_by=popularity.desc&vote_count.gte=1000", tmdbKind = "movie",
            tmdbTv = "discover/tv?with_genres=10759&sort_by=popularity.desc&vote_count.gte=200"),
        Row("Fantasy Worlds", "movie", "", tmdb = "discover/movie?with_genres=14&sort_by=popularity.desc&vote_count.gte=300", tmdbKind = "movie",
            tmdbTv = "discover/tv?with_genres=10765&sort_by=popularity.desc&vote_count.gte=100"),
        Row("War Movies", "movie", "", tmdb = "discover/movie?with_genres=10752&sort_by=popularity.desc&vote_count.gte=200", tmdbKind = "movie"),
        Row("Musicals", "movie", "", tmdb = "discover/movie?with_genres=10402&sort_by=popularity.desc&vote_count.gte=100", tmdbKind = "movie"),
        Row("Cozy Mystery Series", "series", "", tmdb = "discover/tv?with_genres=9648&sort_by=popularity.desc&vote_count.gte=50", tmdbKind = "tv"),
        Row("True Crime", "series", "", tmdb = "discover/tv?with_genres=99,80&sort_by=popularity.desc", tmdbKind = "tv"),
        Row("Based on a True Story", "movie", "", tmdb = "discover/movie?with_keywords=9672&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("Classics", "movie", "", tmdb = "discover/movie?primary_release_date.lte=1989-12-31&sort_by=vote_count.desc", tmdbKind = "movie"),
        Row("90s Throwbacks", "movie", "", tmdb = "discover/movie?primary_release_date.gte=1990-01-01&primary_release_date.lte=1999-12-31&sort_by=vote_count.desc", tmdbKind = "movie"),
        Row("Kids Movies", "movie", "", tmdb = "discover/movie?with_genres=16,10751&sort_by=popularity.desc&certification_country=US&certification.lte=PG", tmdbKind = "movie"),
        Row("Westerns", "movie", "top", "Western"),
        Row("Mystery", "movie", "top", "Mystery"),
        Row("Kids TV", "series", "", tmdb = "discover/tv?with_genres=10762&sort_by=popularity.desc", tmdbKind = "tv"),
        Row("Popular Movies", "movie", "top"),
        Row("Popular Series", "series", "top"),
        Row("New in Theaters", "movie", "", tmdb = nowPlaying(), tmdbKind = "movie"),
        Row("🍅 Certified Fresh", "movie", "", tmdb = "discover/movie?vote_average.gte=7.4&vote_count.gte=300&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("🍅 Certified Fresh Series", "series", "", tmdb = "discover/tv?vote_average.gte=7.7&vote_count.gte=200&sort_by=popularity.desc", tmdbKind = "tv"),
        Row("Trending Movies", "movie", "", tmdb = "trending/movie/week", tmdbKind = "movie"),
        Row("Trending Series", "series", "", tmdb = "trending/tv/week", tmdbKind = "tv"),
        Row("New Shows", "series", "", tmdb = "discover/tv?sort_by=first_air_date.desc&vote_count.gte=25", tmdbKind = "tv"),
        Row("Top Rated Movies", "movie", "imdbRating"),
        Row("Top Rated Series", "series", "imdbRating"),
        Row("Anime", "series", "", tmdb = "discover/tv?with_genres=16&with_origin_country=JP&sort_by=popularity.desc", tmdbKind = "tv"),
        Row("Anime Movies", "movie", "", tmdb = "discover/movie?with_genres=16&with_origin_country=JP&sort_by=popularity.desc", tmdbKind = "movie"),
        // "Hallmark" = the MOVIES (that's what the brand means to viewers) — production-company
        // scoped so only real Hallmark originals show. Network 384 kept old miniseries that
        // merely AIRED there (Jules Verne, King Solomon's Mines) in what read as a movie shelf.
        Row("Hallmark", "movie", "", tmdb = "discover/movie?with_companies=53015|304438&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("Hallmark New", "movie", "", tmdb = "discover/movie?with_companies=53015|304438&sort_by=primary_release_date.desc&vote_count.gte=1", tmdbKind = "movie"),
        Row("Hallmark Series", "series", "", tmdb = "discover/tv?with_networks=384&sort_by=popularity.desc", tmdbKind = "tv"),
        // Hallmark ∩ Christmas keyword = only the actual Christmas ones (AJ Sep 10)
        Row("Hallmark Christmas Movies", "movie", "", tmdb = "discover/movie?with_companies=53015|304438&with_keywords=207317&sort_by=popularity.desc", tmdbKind = "movie"),
        // ---- MARVEL / X-MEN (AJ Sep 10). Chronological + release order are CURATED id lists
        // (every id verified against Cinemeta) — a TMDB query can't express watch order.
        Row("Marvel: Release Order", "movie", "", ids = MCU_RELEASE),
        Row("Marvel: Chronological", "movie", "", ids = MCU_CHRONO),
        Row("Marvel Movies", "movie", "", tmdb = "discover/movie?with_companies=420&sort_by=popularity.desc", tmdbKind = "movie"),
        Row("Marvel Series", "series", "", tmdb = "discover/tv?with_companies=420|7505&sort_by=popularity.desc", tmdbKind = "tv"),
        Row("X-Men Movies", "movie", "", ids = XMEN_RELEASE),
        Row("Netflix", "series", "", tmdb = prov("tv", "8"), tmdbKind = "tv"),
        Row("Hulu", "series", "", tmdb = prov("tv", "15"), tmdbKind = "tv"),
        Row("Disney+", "series", "", tmdb = prov("tv", "337"), tmdbKind = "tv"),
        Row("Max", "series", "", tmdb = prov("tv", "1899"), tmdbKind = "tv"),
        Row("Prime Video", "movie", "", tmdb = prov("movie", "9"), tmdbKind = "movie"),
        Row("Apple TV+", "series", "", tmdb = prov("tv", "350"), tmdbKind = "tv"),
        Row("Paramount+", "series", "", tmdb = prov("tv", "2303|2616|531"), tmdbKind = "tv"),
        Row("Peacock", "series", "", tmdb = prov("tv", "386"), tmdbKind = "tv"),
        Row("Action", "movie", "top", "Action"),
        Row("Comedy", "movie", "top", "Comedy"),
        Row("Horror", "movie", "top", "Horror"),
        Row("Sci-Fi", "movie", "top", "Sci-Fi"),
        Row("Romance", "movie", "top", "Romance"),
        Row("Thriller", "movie", "top", "Thriller"),
        Row("Drama Series", "series", "top", "Drama"),
        Row("Crime Series", "series", "top", "Crime"),
        Row("Reality", "series", "top", "Reality-TV"),
        Row("Documentary", "movie", "top", "Documentary"),
        Row("Family", "movie", "top", "Family"),
    )
    // Default home (AJ): For You leads (always on), the trending/popular basics, then EVERY
    // streaming service row, plus a couple of broad crowd-pleasers. Blur stays off and
    // poster titles stay on by default — set where those prefs are declared.
    val DEFAULT_SHELVES = listOf("Trending Today", "Trending Series", "Popular Movies", "Popular Series",
        "New in Theaters", "Coming Soon",
        "Netflix", "Hulu", "Disney+", "Max", "Prime Video", "Apple TV+", "Paramount+", "Peacock",
        "Top Rated Movies", "Top Rated Series", "True Crime")
}

/** Grid/poster-level info. desc rides along when the catalog offers it (TMDB always does,
 *  Cinemeta sometimes) so the info panel can show a description with ZERO fetch on focus —
 *  that's how Stremio's descriptions feel instant. */
data class Title(val id: String, val type: String, val name: String, val poster: String?,
                 val desc: String? = null) {
    companion object {
        fun from(o: JSONObject) = Title(
            id = o.optString("id"),
            type = o.optString("type", "movie"),
            name = o.optString("name"),
            poster = o.optString("poster").ifBlank { null },
            desc = o.optString("description").ifBlank { null },
        )
    }
}

/** One episode of a series (Cinemeta meta.videos[]). id is the stream id ("tt123:1:2"). */
data class Episode(val id: String, val season: Int, val episode: Int, val name: String,
                   val thumbnail: String?, val description: String,
                   val released: String? = null, val aired: Boolean = true,
                   val releasedIso: String? = null) {
    companion object {
        fun from(o: JSONObject): Episode? {
            val id = o.optString("id").ifBlank { return null }
            val s = o.optInt("season", -1)
            val e = if (o.has("episode")) o.optInt("episode", -1) else o.optInt("number", -1)
            if (s < 0 || e < 0) return null
            // Cinemeta "released" is ISO UTC; keep a friendly date + an aired flag so the UI
            // can show air dates and paint unreleased ones yellow (Stremio-style)
            val rel = o.optString("released", "")
            var relStr: String? = null; var aired = true
            if (rel.length >= 10) {
                try {
                    // FULL timestamp, not just the date (AJ: Silo E10 showed +1 at local
                    // midnight — the drop is 08:00 UTC / 4 AM ET; date-only said "aired")
                    val d = if (rel.length >= 19) {
                        java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
                            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
                            .parse(rel.substring(0, 19))
                    } else java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).parse(rel.substring(0, 10))
                    aired = d != null && d.time <= System.currentTimeMillis()
                    relStr = java.text.SimpleDateFormat("MMM d, yyyy", java.util.Locale.US).format(d!!)
                } catch (_: Exception) {}
            }
            return Episode(id, s, e, o.optString("name").ifBlank { o.optString("title") },
                           o.optString("thumbnail").ifBlank { null },
                           o.optString("overview").ifBlank { o.optString("description") },
                           relStr, aired, rel.ifBlank { null })
        }
    }
}

/** Everything the detail screen shows. */
data class Meta(
    val id: String,
    val type: String,
    val name: String,
    val year: String,
    val runtime: String,
    val imdbRating: String,
    val genres: List<String>,
    val cast: List<String>,
    val director: List<String>,
    val description: String,
    val poster: String?,
    val background: String?,
    val logo: String? = null,
    val trailerYoutubeId: String?,
    val videos: List<Episode>,
) {
    companion object {
        private fun strs(o: JSONObject, key: String): List<String> {
            val a = o.optJSONArray(key) ?: return emptyList()
            return (0 until a.length()).map { a.optString(it) }.filter { it.isNotBlank() }
        }

        fun from(o: JSONObject): Meta {
            // trailer: Cinemeta gives trailers:[{source:<ytid>,type:"Trailer"}] or trailerStreams
            var yt: String? = null
            o.optJSONArray("trailers")?.let { if (it.length() > 0) yt = it.getJSONObject(0).optString("source").ifBlank { null } }
            if (yt == null) o.optJSONArray("trailerStreams")?.let {
                if (it.length() > 0) yt = it.getJSONObject(0).optString("ytId").ifBlank { null }
            }
            return Meta(
                id = o.optString("id"),
                type = o.optString("type", "movie"),
                name = o.optString("name"),
                year = o.optString("year").ifBlank { o.optString("releaseInfo") },
                runtime = o.optString("runtime"),
                imdbRating = o.optString("imdbRating"),
                genres = strs(o, "genres"),
                cast = strs(o, "cast"),
                director = strs(o, "director"),
                description = o.optString("description"),
                poster = o.optString("poster").ifBlank { null },
                background = o.optString("background").ifBlank { null },
                logo = o.optString("logo").ifBlank { null },
                trailerYoutubeId = yt,
                videos = o.optJSONArray("videos")?.let { a ->
                    (0 until a.length()).mapNotNull { Episode.from(a.getJSONObject(it)) }
                } ?: emptyList(),
            )
        }
    }
}
