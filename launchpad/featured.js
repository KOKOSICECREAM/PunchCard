// Featured business page: fills in live token details from the launchpad backend.
// The page sets <main data-mint="…" data-ticker="…" data-business="…">. Before launch (mint not
// set yet) it shows "launching soon".
import { API } from '/launchpad/lp.js';

const main = document.querySelector('main[data-mint]');
const mint = main.dataset.mint, ticker = main.dataset.ticker, business = main.dataset.business;
const $ = (id) => document.getElementById(id);
const sol = (l) => (Number(l) / 1e9).toLocaleString(undefined, { maximumFractionDigits: 4 });
const short = (a) => a.slice(0, 4) + '…' + a.slice(-4);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const acct = (a) => `<a class="mono" href="https://solscan.io/account/${encodeURIComponent(a)}" target="_blank" rel="noopener">${short(a)}</a>`;

const launched = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(mint);
document.querySelectorAll('[data-when="launched"]').forEach((e) => { e.hidden = !launched; });
document.querySelectorAll('[data-when="soon"]').forEach((e) => { e.hidden = launched; });

if (launched) {
  $('ca').textContent = mint;
  $('pumpLink').href = `https://pump.fun/coin/${mint}`;
  $('scanLink').href = `https://solscan.io/token/${mint}`;
  $('dexLink').href = `https://dexscreener.com/solana/${mint}`;
  $('copyCa').addEventListener('click', () => {
    const pick = () => { const r = document.createRange(); r.selectNodeContents($('ca')); const s = getSelection(); s.removeAllRanges(); s.addRange(r); $('copyCa').textContent = 'Selected'; };
    if (navigator.clipboard) navigator.clipboard.writeText(mint).then(() => { $('copyCa').textContent = 'Copied'; }, pick); else pick();
  });
  load().catch(() => { $('fees').innerHTML = '<p class="status-line">Live details are unavailable right now. Try again in a minute.</p>'; });
}

// Who doesn't count for holder payouts, and why (published so anyone can check).
async function showExcluded() {
  const x = await fetch(`${API}/api/excluded?mint=${encodeURIComponent(mint)}`).then((r) => (r.ok ? r.json() : Promise.reject()));
  const early = x.launchWindowBuyers || [];
  const list = (arr) => arr.map((w) => `<li>${acct(w)}</li>`).join('');
  $('excluded').innerHTML = `<details class="excl"><summary>Not counted for holder payouts: the launcher${early.length ? `, ${early.length} wallets that bought in the first minute` : ''}${x.taintedTokens.length ? `, and tokens moved from them to ${x.taintedTokens.length} other wallet(s)` : ''}</summary>
    <p class="status-line">${esc(x.rules)}</p>
    <p><b>Launcher</b></p><ul class="excl-list"><li>${acct(x.launcher)}</li></ul>
    ${early.length ? `<p><b>Bought in the first ${x.launchWindowSecs} seconds</b></p><ul class="excl-list">${list(early)}</ul>` : ''}
    ${x.taintedTokens.length ? `<p><b>Holding tokens moved directly from those wallets</b> (only that amount doesn't count)</p><ul class="excl-list">${x.taintedTokens.map((t) => `<li>${acct(t.wallet)} · ${(Number(t.notCounted) / 1e6).toLocaleString()} not counted</li>`).join('')}</ul>` : ''}
  </details>`;
}

async function load() {
  const [c, r] = await Promise.all([
    fetch(`${API}/api/coins/${mint}`).then((x) => x.json()),
    fetch(`${API}/api/rounds?mint=${mint}`).then((x) => x.json()).catch(() => ({ rounds: [] })),
  ]);
  const owner90 = (10000 - c.platformBps) / 100, holders = c.communityBps / 100;
  const ownerPart = holders ? (owner90 * (100 - holders)) / 100 : owner90, holderPart = (owner90 * holders) / 100;
  let status;
  if (c.status === 'HandedOver') status = `<b>Claimed by ${esc(business)}.</b> pump.fun pays the shop's share straight to its wallet ${acct(c.owner)}.`;
  else if (c.status === 'Attested') status = `<b>${esc(business)} has claimed it.</b> The claim is in its review hold; after that, the shop is paid automatically.`;
  else status = `<b>Waiting for ${esc(business)} to claim.</b> Fees are held in the token's vault until the owner verifies.`;
  const paidRounds = (r.rounds || []).filter((x) => x.status === 'done' || x.status === 'paying');
  const paidHolders = paidRounds.reduce((a, x) => a + Number(x.holdersPaid || 0), 0);
  $('fees').innerHTML = `
    <p>${status}</p>
    <ul class="punch-list">
      <li><b>${esc(business)}: ${ownerPart}%</b> of ${esc(ticker)}'s creator fees${c.status === 'HandedOver' ? ` · paid so far: ${sol(c.ownerPaidLamports)} SOL` : ''}</li>
      ${holders ? `<li><b>${esc(ticker)} holders: ${holderPart}%</b>, chosen by the shop as a thank-you. Paid automatically to holders by time held${paidRounds.length ? ` · ${paidRounds.length} round(s), ${sol(paidHolders)} SOL so far` : ''}. <a href="/launchpad/how/#rules">How it's shared</a></li>` : ''}
      <li><b>PunchCard: ${c.platformBps / 100}%</b> service fee, which keeps launching at 0.02 SOL.</li>
    </ul>
    <p class="status-line">Launched ${new Date(c.launchedAt * 1000).toLocaleDateString()} by PunchCard's launcher ${acct(c.launcher)}, which gets no creator fees. <a href="/launchpad/coin/?mint=${encodeURIComponent(mint)}">Full token details</a></p>
    <div id="excluded"></div>`;
  if (holders) showExcluded().catch(() => {});
}
