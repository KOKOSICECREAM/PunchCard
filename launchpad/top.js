// Top launches: the 5 community tokens that have generated the most creator fees for their business (public on-chain
// data). Not a price ranking.  [data-top-launches] (data-count, default 5) inside [data-top-section]. Refreshes each minute.
import { API } from '/launchpad/lp.js';

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const sol = (l) => { const n = Number(l || 0) / 1e9; return n >= 100 ? n.toFixed(0) : n >= 10 ? n.toFixed(1) : n.toFixed(2); };
let SHORT = null, STORIES = null;

function row(c, i, top) {
  const st = STORIES[c.mint];
  const href = c.page ? c.page.replace(/^https:\/\/punchcard\.club/, '') : SHORT[c.mint] || `/launchpad/coin/?mint=${encodeURIComponent(c.mint)}`;
  const fees = Number(c.feesGeneratedLamports || 0), pct = top > 0 ? Math.max(4, Math.round((fees / top) * 100)) : 0;
  const place = st ? st.place : [c.city, c.country].filter(Boolean).join(', ');
  return `<li class="tl-row${i === 0 ? ' first' : ''}"><a href="${esc(href)}">
    <span class="tl-rank">${i + 1}</span>
    <img src="${st?.hideArt ? '/brand/punchcard.svg' : `${API}/img/${encodeURIComponent(c.mint)}`}" alt="" width="56" height="56" loading="lazy" onerror="this.onerror=null;this.src='/brand/punchcard.svg'">
    <span class="tl-main"><span class="tl-name"><b>$${esc(c.ticker)}</b> ${esc(st ? st.listName : c.business_name)}</span>
      <small>${esc(place)}${c.holders ? ` · ${Number(c.holders).toLocaleString()} ${Number(c.holders) === 1 ? 'holder' : 'holders'}` : ''}</small>
      <span class="tl-bar" aria-hidden="true"><i style="width:${pct}%"></i></span></span>
    <span class="tl-fees"><b>${sol(fees)}</b><small>SOL in creator fees</small></span>
  </a></li>`;
}

async function load() {
  const lists = document.querySelectorAll('[data-top-launches]');
  if (!lists.length) return;
  const [data, short, stories] = await Promise.all([
    fetch(`${API}/api/coins?t=${Math.floor(Date.now() / 60000)}`).then((r) => r.json()).catch(() => ({})),
    SHORT || fetch('/launchpad/short-links.json').then((r) => r.json()).catch(() => ({})),
    STORIES || fetch('/launchpad/token-stories.json').then((r) => r.json()).catch(() => ({})),
  ]);
  SHORT = short; STORIES = stories;
  const ranked = (data.coins || []).filter((c) => !c.team && Number(c.feesGeneratedLamports) > 0)
    .sort((a, b) => Number(b.feesGeneratedLamports) - Number(a.feesGeneratedLamports));
  if (!ranked.length) return;
  document.querySelectorAll('[data-top-section]').forEach((s) => { s.hidden = false; });
  for (const el of lists) {
    const list = ranked.slice(0, Number(el.dataset.count || 5));
    el.innerHTML = list.map((c, i) => row(c, i, Number(list[0].feesGeneratedLamports))).join('');
  }
}
setInterval(load, 60_000);
load();
