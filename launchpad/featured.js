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

const MILESTONES = [100, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000];
const usdFmt = (v) => (v >= 1000 ? `$${(v / 1000).toFixed(v >= 10000 ? 0 : 1).replace(/\.0$/, '')}K` : v < 100 ? `$${v.toFixed(2)}` : `$${Math.round(v).toLocaleString()}`);
const money = (lamports, usd) => {
  const s = Number(lamports) / 1e9;
  return usd ? `<b>${usdFmt(s * usd)}</b><small>${s.toLocaleString(undefined, { maximumFractionDigits: 3 })} SOL</small>` : `<b>${s.toLocaleString(undefined, { maximumFractionDigits: 3 })} SOL</b>`;
};

async function load() {
  const c = await fetch(`${API}/api/coins/${mint}`).then((x) => x.json());
  const usd = Number(c.solUsd) || null;
  const handedOver = c.status === 'HandedOver';
  let status;
  if (handedOver) status = `<b>Claimed by ${esc(business)}.</b> pump.fun pays the shop straight to its wallet ${acct(c.owner)} from every trade.`;
  else if (c.status === 'Attested') status = `<b>${esc(business)} has claimed it.</b> Its fees are held safely until the review hold ends, then paid to the shop automatically.`;
  else status = `<b>Waiting for ${esc(business)} to claim.</b> Fees are held in the token's vault until the owner verifies.`;
  const forBusiness = BigInt(c.feesBusinessLamports || 0) + (handedOver ? 0n : BigInt(c.feesProcessingLamports || 0));
  const raisedUsd = usd ? (Number(forBusiness) / 1e9) * usd : null;

  // milestones for what's been raised for the business
  let milestones = '';
  if (raisedUsd !== null) {
    const next = MILESTONES.find((m) => raisedUsd < m);
    const ni = next ? MILESTONES.indexOf(next) : MILESTONES.length;
    // Milestones sit evenly along the bar (centre of each column); the fill runs to where the shop is.
    const at = (i) => ((i + 0.5) / MILESTONES.length) * 100;
    const from = ni === 0 ? 0 : at(ni - 1), to = next ? at(ni) : 100;
    const lo = ni === 0 ? 0 : MILESTONES[ni - 1];
    const pct = next ? from + ((raisedUsd - lo) / (next - lo)) * (to - from) : 100;
    milestones = `<div class="ms">
      <div class="ms-head"><span>Milestones for ${esc(business)}</span><span>${next ? `${usdFmt(next - raisedUsd)} to go to ${usdFmt(next)}` : 'Every milestone reached!'}</span></div>
      <div class="ms-track" role="progressbar" aria-label="Raised for ${esc(business)}" aria-valuenow="${Math.round(raisedUsd)}" aria-valuemin="0" aria-valuemax="${MILESTONES.at(-1)}">
        <div class="ms-bar"><span style="width:${pct.toFixed(1)}%"></span></div>
        <ol class="ms-tiers" style="--n:${MILESTONES.length}">${MILESTONES.map((m) => `<li class="${raisedUsd >= m ? 'done' : m === next ? 'next' : ''}"><i></i>${usdFmt(m)}${m === MILESTONES.at(-1) ? '+' : ''}</li>`).join('')}</ol>
      </div>
    </div>`;
  }

  $('fees').innerHTML = `
    <p>${status}</p>
    <div class="dash">
      <div class="dash-hero"><span>Creator fees generated by ${esc(ticker)}</span>${money(c.feesTotalLamports || 0, usd)}</div>
      <div class="dash-tiles">
        <div class="dash-tile"><span>${handedOver ? `Paid to ${esc(business)}` : `Raised for ${esc(business)}`}</span>${money(forBusiness, usd)}
          <em>${handedOver ? 'Straight to the shop\'s wallet' : 'Held for the shop until its review hold ends'}</em></div>
        ${c.communityShares ? `<div class="dash-tile"><span>Shared with the ${esc(ticker)} community</span>${money(c.feesCommunityLamports || 0, usd)}
          <em>${esc(business)}'s thank-you to holders · ${Number(c.feesCommunityPaidLamports || 0) > 0 ? `${(Number(c.feesCommunityPaidLamports) / 1e9).toLocaleString(undefined, { maximumFractionDigits: 3 })} SOL paid out so far` : 'paid automatically in weekly rounds'}</em></div>` : ''}
      </div>
      ${milestones}
      <p class="dash-note">Read live from the Solana blockchain and updated every few minutes${usd ? `. Dollar amounts at today's SOL price ($${usd.toFixed(2)})` : ''}. ${c.communityShares ? `<a href="/launchpad/how/#rules">How the community share works</a>` : ''}</p>
    </div>
    <p class="status-line">Launched ${new Date(c.launchedAt * 1000).toLocaleDateString()} by PunchCard's launcher ${acct(c.launcher)}, which gets no creator fees. <a href="/launchpad/coin/?mint=${encodeURIComponent(mint)}">Full token details</a></p>
    ${Number(c.launchBurnTokens || 0) > 0 ? `<p class="status-line">🔥 <b>Fair launch:</b> the launcher's ${(c.firstBuyLamports / 1e9).toLocaleString()} SOL first buy was capped at 0.5% of the supply; <b>${Math.round(Number(c.launchBurnTokens) / 1e6).toLocaleString()} tokens were burned</b> at launch.${c.burnTier ? ` <span class="honour h-${c.burnTier.key}">${c.burnTier.emoji} ${c.burnTier.name}</span>` : ''}</p>` : ''}
    <div id="excluded"></div>`;
  if (c.communityShares) showExcluded().catch(() => {});
}
