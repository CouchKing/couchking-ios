// CouchKing renderer — one codebase for the desktop app (Electron + mpv) AND the
// web version at couchking.app/app (ck-web.js shim + HTML5 player). Same account
// endpoints as the TV app; everything syncs through /tvapp/state + /player/progress.
const TMDB = 'b05e998c589bf1393c1059bd1d4c5895';
const CINE = 'https://v3-cinemeta.strem.io';
let SERVICE = 'https://couchking.app';
let S = { email: '', token: '', user: '', useg: '', subKey: '', addons: [], state: {}, guest: false, access: null };
const APPVER = () => (ck.platform === 'web' ? 'web' : 'desktop') + '-0.9';
// the app is a NEUTRAL TRACKER SHELL until an account with an assigned service signs in
// (guests and key-less accounts browse + track + see where-to-watch; no stream buttons)
const hasService = () => !S.guest && S.addons.length > 0;

const $ = (id) => document.getElementById(id);
const j = async (url, opts = {}) => {
    const r = await ck.http({ url, ...opts });
    try { return JSON.parse(r.text); } catch { return null; }
};

// external links (terms/privacy/downloads) — browser opens a tab, desktop the system browser
document.addEventListener('click', (e) => {
    const a = e.target.closest('a[data-ext]');
    if (a) { e.preventDefault(); ck.openExternal(a.dataset.ext); }
});

function toast(msg) {
    document.getElementById('toast')?.remove();
    const t = document.createElement('div'); t.id = 'toast'; t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(() => t.remove(), 2200);
}

// CouchKing confirm panel — replaces the OS confirm() popups (downloads, deletes) with
// the app's own card: dark rounded panel, purple filled action (red for deletes).
function ckAsk(title, line, positive = 'OK', danger = false) {
    return new Promise((resolve) => {
        const wrap = document.createElement('div'); wrap.className = 'ck-ask';
        const card = document.createElement('div'); card.className = 'ck-ask-card';
        const h = document.createElement('h3'); h.textContent = title; card.appendChild(h);
        if (line) { const p = document.createElement('p'); p.textContent = line; card.appendChild(p); }
        const btns = document.createElement('div'); btns.className = 'ck-ask-btns';
        const done = (val) => { wrap.remove(); document.removeEventListener('keydown', esc, true); resolve(val); };
        const esc = (e) => { if (e.key === 'Escape') { e.stopPropagation(); done(false); } };
        const no = document.createElement('button'); no.className = 'ghost'; no.textContent = 'Cancel';
        no.onclick = () => done(false);
        const ok = document.createElement('button'); ok.className = 'primary' + (danger ? ' danger' : '');
        ok.textContent = positive; ok.onclick = () => done(true);
        btns.appendChild(no); btns.appendChild(ok); card.appendChild(btns);
        wrap.appendChild(card); wrap.onclick = (e) => { if (e.target === wrap) done(false); };
        document.addEventListener('keydown', esc, true);
        document.body.appendChild(wrap); ok.focus();
    });
}

// ---------- auth ----------
async function auth(mode) {
    $('auth-error').textContent = '';
    const email = $('auth-email').value.trim(), password = $('auth-pass').value;
    const r = await j(`${SERVICE}/tvapp/auth`, { method: 'POST', body: { email, password, mode, appVer: APPVER() } });
    if (!r?.ok) { $('auth-error').textContent = r?.error || 'Couldn’t sign in'; return; }
    S.email = email.toLowerCase(); S.token = r.token; S.guest = false;
    localStorage.setItem('ck', JSON.stringify({ email: S.email, token: S.token }));
    await bootstrap();
}
function guest() {
    S.guest = true; S.email = ''; S.token = ''; S.state = {}; S.addons = []; S.user = 'Guest'; S.useg = '';
    $('prof-name').textContent = 'Guest'; $('prof-avatar').textContent = '👤';
    show('main'); home();
}
// profile avatar background color — the chosen color, else one derived from the id (same
// palette + hash as the TV app so a profile looks identical on every device). (AJ Sep 15)
function profColor(p) {
    if (p && p.color) return p.color;
    const id = (p && p.id) || '';
    let h = 0; for (let i = 0; i < id.length; i++) h = (Math.imul(31, h) + id.charCodeAt(i)) | 0;
    const pal = CK_CAT.COLOR_CHOICES;
    return pal[Math.abs(h) % pal.length];
}
function paintAvatar(el, p) {
    if (!el) return;
    el.textContent = (p && p.avatar) || (p && p.name ? p.name[0].toUpperCase() : '👤');
    el.style.background = p ? profColor(p) : '#241F3D';
    el.style.borderRadius = '50%';
    el.style.display = 'inline-flex'; el.style.alignItems = 'center'; el.style.justifyContent = 'center';
}
// guest hits a wall on anything account-backed → friendly sign-in gate
function gate(msg) {
    document.getElementById('gate')?.remove();
    const ov = document.createElement('div'); ov.id = 'gate';
    ov.innerHTML = `<div class="gate-card"><h3>Sign in to continue</h3>
        <p class="muted">${msg}</p>
        <button class="primary" id="gate-go">Sign in / Create account</button>
        <button class="ghost" id="gate-no">Not now</button></div>`;
    ov.querySelector('#gate-go').onclick = () => { ov.remove(); localStorage.removeItem('ck'); location.reload(); };
    ov.querySelector('#gate-no').onclick = () => ov.remove();
    ov.onclick = (e) => { if (e.target === ov) ov.remove(); };
    document.body.appendChild(ov);
}

async function bootstrap() {
    // assigned addon auto-install (same as the store app) + full account state
    const acc = await j(`${SERVICE}/tvapp/access?e=${encodeURIComponent(S.email)}&t=${encodeURIComponent(S.token)}`);
    S.access = acc && acc.allowed !== undefined ? { expires: acc.expires || '', daysLeft: acc.daysLeft } : null;
    S.state = await j(`${SERVICE}/tvapp/state?e=${encodeURIComponent(S.email)}&t=${encodeURIComponent(S.token)}`) || {};
    S.addons = S.state.addons || [];
    if (!S.addons.length && acc?.allowed && acc.addon) S.addons = [{ url: acc.addon, name: 'CouchKing' }];
    // subKey rides inside the addon url ({"subKey":"CKG-…"} url-encoded) — scan EVERY
    // path segment of EVERY addon: stream.couchking.app urls have an /a/ prefix before
    // the config, so segment[1] was the literal "a" → empty key → /live//guide.json 404
    // = "guide never loads" (AJ Sep 17, kruz account)
    S.subKey = '';
    for (const a of (S.addons || [])) {
        if (S.subKey) break;
        try {
            for (const seg of new URL(a.url).pathname.split('/')) {
                try { const k = JSON.parse(decodeURIComponent(seg)).subKey; if (k) { S.subKey = k; break; } } catch {}
            }
        } catch {}
    }
    const savedPid = localStorage.getItem('ck-pid');
    const profs = S.state.profiles || [];
    S.pid = profs.find(p => p.id === savedPid)?.id || profs[0]?.id || '';
    const prof = profs.find(p => p.id === S.pid);
    S.user = prof?.name || S.email.split('@')[0];
    // the SAME identity segment the Android apps send: "Name #<last-4-of-profile-id>" so
    // two same-named profiles never blend, and web + Firestick share ONE ckpos resume key
    S.useg = prof ? `${prof.name} #${String(prof.id).slice(-4)}` : S.user;
    $('prof-name').textContent = S.user;
    paintAvatar($('prof-avatar'), prof);
    applyAccountPrefs();
    lastSyncSig = syncSig();
    show('main'); home();
    livetvDetect();
}

// LIVE TV exists only when the installed addon's manifest carries a type:'tv' catalog —
// the shell itself is neutral (AJ Sep 17: "only pops up if you add my addon")
async function livetvDetect() {
    let failed = false;
    try {
        S.liveCat = null;
        for (const a of (S.addons || [])) {
            const m = await j(a.url + '/manifest.json');
            if (!m) { failed = true; continue; }   // addon restarting ≠ no Live TV on plan
            const c = (m?.catalogs || []).find(x => x.type === 'tv');
            if (c) { S.liveCat = { base: a.url, cat: c }; break; }
        }
    } catch { S.liveCat = null; failed = true; }
    $('rail-livetv')?.classList.toggle('hidden', !S.liveCat);
    // a failed manifest fetch mid-boot must not hide the tab until the next full page
    // reload (AJ hit exactly this during an addon restart) — quietly retry
    if (failed && !S.liveCat) setTimeout(livetvDetect, 30e3);
}

