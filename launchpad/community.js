// Community favorites (fan launches, most supported first; may be unclaimed) and the Open Doors banner.
//   [data-community-list="strip"|"full"]  ranked by holders; the section [data-community-section]
//                                         stays hidden until there is at least one community launch.
//   [data-open-doors]                     countdown / spots left while an Open Doors window is set.
import { API } from '/launchpad/lp.js';
import { honourPill } from '/launchpad/icons.js';

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const until = (t) => {
  const s = Math.max(0, t - Math.floor(Date.now() / 1000)), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
};

let SHORT = {}, STORIES = {}; // mint -> short link (launchpad/short-links.json); commemorative titles (token-stories.json)
function card(c) {
  const badge = c.claimed ? '<span class="sel-badge ok">Community-launched · Claimed by the owner</span>' : '<span class="sel-badge">Community-launched · Unclaimed</span>';
  return `<a class="sel-card" href="${esc(c.page ? c.page.replace(/^https:\/\/punchcard\.club/, '') : SHORT[c.mint] || `/launchpad/coin/?mint=${encodeURIComponent(c.mint)}`)}">
    <img src="${STORIES[c.mint]?.hideArt ? '/brand/punchcard.svg' : `${API}/img/${encodeURIComponent(c.mint)}`}" alt="" width="64" height="64" loading="lazy" onerror="this.onerror=null;this.src='/brand/punchcard.svg'">
    <span><b>${esc(c.ticker)} · ${esc(STORIES[c.mint]?.listName || c.business_name)}</b><small>${esc(STORIES[c.mint]?.place || [c.city, c.country].filter(Boolean).join(', '))}</small>${badge}
    <small class="sel-stats">${c.holders ? `${Number(c.holders).toLocaleString()} holders` : 'New'}${Number(c.feesGeneratedLamports) > 0 ? ` · ${(Number(c.feesGeneratedLamports) / 1e9).toFixed(2)} SOL in creator fees` : ''}${c.burnTier ? ` · ${honourPill(c.burnTier)}` : ''}</small></span></a>`;
}

async function communityLists() {
  const lists = document.querySelectorAll('[data-community-list]');
  if (!lists.length) return;
  const [{ coins = [] }, short] = await Promise.all([fetch(`${API}/api/coins`).then((r) => r.json()).catch(() => ({})), fetch('/launchpad/short-links.json').then((r) => r.json()).catch(() => ({})),
    fetch('/launchpad/token-stories.json').then((r) => r.json()).catch(() => ({}))]).then(([a, b, c]) => { STORIES = c; return [a, b]; });
  SHORT = short;
  // Blaze and Inferno launches (2+ SOL committed to the burn) get top placement; then by holders.
  const top = (c) => (c.burnTier?.rank >= 3 ? c.burnTier.rank : 0);
  const fees = (c) => Number(c.feesGeneratedLamports || 0);
  const community = coins.filter((c) => !c.team).sort((a, b) => top(b) - top(a) || (b.holders || 0) - (a.holders || 0) || fees(b) - fees(a) || b.launched_at - a.launched_at);
  if (!community.length) return; // sections stay hidden
  document.querySelectorAll('[data-community-section]').forEach((s) => { s.hidden = false; });
  // Home page strip: the top three by creator fees generated for the business. Launchpad: the full favorites ranking.
  const byFees = [...community].sort((a, b) => fees(b) - fees(a) || (b.holders || 0) - (a.holders || 0));
  for (const el of lists) el.innerHTML = (el.dataset.communityList === 'strip' ? byFees.slice(0, 3) : community.slice(0, 60)).map(card).join('');
}

