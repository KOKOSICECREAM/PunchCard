// PunchCard Select list: renders business-approved launches into any element with
// data-select-list ("strip" = home page highlight, "full" = launchpad). Coming-soon entries come
// from select.json; once an entry has a mint, its card shows live data from the launchpad backend.
// Ranked by what has actually been paid to each business (public on-chain data, never paid placement).
import { API } from '/launchpad/lp.js';

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const sol = (l) => { const n = Number(l) / 1e9; return n >= 10 ? n.toFixed(1) : n >= 1 ? n.toFixed(2) : n.toFixed(3); };

async function live(b) {
  if (!b.mint) return { ...b, state: 'soon', paid: 0 };
  try {
    const c = await fetch(`${API}/api/coins/${encodeURIComponent(b.mint)}`).then((r) => (r.ok ? r.json() : Promise.reject()));
    const state = c.status === 'HandedOver' ? 'approved' : c.status === 'Attested' ? 'review' : 'launched';
    return { ...b, state, paid: Number(c.ownerPaidLamports || 0), holders: c.holders ?? null, ticker: b.ticker || c.ticker };
  } catch { return { ...b, state: 'launched', paid: 0 }; }
}

function card(b) {
  const badge = {
    approved: '<span class="sel-badge ok">★ Business-approved</span>',
    review: '<span class="sel-badge">Owner claim in review</span>',
    launched: '<span class="sel-badge">Live · owner claim pending</span>',
    soon: '<span class="sel-badge soon">Coming soon</span>',
  }[b.state];
  const stats = b.state === 'soon' ? '<small class="sel-stats">Token name: TBD</small>' : `<small class="sel-stats">${b.paid ? `${sol(b.paid)} SOL paid to the business` : 'No payouts yet'}${b.holders ? ` · ${b.holders.toLocaleString()} holders` : ''}</small>`;
  return `<a class="sel-card" href="${esc(b.page)}">
    <img src="${esc(b.logo)}" alt="" width="64" height="64"${b.logoBg ? ` style="background:${esc(b.logoBg)}"` : ''}>
    <span><b>${b.ticker ? `${esc(b.ticker)} · ` : ''}${esc(b.name)}</b><small>${esc(b.tagline)} · ${esc(b.city)}</small>${badge}${stats}</span>
  </a>`;
}

const lists = document.querySelectorAll('[data-select-list]');
if (lists.length) {
  const { businesses = [] } = await fetch('/launchpad/select.json').then((r) => r.json()).catch(() => ({}));
  const rows = await Promise.all(businesses.map(live));
  const order = { approved: 0, review: 1, launched: 2, soon: 3 };
  rows.sort((a, b) => order[a.state] - order[b.state] || b.paid - a.paid);
  for (const el of lists) {
    const max = el.dataset.selectList === 'strip' ? 3 : rows.length;
    el.innerHTML = rows.slice(0, max).map(card).join('') || '<p class="status-line">The first business-approved launches are coming soon.</p>';
  }
}