let lvGenre = 'Guide';
const _lvTune = async (id) => {   // id = full meta id (cklive:espn) → [{url, ts}]
    const s = await j(S.liveCat.base + `/stream/tv/${encodeURIComponent(id)}.json`);
    return (s?.streams || []).map(x => ({ url: x.url, ts: x.ckTs === 1 })).filter(x => x.url);
};
// Top BANNER (AJ Sep 18: "banner across all things when the device limit is reached") — red
// bar pinned to the top of the window, auto-clears after 8s, click to dismiss. Same treatment
// the apps show, so a blocked Live TV tune reads the same everywhere.
function lvBanner(msg) {
    // CENTERED CouchKing-panel modal with an OK button (AJ Sep 18: "in the middle of the
    // screen with an OK button … on firetv, desktop and web").
    document.getElementById('lv-lock')?.remove();
    const scrim = document.createElement('div'); scrim.id = 'lv-lock';
    scrim.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,.72);' +
        'display:flex;align-items:center;justify-content:center;font-family:inherit';
    const p = document.createElement('div');
    p.style.cssText = 'background:#1B1830;border:1px solid #7B5BF5;border-radius:20px;padding:28px 26px;' +
        'max-width:min(420px,88vw);text-align:center;color:#fff;box-shadow:0 20px 60px rgba(0,0,0,.6)';
    const ic = document.createElement('div'); ic.textContent = '🔒'; ic.style.fontSize = '42px';
    const t = document.createElement('div'); t.textContent = 'Live TV locked'; t.style.cssText = 'font-weight:800;font-size:20px;margin-top:10px';
    const s = document.createElement('div'); s.textContent = msg; s.style.cssText = 'color:#A9A5C0;font-size:14px;margin:8px 0 18px';
    const ok = document.createElement('button'); ok.textContent = 'OK';
    ok.style.cssText = 'background:#7B5BF5;color:#fff;border:0;border-radius:12px;padding:11px 34px;font-size:15px;font-weight:700;cursor:pointer';
    ok.onclick = () => scrim.remove();
    p.append(ic, t, s, ok); scrim.appendChild(p);
    scrim.onclick = (e) => { if (e.target === scrim) scrim.remove(); };
    document.body.appendChild(scrim); ok.focus();
}
async function _lvPlayCh(id, name, guideList, busyEl) {
    busyEl?.classList.add('busy');
    try {
        // in-player Guide = the WHOLE guide (AJ Sep 17): ★ Favorites, recently watched,
        // then every section — not just the category you tuned from
        const gd2 = _lvGuideCache.d;
        if (gd2?.channels?.length) {
            const nowMs = Date.now();
            const nowOf = c => (c.progs?.find(p => p.s <= nowMs && p.e > nowMs) || {}).t || '';
            const favSet = new Set(gd2.favs || []);
            const byId = new Map(gd2.channels.map(c => [c.id, c]));
            guideList = [];
            if (gd2.favChannels?.length) {
                guideList.push({ hdr: '★ Favorites' });
                for (const c of gd2.favChannels) guideList.push({ id: 'cklive:' + c.id, name: c.name, now: nowOf(c) });
            }
            const recCh = (gd2.recent || []).filter(r => !favSet.has(r)).map(r => byId.get(r)).filter(Boolean);
            if (recCh.length) {
                guideList.push({ hdr: '↻ Continue watching' });
                for (const c of recCh) guideList.push({ id: 'cklive:' + c.id, name: c.name, now: nowOf(c) });
            }
            let lastSec = null;
            for (const c of gd2.channels) {
                const sec = c.section || c.genre || 'More channels';
                if (sec !== lastSec) { lastSec = sec; guideList.push({ hdr: sec }); }
                guideList.push({ id: 'cklive:' + c.id, name: c.name, now: nowOf(c) });
            }
        }
        const streams = await _lvTune(id);
        if (!streams.length) { toast('Channel is offline right now'); return; }
        // the steady .ts feed sidesteps panel HLS sessions that reset mid-play (the
        // "skipped forward then froze" class) — livePlay prefers it via mpegts.js
        const tsUrl = streams.find(x => x.ts)?.url || '';
        let urls = streams.filter(x => !x.ts).map(x => x.url);
        // 24/7 loop channels ARE the broken-session class (Buffy, Gunsmoke — AJ's exact
        // freezes): skip their HLS entirely, straight to the server hub feed, which also
        // walks the FREE feeds for these shows when the panel's copy is dead
        if (tsUrl && /^cklive:(en-)?24-7-/.test(String(id))) urls = [];
        // ACCESS GATE before the player opens (AJ Sep 18: "firetv, phone, apk AND desktop —
        // all should get a message when it's locked for the device limit"). The gate is
        // per-KEY, identical on every source, so probe one url and read the server's reason
        // instead of spinning forever on a nameless source error.
        {
            const gateUrl = urls[0] || tsUrl;
            if (gateUrl) {
                try {
                    const gr = await fetch(gateUrl, { method: 'GET' });
                    if (gr.status === 429 || gr.status === 503 || gr.status === 403) {
                        const reason = (await gr.text().catch(() => '')).trim();
                        lvBanner(reason || (gr.status === 429
                            ? 'All your Live TV device slots are in use — someone on your plan is already watching. Stop that stream, or add more devices to your plan.'
                            : gr.status === 503 ? 'Live TV is at full capacity right now — try again in a couple minutes.'
                            : 'Live TV isn’t part of your plan.'));
                        return;
                    }
                    try { gr.body?.cancel?.(); } catch {}   // status only — don't download the stream
                } catch {}
            }
        }
        // tuning-screen extras from the guide cache: channel logo + what they're about to
        // watch (AJ Sep 17 "loading screen … that they are going to watch")
        const ci = (_lvGuideCache.d?.channels || []).find(c => 'cklive:' + c.id === id);
        const nowP = ci?.progs?.find(p => p.s <= Date.now() && p.e > Date.now());
        await ckPlay({ live: true, url: urls[0] || '', title: name, backups: urls.slice(1), tsUrl,
                       logo: ci?.logo || '', now: nowP?.t || '',
                       chid: id, fav: _lvIsFav(id), isFav: _lvIsFav,
                       onFav: async (cid, on) => {
                           await j(`${SERVICE}/live/${S.subKey}/fav?id=${encodeURIComponent(String(cid).replace(/^cklive:/, ""))}&on=${on ? 1 : 0}&p=${encodeURIComponent(S.pid || "")}`, { method: 'POST' });
                           _lvGuideCache.at = 0;
                       },
                       guide: guideList, onTune: async (cid) => {
                           const st = await _lvTune(cid);
                           return { hls: st.filter(x => !x.ts).map(x => x.url), ts: st.find(x => x.ts)?.url || '' };
                       },
                       // back from the player: repaint so the red now-line + current blocks
                       // reflect NOW, not tune time (AJ Sep 24)
                       onClose: () => { if (page === 'livetv') livetvPage(); } });
    } finally { busyEl?.classList.remove('busy'); }
}
// ---- CLASSIC GUIDE GRID (AJ Sep 17 "like im on a classic tv box"): sticky channel column,
// 6h timeline, program blocks, red now-line, ★ favorites pinned on top, Continue Watching
// strip from the channels this key actually tunes. Data = addon /live/<key>/guide.json.
let _lvGuideCache = { at: 0, d: null };
let lvDay = 0;   // guide day tab: 0=Today 1=Tomorrow 2=day after
let lvShowAll = false;   // guide renders 150 rows fast, expands on demand
async function lvGuideData() {   // one fetch per region per minute, shared by guide + section chips
    let d = _lvGuideCache.r === lvRegion ? _lvGuideCache.d : null;
    if (!d || Date.now() - _lvGuideCache.at > 55e3) {
        d = await j(`${SERVICE}/live/${S.subKey}/guide.json?p=${encodeURIComponent(S.pid || "")}${lvRegion ? "&r=" + lvRegion : ""}`);
        if (d?.channels?.length) _lvGuideCache = { at: Date.now(), d, r: lvRegion };
    }
    return _lvGuideCache.r === lvRegion ? _lvGuideCache.d : null;
}
async function lvRenderGuide(grid) {
    const d = await lvGuideData();
    if (!d?.channels?.length) {   // addon mid-restart or first boot — auto-retry, never dead-end
        grid.innerHTML = '<div class="lv-loading">Loading the guide…</div>';
        setTimeout(() => { if (page === 'livetv' && lvGenre === 'Guide') lvRenderGuide(grid); }, 3000);
        return;
    }
    const favs = new Set(d.favs || []);
    const now = Date.now(), SLOTW = 260;
    // day tabs (AJ: "scroll through the guide and see upcoming stuff"): Today = from the
    // current half hour; future days = full day from 6 AM. EPG feed carries ~3 days.
    const dayStart = (offset) => { const dt = new Date(now + offset * 86400e3); dt.setHours(offset ? 6 : 0, 0, 0, 0);
        return offset ? dt.getTime() : Math.floor(now / 1800e3) * 1800e3; };
    // Today scrolls 72h straight through (144 half-hour slots), day tabs = full-24h jumps
    // (AJ Sep 25 "when i scroll doesn't go out like 3 days")
    const t0 = dayStart(lvDay), SLOTS = lvDay ? 48 : 144, tEnd = t0 + SLOTS * 1800e3;
    const fmtT = ms => new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
    const x = ms => Math.max(0, (ms - t0) / 1800e3 * SLOTW);
    const chans = d.channels;
    const guideList = chans.map(c => ({ id: 'cklive:' + c.id, name: c.name, now: (c.progs.find(p => p.s <= now && p.e > now) || {}).t || '' }));
    const rec = (d.recent || []).map(id => d.channels.find(c => c.id === id)).filter(Boolean);
    const esc = s => String(s).replace(/[&<>"]/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));
    // 4 day tabs (AJ Sep 25): from a Thursday, 3 tabs stopped at Saturday — Sunday games
    // need their own tab; server ships 96h of listings now
    let h = '<div class="lv-days">' + [0, 1, 2, 3].map(o => {
        const label = o === 0 ? 'Today' : o === 1 ? 'Tomorrow'
            : new Date(now + o * 86400e3).toLocaleDateString('en-US', { weekday: 'long' });
        return `<button class="lv-chip${o === lvDay ? ' on' : ''}" data-day="${o}">${label}</button>`;
    }).join('') + '</div>';
    if (rec.length && lvDay === 0) {
        h += `<div class="lvcw"><div class="lvcw-t">Continue watching — Live TV</div><div class="lvcw-row">` + rec.map(c => {
            const nowP = c.progs.find(p => p.s <= now && p.e > now);
            return `<div class="lvcw-card" data-ch="${esc(c.id)}" data-n="${esc(c.name)}">${c.logo ? `<img src="${esc(c.logo)}" onerror="this.style.display='none'">` : ''}<div><div class="lvcw-n">${esc(c.name)}</div><div class="lvcw-p">${esc(nowP?.t || 'Live')}</div></div></div>`;
        }).join('') + `</div></div>`;
    }
    let ticks = '';
    for (let i = 0; i < SLOTS; i++) ticks += `<div class="epg-tick" style="width:${SLOTW}px">${fmtT(t0 + i * 1800e3)}</div>`;
    h += `<div class="epg"><div class="epg-scroll"><div class="epg-hrow"><div class="epg-ch epg-corner">${new Date(t0).toLocaleDateString("en-US",{weekday:"short",month:"numeric",day:"numeric"})}</div><div class="epg-lane" style="width:${SLOTS * SLOTW}px">${ticks}</div></div>`;
    const rowHtml = (c) => {
        const progs = (c.progs || []).filter(p => p.e > t0 && p.s < tEnd);
        let blocks = '';
        if (progs.length) for (const p of progs) {
            const l = x(p.s), r = Math.min(x(p.e), SLOTS * SLOTW);
            const on = p.s <= now && p.e > now;
            blocks += `<div class="epg-block${on ? ' on' : ''}" style="left:${l}px;width:${Math.max(r - l - 4, 40)}px" title="${esc(p.t)} (${fmtT(p.s)}–${fmtT(p.e)})"><div class="epg-bt">${esc(p.t)}</div><div class="epg-bs">${fmtT(p.s)}</div></div>`;
        }
        else blocks = `<div class="epg-block dim" style="left:0;width:${SLOTS * SLOTW - 4}px"><div class="epg-bt">${lvDay ? 'No guide data for this day' : 'Live programming'}</div></div>`;
        return `<div class="epg-row" data-ch="${esc(c.id)}" data-n="${esc(c.name)}">
            <div class="epg-ch"><span class="epg-fav${favs.has(c.id) ? ' on' : ''}" data-fav="${esc(c.id)}">★</span>${c.logo ? `<img loading="lazy" src="${esc(c.logo)}" onerror="this.style.display='none'">` : ''}<span class="epg-cn">${esc(c.name)}</span></div>
            <div class="epg-lane" style="width:${SLOTS * SLOTW}px">${lvDay ? '' : `<div class="epg-nowline" style="left:${x(now)}px"></div>`}${blocks}</div></div>`;
    };
    const secHdr = (t) => `<div class="epg-sechdr"><div class="epg-ch epg-sec">${esc(t)}</div><div class="epg-lane epg-seclane" style="width:${SLOTS * SLOTW}px"></div></div>`;
    // ★ favorites first as their own section, then the lineup grouped by section
    // (USA: Sports/News/Kids/Movies/Entertainment; UK/CA: the provider's own sub-groups)
    const favRows = chans.filter(c => favs.has(c.id));
    const rest = chans.filter(c => !favs.has(c.id));
    if (favRows.length) { h += secHdr('★ Favorites'); for (const c of favRows) h += rowHtml(c); }
    // 500 (was 150): games ride at the BOTTOM of the grid now (AJ Sep 25) — a 150 cap
    // would hide them behind the Show-all click; ~330 HTML rows render fine
    const LIMIT = lvShowAll ? Infinity : 500;
    let lastSec = null, shown = 0;
    for (const c of rest) {
        if (shown >= LIMIT) break;
        const sec = c.section || 'More Channels';
        if (sec !== lastSec) { h += secHdr(sec); lastSec = sec; }
        h += rowHtml(c); shown++;
    }
    if (rest.length > shown) h += `<div class="epg-more"><button id="epg-showall" class="lv-chip">Show all ${rest.length} channels</button></div>`;
    h += `</div></div>`;
    grid.innerHTML = h;
    // the corner date FOLLOWS the scroll — crossing midnight flips it to the next day
    // (AJ Sep 18 "i'm scrolling and don't know what day i'm on")
    {
        const sc = grid.querySelector('.epg-scroll'), corner = grid.querySelector('.epg-corner');
        if (sc && corner) sc.addEventListener('scroll', () => {
            corner.textContent = new Date(t0 + (sc.scrollLeft / SLOTW) * 1800e3)
                .toLocaleDateString('en-US', { weekday: 'short', month: 'numeric', day: 'numeric' });
        }, { passive: true });
    }
    grid.querySelectorAll('[data-day]').forEach(el => el.onclick = (ev) => {
        ev.stopPropagation(); lvDay = +el.dataset.day; lvRenderGuide(grid);
    });
    const sa = grid.querySelector('#epg-showall');
    if (sa) sa.onclick = (ev) => { ev.stopPropagation(); lvShowAll = true; lvRenderGuide(grid); };
    grid.querySelectorAll('[data-ch]').forEach(el => el.onclick = (ev) => {
        if (ev.target.closest('[data-fav]')) return;
        _lvPlayCh('cklive:' + el.dataset.ch, el.dataset.n, guideList, el);
    });
    grid.querySelectorAll('[data-fav]').forEach(el => el.onclick = async (ev) => {
        ev.stopPropagation();
        const on = !el.classList.contains('on');
        el.classList.toggle('on', on);
        await j(`${SERVICE}/live/${S.subKey}/fav?id=${encodeURIComponent(el.dataset.fav)}&on=${on ? 1 : 0}&p=${encodeURIComponent(S.pid || "")}`, { method: 'POST' });
        _lvGuideCache.at = 0;   // re-pin on next render
    });
}
// LIVE GAMES BANNER (AJ: "live banner with games live now… only if they are active real
// games, dont just give me more panels"): sport strips appear ONLY when that sport has a
// live game; one compact Upcoming strip below. Data = /live/<key>/games.json.
let lvRegion = '';
async function lvRenderBanner(el) {
    const d = await j(`${SERVICE}/live/${S.subKey}/games.json`);
    const esc = s => String(s).replace(/[&<>"]/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));
    if (!d?.sports?.length) { el.innerHTML = ''; return; }
    // REGION-AWARE (AJ Sep 17): Fútbol rides with the UK view (it's not American sports);
    // USA/UK/CA each see the games on THEIR channels — live strips and upcoming both.
    const want = lvRegion || 'US';
    const keep = (sp, g) => sp.sport === 'Fútbol' ? want === 'UK' : (g.rg || 'US') === want;
    const sports = d.sports.map(sp => ({ ...sp,
        live: sp.live.filter(g => keep(sp, g)), soon: sp.soon.filter(g => keep(sp, g)) }))
        .filter(sp => sp.live.length || sp.soon.length);
    if (!sports.length) { el.innerHTML = ''; return; }
    let h = '';
    const card = (g, live) => `<div class="lvb-card${live ? ' live' : ''}" data-ch="${esc(g.chid)}" data-n="${esc(g.t)}">
        <div class="lvb-t">${esc(g.t)}</div><div class="lvb-m">${live ? '<span class="lvb-dot"></span>LIVE' : esc(g.when)} • ${esc(g.ch)}</div></div>`;
    for (const sp of sports) if (sp.live.length)
        h += `<div class="lvb-strip"><div class="lvb-h">${sp.emoji} ${esc(sp.sport)} — <span class="lvb-livehdr">LIVE NOW</span></div><div class="lvb-row">${sp.live.map(g => card(g, true)).join('')}</div></div>`;
    const soon = sports.flatMap(sp => sp.soon.map(g => ({ ...g, _e: sp.emoji }))).sort((a, b) => a.s - b.s).slice(0, 25);
    if (soon.length)
        h += `<div class="lvb-strip"><div class="lvb-h">📅 Upcoming games</div><div class="lvb-row">${soon.map(g => card({ ...g, t: g._e + ' ' + g.t }, false)).join('')}</div></div>`;
    el.innerHTML = h;
    el.querySelectorAll('[data-ch]').forEach(c => c.onclick = () => _lvPlayCh(c.dataset.ch, c.dataset.n, [], c));
}
// favorite toggle from anywhere a row shows (AJ Sep 17: "favorite … if i search it
// because its hard to find") — server remembers per key, guide pins them
async function _lvFavToggle(chid, btn) {
    const id = String(chid).replace(/^cklive:/, '');
    const on = !btn.classList.contains('on');
    btn.classList.toggle('on', on);
    btn.textContent = on ? '★' : '☆';
    // patch the cache IN PLACE so every view agrees instantly — waiting on the next
    // fetch made a fresh star look broken (AJ Sep 17 "doesn't add until i refresh")
    const d0 = _lvGuideCache.d;
    if (d0) {
        d0.favs = (d0.favs || []).filter(x => x !== id);
        d0.favChannels = (d0.favChannels || []).filter(c => c.id !== id);
        if (on) {
            d0.favs.push(id);
            const full = (d0.channels || []).find(c => c.id === id);
            if (full) d0.favChannels.push(full);
        }
    }
    await j(`${SERVICE}/live/${S.subKey}/fav?id=${encodeURIComponent(id)}&on=${on ? 1 : 0}&p=${encodeURIComponent(S.pid || "")}`, { method: 'POST' });
    _lvGuideCache.at = 0;   // still refetch soon for server truth
}
const _lvIsFav = chid => (_lvGuideCache.d?.favs || []).includes(String(chid).replace(/^cklive:/, ''));
// one channel row: logo | now-playing + progress | next | ★ | ▶  (sections, search, favs)
function _lvRow(grid, m, guideList) {
    const fmtT = ms => new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
    const g = m.ckGuide || {};
    const r = document.createElement('div'); r.className = 'lvg-chrow';
    const pct = g.now?.s && g.now?.e ? Math.min(100, Math.max(0, 100 * (Date.now() - g.now.s) / (g.now.e - g.now.s))) : 0;
    // every row keeps its progress bar, but marathon 24/7 "programmes" (>4h) get a DIM
    // one — full-bright near-full bars stacked up read as one giant solid line
    const longProg = g.now?.s && g.now?.e && (g.now.e - g.now.s) >= 4 * 3600e3;
    r.innerHTML = `
      <div class="lvg-ch">${m.poster ? `<img loading="lazy" src="${m.poster}" onerror="this.style.display='none'">` : ''}<span class="lvg-chname"></span></div>
      <div class="lvg-prog">
        <div class="lvg-title">${g.now ? '' : '<span class="lvg-dim">Live programming</span>'}</div>
        ${g.now ? `<div class="lvg-bar"><div class="lvg-fill" style="width:${pct}%${longProg ? ';opacity:.3' : ''}"></div></div>` : ''}
        <div class="lvg-times"></div>
      </div>
      <div class="lvg-next"></div>
      <button class="lvg-play lvg-favb${_lvIsFav(m.id) ? ' on' : ''}" style="margin-right:6px">${_lvIsFav(m.id) ? '★' : '☆'}</button>
      <button class="lvg-play">▶</button>`;
    const fb = r.querySelector('.lvg-favb');
    if (fb.classList.contains('on')) fb.style.color = '#f5c542';
    fb.onclick = (ev) => { ev.stopPropagation(); _lvFavToggle(m.id, fb); fb.style.color = fb.classList.contains('on') ? '#f5c542' : ''; };
    r.querySelector('.lvg-chname').textContent = m.name;
    if (g.now) {
        r.querySelector('.lvg-title').textContent = g.now.t;
        r.querySelector('.lvg-times').textContent = `${fmtT(g.now.s)} – ${fmtT(g.now.e)}`;
    }
    if (g.next) r.querySelector('.lvg-next').textContent = `Next: ${g.next.t} • ${fmtT(g.next.s)}`;
    r.onclick = () => _lvPlayCh(m.id, m.name, guideList, r);
    grid.appendChild(r);
}
async function livetvPage() {
    if (!S.liveCat) return;
    const chips = $('livetv-chips'), grid = $('livetv-grid');
    const sel = $('lv-region');
    // LOCKED (Live TV not on this plan, AJ Sep 18): a big centered banner, nothing else —
    // no chips, no guide, no clickable tiles. The catalog returns a single cklive:upgrade
    // marker when the key isn't entitled.
    const lockChk = await j(S.liveCat.base + `/catalog/tv/${S.liveCat.cat.id}.json`);
    if ((lockChk?.metas || []).length === 1 && lockChk.metas[0].id === 'cklive:upgrade') {
        if (sel) sel.style.display = 'none';
        const bn = $('livetv-banner'); if (bn) bn.innerHTML = '';
        chips.innerHTML = '';
        grid.innerHTML = `<div style="min-height:60vh;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:14px;padding:2rem">
            <div style="font-size:56px">🔒</div>
            <div style="font-size:26px;font-weight:800">CouchKing Live TV — Locked</div>
            <div style="font-size:15px;color:#9a9aa4;max-width:420px">Live TV isn't part of your plan. Contact support to unlock it.</div></div>`;
        return;
    }
    if (sel) sel.style.display = '';
    if (sel && !sel._wired) { sel._wired = 1; sel.onchange = () => { lvRegion = sel.value; lvGenre = 'Guide'; lvShowAll = false; livetvPage(); }; }
    const banner = $('livetv-banner');
    if (banner) lvRenderBanner(banner);   // async, fills in when ready
    grid.innerHTML = '<div class="lv-loading">Loading…</div>';
    // chips = THIS region's real sections (AJ: "where is the separate sport or news") +
    // catalog extras. USA: Sports/News/Kids/Movies/Entertainment · UK: Sky Sports/EFL/News…
    const gd = await lvGuideData();
    const secs = gd ? [...new Set(gd.channels.map(c => c.section).filter(Boolean))] : [];
    const genres = ['Guide', '★ Favorites', ...secs, ...(lvRegion ? [] : ['Local', '24/7']), 'All Channels'];
    chips.innerHTML = '';
    for (const g of genres) {
        const b = document.createElement('button');
        b.className = 'lv-chip' + (g === lvGenre ? ' on' : '');
        b.textContent = g;
        b.onclick = () => { lvGenre = g; livetvPage(); };
        chips.appendChild(b);
    }
    // SEARCH channels + shows (AJ Sep 17): server matches channel names AND anything in
    // the next 24h of guide. Renders into the grid only — the input never rebuilds, so
    // typing keeps focus.
    const sin = document.createElement('input');
    sin.type = 'search'; sin.placeholder = '🔎 Channels & shows';
    sin.style.cssText = 'background:#1c1c22;border:1px solid #3a3a44;border-radius:16px;padding:6px 14px;color:#fff;min-width:190px;font-size:14px;outline:none';
    sin.oninput = () => { clearTimeout(sin._t); sin._t = setTimeout(async () => {
        const qq = sin.value.trim();
        if (!qq) return livetvPage();
        const d2 = await j(S.liveCat.base + `/catalog/tv/${S.liveCat.cat.id}/search=${encodeURIComponent(qq)}.json`);
        if (qq !== sin.value.trim()) return;   // stale response, user kept typing
        const metas = d2?.metas || [];
        grid.innerHTML = metas.length ? '' : '<div class="lv-loading">No channels or shows match.</div>';
        const gl = metas.map(m => ({ id: m.id, name: m.name, now: '' }));
        for (const m of metas) {
            _lvRow(grid, m, gl);
            if (m.ckHit) {   // show-title hit: say WHY this channel matched
                const el = grid.lastChild.querySelector('.lvg-next');
                el.textContent = (m.ckHit.live ? '🔴 ON NOW: ' : '📅 ') + m.ckHit.t + (m.ckHit.when ? ' • ' + m.ckHit.when : '');
                if (m.ckHit.live) el.style.color = '#e64545';
            }
        }
    }, 350); };
    chips.appendChild(sin);
    if (lvGenre === 'Guide') return lvRenderGuide(grid);
    const now = Date.now();
    if (lvGenre === '★ Favorites') {
        // full channel objects ride in guide.json favChannels — region-independent
        const chans = gd?.favChannels || [];
        grid.innerHTML = chans.length ? '' : '<div class="lv-loading">No favorites yet — hit the ★ on any channel (search finds the hidden ones).</div>';
        const guideList = chans.map(c => ({ id: 'cklive:' + c.id, name: c.name, now: (c.progs.find(p => p.s <= now && p.e > now) || {}).t || '' }));
        for (const c of chans) {
            const nowP = c.progs.find(p => p.s <= now && p.e > now), nextP = c.progs.find(p => p.s > now);
            _lvRow(grid, { id: 'cklive:' + c.id, name: c.name, poster: c.logo, ckGuide: { now: nowP, next: nextP } }, guideList);
        }
        return;
    }
    if (secs.includes(lvGenre)) {
        // section view straight from guide data — instant, region-aware, no extra fetch
        const chans = gd.channels.filter(c => c.section === lvGenre);
        const guideList = chans.map(c => ({ id: 'cklive:' + c.id, name: c.name, now: (c.progs.find(p => p.s <= now && p.e > now) || {}).t || '' }));
        grid.innerHTML = chans.length ? '' : '<div class="lv-loading">Nothing here right now.</div>';
        for (const c of chans) {
            const nowP = c.progs.find(p => p.s <= now && p.e > now), nextP = c.progs.find(p => p.s > now);
            _lvRow(grid, { id: 'cklive:' + c.id, name: c.name, poster: c.logo, ckGuide: { now: nowP, next: nextP } }, guideList);
        }
        return;
    }
    // catalog views (Local / 24⁄7 / All Channels) — server pages of 100 with a Load-more
    grid.innerHTML = '';
    let skip = 0, my = ++_lvCatalogGen;
    const loadPage = async () => {
        grid.querySelector('.epg-more')?.remove();
        // Stremio extras ride IN the path segment ("genre=X&skip=100.json"), not the query string
        const path = `/catalog/tv/${S.liveCat.cat.id}/genre=${encodeURIComponent(lvGenre.replace('24/7','24-7'))}${skip ? '&skip=' + skip : ''}.json`;
        const d = await j(S.liveCat.base + path);
        if (my !== _lvCatalogGen) return;   // user switched chips mid-load
        const metas = d?.metas || [];
        if (!metas.length && !skip) { grid.innerHTML = '<div class="lv-loading">No channels in this category right now.</div>'; return; }
        const guideList = metas.map(m => ({ id: m.id, name: m.name, now: (m.description || '').split('\n')[0] }));
        for (const m of metas) _lvRow(grid, m, guideList);
        skip += metas.length;
        if (metas.length === 100) {
            const more = document.createElement('div'); more.className = 'epg-more';
            more.innerHTML = `<button class="lv-chip">Load more channels (${skip} shown)</button>`;
            more.querySelector('button').onclick = loadPage;
            grid.appendChild(more);
        }
    };
    await loadPage();
}
let _lvCatalogGen = 0;

// live sync like the phone/Firestick: re-pull account state every 60s so what you watch
// on other devices shows up here without a restart. QUIET: the server re-derives the
// Continue order on every GET (tvSortContinue), so a full re-render every minute made
// the page visibly rebuild — now ONLY the hero + Continue row repaint, in place.
let lastSyncSig = '';
function syncSig() {
    const p = pstate();
    return JSON.stringify([p.continue, p.cwlast, p.positions, p.watchlist, p.watchedIds, p.prefs, p.newEpsSeen]);
}
setInterval(async () => {
    if (S.guest || !S.token || playing) return;
    const st = await j(`${SERVICE}/tvapp/state?e=${encodeURIComponent(S.email)}&t=${encodeURIComponent(S.token)}`);
    if (!st) return;
    S.state = st; applyAccountPrefs();
    // the active profile may have been renamed/recolored on another device — keep the
    // rail chip live too, not just the content rows (Sep 17 profile-sync pass)
    const liveProf = (st.profiles || []).find(p => p.id === S.pid);
    if (liveProf) {
        S.user = liveProf.name; S.useg = `${liveProf.name} #${String(liveProf.id).slice(-4)}`;
        $('prof-name').textContent = liveProf.name; paintAvatar($('prof-avatar'), liveProf);
    }
    const sig = syncSig();
    if (sig === lastSyncSig) return;
    lastSyncSig = sig;
    if (page === 'home') { hero(pstate()); paintContinueRow(); }
    // badge refresh IN PLACE (AJ Sep 17 "can't tell if watched/added unless i click"):
    // a state fetch that failed mid-load (server restart) left every tile badge-less
    // forever — patch eyes/checks onto existing tiles whenever fresh state lands
    try {
        document.querySelectorAll('.poster').forEach(po => {
            const t = po._ckT;
            if (!t || po.querySelector('.cw-x')) return;   // CW row keeps its ✕, no badges
            const wrap = po.querySelector('.pwrap'); if (!wrap) return;
            const { inList, isDone } = markState(t);   // matches TMDB home tiles by name too
            const want = (cls, on, txt) => {
                let el = wrap.querySelector('.' + cls);
                if (on && !el) { el = document.createElement('div'); el.className = cls; el.textContent = txt; wrap.appendChild(el); }
                if (!on && el) el.remove();
            };
            want('badge-list', inList, '✓');
            want('badge-done', isDone, '✓');
        });
    } catch {}
}, 60000);

// rail navigation: pages live side by side, rail icon marks the active one
let page = 'home';
function nav(which) {
    page = which;
    document.querySelectorAll('.rail-item.nav').forEach(n => n.classList.toggle('on', n.dataset.nav === which));
    for (const v of ['home', 'search', 'discover', 'library', 'downloads', 'livetv', 'settings', 'detail', 'person', 'episode'])
        $('view-' + v)?.classList.toggle('hidden', v !== which);
    if (which === 'livetv') livetvPage();
    if (which === 'search') setTimeout(() => $('search').focus(), 50);
    if (which === 'discover' && !$('discover-rows').childElementCount) discover();
    if (which === 'library') library();
    if (which === 'downloads') downloadsPage();
    if (which === 'settings') renderSettings();
}
function show(which) {
    $('view-auth').classList.toggle('hidden', which !== 'auth');
    $('shell').classList.toggle('hidden', which === 'auth');
    if (which !== 'auth') nav('home');
}

// ---------- posters / rows ----------
const IMG = (p, w = 342) => p ? (p.startsWith('http') ? p : `https://image.tmdb.org/t/p/w${w}${p}`) : '';
// tile = EXACT Firestick card: white bar on a dark track flush at the poster's bottom
// (only 2–97%), purple ✓ top-right = My List, yellow eye top-left = watched, "+N" =
// new episodes aired since last watched, single-line ELLIPSIZED centered title below
function markState(t) {
    const st = pstate();
    const nm = (t.name || '').toLowerCase().trim();
    const ty = t.type || '';
    const wl = st.watchlist || [];
    const wt = st.watchedTitles || [];
    const nameHit = (arr) => nm && arr.some(x => (x.name || '').toLowerCase().trim() === nm && (!x.type || !ty || x.type === ty));
    const inList = (t.id ? wl.some(x => x.id === t.id) : false) || nameHit(wl);
    const isDone = (t.id ? (st.watchedIds || []).includes(t.id) : false) || nameHit(wt);
    return { inList, isDone };
}
function posterEl(t, opts = {}) {
    const d = document.createElement('div'); d.className = 'poster';
    const st = pstate();
    const hasBar = opts.pct >= 2 && opts.pct <= 97;
    const { inList, isDone } = markState(t);
    d.innerHTML = `<div class="pwrap"><img loading="lazy" src="${t.poster || ''}">`
        + (opts.chip ? `<div class="ep-chip">${opts.chip}</div>` : '')
        + (opts.removable ? `<div class="cw-x" title="Remove from Continue Watching">✕</div>` : '')
        + (inList && !opts.removable ? '<div class="badge-list">✓</div>' : '')
        + (isDone && !opts.removable ? '<div class="badge-done">✓</div>' : '')
        + (opts.newEps > 0 ? `<div class="badge-new">+${opts.newEps}</div>` : '')
        + (hasBar ? `<div class="bar"><div style="width:${opts.pct}%"></div></div>` : '')
        + `</div>`
        + (PREF('titles', true) ? `<div class="pt" title="${(t.name || '').replace(/"/g, '&quot;')}">${t.name || ''}</div>` : '');
    d.onclick = (e) => { if (!e.target.classList.contains('cw-x')) detail(t); };
    if (opts.removable) d.querySelector('.cw-x').onclick = () => removeContinue(t, d);
    d._ckT = t;   // the badge-refresh pass needs the tile's identity
    return d;
}
function removeContinue(t, el) {
    if (S.guest) return;
    const st = pstate();
    st.continue = (st.continue || []).filter(x => x.id !== t.id);
    // cw:-scoped (Sep 17): hiding from Continue Watching must NOT delete the watched
    // mark / library entry — the old bare-id tombstone nuked all three lists on merge
    st.removedTs = stamp(st.removedTs, 'cw:' + t.id);
    // clear-progress tombstones so the removal reaches every device (server merge rule)
    const pos = st.positions || {};
    for (const k of Object.keys(pos)) if (k === t.id || k.startsWith(t.id + ':')) {
        st.removedTs = stamp(st.removedTs, 'pos:' + k); delete pos[k];
    }
    el.remove(); pushAccount();
    j(`${SERVICE}/player/clear`, { method: 'POST', body: { k: S.subKey, u: S.useg, i: t.id } });
}
function addRow(label, items, opts, holder) {
    if (!items?.length) return;
    const rows = holder || document.querySelector('#view-home .rows');
    if (label) { const l = document.createElement('div'); l.className = 'row-label'; l.textContent = label; rows.appendChild(l); }
    const s = document.createElement('div'); s.className = 'strip';
    for (const t of items) s.appendChild(posterEl(t, typeof opts === 'function' ? opts(t) : (opts || {})));
    rows.appendChild(s);
}
async function tmdbRow(kind, path, pages = 3, cap = 0) {
    const reqs = [];
    for (let p = 1; p <= pages; p++)
        reqs.push(j(`https://api.themoviedb.org/3/${path}${path.includes('?') ? '&' : '?'}api_key=${TMDB}&page=${p}`));
    const seen = new Set(); const out = [];
    for (const d of await Promise.all(reqs))
        for (const r of (d?.results || [])) {
            if (seen.has(r.id)) continue; seen.add(r.id);
            out.push({ tmdb: r.id, type: kind === 'tv' ? 'series' : 'movie', name: r.title || r.name,
                       poster: IMG(r.poster_path), backdrop: IMG(r.backdrop_path, 1280),
                       genres: r.genre_ids || [] });
        }
    return out.slice(0, cap || (pages > 3 ? 400 : 60));
}
async function cineRow(type, id, genre, pages = 1) {
    const reqs = [];
    for (let p = 0; p < pages; p++) {
        const g = genre ? `/genre=${encodeURIComponent(genre.replace('24/7','24-7'))}` : '';
        reqs.push(j(`${CINE}/catalog/${type}/${id}${g}${p ? (genre ? '&skip=' + p * 100 : '/skip=' + p * 100) : ''}.json`));
    }
    const out = []; const seen = new Set();
    for (const d of await Promise.all(reqs))
        for (const m of (d?.metas || [])) {
            if (seen.has(m.id)) continue; seen.add(m.id);
            out.push({ id: m.id, type, name: m.name, poster: m.poster });
        }
    return out.slice(0, pages > 2 ? 400 : 60);
}
async function idsRow(type, ids) {
    const metas = await Promise.all(ids.map(async id => {
        const m = (await j(`${CINE}/meta/movie/${id}.json`))?.meta
            || (await j(`${CINE}/meta/series/${id}.json`))?.meta;
        if (m) return m;
        // Cinemeta doesn't know far-future titles yet (VisionQuest) — TMDB does; the tile
        // still shows in watch order, clicking gets the standard unaired treatment (Sep 17)
        const f = await j(`https://api.themoviedb.org/3/find/${id}?api_key=${TMDB}&external_source=imdb_id`);
        const mv = f?.movie_results?.[0], tv = f?.tv_results?.[0], hit = mv || tv;
        return hit ? { id, type: mv ? 'movie' : 'series', name: hit.title || hit.name,
            poster: hit.poster_path ? `https://image.tmdb.org/t/p/w342${hit.poster_path}` : '' } : null;
    }));
    const out = [];
    for (const m of metas) if (m) out.push({ id: m.id, type: m.type || type, name: m.name, poster: m.poster });
    return out;
}
async function rowItems(r) {
    if (r.ids) return idsRow(r.type, r.ids);   // curated watch orders: EXACT order, never shuffled
    // theme category spanning both types (Superheroes/Zombies/…): movies + shows interleaved
    if (r.tvTmdb && r.tmdb) {
        // pages=2 mirrors the web build + the TV app's tmdbBoth() (same input → same profileMix order)
        const [mv, tv] = await Promise.all([tmdbRow('movie', r.tmdb, 2), tmdbRow('tv', r.tvTmdb, 2)]);
        const out = []; const n = Math.max(mv.length, tv.length);
        for (let i = 0; i < n; i++) { if (mv[i]) out.push(mv[i]); if (tv[i]) out.push(tv[i]); }
        // dedupe by type+TMDB id — these items carry .tmdb, NOT .id, so keying on x.id
        // (undefined for all of them) collapsed every themed row to a single tile
        // (AJ Sep 27 "zombies / time travel / superhero rows only have one item")
        const seen = new Set();
        return profileMix(out.filter(x => { const k = x.id || x.type + ':' + x.tmdb; return x && !seen.has(k) && seen.add(k); }));
    }
    if (r.tmdb) return profileMix(await tmdbRow(r.type === 'series' ? 'tv' : 'movie', r.tmdb));
    return profileMix(await cineRow(r.type, r.cine, r.genre, 2));
}
// deterministic per-profile per-day shuffle — stable all day, fresh mix tomorrow,
// different per profile (same seed rule as the TV app's profileMix)
function profileMix(items) {
    if (!items || items.length < 4) return items || [];
    const pid = S.pid || 'guest';
    let h = 0;
    for (let i = 0; i < pid.length; i++) h = (Math.imul(31, h) + pid.charCodeAt(i)) | 0;
    const day = Math.floor(Date.now() / 86400000);
    let seed = (Math.imul(h, 1000003) ^ day) >>> 0;
    const rnd = () => {   // mulberry32
        seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
        let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    const a = [...items];
    for (let i = a.length - 1; i > 0; i--) {
        const k = Math.floor(rnd() * (i + 1));
        [a[i], a[k]] = [a[k], a[i]];
    }
    return a;
}
// For You — prefer the addon server's PERSONALIZED catalog: the SAME source the TV/mobile
// app uses (real per-profile watch-history weighting + daily respin), so a signed-in user
// gets an identical, truly-personal For You on desktop. Guests — or a service that returns
// nothing — fall through to the client-side TMDB consensus below. (AJ Sep 19: the desktop/web
// For You was a generic consensus while the apps had the personalized server one.)
// Swap the active profile ("Name #ab12" = S.useg) into the addon URL's config segment —
// same as the TV app's Addons.withUser — so the service logs clicks and personalizes
// For You per PROFILE, not per account (AJ Sep 24). Guest / non-config URL → unchanged.
function withUser(url) {
    if (!S.useg) return url;
    try {
        const i = url.lastIndexOf('/');
        const cfg = JSON.parse(decodeURIComponent(url.slice(i + 1)));
        if (!cfg.subKey) return url;
        cfg.userName = S.useg;
        return url.slice(0, i + 1) + encodeURIComponent(JSON.stringify(cfg));
    } catch { return url; }
}
const _fyManifest = {};
async function forYouAddon(kind) {
    if (!hasService()) return [];
    const base = S.addons[0].url.replace(/\/$/, '');
    const stype = kind === 'tv' ? 'series' : 'movie';
    // discover the catalog id from the manifest (matches the TV app), with the known
    // couchking id as the fallback if the manifest can't be read
    let catId = 'couchking-foryou-' + (kind === 'tv' ? 'series' : 'movies');
    const man = _fyManifest[base] || (_fyManifest[base] = await j(`${base}/manifest.json`));
    const hit = (man?.catalogs || []).find(c => c.type === stype && /for you/i.test(c.name || ''));
    if (hit?.id) catId = hit.id;
    const d = await j(`${withUser(base)}/catalog/${stype}/${encodeURIComponent(catId)}.json`);
    return (d?.metas || []).map(m => ({ id: m.id, type: stype, name: m.name, poster: m.poster }));
}
// consensus ranking (votes across your watched/library seeds) — TV app's fallback, and ours
async function forYouRow(kind) {
    const fromAddon = await forYouAddon(kind).catch(() => []);
    if (fromAddon.length) return fromAddon;
    const st = pstate();
    const lib = [...(st.continue || []), ...(st.watchlist || []), ...(st.watchedTitles || [])];
    const seeds = lib.filter(t => kind === 'tv' ? t.type === 'series' : t.type !== 'series')
        .map(t => t.id).filter(id => id?.startsWith('tt'));
    if (!seeds.length) return [];
    const lists = await Promise.all([...new Set(seeds)].slice(0, 8).map(async imdb => {
        const f = await j(`https://api.themoviedb.org/3/find/${imdb}?api_key=${TMDB}&external_source=imdb_id`);
        const id = f?.[kind === 'tv' ? 'tv_results' : 'movie_results']?.[0]?.id;
        if (!id) return [];
        const d = await j(`https://api.themoviedb.org/3/${kind}/${id}/recommendations?api_key=${TMDB}`);
        return d?.results || [];
    }));
    const votes = {}; const best = {};
    for (const lst of lists) { const once = new Set();
        for (const o of lst) { if (o.id && !once.has(o.id)) { once.add(o.id); votes[o.id] = (votes[o.id] || 0) + 1; best[o.id] = best[o.id] || o; } } }
    return Object.values(best)
        .sort((a, b) => (votes[b.id] - votes[a.id]) || (b.popularity - a.popularity))
        .slice(0, 40)
        .map(r => ({ tmdb: r.id, type: kind === 'tv' ? 'series' : 'movie', name: r.title || r.name, poster: IMG(r.poster_path) }));
}

// ---------- new-episode badges (synced through newEpsSeen, key = season*10000+episode) ----------
const newEpCache = {};
const newEpAirCache = {};   // titleId -> newest unwatched ep's air timestamp (drives CW order)
async function newEpisodeCount(titleId) {
    if (titleId in newEpCache) return newEpCache[titleId];
    const st = pstate();
    const meta = (await j(`${CINE}/meta/series/${titleId}.json`))?.meta;
    const eps = (meta?.videos || []).filter(v => v.season > 0)
        .sort((a, b) => a.season - b.season || a.episode - b.episode);
    if (!eps.length) return (newEpCache[titleId] = 0);
    const aired = (e) => !e.released || new Date(e.released) <= new Date();
    const key = (e) => e.season * 10000 + e.episode;
    const latestAiredKey = Math.max(0, ...eps.filter(aired).map(key));
    // opening the show dismissed the badge (on ANY device — merged by max) until
    // something genuinely newer airs
    if (latestAiredKey > 0 && ((st.newEpsSeen || {})[titleId] || 0) >= latestAiredKey)
        return (newEpCache[titleId] = 0);
    const pos = st.positions || {};
    const watchedIds = new Set(st.watchedIds || []);
    const watched = eps.filter(e => {
        const k = `${titleId}:${e.season}:${e.episode}`;
        return watchedIds.has(k) || (parseInt(String(pos[k] || '').split('|')[0]) || 0) > 60000;
    });
    if (!watched.length) {
        // never-watched but in the library (AJ Sep 14: "anything in there, watched or
        // not") — badge counts episodes aired AFTER the show was added, same as the TV app
        const addedAt = +((st.addedTs || {})[titleId] || 0);
        if (!addedAt) return (newEpCache[titleId] = 0);
        const freshAdd = eps.filter(e => aired(e) && e.released && +new Date(e.released) > addedAt);
        const nA = Math.min(9, freshAdd.length);
        newEpAirCache[titleId] = nA ? Math.max(...freshAdd.map(e => +new Date(e.released))) : 0;
        return (newEpCache[titleId] = nA);
    }
    const last = watched[watched.length - 1];
    // deep back-catalog binges: "+9" means nothing when nothing new actually aired
    const maxSeason = Math.max(0, ...eps.filter(aired).map(e => e.season));
    if (last.season < maxSeason - 1) return (newEpCache[titleId] = 0);
    const fresh = eps.filter(e => aired(e) && key(e) > key(last));
    const n = Math.min(9, fresh.length);
    // the air date acts like a "touch": the show sorts as if it was watched the moment
    // the new episode dropped — front of CW that day, then normal recency order takes
    // over as other things get watched (AJ Sep 14: badge shows must FOLLOW order, not pin)
    newEpAirCache[titleId] = n ? Math.max(0, ...fresh.map(e => +new Date(e.released || 0) || 0)) : 0;
    return (newEpCache[titleId] = n);
}
// opening a show's page clears its badge — record the latest aired key as seen (merged
// by MAX across devices, exactly like the Firestick)
function dismissNewEpsBadge(titleId, meta) {
    if (S.guest || meta?.type !== 'series') return;
    const eps = (meta.videos || []).filter(v => v.season > 0 && (!v.released || new Date(v.released) <= new Date()));
    if (!eps.length) return;
    const key = Math.max(...eps.map(e => e.season * 10000 + e.episode));
    const st = pstate();
    if (key > ((st.newEpsSeen || {})[titleId] || 0)) {
        st.newEpsSeen = { ...(st.newEpsSeen || {}), [titleId]: key };
        newEpCache[titleId] = 0;
        pushAccount();
    }
}

// ---------- home ----------
// SAME rule as the Firestick's cwProgress: the bar shows ONLY the episode you're on
// (cwlast) — never the max across the whole show (a finished S1E1 made a 2-min-into-S2E4
// card read "fully watched", AJ Sep 10)
function pctOf(st, t) {
    const key = t.type === 'series' ? (st.cwlast || {})[t.id] : t.id;
    if (!key) return 0;
    const [p, d] = String((st.positions || {})[key] || '').split('|').map(Number);
    return d > 0 ? Math.min(100, Math.round(100 * p / d)) : 0;
}
function cwChip(st, t) {
    if (t.type !== 'series') return '';
    const last = (st.cwlast || {})[t.id] || '';
    const [, s, e] = last.split(':');
    return s && e ? `S${s} · E${e}` : '';
}
let lastHeroKey = '';
async function hero(st) {
    const h = $('hero');
    let t = (st.continue || [])[0];
    let sub = '', bg = '';
    if (t) sub = t.type === 'series' && cwChip(st, t) ? `Continue watching · ${cwChip(st, t)}` : 'Continue watching';
    const heroKey = t ? t.id + '|' + sub : 'trend';
    if (heroKey === lastHeroKey && h.childElementCount) return;   // quiet sync: no repaint when nothing changed
    if (t) {
        const meta = (await j(`${CINE}/meta/${t.type}/${t.id}.json`))?.meta;
        bg = meta?.background || '';
    } else {
        const tr = await tmdbRow('tv', 'trending/tv/week', 1);
        t = tr[0]; bg = t?.backdrop || ''; sub = 'Trending this week';
        if (t) { const f = await j(`https://api.themoviedb.org/3/tv/${t.tmdb}/external_ids?api_key=${TMDB}`); if (f?.imdb_id) t.id = f.imdb_id; }
    }
    if (!t || !bg) { h.classList.add('hidden'); return; }
    lastHeroKey = heroKey;
    // no service on the account → tracker shell: More info only, no play button
    h.innerHTML = `<div class="hero-bg" style="background-image:url('${bg}')"></div><div class="hero-fade"></div>
        <div class="hero-body"><h2>${t.name || ''}</h2><div class="hero-sub">${sub}</div>
        <div class="hero-btns">${hasService() ? `<button class="primary">▶ ${st.continue?.length ? 'Resume' : 'Watch'}</button>` : ''}
        <button class="ghost">More info</button></div></div>`;
    h.classList.remove('hidden');
    const btns = h.querySelectorAll('button');
    const info = btns[btns.length - 1];
    info.onclick = (e) => { e.stopPropagation(); detail(t); };
    h.onclick = () => detail(t);
    if (hasService()) btns[0].onclick = async (e) => {
        e.stopPropagation();
        resumeTitle(t);
    };
}
// hero Resume / CW: series jumps straight to the current episode's page (auto-plays the
// top stream), movies play directly — same as the Firestick's resumeFromCw
async function resumeTitle(t) {
    const st = pstate();
    const last = (st.cwlast || {})[t.id];
    if (t.type === 'series' && last?.includes(':')) {
        const meta = (await j(`${CINE}/meta/series/${t.id}.json`))?.meta;
        const [, s, e] = last.split(':');
        const ep = (meta?.videos || []).find(v => v.season == s && v.episode == e);
        if (meta && ep) { episodePage({ id: t.id, type: 'series' }, meta, ep, true); return; }
    }
    await detail(t);
    if (t.type !== 'series') pickStream(t.id, t.name, true);
}
let cwHolderEl = null;
function paintContinueRow() {
    if (!cwHolderEl || !cwHolderEl.isConnected) return;
    const st = pstate();
    cwHolderEl.innerHTML = '';
    const cont = st.continue || [];
    if (!cont.length || !hasService()) return;
    // CW order = newest of (your last watch, a badge'd show's new-episode air date).
    // A new episode bumps its show to the front THAT DAY like a touch — but anything you
    // actually watch after that outranks it, so the row keeps following real order
    // (AJ Sep 14: v1 pinned badge shows in front — "The President" sat above a
    // just-started Lanterns; air date as a stamp fixes exactly that)
    const stampOf = (t) => {
        let best = 0;
        for (const [k, v] of Object.entries(st.positions || {}))
            if (k === t.id || k.startsWith(t.id + ':')) best = Math.max(best, +String(v).split('|')[2] || 0);
        return best;
    };
    const sortKey = (t) => Math.max(stampOf(t), (newEpCache[t.id] || 0) > 0 ? (newEpAirCache[t.id] || 0) : 0);
    const bumped = () => [...cont].sort((a, b) => sortKey(b) - sortKey(a));
    addRow('Continue Watching', bumped().map(t => ({ ...t })),
        (t) => ({ pct: pctOf(st, t), chip: cwChip(st, t), removable: !S.guest, newEps: newEpCache[t.id] || 0 }),
        cwHolderEl);
    // "+N new episodes" pass — fills badges in place once the counts land
    (async () => {
        let any = false;
        for (const t of cont.filter(x => x.type === 'series'))
            if (await newEpisodeCount(t.id) > 0) any = true;
        if (any && cwHolderEl.isConnected) {
            cwHolderEl.innerHTML = '';
            addRow('Continue Watching', bumped().map(t => ({ ...t })),
                (t) => ({ pct: pctOf(st, t), chip: cwChip(st, t), removable: !S.guest, newEps: newEpCache[t.id] || 0 }),
                cwHolderEl);
        }
    })();
}
// Netflix's Top 10 shelf — giant ghost rank numeral tucked behind each poster, same
// trending/day movie+show interleave as the TV app, never profile-shuffled
async function top10Row(holder) {
    const [mv, tv] = await Promise.all([
        tmdbRow('movie', 'trending/movie/day', 1),
        tmdbRow('tv', 'trending/tv/day', 1),
    ]);
    const mix = [];
    for (let i = 0; i < Math.max(mv.length, tv.length); i++) {
        if (mv[i]) mix.push(mv[i]);
        if (tv[i]) mix.push(tv[i]);
    }
    const ten = mix.slice(0, 10);
    if (!ten.length || !holder.isConnected) return;
    holder.innerHTML = '';
    const l = document.createElement('div'); l.className = 'row-label'; l.textContent = 'Top 10 Today';
    holder.appendChild(l);
    const strip = document.createElement('div'); strip.className = 'strip top10';
    ten.forEach((t, i) => {
        const cell = document.createElement('div'); cell.className = 'top10-cell' + (i === 9 ? ' wide' : '');
        const num = document.createElement('div'); num.className = 'top10-num'; num.textContent = i + 1;
        cell.appendChild(num);
        cell.appendChild(posterEl(t));
        strip.appendChild(cell);
    });
    holder.appendChild(strip);
}
async function home() {
    const rows = document.querySelector('#view-home .rows');
    rows.innerHTML = '';
    lastHeroKey = '';
    const st = pstate();
    hero(st);
    // Continue Watching lives in a STABLE holder so the 60s sync can repaint just it
    cwHolderEl = document.createElement('div'); rows.appendChild(cwHolderEl);
    paintContinueRow();
    // Top 10 rides right under Continue Watching (leads the page when there's no CW)
    const top10Holder = document.createElement('div'); rows.appendChild(top10Holder);
    top10Row(top10Holder);
    // rows land IN CATALOG ORDER via pre-placed slots (async fills used to append in
    // completion order — the board shuffled on every load and looked nothing like the TV)
    const slot = () => { const s = document.createElement('div'); rows.appendChild(s); return s; };
    const fill = (holder, label, items) => {
        if (!items?.length) { holder.remove(); return; }
        addRow(label, items, null, holder);
    };
    if (!S.guest) {
        const fm = slot(), fs = slot();
        forYouRow('movie').then(x => fill(fm, 'For You — Movies', x));
        forYouRow('tv').then(x => fill(fs, 'For You — Series', x));
    }
    // the profile's shelf line-up SYNCS from the account (same picks as the Firestick)
    const enabled = (st.shelves && st.shelves.length) ? st.shelves : CK_CAT.DEFAULT_SHELVES;
    // render in the USER'S chosen order (was SHELF_CATALOG order, which ignored reordering)
    for (const label of enabled) {
        const r = CK_CAT.SHELF_CATALOG.find(x => x.label === label);
        if (!r) continue;
        const s = slot();
        rowItems(r).then(items => fill(s, r.label, items));
    }
}

// ---------- search (movies + shows + PEOPLE, like the apps) ----------
let searchT = null;
$('search').addEventListener('input', () => {
    clearTimeout(searchT);
    searchT = setTimeout(async () => {
        const q = $('search').value.trim();
        const holder = $('search-rows');
        holder.innerHTML = '';
        if (q.length < 2) return;
        const [m, s, people] = await Promise.all([
            j(`${CINE}/catalog/movie/top/search=${encodeURIComponent(q)}.json`),
            j(`${CINE}/catalog/series/top/search=${encodeURIComponent(q)}.json`),
            searchPeople(q),
        ]);
        if ($('search').value.trim() !== q) return;
        const map = (d, ty) => (d?.metas || []).slice(0, 25).map(x => ({ id: x.id, type: ty, name: x.name, poster: x.poster }));
        if (people.length) {
            const l = document.createElement('div'); l.className = 'row-label'; l.textContent = 'People';
            holder.appendChild(l);
            const strip = document.createElement('div'); strip.className = 'strip';
            for (const p of people) strip.appendChild(personCard(p));
            holder.appendChild(strip);
        }
        addRow('Shows', map(s, 'series'), null, holder);
        addRow('Movies', map(m, 'movie'), null, holder);
        if (!holder.childElementCount) holder.innerHTML = `<p class="muted" style="padding-top:1rem">No results for “${q}”</p>`;
    }, 400);
});
// face + name matches for a typed query — real people search, not just text chips
async function searchPeople(q) {
    const d = await j(`https://api.themoviedb.org/3/search/person?api_key=${TMDB}&query=${encodeURIComponent(q)}`);
    const seen = new Set();
    return (d?.results || [])
        .sort((a, b) => (b.popularity || 0) - (a.popularity || 0))
        .filter(p => p.name && !seen.has(p.name) && seen.add(p.name))
        .slice(0, 8)
        .map(p => ({ id: p.id, name: p.name,
            photo: p.profile_path ? `https://image.tmdb.org/t/p/w185${p.profile_path}` : '',
            role: p.known_for_department === 'Directing' ? 'Director' : 'Actor' }));
}
function personCard(p) {
    const d = document.createElement('div'); d.className = 'person-card';
    d.innerHTML = `<div class="person-photo">${p.photo ? `<img src="${p.photo}">` : '👤'}</div>
        <div class="pt">${p.name}</div><div class="person-role">${p.role}</div>`;
    d.onclick = () => personPage(p);
    return d;
}
// Stremio-style person page: who they are + what they've been in (acting or directing)
async function personPage(p) {
    nav('person');
    const body = $('person-body');
    body.innerHTML = `<button class="ghost small" id="person-back">‹ Back</button>
        <div class="person-head">${p.photo ? `<img src="${p.photo}">` : ''}<div><h2>${p.name}</h2><div class="muted">${p.role}</div></div></div>
        <div id="person-rows"><p class="muted">Loading…</p></div>`;
    $('person-back').onclick = () => nav('search');
    const c = await j(`https://api.themoviedb.org/3/person/${p.id}/combined_credits?api_key=${TMDB}`);
    const credits = [...(c?.cast || []), ...((c?.crew || []).filter(x => x.job === 'Director'))];
    const seen = new Set();
    const uniq = credits.filter(x => {
        const k = x.media_type + x.id;
        return x.poster_path && !seen.has(k) && seen.add(k);
    }).sort((a, b) => (b.popularity || 0) - (a.popularity || 0));
    const mk = (x) => ({ tmdb: x.id, type: x.media_type === 'tv' ? 'series' : 'movie',
        name: x.title || x.name, poster: IMG(x.poster_path) });
    const rows = $('person-rows'); rows.innerHTML = '';
    addRow('Shows', uniq.filter(x => x.media_type === 'tv').slice(0, 14).map(mk), null, rows);
    addRow('Movies', uniq.filter(x => x.media_type === 'movie').slice(0, 14).map(mk), null, rows);
    if (!rows.childElementCount) rows.innerHTML = '<p class="muted">Nothing found.</p>';
}

// ---------- detail ----------
async function resolveImdb(t) {
    if (t.id?.startsWith('tt')) return t.id;
    const d = await j(`https://api.themoviedb.org/3/${t.type === 'series' ? 'tv' : 'movie'}/${t.tmdb}/external_ids?api_key=${TMDB}`);
    return d?.imdb_id || null;
}
let cur = null;
async function detail(t) {
    const imdb = await resolveImdb(t);
    if (!imdb) return;
    const meta = (await j(`${CINE}/meta/${t.type}/${imdb}.json`))?.meta;
    if (!meta) return;
    cur = { imdb, type: t.type, meta, t: { ...t, id: imdb } };
    dismissNewEpsBadge(imdb, meta);   // opening the show clears its "+N" badge everywhere
    nav('detail');
    $('detail-backdrop').style.backgroundImage = meta.background ? `url('${meta.background}')` : '';
    const st = pstate();
    const moviePct = t.type === 'movie' ? pctOf(st, { id: imdb }) : 0;
    const b = $('detail-body');
    b.innerHTML = `<div class="d-head"><img class="d-poster" src="${meta.poster || t.poster || ''}">
        <div><h2>${meta.name}</h2>
        <div class="d-meta">${meta.year || ''}${meta.runtime ? ' · ' + meta.runtime : ''} · ⭐ ${meta.imdbRating || '—'}${(meta.genres || []).length ? ' · ' + meta.genres.slice(0, 3).join(', ') : ''}</div>
        <div class="d-desc">${meta.description || ''}</div>
        <div class="d-btns">
          ${t.type === 'movie' && hasService() && ck.dlStart ? `<button class="ghost" id="d-download">⬇ Download</button>` : ''}
          <button class="ghost hidden" id="d-trailer">🎬 Trailer</button>
          <button class="ghost" id="d-list"></button>
          <button class="ghost" id="d-watched"></button>
          <button class="ghost" id="d-up" title="Thumbs up — For You shows more like this"></button>
          <button class="ghost" id="d-down" title="Thumbs down — hidden from For You"></button>
        </div>
        <div id="d-cast" class="cast-row"></div>
        <div id="d-wtw" class="wtw"></div>
        </div></div>
        <div id="d-eps"></div><div id="d-streams" class="streams"></div>`;
    // trailer (AJ Sep 13: web had no trailer option) — plays in an in-app overlay
    const ytId = meta.trailers?.[0]?.source || meta.trailerStreams?.[0]?.ytId || null;
    if (ytId) { $('d-trailer').classList.remove('hidden'); $('d-trailer').onclick = () => playTrailerWeb(ytId); }
    // clickable cast (AJ Sep 13) — name chips open the same person page search results use
    const castHolder = $('d-cast');
    for (const nm of (meta.cast || []).slice(0, 10)) {
        const c = document.createElement('span'); c.className = 'chip chip-cast'; c.textContent = nm;
        c.onclick = async () => {
            const r = await j(`https://api.themoviedb.org/3/search/person?query=${encodeURIComponent(nm)}&api_key=${TMDB}`);
            const hit = r?.results?.[0];
            if (hit) personPage({ id: hit.id, name: hit.name, role: 'Actor',
                photo: hit.profile_path ? `https://image.tmdb.org/t/p/w185${hit.profile_path}` : null });
        };
        castHolder.appendChild(c);
    }
    const tt = { id: imdb, type: t.type, name: meta.name, poster: meta.poster || t.poster || '' };
    const paintBtns = () => {
        const st = pstate();
        $('d-list').textContent = (st.watchlist || []).some(x => x.id === imdb) ? '✓ In My List' : '+ My List';
        $('d-watched').textContent = (st.watchedIds || []).includes(imdb) ? '✓ Watched' : 'Mark watched';
        const rv = ((st.ratings || {})[imdb] || {}).v || 0;
        $('d-up').textContent = rv === 1 ? '👍 Liked' : '👍';
        $('d-down').textContent = rv === -1 ? '👎 Not for me' : '👎';
    };
    $('d-list').onclick = () => { if (S.guest) return gate('My List syncs across your devices with a free account.'); toggleList(tt); paintBtns(); };
    $('d-watched').onclick = () => { if (S.guest) return gate('Watch history syncs across your devices with a free account.'); toggleWatchedTitle(tt); paintBtns(); };
    $('d-up').onclick = () => { if (S.guest) return gate('Ratings shape your For You with a free account.'); setRating(imdb, 1); paintBtns(); };
    $('d-down').onclick = () => { if (S.guest) return gate('Ratings shape your For You with a free account.'); setRating(imdb, -1); paintBtns(); };
    paintBtns();
    if (!hasService()) whereToWatch(imdb, t.type);   // tracker shell: providers, not streams
    if (t.type === 'movie') {
        // AJ Sep 27: no Play gate on movies — the stream list loads inline the moment the
        // page opens (Stremio behavior, same as episode pages). Clicking a stream resumes
        // from the saved position; the Resume/CW hero path still auto-plays the top stream.
        if (hasService()) pickStream(imdb, meta.name);
        // Download entry point right on the page (AJ: "no download option in desktop") —
        // a movie poster auto-plays the first stream, so the per-stream ⬇ was never seen.
        // This resolves the best stream, then runs the same lean-pick download flow.
        if (hasService() && ck.dlStart) $('d-download')?.addEventListener('click', () => downloadFor(imdb, meta.name, meta));
    }
    else seasons(meta);
}
// where-to-watch (guest / no-service accounts): TMDB providers, same idea as the TV app
async function whereToWatch(imdb, type) {
    const f = await j(`https://api.themoviedb.org/3/find/${imdb}?api_key=${TMDB}&external_source=imdb_id`);
    const id = f?.[type === 'series' ? 'tv_results' : 'movie_results']?.[0]?.id;
    if (!id) return;
    const d = await j(`https://api.themoviedb.org/3/${type === 'series' ? 'tv' : 'movie'}/${id}/watch/providers?api_key=${TMDB}`);
    const us = d?.results?.US;
    const holder = $('d-wtw'); if (!holder) return;
    if (!us) { holder.innerHTML = '<div class="wtw-kind">Where to watch</div><span class="muted">No streaming info for this title.</span>'; return; }
    let html = '';
    for (const [kind, label] of [['flatrate', 'Stream'], ['free', 'Free'], ['rent', 'Rent'], ['buy', 'Buy']]) {
        const list = us[kind];
        if (!list?.length) continue;
        // every chip LINKS OUT to the watch page (AJ: "buy rent and watch should all be links")
        html += `<div class="wtw-kind">${label}</div>` + list.slice(0, 8).map(p =>
            `<a class="prov" href="#" data-ext="${us.link || 'https://www.themoviedb.org'}"><img src="https://image.tmdb.org/t/p/w92${p.logo_path}">${p.provider_name} ↗</a>`).join('');
    }
    holder.innerHTML = html ? `<div class="wtw-kind" style="margin-top:0">Where to watch</div>` + html : '';
}
function seasons(meta) {
    const eps = (meta.videos || []).filter(v => v.season > 0);
    const ss = [...new Set(eps.map(e => e.season))].sort((a, b) => a - b);
    const holder = $('d-eps');
    const bar = document.createElement('div'); bar.className = 'season-row';
    const lbl = document.createElement('div'); lbl.className = 'row-label'; lbl.textContent = 'Episodes';
    const sel = document.createElement('select');
    for (const sn of ss) { const o = document.createElement('option'); o.value = sn; o.textContent = 'Season ' + sn; sel.appendChild(o); }
    bar.append(lbl, sel);
    const list = document.createElement('div');
    holder.replaceChildren(bar, list);
    const paint = (sn) => {
        const st = pstate();
        const pos = st.positions || {};
        const watched = new Set(st.watchedIds || []);
        const doBlur = PREF('blur', false);
        list.innerHTML = '';
        for (const e of eps.filter(x => x.season === sn).sort((a, b) => a.episode - b.episode)) {
            const key = `${cur.imdb}:${e.season}:${e.episode}`;
            const [p, d] = String(pos[key] || '').split('|').map(Number);
            const pct = d > 0 ? Math.round(100 * p / d) : 0;
            const seen = watched.has(key);
            const aired = !e.released || new Date(e.released) <= new Date();
            const el = document.createElement('div'); el.className = 'ep';
            el.style.opacity = aired ? 1 : .45;
            el.innerHTML = `<div class="ep-thumb">
                  <img loading="lazy" src="${e.thumbnail || ''}" class="${doBlur && !seen && aired ? 'blur' : ''}">
                  ${seen ? '<div class="seen">✓</div>' : ''}
                  ${pct > 0 ? `<div class="ebar"><div style="width:${pct}%"></div></div>` : ''}
                </div>
                <div class="et"><b>${e.episode}. ${e.name || ''}</b><span>${(e.released || '').slice(0, 10)}${aired ? '' : ' · not aired'}</span>
                ${e.overview && !(doBlur && !seen) ? `<div class="ep-desc">${e.overview}</div>` : ''}</div>
                ${aired && hasService() && ck.dlStart ? `<button class="ep-eye ep-dl" title="Download for offline">⬇</button>` : ''}
                <button class="ep-eye" title="${seen ? 'Watched — click to unmark' : 'Mark episode watched'}">${seen ? '✓' : '👁'}</button>`;
            // Stremio-style: the episode click opens its own PAGE (facts + streams filling
            // in) — never a toast-and-wait, never streams dumped at the page bottom
            el.onclick = () => aired && episodePage(cur.t, meta, e);
            el.querySelector('.ep-dl')?.addEventListener('click', (ev) => {
                ev.stopPropagation();
                downloadFor(key, `${meta.name} S${e.season}E${e.episode}`, meta);
            });
            el.querySelector('.ep-eye:not(.ep-dl)').onclick = (ev) => {
                ev.stopPropagation();
                if (S.guest) return gate('Track watched episodes with a free account.');
                toggleEpWatched(key); paint(sn);
            };
            list.appendChild(el);
        }
    };
    // open on the season you're currently in (cwlast — synced from every device)
    const last = (pstate().cwlast || {})[cur.imdb];
    const startSn = last ? +(last.split(':')[1] || ss[0]) : ss[0];
    sel.value = ss.includes(startSn) ? startSn : ss[0];
    sel.onchange = () => paint(+sel.value);
    paint(+sel.value);
    // metahub-404 fallback (Sep 13, Bleach TYBW): paint first, then swap in TMDB stills if
    // metahub has none for this show, and repaint the open season in place
    fixEpThumbs(meta).then(ch => { if (ch) paint(+sel.value); }).catch(() => {});
}

/** Probe one metahub episode still; on a miss swap ALL episode thumbnails to TMDB stills.
 *  TMDB may model the show under different season numbering (TYBW = "Bleach season 2",
 *  absolute), so episodes match by air date (exact, then ±1 day for JP-vs-US air dates),
 *  then by unique name, then ordinally when both lists are the same length.
 *  Mutates meta.videos in place; resolves true when anything changed. */
const _epThumbFixed = new Set();
function imgOk(url) {
    return new Promise(res => {
        const im = new Image();
        im.onload = () => res(true); im.onerror = () => res(false);
        setTimeout(() => res(false), 4000);
        im.src = url;
    });
}
async function fixEpThumbs(meta) {
    const id = meta.imdb_id || meta.id || '';
    if (!id || _epThumbFixed.has(id)) return false;
    const eps = (meta.videos || []).filter(v => v.season > 0);
    const probe = eps.find(v => (v.thumbnail || '').includes('episodes.metahub.space'))?.thumbnail;
    if (!probe || await imgOk(probe)) return false;
    _epThumbFixed.add(id);
    try {
        let tv = (await j(`https://api.themoviedb.org/3/find/${id}?api_key=${TMDB}&external_source=imdb_id`))?.tv_results?.[0]?.id;
        if (!tv && meta.name)
            tv = (await j(`https://api.themoviedb.org/3/search/tv?query=${encodeURIComponent(meta.name)}&api_key=${TMDB}`))?.results?.[0]?.id;
        if (!tv) return false;
        const show = await j(`https://api.themoviedb.org/3/tv/${tv}?api_key=${TMDB}`);
        const flat = [];
        for (const s of (show?.seasons || []).filter(s => s.season_number > 0)) {
            const sj = await j(`https://api.themoviedb.org/3/tv/${tv}/season/${s.season_number}?api_key=${TMDB}`);
            for (const e of (sj?.episodes || []))
                flat.push({ date: e.air_date || '', name: (e.name || '').trim().toLowerCase(),
                            still: e.still_path ? `https://image.tmdb.org/t/p/w500${e.still_path}` : '' });
        }
        const withStill = flat.filter(x => x.still);
        if (!withStill.length) return false;
        const byDate = {}; withStill.forEach(x => (byDate[x.date] = byDate[x.date] || []).push(x));
        const byName = {}; withStill.forEach(x => byName[x.name] = (x.name in byName) ? null : x);
        const shift = (d, by) => { const t = new Date(d + 'T00:00:00Z'); if (isNaN(t)) return null; t.setUTCDate(t.getUTCDate() + by); return t.toISOString().slice(0, 10); };
        const sameLen = eps.length === flat.length;
        let changed = false;
        eps.forEach((e, i) => {
            const iso = (e.released || '').slice(0, 10);
            let still = byDate[iso]?.[0]?.still || byDate[shift(iso, 1)]?.[0]?.still || byDate[shift(iso, -1)]?.[0]?.still;
            if (!still) still = byName[(e.name || '').trim().toLowerCase()]?.still || null;
            if (!still && sameLen) still = flat[i].still || null;
            if (still && still !== e.thumbnail) { e.thumbnail = still; changed = true; }
        });
        return changed;
    } catch (_) { return false; }
}

// per-episode watched toggle (eye button — same as the phone/Firestick)
function toggleEpWatched(key) {
    const st = pstate(); st.watchedIds = st.watchedIds || [];
    const i = st.watchedIds.indexOf(key);
    if (i >= 0) { st.watchedIds.splice(i, 1); st.removedTs = stamp(st.removedTs, 'wt:' + key); }
    else { st.watchedIds.push(key); st.addedTs = stamp(st.addedTs, key); st.addedTs = stamp(st.addedTs, 'wt:' + key); }
    pushAccount();
}

// ---------- episode page (Stremio-style, mirrors the TV app's showEpisodeDetail) ----------
let epPollToken = 0;
async function episodePage(t, meta, ep, autoplay = false) {
    cur = { imdb: meta.id, type: 'series', meta, t: { ...t, id: meta.id } };
    const sid = `${meta.id}:${ep.season}:${ep.episode}`;
    const label = `${meta.name} S${ep.season}E${ep.episode}`;
    nav('episode');
    $('episode-backdrop').style.backgroundImage =
        (meta.background || ep.thumbnail || meta.poster) ? `url('${meta.background || ep.thumbnail || meta.poster}')` : '';
    $('ep-back').onclick = () => detail(cur.t);
    const body = $('episode-body');
    const st = pstate();
    const [p, d] = String((st.positions || {})[sid] || '').split('|').map(Number);
    const resumePct = p > 60000 && d > 0 ? Math.round(100 * p / d) : 0;
    // logo (or name) big, then "year · SxxEyy · air date · name", resume %, description,
    // Mark watched, then the streams strip filling in
    body.innerHTML = `
        ${meta.logo ? `<img class="ep-logo" src="${meta.logo}">` : `<h2>${meta.name}</h2>`}
        <div class="ep-facts">${[meta.year, `S${String(ep.season).padStart(2, '0')}E${String(ep.episode).padStart(2, '0')}`,
            (ep.released || '').slice(0, 10), ep.name].filter(Boolean).join('  ·  ')}</div>
        ${resumePct > 0 ? `<div class="ep-resume">Resume from ${resumePct}%</div>` : ''}
        ${ep.overview || ep.description ? `<div class="d-desc" style="margin:.5rem 0">${ep.overview || ep.description || ''}</div>` : ''}
        <button class="ghost small" id="ep-watched"></button>
        <div class="row-label">Streams</div>
        <div class="muted" id="ep-note">Finding streams…</div>
        <div id="ep-streams" class="streams"></div>`;
    const paintWt = () => {
        $('ep-watched').textContent = (pstate().watchedIds || []).includes(sid) ? '✓ Watched' : 'Mark watched';
    };
    $('ep-watched').onclick = () => { if (S.guest) return gate('Track watched episodes with a free account.'); toggleEpWatched(sid); paintWt(); };
    paintWt();
    if (!hasService()) { $('ep-note').textContent = 'Streams need a connected account.'; return; }
    // a just-aired episode is usually still CACHING — poll every 15s (up to ~3 min) and
    // fill streams in the moment the download lands (same rule as the Firestick)
    const token = ++epPollToken;
    const base = S.addons[0].url.replace(/\/$/, '');
    let streams = [], tries = 0;
    const fetchStreams = async () =>
        (await j(`${withUser(base)}/stream/series/${encodeURIComponent(sid)}.json`, { timeoutMs: 30000 }))?.streams || [];
    streams = await fetchStreams();
    const aired = !ep.released || new Date(ep.released) <= new Date();
    while (!streams.length && aired && tries < 12 && token === epPollToken && page === 'episode') {
        $('ep-note').textContent = 'Getting this episode ready — it’ll appear here in a minute or two…';
        await new Promise(r => setTimeout(r, 15000));
        if (token !== epPollToken || page !== 'episode') return;
        streams = await fetchStreams();
        tries++;
    }
    if (token !== epPollToken) return;
    if (!streams.length) {
        $('ep-note').textContent = !aired ? 'This episode hasn’t aired yet.' : 'Still getting this ready — check back in a minute.';
        return;
    }
    $('ep-note').classList.add('hidden');
    const holder = $('ep-streams');
    holder.innerHTML = '';
    for (const s of streams) {
        const el = streamEl(s);
        // ckNotice (AJ Sep 16): "hasn't aired yet"-style rows are info banners, not buttons
        if (!s.ckNotice) el.onclick = () => playEpisodeStream(s, meta, ep, sid, label);
        holder.appendChild(el);
    }
    const auto0 = streams.find(s => !s.ckNotice);
    if (autoplay && auto0) playEpisodeStream(auto0, meta, ep, sid, label);
}
function playEpisodeStream(s, meta, ep, sid, label) {
    ckEpTouched = false;   // fresh episode, fresh still-watching slate
    // Continue Watching means you PLAYED it — not that you looked at the page
    if (!S.guest) {
        pushContinueLocal({ id: meta.id, type: 'series', name: meta.name, poster: meta.poster || '' });
        const st = pstate();
        st.cwlast = { ...(st.cwlast || {}), [meta.id]: sid };
        pushAccount();
    }
    play(s.url, label, sid, s.subtitles || null);
}

// ---------- streams + play ----------
/** In-app trailer overlay (AJ Sep 13: "why not in our player, in our app") — a YouTube
 *  embed runs from the viewer's own IP, so no bot-wall; ESC or ✕ closes. */
function playTrailerWeb(ytId) {
    if (ck.platform !== 'web' && ck.openTrailer) { ck.openTrailer(ytId); return; }
    const cover = document.createElement('div');
    cover.id = 'trailer-cover';
    cover.style.cssText = 'position:fixed;inset:0;z-index:9998;background:rgba(5,4,12,.96);display:flex;align-items:center;justify-content:center';
    cover.innerHTML = `<iframe width="80%" style="aspect-ratio:16/9;border:0;border-radius:12px"
        src="https://www.youtube-nocookie.com/embed/${ytId}?autoplay=1&rel=0" allow="autoplay; fullscreen" allowfullscreen></iframe>
        <button style="position:absolute;top:18px;right:22px;background:#2a2545;color:#fff;border:none;border-radius:999px;padding:.5rem .9rem;cursor:pointer;font-size:1rem">✕ Close</button>`;
    const close = () => { cover.remove(); document.removeEventListener('keydown', esc); };
    const esc = (e) => { if (e.key === 'Escape') close(); };
    cover.querySelector('button').onclick = close;
    cover.onclick = (e) => { if (e.target === cover) close(); };
    document.addEventListener('keydown', esc);
    document.body.appendChild(cover);
}

/** One stream row, prettier (AJ Sep 13 "make the streams look better"): source name,
 *  quality/flavor as chips, episode line under it, ⏳ notes highlighted. */
function streamEl(st) {
    const el = document.createElement('div'); el.className = st.ckNotice ? 'stream ck-notice' : 'stream';
    const parts = String(st.name || '').split('|').map(x => x.trim()).filter(Boolean);
    const src = parts.shift() || 'Stream';
    const lines = String(st.description || st.title || '').split('\n');
    el.innerHTML = `<div class="stream-top"><b>${src}</b>${parts.map(c =>
            `<span class="chip chip-${c.toLowerCase().replace(/[^a-z0-9]/g, '')}">${c}</span>`).join('')}</div>
        <div class="stream-title">${lines[0] || ''}</div>
        ${lines[1] ? `<div class="stream-note">${lines[1]}</div>` : ''}`;
    return el;
}

async function pickStream(sid, label, autoFirst = false) {
    if (!hasService()) return;   // tracker shell: no stream fetches without a service
    const holder = $('d-streams');
    holder.innerHTML = '<div class="muted">Finding streams…</div>';
    const base = S.addons[0].url.replace(/\/$/, '');
    const type = sid.includes(':') ? 'series' : 'movie';
    const d = await j(`${withUser(base)}/stream/${type}/${encodeURIComponent(sid)}.json`, { timeoutMs: 30000 });
    const streams = d?.streams || [];
    if (!streams.length) { holder.innerHTML = '<div class="muted">Getting this ready — try again in a minute.</div>'; return; }
    const start = (st) => {
        if (!S.guest && cur?.meta) {
            pushContinueLocal({ id: sid.split(':')[0], type, name: cur.meta.name, poster: cur.meta.poster || '' });
            pushAccount();
        }
        play(st.url, label, sid, st.subtitles || null);
    };
    const _auto0 = streams.find(s => !s.ckNotice);
    if (autoFirst && _auto0) { start(_auto0); return; }
    holder.innerHTML = '<div class="row-label">Streams</div>';
    for (const st of streams) {
        const el = streamEl(st);
        if (!st.ckNotice) el.onclick = () => start(st);
        // desktop: one-tap offline download per stream (web can't hold GBs — no button)
        if (ck.dlStart && !st.ckNotice) {
            const dl = document.createElement('button');
            dl.className = 'ghost small dl-btn'; dl.textContent = '⬇'; dl.title = 'Download for offline';
            dl.onclick = (ev) => { ev.stopPropagation(); startDownload(st, sid, label); };
            el.appendChild(dl);
        }
        holder.appendChild(el);
    }
}

// ---------- OFFLINE DOWNLOADS (desktop only — ck.dlStart exists only under Electron) ----
// AJ Sep 14 spec: easy download, easy delete, Movies + Shows grouped (show → seasons →
// episodes), and offline play keeps EVERYTHING — subs, skip-intro, credits/up-next.
// downloads are PER ACCOUNT+PROFILE (AJ Sep 14): the key carries the profile, the list
// filters on it — grandma's profile never sees (or deletes) yours on a shared machine
const profKey = () => (S.email || 'guest') + '|' + (S.pid || '');
const dlKeyOf = (sid) => (profKey() + '_' + String(sid || '')).replace(/[^\w]+/g, '_');
// Page-level Download button (movie page / episode row): resolve the stream list first,
// then hand the best one to the same lean-pick flow the per-stream ⬇ uses. cur.meta must
// point at the title being downloaded so posters/names on the Downloads page are right.
async function downloadFor(sid, label, meta) {
    if (!hasService() || !ck.dlStart) return;
    if (meta) cur = { ...(cur || {}), meta, imdb: sid.split(':')[0] };
    toast('Finding a stream…');
    const base = S.addons[0].url.replace(/\/$/, '');
    const type = sid.includes(':') ? 'series' : 'movie';
    const d = await j(`${withUser(base)}/stream/${type}/${encodeURIComponent(sid)}.json`, { timeoutMs: 30000 });
    const st = (d?.streams || [])[0];
    if (!st) { toast('No stream to download yet — try again shortly'); return; }
    startDownload(st, sid, label);
}
async function startDownload(st, sid, label) {
    const imdb = sid.split(':')[0]; const [, s, e] = sid.split(':');
    // LEAN PICK (AJ Sep 14, "Black Panther is 7.9GB"): the visible list is quality-ranked
    // top-3 — /dlpick scans the FULL candidate pool server-side and offers the smallest
    // healthy H264 per tier with real sizes. Decline 1080p → offered 720p → abort.
    let dlUrl = st.url, dlSubs = st.subtitles || [];
    let picked = false;
    try {
        const d = await j(`${SERVICE}/dlpick/${S.subKey}?i=${imdb}&s=${s || ''}&e=${e || ''}&t=${encodeURIComponent(cur?.meta?.name || label)}&u=${encodeURIComponent(S.useg)}`);
        for (const o of (d?.options || [])) {
            if (await ckAsk(`Download ${cur?.meta?.name || label}?`, `${o.q} — ${gb(+o.bytes || 0)}`, 'Download')) {
                dlUrl = o.url; picked = true;
                if (d.subtitles?.length) dlSubs = d.subtitles;
                break;
            }
        }
        if (!picked && (d?.options || []).length) return;   // saw real options, declined all
    } catch {}
    // no lean options (rare/offline titles): confirm the clicked stream's real size instead
    if (!picked && ck.dlSize) {
        const { bytes } = await ck.dlSize(st.url);
        if (bytes > 0 && !(await ckAsk(`Download ${cur?.meta?.name || label}?`,
            gb(bytes) + (bytes > 5e9 ? ' — that’s a big file' : ''), 'Download'))) return;
    }
    // capture the learned intro/credits windows NOW — offline play can't ask later
    let introFromMs = -1, introToMs = -1, creditsMs = 0;
    try {
        const r = await j(`${SERVICE}/player/resume?k=${S.subKey}&u=${encodeURIComponent(S.useg)}&i=${imdb}&s=${s || ''}&e=${e || ''}`);
        if (r) {
            if (r.introFrom != null && r.introTo > r.introFrom) { introFromMs = r.introFrom; introToMs = r.introTo; }
            if (r.credits > 0) creditsMs = r.credits;
        }
    } catch {}
    const res = await ck.dlStart({ sid, prof: profKey(), url: dlUrl, title: label, poster: cur?.meta?.poster || '',
        kind: sid.includes(':') ? 'episode' : 'movie', showName: cur?.meta?.name || label, epName: label,
        season: +s || 0, episode: +e || 0, subs: dlSubs,
        introFromMs, introToMs, creditsMs, capGB: PREF('dlcap', 30) });
    toast(res?.ok ? '⬇ Downloading — see Downloads in the sidebar' : 'Download failed: ' + (res?.error || 'unknown'));
}
const gb = (n) => (n / 1e9).toFixed(1) + ' GB';
async function downloadsPage() {
    const body = $('downloads-body');
    if (!ck.dlList) { body.innerHTML = '<p class="muted">Downloads are a desktop-app feature.</p>'; return; }
    const items = (await ck.dlList()).filter(m => (m.prof || '') === profKey());
    body.innerHTML = `<h2>Downloads</h2>
        <div class="dl-opts muted">
          <label><input type="checkbox" id="dl-autodel" ${PREF('dlautodel', false) ? 'checked' : ''}> Auto-delete watched</label>
          <label style="margin-left:1.2rem">Storage cap
            <input type="number" id="dl-cap" min="5" max="500" value="${PREF('dlcap', 30)}" style="width:4.5rem"> GB</label>
          <span style="margin-left:1.2rem">${items.length ? 'Using ' + gb(items.reduce((a, x) => a + (x.bytes || 0), 0)) : ''}</span>
        </div>`;
    $('dl-autodel').onchange = (e2) => localStorage.setItem('ckp-dlautodel', JSON.stringify(e2.target.checked));
    $('dl-cap').onchange = (e2) => localStorage.setItem('ckp-dlcap', JSON.stringify(Math.max(5, +e2.target.value || 30)));
    if (!items.length) { body.insertAdjacentHTML('beforeend', '<p class="muted">Nothing downloaded yet — hit ⬇ on any stream.</p>'); return; }
    const row = (m) => {
        const d = document.createElement('div'); d.className = 'dl-row'; d.dataset.key = m.key;
        const pctTxt = m.done ? gb(m.bytes || 0) : (m.active ? `downloading… ${gb(m.bytes || 0)}${m.est ? ' of ~' + gb(m.est) : ''}` : 'failed');
        d.innerHTML = `<img src="${IMG(m.poster, 154)}" onerror="this.style.visibility='hidden'">
            <div class="dl-info"><b>${m.kind === 'episode' ? `S${m.season}E${m.episode} — ${m.epName || m.title}` : m.title}</b>
            <span class="muted dl-size">${pctTxt}</span></div>
            <button class="primary small">▶ Play</button><button class="ghost small">🗑 Delete</button>`;
        const [playB, delB] = d.querySelectorAll('button');
        playB.onclick = () => m.done && playDownload(m);
        delB.onclick = async () => { await ck.dlDelete(m.key); toast('Deleted — space freed'); downloadsPage(); };
        return d;
    };
    const movies = items.filter(x => x.kind !== 'episode').sort((a, b) => b.ts - a.ts);
    if (movies.length) {
        body.insertAdjacentHTML('beforeend', '<div class="row-label">Movies</div>');
        movies.forEach(m => body.appendChild(row(m)));
    }
    const shows = {};
    for (const it of items.filter(x => x.kind === 'episode')) (shows[it.showName || it.sid.split(':')[0]] ??= []).push(it);
    if (Object.keys(shows).length) body.insertAdjacentHTML('beforeend', '<div class="row-label">Shows</div>');
    for (const [name, eps] of Object.entries(shows)) {
        const det = document.createElement('details'); det.className = 'dl-show';
        det.innerHTML = `<summary><b>${name}</b> <span class="muted">${eps.length} episode${eps.length > 1 ? 's' : ''} · ${gb(eps.reduce((a, x) => a + (x.bytes || 0), 0))}</span></summary>`;
        const bySeason = {};
        for (const ep2 of eps) (bySeason[ep2.season] ??= []).push(ep2);
        for (const sn of Object.keys(bySeason).sort((a, b) => a - b)) {
            det.insertAdjacentHTML('beforeend', `<div class="row-label" style="font-size:.9em">Season ${sn}</div>`);
            bySeason[sn].sort((a, b) => a.episode - b.episode).forEach(m => det.appendChild(row(m)));
        }
        body.appendChild(det);
    }
}
function playDownload(m) {
    const [, s, e] = String(m.sid).split(':');
    const st = pstate();
    const [lp, ld] = String((st.positions || {})[m.sid] || '').split('|').map(Number);
    const startSec = (lp > 60000 && ld > 0 && lp / ld < 0.92) ? Math.floor(lp / 1000) : 0;
    const label = m.kind === 'episode' ? `${m.showName} S${m.season}E${m.episode}` : m.title;
    playing = { sid: m.sid, imdb: m.sid.split(':')[0], s, e, label, pos: 0, dur: 0,
                startMs: startSec * 1000, credits: m.creditsMs || 0, next: null };
    const fileUrl = encodeURI('file://' + (m.file.startsWith('/') ? '' : '/') + m.file.replace(/\\/g, '/'));
    ckPlay({ localFile: fileUrl, url: m.file, title: label, startSec, sid: m.sid,
        inlineSubs: m.subs || [], probeDur: m.durSec || 0,
        introFromMs: m.introFromMs ?? -1, introToMs: m.introToMs ?? -1, creditsMs: m.creditsMs || 0,
        subScale: PREF('subscale', 1.0), subLang: PREF('sublang', 'en'), subBg: PREF('subbg', false),
        subOutline: PREF('suboutline', true), subPos: PREF('subpos', 0), seekStep: PREF('seek', 10),
        hasNext: false, autonext: false });
}
// live progress on the Downloads page; errors surface as toasts wherever you are
ck.onDlProg?.((d) => {
    if (page !== 'downloads') return;
    const el = document.querySelector(`.dl-row[data-key="${d.key}"] .dl-size`);
    if (el) el.textContent = `downloading… ${gb(d.got)}${d.est ? ' of ~' + gb(d.est) : ''}`;
});
ck.onDlDone?.(() => { toast('⬇ Download finished'); if (page === 'downloads') downloadsPage(); });
ck.onDlErr?.((d) => toast('Download failed: ' + (d?.error || '')));

function nextEpisodeOf(sid) {
    if (!cur?.meta?.videos || !sid.includes(':')) return null;
    const [, s, e] = sid.split(':');
    const eps = cur.meta.videos.filter(v => v.season > 0).sort((a, b) => a.season - b.season || a.episode - b.episode);
    const i = eps.findIndex(x => x.season == s && x.episode == e);
    if (i < 0) return null;
    return eps.slice(i + 1).find(x => !x.released || new Date(x.released) <= new Date()) || null;
}

// stale-cache insurance (web only): a browser holding yesterday's ck-web.js next to
// today's app.js still plays — the old single-engine path is a perfect stand-in
window.ckPlay = window.ckPlay || ((o) => ck.play(o));
window.ckOnPos = window.ckOnPos || ((cb) => ck.onMpvPos(cb));
window.ckOnExit = window.ckOnExit || ((cb) => ck.onMpvExit(cb));
window.ckStop = window.ckStop || (() => ck.stopPlay());
let playing = null;
async function play(url, label, sid, subs = null) {
    const imdb = sid.split(':')[0];
    const [, s, e] = sid.split(':');
    // cross-device resume + learned intro window + learned credits point, one call
    let startSec = 0, introFromMs = -1, introToMs = -1, creditsMs = 0, acList = [];
    try {
        const r = await j(`${SERVICE}/player/resume?k=${S.subKey}&u=${encodeURIComponent(S.useg)}&i=${imdb}&s=${s || ''}&e=${e || ''}`);
        if (r) {
            if (String(r.s || '') === String(s || '') && String(r.e || '') === String(e || '') && r.pos > 60000 && r.pct < 92)
                startSec = Math.floor(r.pos / 1000);
            if (r.introFrom != null && r.introTo > r.introFrom) { introFromMs = r.introFrom; introToMs = r.introTo; }
            if (r.credits > 0) creditsMs = r.credits;
            if (Array.isArray(r.afterCredits)) acList = r.afterCredits;
        }
    } catch {}
    // whichever device is further in wins — but a local synced position can be fresher
    const [lp, ld] = String((pstate().positions || {})[sid] || '').split('|').map(Number);
    if (lp > 60000 && ld > 0 && lp / ld < 0.92 && lp / 1000 > startSec) startSec = Math.floor(lp / 1000);
    const next = nextEpisodeOf(sid);
    playing = { sid, imdb, s, e, label, pos: 0, dur: 0, startMs: startSec * 1000, credits: creditsMs, next };
    // 0.9.13: desktop plays IN-WINDOW through the same player as the web (AJ: raw mpv
    // window is "awful") — mpv only takes over for codecs Chromium can't decode, silently;
    // the banner below only appears in that mpv case (ck-engine event)
    await ckPlay({ url, title: label, startSec, sid, subs: subs || [],
        subScale: PREF('subscale', 1.0), subLang: PREF('sublang', 'en'), audioLang: PREF('audlang', 'en'),
        subBg: PREF('subbg', false), subOutline: PREF('suboutline', true), subPos: PREF('subpos', 0),
        seekStep: PREF('seek', 10),
        introFromMs, introToMs, creditsMs, afterCredits: acList,
        hasNext: !!(next && hasService()), autonext: PREF('autonext', true),
        nextLabel: next ? `${cur?.meta?.name || ''} S${next.season}E${next.episode}${next.name ? ' — ' + next.name : ''}` : '' });
}
// mpv fallback engaged (HEVC & co.) — its window is external, so surface the little
// "Now Playing / Stop" banner exactly like pre-0.9.13 desktop always did
document.addEventListener('ck-engine', (e) => {
    if (e.detail === 'mpv' && playing) {
        $('playing-title').textContent = playing.label;
        $('playing').classList.remove('hidden');
    }
});
ck.onMpvDead?.((d) => {
    // phone-home the real failure so it can be fixed without the user doing anything
    try {
        j(`${SERVICE}/tvapp/diag`, { method: 'POST', body: { email: S.email, token: S.token,
            text: `desktop mpv died: code=${d?.code} sig=${d?.signal} bin=${(d?.bin || '').split('/').slice(-4).join('/')} err=${(d?.err || '').slice(-600)}` } });
    } catch {}
    // mpv died instantly (macOS killed the binary / broken install) — say so and offer
    // the in-window fallback instead of silently doing nothing (AJ Sep 13, Mac)
    const n = document.createElement('div');
    n.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:9999;' +
        'background:#2a1e1e;color:#ffb3b3;border:1px solid #663;border-radius:10px;padding:.8rem 1.2rem;max-width:640px;text-align:center';
    n.innerHTML = 'The video engine was blocked by macOS. <b>Update to the latest version from couchking.app/downloads</b> — it fixes this. (Playback also works at couchking.app/app meanwhile.)';
    document.body.appendChild(n);
    setTimeout(() => n.remove(), 12000);
});

ckOnPos(({ pos, dur }) => {
    if (!playing) return;
    playing.pos = pos; playing.dur = dur;
    if (dur > 0) $('playing-pos').textContent = `${fmt(pos)} / ${fmt(dur)}`;
    // instant start-stamp (AJ Sep 13, full-sync): the moment playback begins, position +
    // resume pointer push to the account — every other device knows within seconds,
    // half a second of watching counts (same rule as TV v2.0)
    if (dur > 0 && !playing.startStamped && !S.guest) {
        playing.startStamped = true;
        const st = pstate();
        st.positions = st.positions || {};
        st.positions[playing.sid] = `${Math.max(Math.round(pos * 1000), 500)}|${Math.round(dur * 1000)}|${Date.now()}`;
        if (playing.s) st.cwlast = { ...(st.cwlast || {}), [playing.imdb]: playing.sid };
        Promise.resolve(pushAccount()).catch(() => {});
    }
});
// position where the episode is "basically over" (credits rolling) — same rule as the
// TV player: credits lead (subs-last-cue → learned clicks → 90s), FLOORED at 80%
function finishPointSec(durSec, creditsMs, lastCueSec, isShow) {
    const subsLead = lastCueSec > 0 ? durSec - lastCueSec - 2 : -1;
    const lead = (subsLead >= 15 && subsLead <= 300) ? subsLead
        : (creditsMs > 0 ? Math.min(240, Math.max(20, (creditsMs + 5000) / 1000)) : 90);
    // CAP (AJ Sep 28, parity w/ TV 2.0.123): finished by 90% (movies) / 92% (shows) so a
    // long-credits movie marks watched + leaves Continue Watching without sitting through credits.
    const cap = durSec * (isShow ? 0.92 : 0.90);
    return Math.min(Math.max(durSec - lead, durSec * 0.8), cap);
}
ckOnExit(async ({ pos, dur, next = false, credits = 0, lastCue = 0 }) => {
    $('playing').classList.add('hidden');
    const p = playing; playing = null;
    if (!p || !dur || pos < 0.5) { if (p && next) advanceNext(p); return; }   // 0.5s floor (AJ Sep 13, was 5s)
    const posMs = Math.floor(pos * 1000), durMs = Math.floor(dur * 1000);
    // one beacon per sit-down — powers For You + cross-device resume (same as TV app);
    // a human's next-click near the end also teaches the server where credits start
    await j(`${SERVICE}/player/progress`, { method: 'POST', body: {
        k: S.subKey, u: S.useg, i: p.imdb, s: p.s || '', e: p.e || '',
        pos: posMs, dur: durMs,
        ...(next && credits >= 5000 && credits <= 300000 ? { credits } : {}) } });
    // the exact same watched rule as the Firestick: only past the finish point (credits
    // lead, ≥80% floor) AND a real sitting (2+ min or true end) — a bogus near-end
    // landing + immediate back must NOT count as watched
    const finish = finishPointSec(dur, p.credits, lastCue, !!p.s);
    // false-watched fix (mirror of Firestick): a short/broken/wrong stream can fire
    // 'ended' with pos≈dur of the SHORT file, which used to satisfy `posMs >= durMs-5000`
    // and mark the real episode watched at ~4%. Started-near-the-top + <2min played must
    // NEVER count; only a genuine RESUME near the end (started deep, p.startMs≥2min) does.
    const realSit = posMs - p.startMs >= 120000 || p.startMs >= 120000;
    const watchedNow = pos >= finish && realSit;
    // finished a downloaded copy + "Auto-delete watched" on → space back immediately
    if (watchedNow && ck.dlDelete && PREF('dlautodel', false)) try { ck.dlDelete(dlKeyOf(p.sid)); } catch {}
    if (!S.guest) {
        const st = pstate();
        // STAMPED position + cwlast into the synced blob — exactly what the Android apps
        // write, so every device's Continue row and resume % agree with this one
        st.positions = st.positions || {};
        st.positions[p.sid] = `${posMs}|${durMs}|${Date.now()}`;
        if (p.s) st.cwlast = { ...(st.cwlast || {}), [p.imdb]: p.sid };
        if (watchedNow) {
            if (p.s) {   // episode → checkmark (blur-clear + eye sync to every device)
                st.watchedIds = st.watchedIds || [];
                if (!st.watchedIds.includes(p.sid)) { st.watchedIds.push(p.sid); st.addedTs = stamp(st.addedTs, p.sid); st.addedTs = stamp(st.addedTs, 'wt:' + p.sid); }
                // parity w/ TV 2.0.123 (AJ Sep 28): advance Continue Watching to the next unwatched
                // AIRED episode with a fresh (blank) bar; if there's none you're CAUGHT UP, so the
                // SHOW earns the Library "Watched" shelf (only when caught up, not after one episode).
                if (cur?.meta?.id === p.imdb && Array.isArray(cur.meta.videos)) {
                    const eps = cur.meta.videos.filter(v => v.season > 0)
                        .sort((a, b) => a.season - b.season || a.episode - b.episode);
                    const idx = eps.findIndex(x => `${p.imdb}:${x.season}:${x.episode}` === p.sid);
                    const after = idx >= 0 ? eps.slice(idx + 1) : [];
                    const nextAired = after.find(x => (!x.released || new Date(x.released) <= new Date()) &&
                        !st.watchedIds.includes(`${p.imdb}:${x.season}:${x.episode}`));
                    if (nextAired) st.cwlast[p.imdb] = `${p.imdb}:${nextAired.season}:${nextAired.episode}`;   // resume next aired, blank bar
                    else if (after.length === 0) st.watchedTitles = [{ id: p.imdb, type: 'series', name: cur.meta.name || p.label, poster: cur.meta.poster || '' },
                        ...(st.watchedTitles || []).filter(x => x.id !== p.imdb)].slice(0, 60);   // finished the LAST episode → whole series watched
                    else st.cwlast[p.imdb] = `${p.imdb}:${after[0].season}:${after[0].episode}`;   // caught up but an upcoming episode is pending → point at it, don't mark watched
                }
            } else {     // a FINISHED movie leaves Continue Watching (real finish only)
                st.watchedIds = st.watchedIds || [];
                if (!st.watchedIds.includes(p.imdb)) { st.watchedIds.push(p.imdb); st.addedTs = stamp(st.addedTs, p.imdb); st.addedTs = stamp(st.addedTs, 'wt:' + p.imdb); }
                st.watchedTitles = [{ id: p.imdb, type: 'movie', name: cur?.meta?.name || p.label, poster: cur?.meta?.poster || '' },
                    ...(st.watchedTitles || []).filter(x => x.id !== p.imdb)].slice(0, 60);
                st.continue = (st.continue || []).filter(x => x.id !== p.imdb);
                st.removedTs = stamp(st.removedTs, 'cw:' + p.imdb);   // leave CW without touching the mark
                st.removedTs = stamp(st.removedTs, 'pos:' + p.imdb);
                delete st.positions[p.imdb];
            }
        }
        await pushAccount();
        lastSyncSig = syncSig();
    }
    if (page === 'home') { hero(pstate()); paintContinueRow(); }
    if (page === 'detail' && cur?.meta && p.s) seasons(cur.meta);
    // AUTOPLAY NEXT: an explicit next-click always advances; a natural finish advances
    // when the setting is on and the episode really ended
    if (p.s && (next || (PREF('autonext', true) && watchedNow && pos >= dur - 5))) {
        // "ARE YOU STILL WATCHING?" (AJ Sep 25): two whole episodes with zero inputs →
        // ask before the third. Any key/click/tap during an episode resets the chain and
        // an explicit next-click resets it too — normal watching can never summon it.
        if (next) { ckIdleEps = 0; advanceNext(p); }
        else {
            if (ckEpTouched) ckIdleEps = 0; else ckIdleEps++;
            if (ckIdleEps >= 2) ckStillWatching(p); else advanceNext(p);
        }
    }
});
let ckIdleEps = 0, ckEpTouched = false;
for (const ev of ['pointerdown', 'keydown', 'touchstart', 'wheel'])
    document.addEventListener(ev, () => { ckEpTouched = true; }, true);
function ckStillWatching(p) {
    if (document.getElementById('ck-staywatch')) return;
    const ov = document.createElement('div');
    ov.id = 'ck-staywatch';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100000;background:rgba(8,6,20,.88);display:flex;align-items:center;justify-content:center;';
    const card = document.createElement('div');
    card.style.cssText = 'background:#1B1830;border:1px solid #2C2649;border-radius:22px;padding:30px 34px 24px;max-width:380px;width:90%;text-align:center;box-shadow:0 12px 60px rgba(123,91,245,.28);';
    const crown = document.createElement('div');
    crown.style.cssText = 'font-size:2.3rem;line-height:1;margin-bottom:10px;';
    crown.textContent = '\u{1F451}';
    card.appendChild(crown);
    const title = document.createElement('div');
    title.style.cssText = 'color:#fff;font-size:1.25rem;font-weight:700;';
    title.textContent = 'Are you still watching?';
    card.appendChild(title);
    const name = (cur?.meta?.name || p.label || '').toString();
    if (name) {
        const sub = document.createElement('div');
        sub.style.cssText = 'color:#A9A5C0;font-size:.95rem;margin-top:8px;';
        sub.textContent = name;
        card.appendChild(sub);
    }
    const mkBtn = (label, bg) => {
        const b = document.createElement('button');
        b.textContent = label;
        b.style.cssText = `display:block;width:100%;margin-top:12px;padding:13px;border:none;border-radius:999px;background:${bg};color:#fff;font-weight:700;font-size:1rem;cursor:pointer;`;
        b.onfocus = () => b.style.outline = '2px solid #fff';
        b.onblur = () => b.style.outline = 'none';
        card.appendChild(b);
        return b;
    };
    const keep = mkBtn('Keep watching', '#7B5BF5');
    const done = mkBtn("I'm done for now", '#2C2649');
    const hint = document.createElement('div');
    hint.style.cssText = 'color:#6A6590;font-size:.8rem;margin-top:14px;';
    hint.textContent = "No answer in 5 minutes and we'll tuck the stream in for the night \u{1F634}";
    card.appendChild(hint);
    ov.appendChild(card);
    document.body.appendChild(ov);
    let ended = false;
    let tm = 0;
    const close = () => { ended = true; clearTimeout(tm); window.removeEventListener('keydown', trap, true); ov.remove(); };
    keep.onclick = (e) => { e.stopPropagation(); close(); ckIdleEps = 0; ckEpTouched = false; advanceNext(p); };
    done.onclick = (e) => { e.stopPropagation(); close(); try { ckStop(); } catch {} };
    // MODAL (AJ: "the only buttons you can click — it won't fall behind"): every key is
    // trapped up here; arrows/tab hop between the two buttons, everything else is eaten,
    // and the full-screen scrim swallows clicks so nothing behind is reachable.
    const trap = (e) => {
        if (ended) return;
        e.stopImmediatePropagation();
        if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Tab'].includes(e.key)) {
            e.preventDefault(); (document.activeElement === keep ? done : keep).focus();
        } else if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault(); (document.activeElement === done ? done : keep).click();
        } else e.preventDefault();
    };
    window.addEventListener('keydown', trap, true);
    keep.focus();
    // walked away: stop the stream after 5 minutes instead of playing to an empty room
    tm = setTimeout(() => { if (!ended) { close(); try { ckStop(); } catch {} try { profileManager(); } catch {} } }, 5 * 60 * 1000);   // timeout -> who's watching (AJ Sep 25)
}
function advanceNext(p) {
    const nxt = p.next || nextEpisodeOf(p.sid);
    if (!nxt || !cur?.meta) return;
    episodePage(cur.t || { id: p.imdb, type: 'series' }, cur.meta, nxt, true);
}
const fmt = (s) => { s = Math.floor(s); const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60); return (h ? h + ':' : '') + String(m).padStart(h ? 2 : 1, '0') + ':' + String(s % 60).padStart(2, '0'); };
$('playing-stop').onclick = () => ckStop();

// ---------- wiring ----------
$('auth-signin').onclick = () => auth('signin');
$('auth-signup').onclick = () => auth('signup');
$('auth-guest').onclick = () => guest();
$('back').onclick = () => { nav('home'); };

(async () => {
    SERVICE = await ck.service();
    if (ck.dlStart) $('rail-downloads')?.classList.remove('hidden');   // desktop only
    const saved = JSON.parse(localStorage.getItem('ck') || 'null');
    if (saved?.token) { S.email = saved.email; S.token = saved.token; await bootstrap(); }
    else show('auth');
    checkUpdate();
})();

// ---------- self-update pill (same yellow-button flow as the TV player app) ----------
// Polls couchking.app/desktop/version.json on open; a newer version shows a pill that
// opens the right installer (.exe / .dmg) in the browser — run it and you're updated.
ck.onUpdReady?.((d) => {
    // Windows: the update is already downloaded — one click installs + relaunches
    document.getElementById('update-pill')?.remove();
    const b = document.createElement('button');
    b.id = 'update-pill';
    b.textContent = `⟳ Restart to update${d?.version ? ' · v' + d.version : ''}`;
    b.style.cssText = 'position:fixed;top:14px;right:16px;z-index:999;background:#f5c518;color:#1a1400;' +
        'border:none;border-radius:999px;padding:.45rem 1rem;font-weight:700;cursor:pointer;' +
        'box-shadow:0 2px 12px rgba(245,197,24,.4)';
    b.onclick = () => ck.applyUpdate();
    document.body.appendChild(b);
});

async function checkUpdate() {
    if (ck.platform === 'win32' && ck.applyUpdate) return;  // in-app updater owns Windows now
    if (ck.platform === 'web') return;   // browser version is always current
    try {
        const cur = await ck.version();
        const r = await j(`${SERVICE}/desktop/version.json`);
        if (!r?.version) return;
        const cmp = (a, b) => {
            const A = String(a).split('.').map(Number), B = String(b).split('.').map(Number);
            for (let i = 0; i < 3; i++) if ((A[i] || 0) !== (B[i] || 0)) return (A[i] || 0) - (B[i] || 0);
            return 0;
        };
        if (cmp(r.version, cur) <= 0) return;
        const url = ck.platform === 'darwin' ? r.mac : r.win;
        if (!url) return;
        // MANDATORY (AJ Sep 13, updates everywhere): below minVersion the whole app blocks
        // behind a full-screen update panel — version skew is what breaks cross-device sync
        const mandatory = r.minVersion && cmp(r.minVersion, cur) > 0;
        if (mandatory) {
            const cover = document.createElement('div');
            cover.id = 'update-block';
            cover.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(10,8,20,.97);' +
                'display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;color:#fff;text-align:center';
            cover.innerHTML = `<div style="font-size:1.6rem;font-weight:800">Update required</div>
                <div style="color:#9aa">This version is out of date and can't sync correctly.<br>Update to v${r.version} to keep watching.</div>`;
            const ub = document.createElement('button');
            ub.textContent = `⬇ Update to v${r.version}`;
            ub.style.cssText = 'background:#f5c518;color:#1a1400;border:none;border-radius:999px;' +
                'padding:.6rem 1.4rem;font-weight:700;cursor:pointer;font-size:1.05rem';
            ub.onclick = () => { ck.openExternal(url); ub.textContent = '⬇ Downloading — run the installer, then reopen'; };
            cover.appendChild(ub);
            document.body.appendChild(cover);
            return;
        }
        const b = document.createElement('button');
        b.id = 'update-pill';
        b.textContent = `⬇ Update v${r.version}`;
        b.style.cssText = 'position:fixed;top:14px;right:16px;z-index:999;background:#f5c518;color:#1a1400;' +
            'border:none;border-radius:999px;padding:.45rem 1rem;font-weight:700;cursor:pointer;' +
            'box-shadow:0 2px 12px rgba(245,197,24,.4)';
        b.onclick = () => { ck.openExternal(url); b.textContent = '⬇ Downloading — run the installer'; };
        document.body.appendChild(b);
    } catch {}
}

// ---------- Discover (Stremio-style, EXACT app port): three DROPDOWNS — Type /
// Catalog (MOVIE_CATS · TV_CATS) / Genre — deep pools (12 TMDB pages, 5 Cinemeta),
// per-profile daily shuffle, rows of 15 ----------
let dType = 'movie', dCatIx = 0, dGenre = null, dYear = null, dLoadToken = 0;
const dCats = () => dType === 'movie' ? CK_CAT.MOVIE_CATS : CK_CAT.TV_CATS;
function discoverPickers() {
    const bar = $('discover-pickers');
    bar.innerHTML = '';
    const mk = (labelText, opts, curV, on) => {
        const l = document.createElement('label'); l.textContent = labelText;
        const s = document.createElement('select');
        for (const o of opts) { const e = document.createElement('option'); e.value = o; e.textContent = o; s.appendChild(e); }
        s.value = curV; s.onchange = () => on(s.value);
        bar.append(l, s);
    };
    mk('Type', ['Movies', 'TV Series'], dType === 'movie' ? 'Movies' : 'TV Series',
        v => { dType = v === 'TV Series' ? 'series' : 'movie'; dCatIx = 0; discover(); });
    mk('Catalog', dCats().map(c => c.label), dCats()[dCatIx].label,
        v => { dCatIx = Math.max(0, dCats().findIndex(c => c.label === v)); discover(); });
    mk('Genre', ['All genres', ...CK_CAT.GENRES.filter(g => g !== 'All')], dGenre || 'All genres',
        v => { dGenre = v === 'All genres' ? null : v; discover(); });
    const years = []; for (let y = new Date().getFullYear(); y >= 1950; y--) years.push(String(y));
    mk('Year', ['All years', ...years], dYear ? String(dYear) : 'All years',
        v => { dYear = v === 'All years' ? null : parseInt(v); discover(); });
}
async function discover() {
    discoverPickers();
    const token = ++dLoadToken;
    const h = $('discover-rows'); h.innerHTML = '<div class="muted" style="padding:1rem 0">Loading…</div>';
    const cat = dCats()[Math.min(dCatIx, dCats().length - 1)];
    const kind = dType === 'series' ? 'tv' : 'movie';
    let items;
    if (dYear && !cat.foryou) {
        // YEAR forces an accurate TMDB discover (keeps the provider filter if the catalog is
        // a discover/ one, and honors genre) — parity with the TV app's year filter. (AJ Sep 15)
        const yp = kind === 'tv' ? `first_air_date_year=${dYear}` : `primary_release_year=${dYear}`;
        let base = (cat.tmdb && cat.tmdb.startsWith('discover/')) ? cat.tmdb : `discover/${kind}?sort_by=popularity.desc&vote_count.gte=40`;
        const gid = dGenre ? (dType === 'series' ? CK_CAT.TMDB_TV_GENRE_IDS : CK_CAT.TMDB_GENRE_IDS)[dGenre] : null;
        if (gid) base += `&with_genres=${gid}`;
        base += `&${yp}`;
        items = profileMix(await tmdbRow(kind, base, 12, 400));
    } else if (cat.foryou) {
        items = await forYouRow(kind);
        if (!items.length) items = await tmdbRow(kind, `trending/${kind}/week`);
    } else if (cat.tmdb) {
        // deep pools + genre narrowing: discover queries filter server-side, the rest by
        // TMDB genre ids on the results
        let path = cat.tmdb;
        const gid = dGenre ? (dType === 'series' ? CK_CAT.TMDB_TV_GENRE_IDS : CK_CAT.TMDB_GENRE_IDS)[dGenre] : null;
        if (gid && path.startsWith('discover/')) path += `&with_genres=${gid}`;
        items = await tmdbRow(kind, path, 12, 400);
        if (gid && !path.includes('with_genres')) items = items.filter(t => (t.genres || []).includes(gid));
        items = profileMix(items);
    } else {
        items = profileMix(await cineRow(dType, cat.cine, dGenre, 5));
    }
    if (token !== dLoadToken) return;
    h.innerHTML = '';
    if (!items.length) { h.innerHTML = '<p class="muted" style="padding-top:1rem">Nothing here.</p>'; return; }
    // rows of 15, label on the first — same as the TV app's Discover
    for (let i = 0; i < items.length; i += 15)
        addRow(i === 0 ? `${cat.label}${dGenre ? ' · ' + dGenre : ''}${dYear ? ' · ' + dYear : ''}` : '', items.slice(i, i + 15), null, h);
}

// ---------- Library (Stremio-style: search + type chips + sort cycle + rows) ----------
// Library = what you ADDED, nothing else. Continue Watching owns in-progress; the
// Watched/Unwatched sorts still work within your list.
let libFilter = 'All', libSort = 'Recent', libQuery = '';
const LIB_SORTS = ['Recent', 'New episodes', 'A–Z', 'Z–A', 'Watched', 'Unwatched'];
function library() {
    const body = $('library-body');
    body.innerHTML = '';
    if (S.guest) { body.innerHTML = '<p class="muted" style="padding-top:1rem">Your library lives on your account — sign in to see it.</p>'; return; }
    const input = document.createElement('input');
    input.type = 'search'; input.placeholder = 'Search your library…'; input.value = libQuery;
    body.appendChild(input);
    const controls = document.createElement('div'); controls.className = 'lib-controls';
    const gridHolder = document.createElement('div');
    body.append(controls, gridHolder);
    const render = async () => {
        const st = pstate();
        gridHolder.innerHTML = '';
        const seen = new Set();
        const all = (st.watchlist || []).filter(t => t.id && !seen.has(t.id) && seen.add(t.id));
        let list = libFilter === 'Movies' ? all.filter(t => t.type !== 'series')
            : libFilter === 'Shows' ? all.filter(t => t.type === 'series') : all;
        if (libQuery) list = list.filter(t => (t.name || '').toLowerCase().includes(libQuery.toLowerCase()));
        const watched = new Set(st.watchedIds || []);
        if (libSort === 'A–Z') list = [...list].sort((a, b) => (a.name || '').localeCompare(b.name || ''));
        else if (libSort === 'Z–A') list = [...list].sort((a, b) => (b.name || '').localeCompare(a.name || ''));
        else if (libSort === 'Watched') list = list.filter(t => watched.has(t.id));
        else if (libSort === 'Unwatched') list = list.filter(t => !watched.has(t.id));
        // Recent = natural order (most-recent adds first)
        const paint = (counts) => {
            gridHolder.innerHTML = '';
            let shown = list;
            if (libSort === 'New episodes' && counts) {
                // a real FILTER: only shows that actually have unwatched new episodes,
                // most new first — not the whole library re-sorted
                shown = list.filter(t => (counts[t.id] || 0) > 0).sort((a, b) => (counts[b.id] || 0) - (counts[a.id] || 0));
                if (!shown.length) {
                    gridHolder.innerHTML = '<p class="muted" style="padding-top:1rem">No new episodes right now — shows you track will appear here when new episodes air.</p>';
                    return;
                }
            }
            if (!shown.length) {
                gridHolder.innerHTML = `<p class="muted" style="padding-top:1rem">${!libQuery && !['Watched', 'Unwatched'].includes(libSort)
                    ? 'Your library is empty. Add titles with the + on any movie or show — they’ll live here.' : 'Nothing matches'}</p>`;
                return;
            }
            // "All" = Movies section first, Shows underneath; rows of 15 everywhere
            const rowsOf = (label, l) => {
                for (let i = 0; i < l.length; i += 15)
                    addRow(i === 0 ? label : '', l.slice(i, i + 15),
                        (t) => ({ newEps: counts ? (counts[t.id] || 0) : 0 }), gridHolder);
            };
            if (libFilter === 'All') {
                const movies = shown.filter(t => t.type !== 'series');
                const showsL = shown.filter(t => t.type === 'series');
                if (movies.length) rowsOf('Movies', movies);
                if (showsL.length) rowsOf('Shows', showsL);
            } else rowsOf(libFilter, shown);
        };
        paint(null);
        // new-episode counts land async and re-paint with badges (and power the filter)
        const counts = {};
        await Promise.all(list.filter(t => t.type === 'series').map(async t => { counts[t.id] = await newEpisodeCount(t.id); }));
        if ($('library-body') === body && (Object.values(counts).some(c => c > 0) || libSort === 'New episodes')) paint(counts);
    };
    // chips repaint IN PLACE — rebuilding stole the search cursor
    const paintControls = () => {
        controls.innerHTML = '';
        for (const f of ['All', 'Movies', 'Shows']) {
            const chip = document.createElement('button');
            chip.className = 'chip' + (f === libFilter ? ' on' : '');
            chip.textContent = f;
            chip.onclick = () => { libFilter = f; paintControls(); render(); };
            controls.appendChild(chip);
        }
        const sortChip = document.createElement('button');
        sortChip.className = 'chip sort';
        sortChip.textContent = `↕ ${libSort}`;
        sortChip.onclick = () => {
            libSort = LIB_SORTS[(LIB_SORTS.indexOf(libSort) + 1) % LIB_SORTS.length];
            sortChip.textContent = `↕ ${libSort}`; render();
        };
        controls.appendChild(sortChip);
    };
    let t = null;
    input.oninput = () => { clearTimeout(t); t = setTimeout(() => { libQuery = input.value.trim(); render(); }, 250); };
    paintControls(); render();
}

// ---------- rail ----------
document.querySelectorAll('.rail-item.nav').forEach(n => n.onclick = () => nav(n.dataset.nav));

// ---------- active profile ----------
function pstate() { return S.state.states?.[S.pid] || S.state; }
// full profile manager (switch / add / rename / avatar / delete) — same as the apps
const AVATARS = CK_CAT.AVATAR_CHOICES;   // same 24 as the TV app
$('rail-profile').onclick = () => { if (!S.guest && S.token) profileManager(); };
function switchProfile(p) {
    S.pid = p.id; S.user = p.name; S.useg = `${p.name} #${String(p.id).slice(-4)}`;
    localStorage.setItem('ck-pid', p.id);
    $('prof-name').textContent = p.name; paintAvatar($('prof-avatar'), p);
    applyAccountPrefs();
    for (const k of Object.keys(newEpCache)) delete newEpCache[k];
    home(); if (page === 'library') library();
}
function profileManager() {
    document.getElementById('prof-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'prof-ov';
    ov.style.cssText = 'position:fixed;inset:0;background:#000A;display:flex;align-items:center;justify-content:center;z-index:50';
    const card = document.createElement('div'); card.className = 'prof-card';
    ov.appendChild(card); ov.onclick = (e) => { if (e.target === ov) ov.remove(); };
    document.body.appendChild(ov);
    const listView = () => {
        editing = false;
        const profs = S.state.profiles || [];
        card.innerHTML = '<h3>Profiles</h3>';
        for (const p of profs) {
            const row = document.createElement('div'); row.className = 'prof-row';
            const use = document.createElement('button'); use.className = (p.id === S.pid ? 'primary' : 'ghost') + ' pr-name';
            use.textContent = (p.avatar || '👤') + '  ' + p.name;
            use.onclick = () => { switchProfile(p); ov.remove(); };
            const ed = document.createElement('button'); ed.className = 'ghost small'; ed.textContent = '✎';
            ed.title = 'Edit'; ed.onclick = () => editView(p);
            row.append(use, ed);
            if (profs.length > 1) {
                const del = document.createElement('button'); del.className = 'ghost small'; del.textContent = '🗑';
                del.title = 'Delete profile';
                del.onclick = async () => {
                    if (!(await ckAsk(`Delete profile "${p.name}"?`, 'Its watch history goes with it.', 'Delete', true))) return;
                    S.state.profiles = profs.filter(x => x.id !== p.id);
                    if (S.state.states) delete S.state.states[p.id];
                    // tombstone so the delete sticks across devices (server honors it on merge)
                    S.state.profilesRemoved = { ...(S.state.profilesRemoved || {}), [p.id]: Date.now() };
                    if (S.pid === p.id) switchProfile(S.state.profiles[0]);
                    pushAccount(); listView();
                };
                row.appendChild(del);
            }
            card.appendChild(row);
        }
        if (profs.length < 5) {
            const add = document.createElement('button'); add.className = 'ghost'; add.textContent = '+ Add profile';
            add.onclick = () => editView(null);
            card.appendChild(add);
        }
    };
    const editView = (p) => {
        let avatar = p?.avatar || '👤';
        let color = p?.color || '';
        card.innerHTML = `<h3>${p ? 'Edit profile' : 'New profile'}</h3>`;
        const nameIn = document.createElement('input'); nameIn.placeholder = 'Name'; nameIn.value = p?.name || '';
        const picks = document.createElement('div'); picks.className = 'avatar-pick';
        for (const a of AVATARS) {
            const b = document.createElement('button'); b.textContent = a; b.className = a === avatar ? 'on' : '';
            b.onclick = () => { avatar = a; [...picks.children].forEach(c => c.classList.toggle('on', c.textContent === a)); };
            picks.appendChild(b);
        }
        // background-color swatches (parity with the TV app's avatar colors)
        const cpicks = document.createElement('div'); cpicks.className = 'color-pick';
        for (const c of CK_CAT.COLOR_CHOICES) {
            const b = document.createElement('button'); b.style.background = c;
            b.className = c === color ? 'on' : '';
            b.onclick = () => { color = c; [...cpicks.children].forEach((el, i) => el.classList.toggle('on', CK_CAT.COLOR_CHOICES[i] === color)); };
            cpicks.appendChild(b);
        }
        const save = document.createElement('button'); save.className = 'primary'; save.textContent = 'Save';
        save.onclick = () => {
            const name = nameIn.value.trim(); if (!name) return;
            S.state.profiles = S.state.profiles || [];
            // mt = edit stamp: server + apps keep the NEWEST edit on merge, so a stale
            // device can't revert this change (Sep 17)
            if (p) { p.name = name; p.avatar = avatar; p.color = color; p.mt = Date.now(); if (p.id === S.pid) switchProfile(p); }
            else {
                const np = { id: 'p' + Date.now().toString(36), name, avatar, color, mt: Date.now() };
                S.state.profiles.push(np);
                S.state.states = S.state.states || {};
                S.state.states[np.id] = {};
            }
            pushAccount(); listView();
        };
        const back = document.createElement('button'); back.className = 'ghost'; back.textContent = '‹ Back';
        back.onclick = listView;
        card.append(nameIn, picks, cpicks, save, back);
        editing = true;
    };
    let editing = false;
    listView();
    // freshen from the server on open so a profile just added on the Fire TV is already
    // here — don't stomp an edit form mid-typing if the reply lands late (Sep 17)
    j(`${SERVICE}/tvapp/state?e=${encodeURIComponent(S.email)}&t=${encodeURIComponent(S.token)}`)
        .then(st => { if (st && !editing && document.getElementById('prof-ov')) { S.state = st; listView(); } })
        .catch(() => {});
}

// ---------- account write-back (server MERGES, so partial pushes are safe) ----------
async function pushAccount() {
    if (S.guest || !S.token) return;
    await j(`${SERVICE}/tvapp/state`, { method: 'POST', body: { email: S.email, token: S.token, appVer: APPVER(), state: S.state } });
}
function stamp(map, id) { const m = map || {}; m[id] = Date.now(); return m; }
// most-recent-first Continue list, cap 12 — same shape Store.pushContinue writes
function pushContinueLocal(t) {
    const st = pstate();
    st.continue = [{ id: t.id, type: t.type, name: t.name, poster: t.poster || '' },
        ...(st.continue || []).filter(x => x.id !== t.id)].slice(0, 12);
    st.addedTs = stamp(st.addedTs, t.id);
    st.addedTs = stamp(st.addedTs, 'cw:' + t.id);   // a rewatch brings a hidden CW item back
}
function toggleList(t) {
    const st = pstate(); st.watchlist = st.watchlist || [];
    const has = st.watchlist.some(x => x.id === t.id);
    if (has) { st.watchlist = st.watchlist.filter(x => x.id !== t.id); st.removedTs = stamp(st.removedTs, 'wl:' + t.id); }
    else { st.watchlist.unshift({ id: t.id, type: t.type, name: t.name, poster: t.poster || '' }); st.addedTs = stamp(st.addedTs, t.id); st.addedTs = stamp(st.addedTs, 'wl:' + t.id); }
    pushAccount(); return !has;
}
function toggleWatchedTitle(t) {
    const st = pstate(); st.watchedIds = st.watchedIds || []; st.watchedTitles = st.watchedTitles || [];
    const has = st.watchedIds.includes(t.id);
    if (has) { st.watchedIds = st.watchedIds.filter(x => x !== t.id); st.watchedTitles = st.watchedTitles.filter(x => x.id !== t.id); st.removedTs = stamp(st.removedTs, 'wt:' + t.id); }
    else { st.watchedIds.push(t.id); st.watchedTitles.unshift({ id: t.id, type: t.type, name: t.name, poster: t.poster || '' }); st.addedTs = stamp(st.addedTs, t.id); st.addedTs = stamp(st.addedTs, 'wt:' + t.id); }
    pushAccount(); return !has;
}
// Thumbs (AJ Sep 25): per-profile { v: 1|-1|0, ts } — tapping the active thumb clears it.
// Newest-ts wins in every merge (stale devices can't clobber); the server drops the For You
// cache on push so the row reshapes immediately.
function setRating(id, v) {
    const st = pstate(); st.ratings = st.ratings || {};
    const cur = (st.ratings[id] || {}).v || 0;
    st.ratings[id] = { v: cur === v ? 0 : v, ts: Date.now() };
    pushAccount();
}

// ---------- settings — EXACT page parity with the phone/Firestick (MainActivity
// showSettings / showPlayerSettings / showShelfPicker / showAddons / showAbout) ----------
// local key ↔ account prefs key (the tvstate prefs blob every device shares)
const PREF_MAP = { autonext: 'autoplayNext', subscale: 'subScale', blur: 'blurUnwatched', titles: 'showTitles',
                   seek: 'seekStep', sublang: 'subLang', audlang: 'audioLang', subbg: 'subBg',
                   suboutline: 'subOutline', subpos: 'subPos' };
const PREF = (k, d) => JSON.parse(localStorage.getItem('ckp-' + k) ?? JSON.stringify(d));
const SETPREF = (k, v) => {
    localStorage.setItem('ckp-' + k, JSON.stringify(v));
    if (!S.guest && PREF_MAP[k]) {
        const st = pstate(); st.prefs = st.prefs || {};
        st.prefs[PREF_MAP[k]] = v;
        pushAccount();
    }
};
// account prefs win on pull (a setting flipped on the Firestick shows up here)
function applyAccountPrefs() {
    const pr = pstate().prefs || S.state.prefs;
    if (!pr) return;
    for (const [loc, acc] of Object.entries(PREF_MAP))
        if (pr[acc] !== undefined) localStorage.setItem('ckp-' + loc, JSON.stringify(pr[acc]));
}
// one settings row: label left, value right — the app's settingRow2
function settingRow(label, value, onClick) {
    const r = document.createElement('div'); r.className = 'srow';
    r.innerHTML = `<span class="srow-label">${label}</span><span class="srow-value">${value || ''}</span><span class="srow-chev">›</span>`;
    if (onClick) r.onclick = onClick; else r.classList.add('static');
    return r;
}
function sectionText(t) {
    const s = document.createElement('div'); s.className = 'ssection'; s.textContent = t;
    return s;
}
function renderSettings() {
    const body = $('settings-body');
    body.innerHTML = '';
    const h = document.createElement('h2'); h.textContent = 'Settings'; body.appendChild(h);
    // user card — avatar circle + who you are + access line (Stremio's account header)
    const card = document.createElement('div'); card.className = 'user-card';
    const statusLine = S.guest || !S.email ? 'Tap to sign in'
        : S.access?.daysLeft > 3650 ? 'Lifetime access'
        : (S.access?.expires && S.access?.daysLeft >= 0) ? `Access through ${S.access.expires} · ${S.access.daysLeft} days left`
        : 'Signed in';
    card.innerHTML = `<div class="uc-avatar">${(S.email || 'G')[0].toUpperCase()}</div>
        <div><div class="uc-email">${S.email || 'Guest'}</div><div class="uc-sub muted">${statusLine}</div></div>`;
    if (S.guest || !S.email) card.onclick = () => { localStorage.removeItem('ck'); location.reload(); };
    body.appendChild(card);
    if (!S.guest && S.email) {
        body.appendChild(settingRow('Sync library now', '', async () => {
            toast('Syncing…');
            const st = await j(`${SERVICE}/tvapp/state?e=${encodeURIComponent(S.email)}&t=${encodeURIComponent(S.token)}`);
            if (st) { S.state = st; applyAccountPrefs(); lastSyncSig = syncSig(); }
            toast('Library synced');
        }));
        body.appendChild(settingRow('Sign out', '', () => { localStorage.removeItem('ck'); location.reload(); }));
        body.appendChild(settingRow('Delete account', '', async () => {
            if (!(await ckAsk('Delete account?',
                'This permanently deletes your account and synced library on the server.', 'Delete', true))) return;
            const r = await j(`${SERVICE}/tvapp/delete`, { method: 'POST', body: { email: S.email, token: S.token } });
            if (!r?.ok) { toast("Couldn't delete — check your connection"); return; }
            localStorage.removeItem('ck'); location.reload();
        }));
    }
    body.appendChild(sectionText('SETTINGS'));
    const st = pstate();
    const shelves = (st.shelves && st.shelves.length) ? st.shelves : CK_CAT.DEFAULT_SHELVES;
    body.appendChild(settingRow('Shelves', `${shelves.length} shelves`, () => shelfPicker()));
    body.appendChild(settingRow('Reorder shelves', 'Set the order they show on Home', () => shelfReorder()));
    body.appendChild(settingRow('Blur unwatched episode images', PREF('blur', false) ? 'On' : 'Off',
        () => { SETPREF('blur', !PREF('blur', false)); renderSettings(); }));
    body.appendChild(settingRow('Show titles under posters', PREF('titles', true) ? 'On' : 'Off',
        () => { SETPREF('titles', !PREF('titles', true)); renderSettings(); }));
    // Player settings only exist when there's something to PLAY
    if (hasService()) body.appendChild(settingRow('Player', '', () => playerSettings()));
    body.appendChild(settingRow('Addons',
        S.guest ? 'sign in to add' : `${S.addons.length} added`, () => addonsPage()));
    body.appendChild(settingRow('Legal & About', '', () => aboutPage()));
}
function settingsSub(title, build) {
    const body = $('settings-body');
    body.innerHTML = '';
    const back = document.createElement('button'); back.className = 'ghost small'; back.textContent = '‹ Back';
    back.onclick = () => renderSettings();
    body.appendChild(back);
    const h = document.createElement('h2'); h.textContent = title; body.appendChild(h);
    build(body);
}
/** Player page (subtitles / audio / playback) — same rows as the Firestick's. */
function playerSettings() {
    settingsSub('Player', (body) => {
        body.appendChild(sectionText('SUBTITLES'));
        // live sample: shows exactly what the options below produce
        const sample = document.createElement('div'); sample.className = 'sub-sample';
        const paintSample = () => {
            const scale = PREF('subscale', 1.0);
            sample.innerHTML = `<span style="font-size:${(15 * scale).toFixed(1)}px;
                ${PREF('suboutline', true) ? 'text-shadow:0 0 5px #000,1px 1px 2px #000;' : ''}
                ${PREF('subbg', false) ? 'background:#000000B3;padding:2px 8px;' : ''}
                margin-bottom:${({ 0: 10, 1: 26, 2: 46 })[PREF('subpos', 0)] || 10}px">This is what subtitles will look like</span>`;
        };
        paintSample();
        body.appendChild(sample);
        const sizes = [['Small', 0.8], ['Normal', 1.0], ['Large', 1.3], ['Huge', 1.6]];
        const rebuild = () => playerSettings();
        const curSize = sizes.find(x => Math.abs(x[1] - PREF('subscale', 1.0)) < .01) || sizes[1];
        body.appendChild(settingRow('Subtitle size', curSize[0], () => {
            const next = sizes[(sizes.indexOf(curSize) + 1) % sizes.length];
            SETPREF('subscale', next[1]); rebuild();
        }));
        // AJ Sep 11: English or Off, nothing else — bg/outline/position/audio ride good
        // defaults (outline on, no box, normal pos, English audio server-gated).
        body.appendChild(settingRow('Subtitles', PREF('sublang', 'en') === 'off' ? 'Off' : 'English', () => {
            SETPREF('sublang', PREF('sublang', 'en') === 'en' ? 'off' : 'en'); rebuild();
        }));
        body.appendChild(sectionText('PLAYBACK'));
        body.appendChild(settingRow('Autoplay next episode', PREF('autonext', true) ? 'On' : 'Off', () => {
            SETPREF('autonext', !PREF('autonext', true)); rebuild();
        }));
        body.appendChild(settingRow('Seek step', `${PREF('seek', 10)}s`, () => {
            const steps = [5, 10, 15, 30];
            SETPREF('seek', steps[(steps.indexOf(PREF('seek', 10)) + 1) % steps.length]); rebuild();
        }));
    });
}
// current enabled shelves as an ORDERED array (the user's line-up), valid labels only
function shelfOrder() {
    const st = pstate();
    const src = (st.shelves && st.shelves.length) ? st.shelves : CK_CAT.DEFAULT_SHELVES;
    return src.filter(l => CK_CAT.SHELF_CATALOG.some(r => r.label === l));
}
/** "Shelves": pick which rows are on (numbered as you pick). Reorder is its own screen. */
function shelfPicker() {
    settingsSub('Shelves', (body) => {
        const note = document.createElement('p'); note.className = 'muted';
        note.textContent = 'Turn rows on or off — the number shows where each lands on Home. For You is always on. Reorder them in Settings → Reorder shelves.';
        body.appendChild(note);
        const st = pstate();
        const order = shelfOrder();
        const chips = [];
        const persist = () => { st.shelves = order.slice(); pushAccount(); };
        const repaint = () => chips.forEach(({ el, label }) => {
            const i = order.indexOf(label);
            el.className = 'chip shelf' + (i >= 0 ? ' on' : '');
            el.textContent = (i >= 0 ? (i + 1) + '. ' : '') + label;
        });
        const G = CK_CAT.SHELF_GROUPS;
        const inG = (label, g) => G[g].includes(label);
        const section = (title, rows) => {
            if (!rows.length) return;
            body.appendChild(sectionText(title));
            const wrap = document.createElement('div'); wrap.className = 'chip-grid';
            for (const r of rows) {
                const chip = document.createElement('button');
                chip.onclick = () => {
                    const i = order.indexOf(r.label);
                    if (i >= 0) order.splice(i, 1); else order.push(r.label);
                    persist(); repaint();
                };
                chips.push({ el: chip, label: r.label });
                wrap.appendChild(chip);
            }
            body.appendChild(wrap);
        };
        const all = CK_CAT.SHELF_CATALOG;
        section('POPULAR & NEW', all.filter(r => !inG(r.label, 'providers') && !inG(r.label, 'channels') && !inG(r.label, 'genres') && !inG(r.label, 'moods')));
        section('MOODS & SEASONS', all.filter(r => inG(r.label, 'moods')));
        section('STREAMING SERVICES', all.filter(r => inG(r.label, 'providers')));
        section('CHANNELS & ANIME', all.filter(r => inG(r.label, 'channels')));
        section('GENRES', all.filter(r => inG(r.label, 'genres')));
        repaint();
    });
}
/** "Reorder shelves": drag rows up/down to set the Home order. Persists + syncs. */
function shelfReorder() {
    settingsSub('Reorder shelves', (body) => {
        const note = document.createElement('p'); note.className = 'muted';
        note.textContent = 'Drag a shelf to change where it shows on Home. For You always stays on top.';
        body.appendChild(note);
        const st = pstate();
        let order = shelfOrder();
        const persist = () => { st.shelves = order.slice(); pushAccount(); };
        const list = document.createElement('div'); list.className = 'reorder-list';
        let dragEl = null;
        const renumber = () => [...list.querySelectorAll('.reorder-row')].forEach((r, i) => {
            const n = r.querySelector('.num'); if (n) n.textContent = (i + 1) + '.';
        });
        const commitFromDOM = () => {   // rebuild order from the live DOM order + save
            order = [...list.querySelectorAll('.reorder-row')].map(r => r.dataset.label);
            renumber(); persist();
        };
        const rowUnder = (y) => [...list.querySelectorAll('.reorder-row')].find(r => {
            if (r === dragEl) return false;
            const b = r.getBoundingClientRect();
            return y < b.top + b.height / 2;
        });
        const rowEl = (label) => {
            const row = document.createElement('div'); row.className = 'reorder-row'; row.dataset.label = label;
            row.innerHTML = `<span class="grip">⋮⋮</span><span class="num"></span><span class="rl">${label}</span>`;
            const btns = document.createElement('span'); btns.className = 'ro-btns';
            const up = document.createElement('button'); up.textContent = '▲'; up.className = 'ghost small';
            up.onclick = (e) => { e.stopPropagation(); const p = row.previousElementSibling; if (p && p.classList.contains('reorder-row')) { list.insertBefore(row, p); commitFromDOM(); } };
            const dn = document.createElement('button'); dn.textContent = '▼'; dn.className = 'ghost small';
            dn.onclick = (e) => { e.stopPropagation(); const nx = row.nextElementSibling; if (nx) { list.insertBefore(nx, row); commitFromDOM(); } };
            btns.append(up, dn); row.appendChild(btns);
            // POINTER-based drag = works with mouse AND touch (mobile) — HTML5 draggable ignores
            // touch entirely. Drag from anywhere on the row except the ▲▼ buttons. touch-action:none
            // (CSS) lets a touch drag reorder instead of scrolling the page. (AJ Sep 15)
            row.addEventListener('pointerdown', (e) => {
                if (e.target.tagName === 'BUTTON') return;
                e.preventDefault();
                dragEl = row; row.classList.add('dragging');
                // document-level listeners fire no matter what's under the pointer AND survive
                // moving the dragged element in the DOM (setPointerCapture gets released on a
                // DOM move in Chrome — that's what killed the drag). (AJ Sep 15)
                const move = (ev) => {
                    const after = rowUnder(ev.clientY);
                    if (after) list.insertBefore(dragEl, after); else list.appendChild(dragEl);
                };
                const end = () => {
                    if (dragEl) dragEl.classList.remove('dragging');
                    dragEl = null;
                    document.removeEventListener('pointermove', move);
                    document.removeEventListener('pointerup', end);
                    document.removeEventListener('pointercancel', end);
                    commitFromDOM();
                };
                document.addEventListener('pointermove', move);
                document.addEventListener('pointerup', end);
                document.addEventListener('pointercancel', end);
            });
            return row;
        };
        if (!order.length) list.innerHTML = '<p class="muted">No shelves on yet — add some in Settings → Shelves.</p>';
        else { order.forEach(l => list.appendChild(rowEl(l))); renumber(); }
        body.appendChild(list);
    });
}
function addonsPage() {
    settingsSub('Addons', (body) => {
        if (S.guest) {
            const p = document.createElement('p'); p.className = 'muted';
            p.textContent = 'Sign in to add addons and start streaming.';
            body.appendChild(p);
            const b = document.createElement('button'); b.className = 'primary'; b.textContent = 'Sign in';
            b.onclick = () => { localStorage.removeItem('ck'); location.reload(); };
            body.appendChild(b);
            return;
        }
        // official built-ins (AJ Sep 13: "I don't see OpenSubtitles or Cinemeta under
        // official addons") — these power every install and can't be removed, same as
        // Stremio lists its preinstalled pair
        body.appendChild(sectionText('OFFICIAL — BUILT IN'));
        body.appendChild(settingRow('Cinemeta', 'Movie & show info · built in', null));
        body.appendChild(settingRow('OpenSubtitles v3', 'Subtitles · built in', null));
        body.appendChild(sectionText('YOUR ADDONS'));
        if (!S.addons.length) {
            const p = document.createElement('p'); p.className = 'muted';
            p.textContent = 'No addons yet — the addon assigned to your account installs automatically once you’re enabled, or add one below.';
            body.appendChild(p);
        }
        // add/remove parity with the Firestick/mobile app (AJ Sep 13: "can't add addons on
        // there — I want them the same"). The list lives in the synced account state, so an
        // addon added here appears on every signed-in device.
        S.addons.forEach((a, ix) => {
            const row = settingRow(a.name || 'Addon', ix === 0 ? 'Connected · primary' : 'Remove', ix === 0 ? null : () => {
                S.addons.splice(ix, 1);
                const st = pstate(); st.addons = S.addons; pushAccount();
                livetvDetect();   // Live TV tab leaves with the addon — no reload needed
                addonsPage();
            });
            body.appendChild(row);
        });
        body.appendChild(sectionText('ADD AN ADDON'));
        const wrap = document.createElement('div'); wrap.style.cssText = 'display:flex;gap:.5rem;max-width:560px';
        const inp = document.createElement('input'); inp.placeholder = 'Addon or manifest URL…';
        inp.style.cssText = 'flex:1';
        const btn = document.createElement('button'); btn.className = 'primary'; btn.textContent = 'Add';
        btn.onclick = async () => {
            let u = inp.value.trim(); if (!u) return;
            if (!/^https?:\/\//.test(u)) u = 'https://' + u;
            u = u.replace(/\/manifest\.json$/, '').replace(/\/$/, '');
            btn.textContent = 'Checking…';
            const man = await j(`${u}/manifest.json`, { timeoutMs: 10000 });
            btn.textContent = 'Add';
            if (!man?.id) { inp.value = ''; inp.placeholder = 'That URL has no addon manifest — check it'; return; }
            if (S.addons.some(x => x.url === u)) { inp.value = ''; inp.placeholder = 'Already added'; return; }
            S.addons.push({ url: u, name: man.name || 'Addon' });
            const st = pstate(); st.addons = S.addons; pushAccount();
            livetvDetect();   // Live TV tab appears the moment the addon lands — no reload
            addonsPage();
        };
        wrap.append(inp, btn); body.appendChild(wrap);
    });
}
function aboutPage() {
    settingsSub('Legal & About', async (body) => {
        body.appendChild(settingRow('Terms & Conditions', '', () => ck.openExternal('https://couchking.app/terms')));
        body.appendChild(settingRow('Privacy Policy', '', () => ck.openExternal('https://couchking.app/privacy')));
        const vRow = settingRow('Version', ck.platform === 'web' ? 'web' : '…', null);
        body.appendChild(vRow);
        if (ck.platform !== 'web') vRow.querySelector('.srow-value').textContent = await ck.version();
    });
}
