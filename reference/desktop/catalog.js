// Ported from the TV app's Discovery.kt — SAME shelves, SAME queries, SAME order,
// so Home/Discover on desktop mirror the Firestick exactly.
const CK_CAT = (() => {
    const nowPlaying = () => {
        const d = (t) => new Date(Date.now() + t).toISOString().slice(0, 10);
        return `discover/movie?sort_by=popularity.desc&with_release_type=3|2&region=US&vote_count.gte=3` +
            `&primary_release_date.gte=${d(-75 * 864e5)}&primary_release_date.lte=${d(3 * 864e5)}`;
    };
    const prov = (kind, ids) => `discover/${kind}?with_watch_providers=${ids}&watch_region=US&sort_by=popularity.desc`;
    // Curated watch orders (every id verified) — identical lists to the TV app
    const MCU_RELEASE = ["tt0371746","tt0800080","tt1228705","tt0800369","tt0458339","tt0848228","tt1300854","tt1981115","tt1843866","tt2015381","tt2395427","tt0478970","tt3498820","tt1211837","tt3896198","tt2250912","tt3501632","tt1825683","tt4154756","tt5095030","tt4154664","tt4154796","tt6320628","tt9140560","tt9208876","tt9140554","tt3480822","tt10168312","tt9376612","tt9032400","tt10160804","tt10872600","tt10234724","tt9419884","tt10857164","tt10648342","tt10857160","tt9114286","tt10954600","tt6791350","tt13157618","tt10676048","tt13966962","tt6263850","tt15571732","tt14513804","tt18923754","tt20969586","tt13623126","tt10676052","tt16027014","tt21066182","tt22084616","tt23112594","tt21357150","tt21361444"];
    const MCU_CHRONO = ["tt0458339","tt4154664","tt0371746","tt1228705","tt0800080","tt0800369","tt0848228","tt1300854","tt1981115","tt1843866","tt2015381","tt3896198","tt2395427","tt0478970","tt3498820","tt3480822","tt1825683","tt2250912","tt1211837","tt3501632","tt5095030","tt4154756","tt4154796","tt6320628","tt9140560","tt9208876","tt9376612","tt9032400","tt10872600","tt10160804","tt9140554","tt10168312","tt10234724","tt9419884","tt10857164","tt10648342","tt10857160","tt9114286","tt13157618","tt10954600","tt6791350","tt10676048","tt13966962","tt6263850","tt15571732","tt14513804","tt18923754","tt20969586","tt13623126","tt10676052","tt16027014","tt21066182","tt22084616","tt23112594","tt21357150","tt21361444"];
    const XMEN = ["tt0120903","tt0290334","tt0376994","tt0458525","tt1270798","tt1430132","tt1877832","tt1431045","tt3385516","tt3315342","tt5463162","tt6565702","tt4682266","tt6263850"];

    // label, type, {tmdb|cine genre|ids}
    const SHELF_CATALOG = [
        { label: "Coming Soon", type: "movie", tmdb: "movie/upcoming" },
        { label: "Trending Today", type: "movie", tmdb: "trending/movie/day" },
        { label: "Christmas Movies", type: "movie", tmdb: "discover/movie?with_keywords=207317&sort_by=popularity.desc" },
        { label: "Halloween Movies", type: "movie", tmdb: "discover/movie?with_keywords=3335&sort_by=popularity.desc" },
        { label: "Date Night", type: "movie", tmdb: "discover/movie?with_genres=10749,35&sort_by=popularity.desc&vote_count.gte=200", tvTmdb: "discover/tv?with_genres=35&sort_by=popularity.desc&vote_count.gte=100" },
        { label: "Superheroes", type: "movie", tmdb: "discover/movie?with_keywords=9715&sort_by=popularity.desc&vote_count.gte=100", tvTmdb: "discover/tv?with_keywords=9715&sort_by=popularity.desc&vote_count.gte=20" },
        { label: "Zombies", type: "movie", tmdb: "discover/movie?with_keywords=12377&sort_by=popularity.desc&vote_count.gte=50", tvTmdb: "discover/tv?with_keywords=12377&sort_by=popularity.desc&vote_count.gte=15" },
        { label: "Time Travel", type: "movie", tmdb: "discover/movie?with_keywords=4379&sort_by=popularity.desc&vote_count.gte=100", tvTmdb: "discover/tv?with_keywords=4379&sort_by=popularity.desc&vote_count.gte=15" },
        { label: "Feel-Good", type: "movie", tmdb: "discover/movie?with_genres=35,10751&sort_by=popularity.desc&vote_count.gte=300", tvTmdb: "discover/tv?with_genres=35,10751&sort_by=popularity.desc&vote_count.gte=100" },
        { label: "Tearjerkers", type: "movie", tmdb: "discover/movie?with_genres=18,10749&sort_by=vote_average.desc&vote_count.gte=500", tvTmdb: "discover/tv?with_genres=18&sort_by=vote_average.desc&vote_count.gte=200" },
        { label: "Summer Blockbusters", type: "movie", tmdb: "discover/movie?with_genres=28,12&sort_by=popularity.desc&vote_count.gte=1000", tvTmdb: "discover/tv?with_genres=10759&sort_by=popularity.desc&vote_count.gte=200" },
        { label: "Fantasy Worlds", type: "movie", tmdb: "discover/movie?with_genres=14&sort_by=popularity.desc&vote_count.gte=300", tvTmdb: "discover/tv?with_genres=10765&sort_by=popularity.desc&vote_count.gte=100" },
        { label: "War Movies", type: "movie", tmdb: "discover/movie?with_genres=10752&sort_by=popularity.desc&vote_count.gte=200" },
        { label: "Musicals", type: "movie", tmdb: "discover/movie?with_genres=10402&sort_by=popularity.desc&vote_count.gte=100" },
        { label: "Cozy Mystery Series", type: "series", tmdb: "discover/tv?with_genres=9648&sort_by=popularity.desc&vote_count.gte=50" },
        { label: "True Crime", type: "series", tmdb: "discover/tv?with_genres=99,80&sort_by=popularity.desc" },
        { label: "Based on a True Story", type: "movie", tmdb: "discover/movie?with_keywords=9672&sort_by=popularity.desc" },
        { label: "Classics", type: "movie", tmdb: "discover/movie?primary_release_date.lte=1989-12-31&sort_by=vote_count.desc" },
        { label: "90s Throwbacks", type: "movie", tmdb: "discover/movie?primary_release_date.gte=1990-01-01&primary_release_date.lte=1999-12-31&sort_by=vote_count.desc" },
        { label: "Kids Movies", type: "movie", tmdb: "discover/movie?with_genres=16,10751&sort_by=popularity.desc&certification_country=US&certification.lte=PG" },
        { label: "Kids TV", type: "series", tmdb: "discover/tv?with_genres=10762&sort_by=popularity.desc" },
        { label: "Popular Movies", type: "movie", cine: "top" },
        { label: "Popular Series", type: "series", cine: "top" },
        { label: "New in Theaters", type: "movie", tmdb: nowPlaying() },
        { label: "🍅 Certified Fresh", type: "movie", tmdb: "discover/movie?vote_average.gte=7.4&vote_count.gte=300&sort_by=popularity.desc" },
        { label: "🍅 Certified Fresh Series", type: "series", tmdb: "discover/tv?vote_average.gte=7.7&vote_count.gte=200&sort_by=popularity.desc" },
        { label: "Trending Movies", type: "movie", tmdb: "trending/movie/week" },
        { label: "Trending Series", type: "series", tmdb: "trending/tv/week" },
        { label: "New Shows", type: "series", tmdb: "discover/tv?sort_by=first_air_date.desc&vote_count.gte=25" },
        { label: "Top Rated Movies", type: "movie", cine: "imdbRating" },
        { label: "Top Rated Series", type: "series", cine: "imdbRating" },
        { label: "Anime", type: "series", tmdb: "discover/tv?with_genres=16&with_origin_country=JP&sort_by=popularity.desc" },
        { label: "Anime Movies", type: "movie", tmdb: "discover/movie?with_genres=16&with_origin_country=JP&sort_by=popularity.desc" },
        { label: "Hallmark", type: "movie", tmdb: "discover/movie?with_companies=53015|304438&sort_by=popularity.desc" },
        { label: "Hallmark New", type: "movie", tmdb: "discover/movie?with_companies=53015|304438&sort_by=primary_release_date.desc&vote_count.gte=1" },
        { label: "Hallmark Series", type: "series", tmdb: "discover/tv?with_networks=384&sort_by=popularity.desc" },
        { label: "Hallmark Christmas Movies", type: "movie", tmdb: "discover/movie?with_companies=53015|304438&with_keywords=207317&sort_by=popularity.desc" },
        { label: "Marvel: Release Order", type: "movie", ids: MCU_RELEASE },
        { label: "Marvel: Chronological", type: "movie", ids: MCU_CHRONO },
        { label: "Marvel Movies", type: "movie", tmdb: "discover/movie?with_companies=420&sort_by=popularity.desc" },
        { label: "Marvel Series", type: "series", tmdb: "discover/tv?with_companies=420|7505&sort_by=popularity.desc" },
        { label: "X-Men Movies", type: "movie", ids: XMEN },
        { label: "Netflix", type: "series", tmdb: prov("tv", "8") },
        { label: "Hulu", type: "series", tmdb: prov("tv", "15") },
        { label: "Disney+", type: "series", tmdb: prov("tv", "337") },
        { label: "Max", type: "series", tmdb: prov("tv", "1899") },
        { label: "Prime Video", type: "movie", tmdb: prov("movie", "9") },
        { label: "Apple TV+", type: "series", tmdb: prov("tv", "350") },
        { label: "Paramount+", type: "series", tmdb: prov("tv", "2303|2616|531") },
        { label: "Peacock", type: "series", tmdb: prov("tv", "386") },
        { label: "Action", type: "movie", cine: "top", genre: "Action" },
        { label: "Comedy", type: "movie", cine: "top", genre: "Comedy" },
        { label: "Horror", type: "movie", cine: "top", genre: "Horror" },
        { label: "Sci-Fi", type: "movie", cine: "top", genre: "Sci-Fi" },
        { label: "Romance", type: "movie", cine: "top", genre: "Romance" },
        { label: "Thriller", type: "movie", cine: "top", genre: "Thriller" },
        { label: "Drama Series", type: "series", cine: "top", genre: "Drama" },
        { label: "Crime Series", type: "series", cine: "top", genre: "Crime" },
        { label: "Reality", type: "series", cine: "top", genre: "Reality-TV" },
        { label: "Documentary", type: "movie", cine: "top", genre: "Documentary" },
        { label: "Family", type: "movie", cine: "top", genre: "Family" },
    ];
    const DEFAULT_SHELVES = ["Trending Today", "Trending Series", "Popular Movies", "Popular Series",
        "New in Theaters", "Coming Soon", "Netflix", "Hulu", "Disney+", "Max", "Prime Video",
        "Apple TV+", "Paramount+", "Peacock", "Top Rated Movies", "Top Rated Series", "True Crime"];
    // Discover catalogs — EXACT port of Discovery.kt MOVIE_CATS / TV_CATS (one dropdown's
    // worth per type, same labels, same order, same queries)
    const MOVIE_CATS = [
        { label: "Popular", cine: "top" },
        { label: "Trending", tmdb: "trending/movie/week" },
        { label: "For You", foryou: true },
        { label: "New", cine: "year" },
        { label: "Top Rated", cine: "imdbRating" },
        { label: "New in Theaters", tmdb: nowPlaying() },
        { label: "🍅 Certified Fresh", tmdb: "discover/movie?vote_average.gte=7.4&vote_count.gte=300&sort_by=popularity.desc" },
        { label: "Netflix", tmdb: prov("movie", "8") },
        { label: "Hulu", tmdb: prov("movie", "15") },
        { label: "Max", tmdb: prov("movie", "1899") },
        { label: "Prime Video", tmdb: prov("movie", "9") },
        { label: "Apple TV+", tmdb: prov("movie", "350") },
        { label: "Disney+", tmdb: prov("movie", "337") },
        { label: "Paramount+", tmdb: prov("movie", "2303|2616|531") },
        { label: "Peacock", tmdb: prov("movie", "386") },
    ];
    const TV_CATS = [
        { label: "Popular", cine: "top" },
        { label: "Trending", tmdb: "trending/tv/week" },
        { label: "For You", foryou: true },
        { label: "New", cine: "year" },
        { label: "Top Rated", cine: "imdbRating" },
        { label: "New Shows", tmdb: "discover/tv?sort_by=first_air_date.desc&vote_count.gte=25" },
        { label: "Anime", tmdb: "discover/tv?with_genres=16&with_origin_country=JP&sort_by=popularity.desc" },
        { label: "Netflix", tmdb: prov("tv", "8") },
        { label: "Hulu", tmdb: prov("tv", "15") },
        { label: "Max", tmdb: prov("tv", "1899") },
        { label: "Prime Video", tmdb: prov("tv", "9") },
        { label: "Apple TV+", tmdb: prov("tv", "350") },
        { label: "Disney+", tmdb: prov("tv", "337") },
        { label: "Paramount+", tmdb: prov("tv", "2303|2616|531") },
        { label: "Peacock", tmdb: prov("tv", "386") },
    ];
    // shelf-picker groupings — same buckets as the Firestick's Home-shelves page
    const SHELF_GROUPS = {
        providers: ["Netflix", "Hulu", "Disney+", "Max", "Prime Video", "Apple TV+", "Paramount+", "Peacock"],
        channels: ["Hallmark", "Hallmark New", "Hallmark Series", "Hallmark Christmas Movies",
            "Anime", "Anime Movies",
            "Marvel: Release Order", "Marvel: Chronological", "Marvel Movies", "Marvel Series", "X-Men Movies"],
        moods: ["Christmas Movies", "Halloween Movies", "Date Night", "True Crime",
            "Based on a True Story", "Classics", "90s Throwbacks", "Kids Movies", "Kids TV",
            "Superheroes", "Zombies", "Time Travel", "Feel-Good", "Tearjerkers",
            "Summer Blockbusters", "Fantasy Worlds", "War Movies", "Musicals", "Cozy Mystery Series"],
        genres: ["Action", "Comedy", "Horror", "Sci-Fi", "Romance", "Thriller",
            "Drama Series", "Crime Series", "Reality", "Documentary", "Family"],
    };
    const GENRES = ["All", "Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama",
        "Family", "Fantasy", "History", "Horror", "Music", "Mystery", "Romance", "Sci-Fi", "Thriller", "War", "Western"];
    const TMDB_GENRE_IDS = { Action: 28, Adventure: 12, Animation: 16, Comedy: 35, Crime: 80, Documentary: 99,
        Drama: 18, Family: 10751, Fantasy: 14, History: 36, Horror: 27, Music: 10402, Mystery: 9648,
        Romance: 10749, "Sci-Fi": 878, Thriller: 53, War: 10752, Western: 37 };
    const TMDB_TV_GENRE_IDS = { Action: 10759, Adventure: 10759, Animation: 16, Comedy: 35, Crime: 80,
        Documentary: 99, Drama: 18, Family: 10751, Fantasy: 10765, Mystery: 9648, Romance: 10749,
        "Sci-Fi": 10765, War: 10768, Western: 37 };
    // profile avatars + background colors — SAME sets as the TV app (parity)
    const AVATAR_CHOICES = ["👑","🦁","🦊","🐼","🐸","🚀","🌸","🎮","🐱","🐶","🐰","🐻",
        "🐧","🦄","⚽","🍕","🤖","👽","🦸","🍿","⭐","🌟","🎈","🎸"];
    const COLOR_CHOICES = ["#7B5BF5","#E2574C","#4CAF7D","#E2A54C","#4C9DE2","#C24CE2","#E24C9D","#3FB6B0"];
    return { SHELF_CATALOG, DEFAULT_SHELVES, MOVIE_CATS, TV_CATS, SHELF_GROUPS, GENRES, TMDB_GENRE_IDS, TMDB_TV_GENRE_IDS, AVATAR_CHOICES, COLOR_CHOICES };
})();
