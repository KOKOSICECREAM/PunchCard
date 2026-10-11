// "Trading X has helped burn N PUNCH": the coin's share of the weekly PUNCH buy-and-burn (20% of
// PunchCard's fee), in proportion to the fees it brought in. Fills an element; stays empty until
// there's something burned, or if the backend can't be reached.
import { API } from '/launchpad/lp.js';
import { ICONS } from '/launchpad/icons.js';

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export async function showPunchBurned(el, mint, ticker) {
  if (!el) return;
  const s = await fetch(`${API}/api/punch-burns`).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  const raw = Number((s?.coins || []).find((x) => x.mint === mint)?.punchBurnedRaw || 0);
  if (raw < 1e6) return;
  el.innerHTML = `<p class="status-line">${ICONS.flame} Trading ${esc(ticker)} has helped burn <b>${Math.round(raw / 1e6).toLocaleString()} PUNCH</b>: 20% of PunchCard's fee buys and burns PUNCH every week. <a href="/punch/">See every burn</a></p>`;
}