// ---------- Open Doors banner: live countdown + 24 punch-card holes (one per spot, punched out as spots are taken) ----------
const pad = (n) => String(n).padStart(2, '0');
function clock(secs) {
  const s = Math.max(0, secs), d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  const unit = (v, l) => `<span class="od-unit"><b>${pad(v)}</b><small>${l}</small></span>`;
  return (d ? unit(d, 'days') : '') + unit(h, 'hrs') + unit(m, 'min') + unit(x, 'sec');
}
function holes(cap, used) {
  return `<div class="od-holes" role="img" aria-label="${cap - used} of ${cap} spots left">${Array.from({ length: cap }, (_, i) =>
    `<span class="od-hole${i < used ? ' taken' : ''}"></span>`).join('')}</div>`;
}
function bannerHtml(st, now) {
  const hours = Math.round((st.closesAt - st.opensAt) / 3600);
  const when = new Date(st.opensAt * 1000).toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' });
  if (now < st.opensAt) return `<div class="od-left"><p class="od-kicker">Open Doors · ${esc(when)}</p>
      <h2 class="od-title">${st.cap} launches. ${hours} hours.</h2>
      <p class="od-sub">Any PunchCard member can launch a token for a local business they love. One launch per wallet, first come, first served.</p>
      <div class="od-ctas"><a class="od-btn" href="/launchpad/how/#membership">Get ready: become a member</a><a class="od-link" href="/open-doors/">Share</a></div></div>
    <div class="od-right"><p class="od-label">Doors open in</p><div class="od-clock" data-od-to="${st.opensAt}">${clock(st.opensAt - now)}</div>${holes(st.cap, 0)}<p class="od-label">${st.cap} spots</p></div>`;
  if (st.open) return `<div class="od-left"><p class="od-kicker od-live"><span class="od-dot"></span>Open Doors is live</p>
      <h2 class="od-title">${st.remaining} of ${st.cap} spots left.</h2>
      <p class="od-sub">Any PunchCard member can launch a token for a local business they love, right now. One launch per wallet.</p>
      <div class="od-ctas"><a class="od-btn" href="/go/">Launch a token</a><a class="od-link" href="/launchpad/how/#membership">Membership</a></div></div>
    <div class="od-right"><p class="od-label">Doors close in</p><div class="od-clock" data-od-to="${st.closesAt}">${clock(st.closesAt - now)}</div>${holes(st.cap, st.used)}<p class="od-label">${st.used} launched · ${st.remaining} left</p></div>`;
  if (now < st.closesAt) return `<div class="od-left"><p class="od-kicker">Open Doors</p>
      <h2 class="od-title">All ${st.cap} spots are taken.</h2>
      <p class="od-sub">Thank you! Every one of them is now a token for a local business. Follow <a href="https://x.com/punchcard_club" target="_blank" rel="noopener">@punchcard_club</a> and <a href="https://t.me/punchcardclub" target="_blank" rel="noopener">Telegram</a> for the next Open Doors.</p>
      <div class="od-ctas"><a class="od-btn" href="/launchpad/#latest">See the new launches</a></div></div>
    <div class="od-right">${holes(st.cap, st.cap)}<p class="od-label">${st.cap} of ${st.cap} launched</p></div>`;
  return null;
}

let odTick = null;
async function openDoors() {
  const els = document.querySelectorAll('[data-open-doors]');
  if (!els.length) return;
  const st = await fetch(`${API}/api/launch/status`).then((r) => r.json()).catch(() => null);
  if (!st || st.mode !== 'open-doors') { // no date yet: optional "coming soon" teaser (launchpad/open-doors.json)
    const t = await fetch('/launchpad/open-doors.json').then((r) => r.json()).catch(() => null);
    if (!t?.tease || st?.mode === 'public') return;
    for (const el of els) {
      el.innerHTML = `<div class="od-left"><p class="od-kicker">Coming soon</p><h2 class="od-title">Open Doors.</h2>
        <p class="od-sub">For ${t.hours || 24} hours, any PunchCard member can launch a token for a local business they love. ${t.cap || 24} spots. Date announced on <a href="https://x.com/punchcard_club" target="_blank" rel="noopener">@punchcard_club</a> and <a href="https://t.me/punchcardclub" target="_blank" rel="noopener">Telegram</a>.</p></div>
        <div class="od-right">${holes(t.cap || 24, 0)}</div>`;
      el.hidden = false;
    }
    return;
  }
  const now = Math.floor(Date.now() / 1000);
  const html = bannerHtml(st, now);
  if (!html) return;
  for (const el of els) { el.innerHTML = html; el.hidden = false; }
  if (st.open) document.querySelectorAll('[data-hide-when-open]').forEach((e) => { e.hidden = true; });
  // Tick every second; refresh the spots every 30 s, and right away when a countdown reaches zero.
  clearInterval(odTick);
  let last = Date.now();
  odTick = setInterval(() => {
    const t = Math.floor(Date.now() / 1000);
    let zero = false;
    document.querySelectorAll('[data-od-to]').forEach((c) => { const left = Number(c.dataset.odTo) - t; if (left <= 0) zero = true; c.innerHTML = clock(left); });
    if (zero || Date.now() - last > 30_000) { last = Date.now(); clearInterval(odTick); openDoors(); }
  }, 1000);
}

communityLists();
openDoors();
