// "Just launched": the newest PunchCard tokens, newest first, straight from the chain-backed coin list.
// Every token is listed as soon as it's registered, with its official CA, before any page is approved.
//   [data-latest-launches]          the list (data-count = how many, default 10)
//   [data-latest-section]           shown once there is at least one launch
// Refreshes every minute; "x min ago" ticks every 30 seconds.
import { API } from '/launchpad/lp.js';

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const ago = (t) => {
  const s = Math.max(0, Math.floor(Date.now() / 1000) - t);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  const d = Math.floor(s / 86400);
  return d === 1 ? 'yesterday' : `${d} days ago`;
};
const shortCa = (m) => `${m.slice(0, 4)}…${m.slice(-4)}`;
let SHORT = null, STORIES = {};

function row(c) {
  const st = STORIES[c.mint]; // commemorative tokens show their own title (launchpad/token-stories.json)
  const page = c.page ? c.page.replace(/^https:\/\/punchcard\.club/, '') : SHORT[c.mint] || `/launchpad/coin/?mint=${encodeURIComponent(c.mint)}`;
  const fresh = Math.floor(Date.now() / 1000) - c.launched_at < 86400;
  const tag = c.team ? '<span class="ll-tag sel">PunchCard Select</span>' : '<span class="ll-tag">Community</span>';
  return `<li class="ll-row">
    <a class="ll-main" href="${esc(page)}">
      <img src="${API}/img/${encodeURIComponent(c.mint)}" alt="" width="52" height="52" loading="lazy" onerror="this.onerror=null;this.src='/brand/punchcard.svg'">
      <span class="ll-txt"><span class="ll-top"><b>$${esc(c.ticker)}</b> <span class="ll-name">${esc(st ? st.listName : c.coin_name || c.business_name)}</span></span>
        <small>${st ? esc(st.place) : `${esc(c.business_name)}${c.city ? ' · ' + esc(c.city) : ''}${c.country ? ', ' + esc(c.country) : ''}`}</small></span>
    </a>
    <span class="ll-meta">${fresh ? '<span class="ll-new">New</span>' : ''}${tag}<time data-t="${Number(c.launched_at)}">${ago(c.launched_at)}</time></span>
    <span class="ll-ca"><span class="ll-lbl">CA</span><code title="${esc(c.mint)}"><span class="ll-full">${esc(c.mint)}</span><span class="ll-short">${shortCa(c.mint)}</span></code><button type="button" class="ll-copy" data-ca="${esc(c.mint)}" aria-label="Copy the official CA for $${esc(c.ticker)}">Copy CA</button>
      <a class="ll-pump" href="https://pump.fun/coin/${encodeURIComponent(c.mint)}" target="_blank" rel="noopener">pump.fun</a></span>
  </li>`;
}

async function load() {
  const lists = document.querySelectorAll('[data-latest-launches]');
  if (!lists.length) return;
  const [{ coins = [] }, short] = await Promise.all([
    fetch(`${API}/api/coins?t=${Math.floor(Date.now() / 60000)}`).then((r) => r.json()).catch(() => ({})),
    SHORT ? Promise.resolve(SHORT) : fetch('/launchpad/short-links.json').then((r) => r.json()).catch(() => ({})),
    fetch('/launchpad/token-stories.json').then((r) => r.json()).catch(() => ({})),
  ]).then(([a, b, c]) => { STORIES = c; return [a, b]; });
  SHORT = short;
  const latest = coins.filter((c) => c.launched_at).sort((a, b) => b.launched_at - a.launched_at);
  if (!latest.length) return;
  document.querySelectorAll('[data-latest-section]').forEach((s) => { s.hidden = false; });
  for (const el of lists) el.innerHTML = latest.slice(0, Number(el.dataset.count || 10)).map(row).join('');
}

document.addEventListener('click', async (e) => {
  const b = e.target.closest('.ll-copy');
  if (!b) return;
  try { await navigator.clipboard.writeText(b.dataset.ca); b.textContent = 'Copied'; }
  catch { const code = b.previousElementSibling; code.textContent = b.dataset.ca; getSelection().selectAllChildren(code); b.textContent = 'Select + copy'; }
  setTimeout(() => { b.textContent = 'Copy CA'; }, 1600);
});
setInterval(() => document.querySelectorAll('.ll-row time[data-t]').forEach((t) => { t.textContent = ago(Number(t.dataset.t)); }), 30_000);
setInterval(load, 60_000);
load();
