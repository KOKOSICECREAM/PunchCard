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
    <img src="${API}/img/${encodeURIComponent(c.mint)}" alt="" width="64" height="64" loading="lazy" onerror="this.onerror=null;this.src='/brand/punchcard.svg'">
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

async function openDoors() {
  const els = document.querySelectorAll('[data-open-doors]');
  if (!els.length) return;
  const st = await fetch(`${API}/api/launch/status`).then((r) => r.json()).catch(() => null);
  if (!st || st.mode !== 'open-doors') { // no date yet: optional "coming soon" teaser (launchpad/open-doors.json)
    const t = await fetch('/launchpad/open-doors.json').then((r) => r.json()).catch(() => null);
    if (!t?.tease || st?.mode === 'public') return;
    for (const el of els) { el.innerHTML = `<b>Coming soon: Open Doors.</b> For ${t.hours || 24} hours, any PunchCard member can launch a token for a local business they love. ${t.cap || 24} spots. Date announced on <a href="https://x.com/punchcard_club" target="_blank" rel="noopener">@punchcard_club</a> and <a href="https://t.me/punchcardclub" target="_blank" rel="noopener">Telegram</a>.`; el.hidden = false; }
    return;
  }
  const now = Math.floor(Date.now() / 1000);
  let html;
  const hours = Math.round((st.closesAt - st.opensAt) / 3600);
  if (now < st.opensAt) html = `<b>Open Doors:</b> for ${hours} hours, any PunchCard member can launch a token for a local business they love. ${st.cap} spots. Starts in <b>${until(st.opensAt)}</b> (${new Date(st.opensAt * 1000).toLocaleString()}).`;
  else if (st.open) html = `<b>Open Doors is on!</b> Any PunchCard member can launch for a local business: <b>${st.remaining} of ${st.cap} spots left</b> · closes in ${until(st.closesAt)}. <a href="/go/">Launch a token →</a>`;
  else if (now < st.closesAt) html = `<b>Open Doors:</b> all ${st.cap} spots are taken. Thank you! Follow <a href="https://x.com/punchcard_club" target="_blank" rel="noopener">@punchcard_club</a> for the next one.`;
  else return;
  for (const el of els) { el.innerHTML = html; el.hidden = false; }
  if (st.open) document.querySelectorAll('[data-hide-when-open]').forEach((e) => { e.hidden = true; });
}

communityLists();
openDoors();
