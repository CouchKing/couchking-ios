// The IN-WINDOW player + the web shim, shared by BOTH worlds (0.9.13):
//   • web: also defines window.ck (fetch/openExternal/etc.) exactly like before
//   • desktop: preload already made window.ck — this file adds the SAME in-window
//     player on top, and playback ROUTES here first (AJ Sep 14: raw mpv window is
//     "awful, hard to navigate"); mpv is a silent fallback for streams Chromium can't
//     decode (HEVC & friends — the reason mpv exists at all) and for runtime failures.
// app.js talks only to the unified surface at the bottom: ckPlay / ckStop / ckOnPos /
// ckOnExit — it never needs to know which engine is on screen.
//
// Playback goes through the service's /webplay remux (video copied, audio → AAC the
// browser can decode, MKV → fragmented MP4) with custom controls styled like the TV
// player: purple time bar, labeled buttons (word ABOVE icon), top overlay with clock +
// "Ends h:mm", Skip-intro from the learned window, and the UP NEXT card at credits time.
// Seeking reopens the stream at the new offset (fMP4 can't range-seek) — every position
// shown/reported is offset + video.currentTime, duration from /webplay/probe.
(function () {
    const DESK = !!window.ck;   // preload ran first = Electron

    // Live-captions side panel CSS — matches the look of .wp-menu (see style.css) but
    // pinned to the RIGHT edge and vertically centred so it stays open while the viewer
    // clicks through tracks, and never covers the bottom-centre .wp-cue captions.
    if (!document.getElementById('wp-subpanel-css')) {
        const st = document.createElement('style');
        st.id = 'wp-subpanel-css';
        st.textContent = `
#web-player .wp-subpanel { position:absolute; right:0; top:50%; transform:translateY(-50%);
                           max-height:70vh; width:280px; overflow-y:auto;
                           background:var(--card); border:1px solid #37315C; border-right:none;
                           border-radius:16px 0 0 16px; padding:.7rem;
                           display:flex; flex-direction:column; gap:.2rem;
                           box-shadow:0 12px 40px #000C; z-index:120; }
#web-player .wp-subpanel .wp-sptitle { color:var(--muted); font-size:.72rem; font-weight:800;
                           text-transform:uppercase; letter-spacing:.08em; padding:.2rem .9rem .5rem; }
#web-player .wp-subpanel button { background:transparent; padding:.55rem .9rem; text-align:left;
                           border-radius:10px; font-size:.95rem; color:#fff; }
#web-player .wp-subpanel button:hover { background:#332D55; }
#web-player .wp-subpanel button.on { background:transparent; color:var(--accent); font-weight:800; }
#web-player .wp-subpanel button.on:hover { background:#332D55; }`;
        document.head.appendChild(st);
    }
    const b64u = (s) => btoa(unescape(encodeURIComponent(s))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    const fmt = (s) => { s = Math.max(0, Math.floor(s)); const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60); return (h ? h + ':' : '') + String(m).padStart(h ? 2 : 1, '0') + ':' + String(s % 60).padStart(2, '0'); };
    const clock = (d) => d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
    let posCb = null, exitCb = null, player = null, state = null;
    let engine = null;   // 'web' | 'mpv' | null — which engine owns the current playback

    // cross-origin text fetch that works from the desktop's file:// page too (no CORS
    // over the IPC bridge) — subtitles + the OpenSubtitles feed go through here
    async function httpText(url) {
        if (DESK) { const r = await window.ck.http({ url, timeoutMs: 15000 }); return r?.ok ? r.text : null; }
        const r = await fetch(url); return r.ok ? r.text() : null;
    }

    function closePlayer(fireExit, extra) {
        if (!player) return;
        const st = state; state = null;
        const v = player.querySelector('video');
        // read the position BEFORE load() — load() resets currentTime to 0 and used to
        // collapse the exit beacon's saved position (the resume/false-watched bug)
        const posAtExit = st ? st.offset + (v?.currentTime || 0) : 0;
        clearInterval(st?.tick);
        clearTimeout(st?.fbTimer);
        // DESTROY the streaming engine, don't just pause the <video> (AJ Sep 18: a closed web/
        // desktop player kept pulling segments = kept its Live TV device slot held). hls.js /
        // mpegts.js keep fetching after a bare pause; destroy() closes the connections so the
        // slot frees (server sweeps it within ~15s once the beats stop).
        try { st?.hls?.destroy(); } catch {}
        try { st?.mp?.destroy(); } catch {}
        try { v.pause(); v.removeAttribute('src'); v.load(); } catch {}
        player.remove(); player = null;
        document.body.style.overflow = '';
        if (fireExit && st) {
            engine = null;
            exitCb && exitCb({ pos: posAtExit, dur: st.dur || 0, lastCue: st.lastCue || 0, ...(extra || {}) });
        }
    }

    async function service() {
        if (DESK) return window.ck.service();
        return location.origin.includes('couchking') ? location.origin : 'https://couchking.app';
    }

    async function webPlay({ url, title, startSec = 0, seekStep = 10, sid = '', subs = [],
                       subScale = 1.0, subLang = 'en', subBg = false, subOutline = true, subPos = 0,
                       introFromMs = -1, introToMs = -1, creditsMs = 0, probeDur = 0,
                       afterCredits = [],
                       localFile = '', inlineSubs = [],
                       nextLabel = '', hasNext = false, autonext = true }, hooks = null) {
            closePlayer(false);
            engine = 'web';
            const SVC = await service();
            const u = b64u(url);
            state = { offset: localFile ? 0 : startSec, dur: probeDur || 0, u, SVC, step: seekStep || 10,
                      cues: [], lastCue: 0, introHandled: false, nextShown: false, speed: 1,
                      started: false, fbTimer: null };
            player = document.createElement('div');
            player.id = 'web-player';
            player.innerHTML = `
                <video autoplay playsinline></video>
                <div class="wp-cue"></div>
                <div class="wp-ui">
                  <div class="wp-top">
                    <button class="wp-btn wp-back">‹ Back</button><span class="wp-title"></span>
                    <span class="wp-right"><span class="wp-clock"></span><span class="wp-ends"></span></span>
                  </div>
                  <button class="wp-skip hidden">Skip intro ⏭</button>
                  <div class="wp-next hidden">
                    <div class="wpn-tag">UP NEXT</div><div class="wpn-title"></div>
                    <div class="wpn-btns"><button class="wpn-play">▶ Play now</button><button class="wpn-dismiss">Dismiss</button></div>
                  </div>
                  <div class="wp-bottom">
                    <div class="wp-bar"><div class="wp-fill"></div><div class="wp-dot"></div></div>
                    <div class="wp-times"><span class="wp-cur">0:00</span><span class="wp-dur">–:––</span></div>
                    <div class="wp-controls">
                      <div class="wp-cell"><span>Back ${seekStep}s</span><button class="wp-btn wp-rew">⏪</button></div>
                      <div class="wp-cell"><span>Play / Pause</span><button class="wp-btn wp-pp">⏸</button></div>
                      <div class="wp-cell"><span>Forward ${seekStep}s</span><button class="wp-btn wp-fwd">⏩</button></div>
                      ${hasNext ? '<div class="wp-cell"><span>Next</span><button class="wp-btn wp-nextbtn">⏭</button></div>' : ''}
                      <div class="wp-cell"><span>Subtitles</span><button class="wp-btn wp-subs">💬</button></div>
                      <div class="wp-cell"><span>Sub Size</span><button class="wp-btn wp-subsize">Aa</button></div>
                      <div class="wp-cell"><span>Size</span><button class="wp-btn wp-scale">⤢</button></div>
                      <div class="wp-cell"><span>Speed</span><button class="wp-btn wp-speed">1×</button></div>
                      <div class="wp-cell"><span>Info</span><button class="wp-btn wp-info">ⓘ</button></div>
                      <div class="wp-cell"><span>Volume</span><input class="wp-vol" type="range" min="0" max="1" step=".05" value="1"></div>
                      <div class="wp-cell"><span>Fullscreen</span><button class="wp-btn wp-fs">⛶</button></div>
                    </div>
                  </div>
                  <div class="wp-menu hidden"></div>
                  <div class="wp-subpanel hidden"></div>
                  <div class="wp-infobox hidden"></div>
                  <div class="wp-hint hidden">Trouble playing? Some formats need the free desktop app —
                    <a href="https://couchking.app/downloads" target="_blank">couchking.app/downloads</a></div>
                </div>`;
            player.querySelector('.wp-title').textContent = title || '';
            const v = player.querySelector('video');
            const ui = player.querySelector('.wp-ui');
            const src = (t) => localFile ? localFile : `${SVC}/webplay?u=${u}&t=${Math.floor(t)}`;
            // /webplay stream-copies video, so after a seek it really starts at the
            // KEYFRAME before the asked second — up to several seconds early. Everything
            // here (cues, timeline, reported resume) assumed start == asked second, which
            // is why subs drifted after seeks while phones (exact-seek, original file)
            // stayed accurate. The server now reports the real start; snap offset to it.
            let seekSeq = 0;
            const syncStart = (t) => {
                if (localFile || !state || t <= 0) return;
                const seq = ++seekSeq;
                fetch(`${SVC}/webplay/start?u=${u}&t=${Math.floor(t)}`)
                    .then(r => r.json()).then(d => {
                        if (!state || seq !== seekSeq) return;
                        const real = +d.start;
                        if (isFinite(real) && real >= 0 && Math.abs(real - t) < 30) state.offset = real;
                    }).catch(() => {});
            };
            v.src = src(startSec);
            if (localFile && startSec > 0) v.currentTime = startSec;
            syncStart(startSec);
            // silent mpv fallback (desktop): if the in-window engine can't produce a frame
            // (codec the probe missed, remux hiccup), hand the SAME opts to mpv — the
            // viewer just sees playback start, never an error to deal with
            if (hooks?.fallback) state.fbTimer = setTimeout(() => {
                if (state && !state.started) { closePlayer(false); hooks.fallback(); }
            }, 12000);

            // ---- subtitles: OpenSubtitles v3 feed (same source as the TV app) via our
            // /websub CORS+VTT converter. Rendered by US into a centered, readable-width
            // block (never native full-screen-wide cues); cue times are ABSOLUTE, compared
            // against offset+currentTime, so seeking never needs a re-shift. ----
            const cueEl = player.querySelector('.wp-cue');
            const SIZES = [[.8, 'Small'], [1.0, 'Normal'], [1.3, 'Large'], [1.6, 'Huge']];
            let sizeIx = Math.max(0, SIZES.findIndex(x => Math.abs(x[0] - subScale) < .01));
            const styleCue = () => {
                cueEl.style.fontSize = (3.4 * SIZES[sizeIx][0]).toFixed(2) + 'vh';
                cueEl.style.background = subBg ? 'rgba(0,0,0,.75)' : 'transparent';
                cueEl.style.textShadow = subOutline
                    ? '0 0 5px #000, 0 0 5px #000, 1px 1px 2px #000, -1px -1px 2px #000' : 'none';
                cueEl.style.bottom = ({ 0: '9vh', 1: '16vh', 2: '24vh' })[subPos] || '9vh';
            };
            styleCue();
            // entities show up literally in a hand-rendered cue (&amp;#39; etc) — decode;
            // strip tags again AFTER decoding so encoded markup (&lt;i&gt;) drops too.
            // Two passes: OpenSubtitles files are often DOUBLE-encoded (&amp;#39;)
            const unent1 = (s) => s
                .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n))
                .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
                .replace(/&apos;/g, "'").replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
            const unent = (s) => unent1(unent1(s));
            const parseVtt = (txt) => {
                const cues = [];
                // hours are OPTIONAL (MM:SS.mmm is legal VTT and common) — the old
                // HH:MM:SS-only regex silently dropped every hourless cue
                const re = /(?:(\d{1,3}):)?(\d{1,2}):(\d{2})[.,](\d{3})\s*-->\s*(?:(\d{1,3}):)?(\d{1,2}):(\d{2})[.,](\d{3})/;
                for (const b of txt.replace(/\r/g, '').split(/\n\n+/)) {
                    const lines = b.split('\n');
                    const ti = lines.findIndex(l => l.includes('-->'));
                    if (ti < 0) continue;
                    const m = lines[ti].match(re);
                    if (!m) continue;
                    const s = (+m[1] || 0) * 3600 + +m[2] * 60 + +m[3] + +m[4] / 1000;
                    const e = (+m[5] || 0) * 3600 + +m[6] * 60 + +m[7] + +m[8] / 1000;
                    const text = unent(lines.slice(ti + 1).join('\n').replace(/<[^>]+>/g, ''))
                        .replace(/<[^>]+>/g, '').trim();
                    if (text && e > s) cues.push({ s, e, text });
                }
                return cues;
            };
            let subList = [], curSub = null, subAbort = null, subAuto = true;
            const paintCue = () => {
                if (!state) return;
                const t = cur();
                const c = state.cues.length ? state.cues.find(x => t >= x.s && t <= x.e) : null;
                const want = c ? c.text : '';
                if (cueEl.dataset.t !== want) { cueEl.dataset.t = want; cueEl.textContent = want; }
                cueEl.style.display = want ? 'block' : 'none';
            };
            // Embedded tracks stream PROGRESSIVELY from the current position: subtitle
            // packets are interleaved through the whole video, so a from-the-top pull
            // would take minutes — from-here makes the visible cues arrive immediately
            // while the rest fills in behind. -copyts on the server keeps timestamps
            // absolute, so cues drop straight into the same clock as everything else.
            const loadEmbed = (s, from) => {
                const ac = new AbortController(); subAbort = ac;
                fetch(`${SVC}/webplay/subx?u=${u}&i=${s.embed}&t=${Math.max(0, Math.floor((from || 0) - 8))}`,
                    { signal: ac.signal }).then(async r => {
                    if (!r.ok || !r.body) return;
                    const rd = r.body.getReader(); const dec = new TextDecoder();
                    let buf = '';
                    while (true) {
                        const { done, value } = await rd.read();
                        if (!state || curSub !== s) { ac.abort(); return; }
                        if (value) { buf += dec.decode(value, { stream: true }); state.cues = parseVtt(buf); }
                        if (done) break;
                    }
                    if (state && curSub === s)
                        state.lastCue = state.cues.reduce((m, c) => Math.max(m, c.e), 0);
                }).catch(() => {});
            };
            const selectSub = async (s, auto) => {
                curSub = s; subAuto = !!auto;
                if (subAbort) { subAbort.abort(); subAbort = null; }
                if (state) state.cues = [];
                paintCue();
                player.querySelector('.wp-subs').classList.toggle('on', !!s);
                if (!s) return;
                if (s.embed != null) { loadEmbed(s, cur()); return; }
                try {
                    // downloaded episodes carry their subtitle text INSIDE the meta (offline)
                    const txt = s.vtt || await httpText(`${SVC}/websub?u=${b64u(s.url)}`);
                    if (!state || curSub !== s || !txt) return;
                    state.cues = parseVtt(txt);
                    state.lastCue = state.cues.reduce((m, c) => Math.max(m, c.e), 0);
                } catch {}
            };
            const menu = player.querySelector('.wp-menu');
            // Live-captions side panel: a scrollable track list pinned to the right that
            // STAYS OPEN as tracks are clicked (each applied live via selectSub), so the
            // viewer can watch the on-screen cues and find the one that lines up. It only
            // closes on the 💬 toggle, Back/close, or a controls tap.
            const subPanel = player.querySelector('.wp-subpanel');
            const renderSubPanel = () => {
                subPanel.innerHTML = '';
                const h = document.createElement('div');
                h.className = 'wp-sptitle'; h.textContent = 'Subtitles';
                subPanel.appendChild(h);
                const row = (label, fn, on) => {
                    const b = document.createElement('button');
                    b.textContent = on ? label + '   ✓' : label;
                    b.className = on ? 'on' : '';
                    b.onclick = () => { fn(); renderSubPanel(); };   // re-render moves the ✓, panel stays open
                    subPanel.appendChild(b);
                };
                row('Subtitles off', () => selectSub(null), !curSub);
                for (const s of subList) row(s.lang || '?', () => selectSub(s), curSub === s);
            };
            // CouchKing panel: section title on top, current choice purple with a ✓
            const openMenu = (title, items) => {
                menu.innerHTML = '';
                const h = document.createElement('div');
                h.className = 'wp-mtitle'; h.textContent = title;
                menu.appendChild(h);
                let onBtn = null;
                for (const [label, fn, on] of items) {
                    const b = document.createElement('button');
                    b.textContent = label; b.className = on ? 'on' : '';
                    if (on) { b.textContent += '   ✓'; onBtn = b; }
                    b.onclick = () => { menu.classList.add('hidden'); fn(); };
                    menu.appendChild(b);
                }
                menu.classList.remove('hidden');
                if (onBtn) onBtn.scrollIntoView({ block: 'nearest' });
            };
            if (inlineSubs && inlineSubs.length) {
                // offline: subtitle text was saved WITH the download — no network at all
                subList = inlineSubs.map((x, i) => ({ vtt: x.vtt, lang: x.lang || 'English ' + (i + 1) }));
                if (subLang !== 'off' && subList[0]) selectSub(subList[0]);
            }
            if (sid && !localFile) {
                const type = sid.includes(':') ? 'series' : 'movie';
                // ENGLISH ONLY, BEST FIRST (AJ Sep 14): embedded in-video tracks land on
                // top when the probe answers (exact-release sync), then the addon's
                // RANKED list (release-matched, HI labeled), then feed extras. No other
                // languages in the menu at all.
                const engCount = () => subList.filter(x => x.url).length;
                subList = (subs || []).filter(x => x && x.url)
                    .map((x, i) => ({ url: x.url, lang: x.name || 'English ' + (i + 1) }));
                if (subLang !== 'off' && subList[0]) selectSub(subList[0], true);
                httpText(`https://opensubtitles-v3.strem.io/subtitles/${type}/${encodeURIComponent(sid)}.json`)
                    .then(t => JSON.parse(t || '{}')).then(d => {
                        const haveUrl = new Set(subList.map(x => x.url));
                        for (const s of (d.subtitles || [])) {
                            if (!s.url || haveUrl.has(s.url)) continue;
                            if (!/^en/i.test(s.lang || '')) continue;
                            if (engCount() >= 20) break;
                            subList.push({ url: s.url, lang: 'English ' + (engCount() + 1) });
                            haveUrl.add(s.url);
                        }
                        if (subLang === 'off' || curSub) return;
                        const pref = subList.find(x => x.url);
                        if (pref) selectSub(pref, true);
                    }).catch(() => {});
            }
            // TOGGLE the live side panel (not the auto-closing openMenu) so tracks can be
            // sampled one after another; empty subList still shows just "Subtitles off"
            player.querySelector('.wp-subs').onclick = () => {
                if (subPanel.classList.contains('hidden')) { renderSubPanel(); subPanel.classList.remove('hidden'); }
                else subPanel.classList.add('hidden');
            };
            // reset timers are CANCELLED on re-click — stacked timeouts made the label
            // flip back mid-cycling and lag behind fast presses (AJ Sep 14)
            let sizeT = null, fitT = null;
            player.querySelector('.wp-subsize').onclick = () => {
                sizeIx = (sizeIx + 1) % SIZES.length; styleCue();
                const c = player.querySelector('.wp-subsize'); c.textContent = SIZES[sizeIx][1];
                clearTimeout(sizeT); sizeT = setTimeout(() => { c.textContent = 'Aa'; }, 1200);
            };
            const FITS = [['contain', 'Fit'], ['cover', 'Fill'], ['fill', 'Stretch']];
            let fitIx = 0;
            player.querySelector('.wp-scale').onclick = () => {
                fitIx = (fitIx + 1) % FITS.length;
                v.style.objectFit = FITS[fitIx][0];
                const c = player.querySelector('.wp-scale'); c.textContent = FITS[fitIx][1];
                clearTimeout(fitT); fitT = setTimeout(() => { c.textContent = '⤢'; }, 1200);
            };
            // Speed: real menu, same options + look as the TV/player apps
            const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
            player.querySelector('.wp-speed').onclick = () => menu.classList.contains('hidden')
                ? openMenu('Speed', SPEEDS.map(sp => [sp === 1 ? 'Normal' : sp + '×', () => {
                    state.speed = sp; v.playbackRate = sp;
                    player.querySelector('.wp-speed').textContent = sp + '×';
                }, state.speed === sp]))
                : menu.classList.add('hidden');
            // Info: what the stream actually is (web's version of the TV player's stats)
            const infoBox = player.querySelector('.wp-infobox');
            player.querySelector('.wp-info').onclick = () => {
                if (!infoBox.classList.contains('hidden')) { infoBox.classList.add('hidden'); return; }
                infoBox.textContent = [
                    v.videoWidth ? `${v.videoWidth}×${v.videoHeight}` : 'resolution unknown',
                    state.dur ? `length ${fmt(state.dur)}` : '',
                    `speed ${state.speed}×`,
                    `position ${fmt(cur())}`,
                ].filter(Boolean).join('\n');
                infoBox.classList.remove('hidden');
            };

            // real duration for the timeline (fMP4 stream itself reports none); the desktop
            // router already probed (probeDur rides in), a downloaded file reports its own
            if (!state.dur && !localFile)
                httpText(`${SVC}/webplay/probe?u=${u}`).then(t => {
                    const d = JSON.parse(t || '{}');
                    if (state) { state.dur = d.duration || 0; paint(); }
                    // embedded ENGLISH tracks (full + SDH; forced skipped) go on TOP of
                    // the subtitle menu — cut for this exact release, best sync we have.
                    // An automatic pick upgrades to the full embedded track; a choice
                    // the viewer made by hand is never overridden.
                    if (state && Array.isArray(d.subs) && !localFile) {
                        const isEng = x => /^en/i.test(x.lang || '') || /english/i.test(x.title || '');
                        const isSdh = x => !!x.hi || /sdh|hearing|\bcc\b/i.test(x.title || '');
                        const isForced = x => !!x.forced || /forced/i.test(x.title || '');
                        const emb = d.subs.filter(x => isEng(x) && !isForced(x))
                            .sort((a, b) => isSdh(a) - isSdh(b))
                            .map(x => ({ embed: x.i, lang: 'English — in video' + (isSdh(x) ? ' (SDH)' : '') }));
                        const seen = {};
                        for (const e of emb) {
                            if (seen[e.lang]) e.lang += ' ' + (++seen[e.lang]);
                            else seen[e.lang] = 1;
                        }
                        if (emb.length) {
                            subList.unshift(...emb);
                            if (subLang !== 'off' && (subAuto || !curSub)) selectSub(emb[0], true);
                        }
                    }
                }).catch(() => {});

            const cur = () => state ? state.offset + (v.currentTime || 0) : 0;
            const paint = () => {
                if (!state) return;
                player.querySelector('.wp-cur').textContent = fmt(cur());
                player.querySelector('.wp-dur').textContent = state.dur ? fmt(state.dur) : '–:––';
                const pct = state.dur ? Math.min(100, 100 * cur() / state.dur) : 0;
                player.querySelector('.wp-fill').style.width = pct + '%';
                player.querySelector('.wp-dot').style.left = pct + '%';
            };
            const seekTo = (t) => {
                if (!state) return;
                t = Math.max(0, state.dur ? Math.min(t, state.dur - 5) : t);
                state.offset = t; v.src = src(t); syncStart(t);
                // an embedded track only streamed from the old position — refetch from here
                if (curSub && curSub.embed != null) {
                    if (subAbort) subAbort.abort();
                    state.cues = [];
                    loadEmbed(curSub, t);
                }
                v.playbackRate = state.speed;
                v.play().catch(() => {});
                paintCue();
            };

            // ---- Skip intro + UP NEXT card + clock ("Ends h:mm"), 1-second ticker ----
            const skipBtn = player.querySelector('.wp-skip');
            const nextCard = player.querySelector('.wp-next');
            player.querySelector('.wpn-title').textContent = nextLabel || '';
            skipBtn.onclick = () => {
                if (state.skipMode === 'after' && state.pendingAfter > 0) {
                    skipBtn.classList.add('hidden'); seekTo(state.pendingAfter / 1000);
                } else { state.introHandled = true; skipBtn.classList.add('hidden'); seekTo(introToMs / 1000); }
            };
            const fireNext = () => {
                if (!state || !state.dur) { closePlayer(true, { next: true }); return; }
                const remMs = Math.max(0, Math.round((state.dur - cur()) * 1000));
                closePlayer(true, { next: true, credits: remMs });
            };
            if (hasNext) {
                player.querySelector('.wp-nextbtn').onclick = fireNext;
                player.querySelector('.wpn-play').onclick = fireNext;
                player.querySelector('.wpn-dismiss').onclick = () => nextCard.classList.add('hidden');
            }
            // PiP + OS media controls (AJ Sep 28): 10s-back / 10s-forward / Next-episode buttons in
            // the Picture-in-Picture window + OS media UI via the Media Session API.
            if ('mediaSession' in navigator) {
                try {
                    navigator.mediaSession.metadata = new MediaMetadata({ title: title || 'CouchKing' });
                    navigator.mediaSession.setActionHandler('seekbackward', () => seekTo(cur() - state.step));
                    navigator.mediaSession.setActionHandler('seekforward', () => seekTo(cur() + state.step));
                    navigator.mediaSession.setActionHandler('nexttrack', hasNext ? fireNext : null);
                } catch (e) {}
            }
            state.tick = setInterval(() => {
                if (!state) return;
                player.querySelector('.wp-clock').textContent = clock(new Date());
                if (state.dur > 0) {
                    const remaining = (state.dur - cur()) / (state.speed || 1);
                    player.querySelector('.wp-ends').textContent =
                        'Ends ' + clock(new Date(Date.now() + remaining * 1000));
                    // credits lead, best signal first (same rule as the TV player): the
                    // episode's own last subtitle cue → family's learned credits clicks → 90s
                    const subsLead = state.lastCue > 0 ? state.dur - state.lastCue - 2 : -1;
                    const lead = (subsLead >= 15 && subsLead <= 300) ? subsLead
                        : (creditsMs > 0 ? Math.min(240, Math.max(20, (creditsMs + 5000) / 1000)) : 90);
                    const remReal = state.dur - cur();
                    if (hasNext && !state.nextShown && remReal > 0 && remReal <= lead) {
                        state.nextShown = true;
                        nextCard.classList.remove('hidden');
                    }
                    // learned skip-intro window (from /player/resume): button lives inside it
                    if (!state.introHandled && introFromMs >= 0 && introToMs > introFromMs) {
                        const p = cur() * 1000;
                        const inWin = p >= introFromMs && p <= introToMs - 2000;
                        if (inWin) { state.skipMode = 'intro'; skipBtn.textContent = 'Skip intro ⏭'; }
                        skipBtn.classList.toggle('hidden', !inWin);
                        if (!inWin && p >= introToMs - 2000) state.introHandled = true;
                    }
                    // after-credits (AJ Sep 16): jump-to-scene button per stinger, in sequence
                    if (afterCredits.length) {
                        const p = cur() * 1000;
                        const nextAc = afterCredits.find(x => x.from > p + 1500);
                        const prevEnd = Math.max(-1, ...afterCredits.filter(x => x.to <= p).map(x => x.to));
                        const creditsPt = (state.dur * 1000) - (creditsMs || 90000);
                        const floor = nextAc ? Math.max(creditsPt, nextAc.from - 90000, prevEnd) : Infinity;
                        const inAfter = nextAc && p >= floor && p < nextAc.from - 1500 && !(introFromMs >= 0 && p <= introToMs);
                        if (inAfter) {
                            state.skipMode = 'after'; state.pendingAfter = nextAc.from;
                            skipBtn.textContent = afterCredits.length > 1 ? `After credits ▶ (${afterCredits.indexOf(nextAc) + 1}/${afterCredits.length})` : 'After credits ▶';
                            skipBtn.classList.remove('hidden');
                        } else if (state.skipMode === 'after') { skipBtn.classList.add('hidden'); state.skipMode = 'intro'; }
                    }
                }
                paintCue();
            }, 1000);

            v.addEventListener('loadedmetadata', () => {
                if (state && localFile && v.duration > 0 && isFinite(v.duration)) { state.dur = v.duration; paint(); }
            });
            v.addEventListener('timeupdate', () => {
                if (state && !state.started && v.currentTime > 0.3) { state.started = true; clearTimeout(state.fbTimer); }
                paint(); paintCue(); posCb && posCb({ pos: cur(), dur: state?.dur || 0 });
            });
            v.addEventListener('ended', () => {
                // finished for real: autoplay-next rides the exit (app decides via watched
                // rules); flag it so a finished episode advances even at odd durations
                if (hasNext && autonext) fireNext(); else closePlayer(true);
            });
            v.addEventListener('error', () => {
                // desktop: never show the viewer an error for a format problem — mpv takes
                // over silently with the exact same stream + resume point
                if (hooks?.fallback && state && !state.started) { closePlayer(false); hooks.fallback(); return; }
                player?.querySelector('.wp-hint')?.classList.remove('hidden');
            });
            v.addEventListener('play', () => { player.querySelector('.wp-pp').textContent = '⏸'; });
            v.addEventListener('pause', () => { player.querySelector('.wp-pp').textContent = '▶'; });

            player.querySelector('.wp-back').onclick = () => closePlayer(true);
            player.querySelector('.wp-pp').onclick = () => v.paused ? v.play() : v.pause();
            player.querySelector('.wp-rew').onclick = () => seekTo(cur() - state.step);
            player.querySelector('.wp-fwd').onclick = () => seekTo(cur() + state.step);
            player.querySelector('.wp-vol').oninput = (e) => { v.volume = +e.target.value; };
            player.querySelector('.wp-fs').onclick = () =>
                document.fullscreenElement ? document.exitFullscreen() : player.requestFullscreen().catch(() => {});
            player.querySelector('.wp-bar').onclick = (e) => {
                if (!state?.dur) return;
                const r = e.currentTarget.getBoundingClientRect();
                seekTo(state.dur * (e.clientX - r.left) / r.width);
            };
            v.onclick = () => {
                // tapping the video dismisses any open overlay so it isn't left stranded
                menu.classList.add('hidden'); subPanel.classList.add('hidden');
                v.paused ? v.play() : v.pause();
            };

            // controls fade like the TV player: show on mouse move, hide after 3s idle
            let hideT = null;
            const wake = () => {
                ui.classList.remove('idle');
                clearTimeout(hideT);
                hideT = setTimeout(() => !v.paused && ui.classList.add('idle'), 3000);
            };
            player.addEventListener('mousemove', wake); wake();
            document.addEventListener('keydown', function keys(e) {
                if (!player) { document.removeEventListener('keydown', keys); return; }
                if (e.key === ' ') { e.preventDefault(); v.paused ? v.play() : v.pause(); }
                if (e.key === 'ArrowLeft') seekTo(cur() - state.step);
                if (e.key === 'ArrowRight') seekTo(cur() + state.step);
                if (e.key === 'Escape' && !document.fullscreenElement) closePlayer(true);
            });

            document.body.appendChild(player);
            document.body.style.overflow = 'hidden';
            return { ok: true, engine: 'web' };
    }

    if (!DESK) window.ck = {
        platform: 'web',
        service,
        version: async () => 'web',
        openExternal: (url) => window.open(url, '_blank'),
        http: async ({ url, method = 'GET', body = null, timeoutMs = 15000 }) => {
            try {
                const ctl = new AbortController();
                const t = setTimeout(() => ctl.abort(), timeoutMs);
                const r = await fetch(url, {
                    method, signal: ctl.signal,
                    headers: body ? { 'Content-Type': 'application/json' } : undefined,
                    body: body ? JSON.stringify(body) : undefined
                });
                clearTimeout(t);
                return { ok: r.ok, status: r.status, text: await r.text() };
            } catch (e) { return { ok: false, status: 0, text: String(e).slice(0, 200) }; }
        },
        play: (o) => webPlay(o),
        stopPlay: async () => { closePlayer(true); return { ok: true }; },
        onMpvPos: (cb) => { posCb = cb; },
        onMpvExit: (cb) => { exitCb = cb; },
    };

    // ---- unified engine surface (0.9.13): app.js talks ONLY to these four ----
    const announceMpv = () => document.dispatchEvent(new CustomEvent('ck-engine', { detail: 'mpv' }));
    // codecs Chromium decodes; anything else (hevc/vc1/mpeg2...) goes straight to mpv.
    // Unknown/blank codec = try the window first — the 12s no-frame fallback still saves it.
    const CHROME_OK = ['', 'h264', 'avc1', 'vp8', 'vp9', 'av1', 'mpeg4', 'mjpeg'];
    // LIVE TV (Sep 17): endless HLS channels play natively — Safari has HLS built in,
    // everywhere else hls.js attaches to the same <video>. No /webplay remux (that path is
    // for files), no seeking, auto-failover to the channel's backup urls on fatal error.
    async function livePlay({ url, title, backups = [], guide = [], onTune = null, logo = '', now = '',
                              chid = '', fav = false, onFav = null, isFav = null, tsUrl = '',
                              onClose = null }) {
        closePlayer(false);
        engine = 'web';
        state = { offset: 0, dur: 0 };
        player = document.createElement('div');
        player.id = 'web-player';
        player.innerHTML = `
            <video autoplay playsinline></video>
            <div class="wp-ui">
              <div class="wp-top">
                <button class="wp-btn wp-back">‹ Back</button><span class="wp-title"></span>
                <span class="wp-right"><span class="wp-live">🔴 LIVE</span><span class="wp-clock"></span></span>
              </div>
              <div class="wp-bottom">
                <div class="wp-controls">
                  <div class="wp-cell"><span>Play / Pause</span><button class="wp-btn wp-pp">⏸</button></div>
                  <div class="wp-cell"><span>Favorite</span><button class="wp-btn wp-fav">☆</button></div>
                  <div class="wp-cell"><span>Guide</span><button class="wp-btn wp-guide">📋</button></div>
                  <div class="wp-cell"><span>Volume</span><input class="wp-vol" type="range" min="0" max="1" step=".05" value="1"></div>
                  <div class="wp-cell"><span>Fullscreen</span><button class="wp-btn wp-fs">⛶</button></div>
                </div>
              </div>
              <div class="lv-guidepanel hidden"></div>
            </div>`;
        player.querySelector('.wp-title').textContent = title || '';
        document.body.appendChild(player);
        document.body.style.overflow = 'hidden';
        const v = player.querySelector('video');
        // TUNING SCREEN (AJ Sep 17 "2-3 seconds to load anything"): instant logo + channel
        // + what's on, up until real frames flow; a 12s watchdog walks the backup sources
        // so a dead first url self-heals instead of spinning forever.
        if (!document.getElementById('ck-spin-kf')) {
            const st = document.createElement('style'); st.id = 'ck-spin-kf';
            st.textContent = '@keyframes ckspin{to{transform:rotate(360deg)}}';
            document.head.appendChild(st);
        }
        const ov = document.createElement('div');
        ov.style.cssText = 'position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px;background:#0c0c10;z-index:6';
        const ovImg = document.createElement('img');
        ovImg.style.cssText = 'max-height:90px;max-width:220px'; ovImg.onerror = () => ovImg.remove();
        if (logo) ovImg.src = logo; else ovImg.remove();
        const ovSpin = document.createElement('div');
        ovSpin.style.cssText = 'width:34px;height:34px;border:3px solid #333;border-top-color:#e64545;border-radius:50%;animation:ckspin 1s linear infinite';
        const ovName = document.createElement('div'); ovName.style.cssText = 'font-size:21px;color:#fff;font-weight:600';
        const ovNow = document.createElement('div'); ovNow.style.cssText = 'font-size:15px;color:#9a9aa4';
        ov.append(ovImg, ovSpin, ovName, ovNow);
        // the overlay used to cover the Back button = trapped watching "Tuning…" while
        // the watchdog walked dead sources (AJ Sep 17) — escape hatch ON the overlay
        const ovBack = document.createElement('button');
        ovBack.textContent = '‹ Back';
        ovBack.style.cssText = 'position:absolute;top:18px;left:18px;background:#1c1c22;border:1px solid #3a3a44;color:#fff;border-radius:10px;padding:8px 16px;font-size:15px;cursor:pointer';
        ovBack.onclick = () => bail();
        ov.appendChild(ovBack);
        player.appendChild(ov);
        let tuned = false, dogT = 0;
        const showOv = (nm, nw) => { tuned = false; ovName.textContent = 'Tuning ' + (nm || 'channel') + '…';
            ovNow.textContent = nw ? 'Now: ' + nw : ''; ovSpin.style.display = ''; ov.style.display = 'flex'; };
        showOv(title, now);
        v.addEventListener('playing', () => { tuned = true; clearTimeout(dogT); clearTimeout(stallT); ov.style.display = 'none'; });
        // MID-PLAY stall heal (AJ Sep 17 Buffy "freezes after 7 seconds"): panel sessions
        // die under the player — stuck >12s → re-attach = fresh upstream session
        let stallT = 0;
        v.addEventListener('waiting', () => {
            if (!tuned || !state) return;
            clearTimeout(stallT);
            stallT = setTimeout(() => {
                if (!state) return;
                showOv(player.querySelector('.wp-title').textContent, '');
                // a stall = the HLS session is sick; a fresh session just dies again.
                // Straight to the server-side ffmpeg hub feed (continuous, restart-proof).
                if (tsCur) playTs(tsCur); else attach(sources[si] || sources[0]);
                armDog();
            }, 12000);
        });
        const sources = [url, ...backups];
        let si = 0;
        const attach = async (u) => {
            if (!u) return;
            try { state?.mp?.destroy(); } catch {} if (state) state.mp = null;
            try { state?.hls?.destroy(); } catch {}
            if (v.canPlayType('application/vnd.apple.mpegurl')) { v.src = u; return; }
            if (!window.Hls) await new Promise((res, rej) => {
                const sc = document.createElement('script');
                sc.src = 'hls.min.js';   // self-hosted (CDN/CSP can't break playback)
                sc.onload = res;
                sc.onerror = () => { const c = document.createElement('script');
                    c.src = 'https://cdn.jsdelivr.net/npm/hls.js@1.5.20/dist/hls.min.js';
                    c.onload = res; c.onerror = rej; document.head.appendChild(c); };
                document.head.appendChild(sc);
            });
            // long back buffer = pause keeps your place for a few minutes of live TV
            const h = new window.Hls({ maxBufferLength: 30, backBufferLength: 300 });
            h.on(window.Hls.Events.ERROR, (_, d) => {
                if (d.fatal && state) {
                    if (++si < sources.length) attach(sources[si]);     // next backup
                    else { try { h.destroy(); } catch {} }
                }
            });
            h.loadSource(u); h.attachMedia(v);
            if (state) state.hls = h;
        };
        // STEADY-FEED engine (AJ Sep 17 "skipped forward then it froze"): panel HLS runs
        // on server-side sessions that reset mid-play; the continuous .ts via mpegts.js
        // has no sessions to break. HLS stays as the fallback chain.
        let tsCur = tsUrl;
        const stopMp = () => { try { state?.mp?.destroy(); } catch {} if (state) state.mp = null; };
        const playTs = async (tsu) => {
            if (!window.mpegts) await new Promise((res2) => {
                const sc = document.createElement('script'); sc.src = 'mpegts.min.js';
                sc.onload = res2; sc.onerror = res2; document.head.appendChild(sc);
            });
            if (!window.mpegts?.isSupported?.()) return false;
            stopMp(); try { state?.hls?.destroy(); } catch {}
            const mp = window.mpegts.createPlayer({ type: 'mpegts', isLive: true, url: tsu });
            mp.attachMediaElement(v); mp.load(); v.play().catch(() => {});
            mp.on(window.mpegts.Events.ERROR, () => {
                stopMp();
                if (sources.length && sources[si || 0]) { attach(sources[si] || sources[0]); armDog(); }
            });
            if (state) state.mp = mp;
            return true;
        };
        const armDog = () => { clearTimeout(dogT); dogT = setTimeout(() => {
            if (tuned || !state) return;
            if (++si < sources.length) { showOv(player.querySelector('.wp-title').textContent, ''); stopMp(); attach(sources[si]); armDog(); }
            else { ovSpin.style.display = 'none'; ovName.textContent = 'This channel is down right now'; ovNow.textContent = 'Try another one — this one gets benched so it stops showing up';
                   setTimeout(() => { if (!tuned) bail(); }, 3000); }
        }, 12000); };
        // HLS FIRST (Sep 17 rollback: preferring the panel's direct .ts froze EVERY
        // channel — their raw feed is the broken part). .ts hub = fallback only.
        if (sources[0]) await attach(sources[0]); else if (tsCur) await playTs(tsCur);
        armDog();
        const bail = () => { clearTimeout(dogT); clearTimeout(stallT); stopMp(); try { state?.hls?.destroy(); } catch {} engine = null; closePlayer(false);
            // the guide under the player froze at tune time — let the page re-align its
            // red now-line (AJ Sep 24: "doesn't update unless you update the page")
            try { onClose && onClose(); } catch {} };
        player.querySelector('.wp-back').onclick = bail;
        // GUIDE while watching (AJ Sep 17): side panel of the current category's channels
        // with what's on now — click = tune straight over, playback never closes
        const gp = player.querySelector('.lv-guidepanel');
        const gbtn = player.querySelector('.wp-guide');
        if (guide.length && onTune) {
            gbtn.onclick = () => {
                if (!gp.classList.contains('hidden')) { gp.classList.add('hidden'); return; }
                gp.innerHTML = '';
                for (const ch of guide) {
                    if (ch.hdr) {   // section divider (★ Favorites / Continue watching / Sports…)
                        const h = document.createElement('div');
                        h.textContent = ch.hdr;
                        h.style.cssText = 'opacity:.65;font-weight:700;font-size:12px;padding:10px 4px 2px;pointer-events:none;text-transform:uppercase;letter-spacing:.5px';
                        gp.appendChild(h); continue;
                    }
                    const r = document.createElement('div'); r.className = 'lvg-row';
                    r.innerHTML = `<span class="lvg-name"></span><span class="lvg-now"></span>`;
                    r.querySelector('.lvg-name').textContent = ch.name;
                    r.querySelector('.lvg-now').textContent = ch.now || '';
                    r.onclick = async () => {
                        r.classList.add('busy');
                        try {
                            const r2 = await onTune(ch.id);
                            const hls = r2?.hls || (typeof r2 === 'string' && r2 ? [r2] : []);
                            const ts2 = r2?.ts || '';
                            if (!hls.length && !ts2) return;
                            si = 0; sources.length = 0; hls.forEach(u2 => sources.push(u2));
                            tsCur = ts2;
                            player.querySelector('.wp-title').textContent = ch.name;
                            curCh = ch.id; curFav = !!(isFav && isFav(ch.id)); paintFav();
                            showOv(ch.name, ch.now); armDog();
                            if (sources[0]) await attach(sources[0]); else if (ts2) await playTs(ts2);
                        } finally { r.classList.remove('busy'); }
                    };
                    gp.appendChild(r);
                }
                gp.classList.remove('hidden');
            };
        } else gbtn.parentElement.style.display = 'none';
        // ★ the channel you're WATCHING (AJ Sep 17) — state follows in-player channel hops
        const favB = player.querySelector('.wp-fav');
        let curCh = chid, curFav = !!fav;
        const paintFav = () => { favB.textContent = curFav ? '★' : '☆'; favB.style.color = curFav ? '#f5c542' : ''; };
        if (onFav && chid) {
            paintFav();
            favB.onclick = () => { curFav = !curFav; paintFav(); onFav(curCh, curFav); };
        } else favB.parentElement.style.display = 'none';
        const pp = player.querySelector('.wp-pp');
        pp.onclick = () => { if (v.paused) { v.play(); pp.textContent = '⏸'; } else { v.pause(); pp.textContent = '▶'; } };
        player.querySelector('.wp-vol').oninput = (e) => v.volume = +e.target.value;
        player.querySelector('.wp-fs').onclick = () =>
            document.fullscreenElement ? document.exitFullscreen() : player.requestFullscreen().catch(() => {});
        const ckEl = player.querySelector('.wp-clock');
        ckEl.textContent = clock(new Date());
        state.tick = setInterval(() => { if (player) ckEl.textContent = clock(new Date()); }, 30000);
        // controls fade like the VOD player (AJ Sep 24 mobile: "you can't get rid of the
        // player UI"): 3s idle hides them, mouse move wakes them, tapping the video
        // toggles them. Stay up while paused or while the guide panel is open.
        const ui = player.querySelector('.wp-ui');
        let hideT = null;
        const wake = () => {
            ui.classList.remove('idle');
            clearTimeout(hideT);
            hideT = setTimeout(() => {
                if (!v.paused && gp.classList.contains('hidden')) ui.classList.add('idle');
            }, 3000);
        };
        player.addEventListener('mousemove', wake); wake();
        // a tap fires compat mousemove (= wake) BEFORE click, so snapshot the state at
        // pointerdown — else tap-to-show would instantly re-hide what it just showed
        let wasIdle = false;
        player.addEventListener('pointerdown', () => { wasIdle = ui.classList.contains('idle'); });
        v.onclick = () => { if (wasIdle) wake(); else { clearTimeout(hideT); ui.classList.add('idle'); } };
        document.addEventListener('keydown', function esc(e) {
            if (!player) { document.removeEventListener('keydown', esc); return; }
            if (e.key === 'Escape') { bail(); document.removeEventListener('keydown', esc); }
        });
    }

    window.ckPlay = async (opts) => {
        if (opts?.live) return livePlay(opts);
        if (!DESK) return webPlay(opts);
        const toMpv = (o) => { engine = 'mpv'; announceMpv(); return window.ck.play(o); };
        if (opts.localFile)
            return webPlay(opts, { fallback: () => toMpv({ ...opts, url: opts.localFile }) });
        let p = null;
        try {
            const svc = await window.ck.service();
            const r = await window.ck.http({ url: `${svc}/webplay/probe?u=${b64u(opts.url)}`, timeoutMs: 14000 });
            p = r?.ok ? JSON.parse(r.text) : null;
        } catch {}
        if (p?.vcodec && !CHROME_OK.includes(String(p.vcodec).toLowerCase())) return toMpv(opts);
        if (p?.duration > 0) opts.probeDur = p.duration;
        return webPlay(opts, { fallback: () => toMpv(opts) });
    };
    window.ckStop = () => { if (DESK && engine === 'mpv') return window.ck.stopPlay(); closePlayer(true); };
    window.ckOnPos = (cb) => { posCb = cb; if (DESK) window.ck.onMpvPos((d) => { if (engine === 'mpv') cb(d); }); };
    window.ckOnExit = (cb) => { exitCb = cb; if (DESK) window.ck.onMpvExit((d) => { if (engine === 'mpv') { engine = null; cb(d); } }); };
})();
