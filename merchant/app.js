// PunchCard Merchant: the owner dashboard. Sign in with the verified owner wallet, then see creator fees, the token
// (price + 6-hour change, holders) and manage perks. Talks to /api/merchant/* with an 8-hour session token.
// ?net=devnet uses the test network (remembered for the tab).
import { esc, short, connectWallet, signMessage, signTextAsTx } from '/launchpad/lp.js';

const DEVNET = (() => {
  try {
    if (new URLSearchParams(location.search).get('net') === 'devnet') sessionStorage.setItem('pc-merchant-net', 'devnet');
    return sessionStorage.getItem('pc-merchant-net') === 'devnet';
  } catch { return false; }
})();
const API = DEVNET ? 'https://punchcard-launchpad-devnet.quiet-mode-468e.workers.dev' : 'https://punchcard-launchpad.quiet-mode-468e.workers.dev';
const KEY = DEVNET ? 'pc-merchant-session-devnet' : 'pc-merchant-session';
const $ = (id) => document.getElementById(id);
const app = $('app');

let session = null; // { token, expires, wallet, tokens: [] }
let mint = null;
try { session = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch { session = null; }
if (session && session.expires * 1000 < Date.now()) session = null;

async function call(path, body) {
  const r = await fetch(API + path, {
    method: body ? 'POST' : 'GET',
    headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(session?.token ? { Authorization: 'Bearer ' + session.token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j = {}; try { j = await r.json(); } catch { /* empty */ }
  if (r.status === 401) { signOut(); throw new Error(j.error || 'Please sign in again.'); }
  if (!r.ok) throw new Error(j.error || `Request failed (${r.status})`);
  return j;
}
const save = () => { try { localStorage.setItem(KEY, JSON.stringify(session)); } catch { /* private mode */ } };
function signOut() { session = null; try { localStorage.removeItem(KEY); } catch { /* ignore */ } render(); }

const SOL = (l) => { const n = Number(l || 0) / 1e9; return n >= 100 ? n.toFixed(1) : n >= 1 ? n.toFixed(2) : n >= 0.01 ? n.toFixed(3) : n.toFixed(4); };
const usd = (l, solUsd) => (solUsd ? '$' + ((Number(l || 0) / 1e9) * solUsd).toLocaleString(undefined, { maximumFractionDigits: 0 }) : '');
const price = (v) => { if (!v) return '–'; if (v >= 0.01) return '$' + v.toFixed(4); const s = v.toFixed(12).replace(/0+$/, ''); const m = /^0\.(0+)(\d{1,3})/.exec(s); return m ? `$0.0<sub>${m[1].length}</sub>${m[2]}` : '$' + v; };
const when = (t) => new Date(t * 1000).toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
const greeting = () => { const h = new Date().getHours(); return h < 12 ? 'Good morning,' : h < 18 ? 'Good afternoon,' : 'Good evening,'; };

// ---------- sign in ----------
function signInView(msg = '') {
  $('tabs').hidden = true; $('switch').hidden = true;
  app.innerHTML = `<section class="m-signin">
    <img src="/brand/punchcard.svg" alt="" width="64" height="64" style="justify-self:center">
    <h1>Your business, your token, your perks.</h1>
    <p>Sign in with the wallet you verified your business with. It's a free signature: nothing is sent and nothing is charged.</p>
    ${msg ? `<div class="m-msg">${msg}</div>` : ''}
    <button class="m-btn wide" type="button" id="signin">Connect owner wallet</button>
    <p style="font-size:.82rem">No token yet? Someone may have made one for you. <a href="/launchpad/owners/">Find your business</a></p>
    ${DEVNET ? '<p style="font-size:.78rem">Test network</p>' : ''}
  </section>`;
  $('signin').onclick = signIn;
}
async function signIn() {
  const btn = $('signin'); btn.classList.add('m-busy'); btn.textContent = 'Connecting…';
  try {
    const wallet = await connectWallet();
    const signedAt = Math.floor(Date.now() / 1000);
    const message = ['PunchCard Merchant sign-in', `Wallet: ${wallet}`, `Time: ${signedAt}`].join('\n');
    btn.textContent = 'Approve in your wallet (free)…';
    let proof;
    try { proof = { signature: await signMessage(message) }; }
    catch (e) { if (/reject|cancel|denied/i.test(e.message)) throw e; proof = { signedTx: await signTextAsTx(wallet, message) }; }
    session = await call('/api/merchant/login', { wallet, signedAt, ...proof });
    if (!session.tokens?.length) {
      const w = session.wallet; session = null;
      return signInView(`This wallet (${esc(short(w))}) isn't the verified owner of a PunchCard token yet. If someone made a token for your business, <a href="/launchpad/owners/">find it and claim it</a> first, then sign in with that wallet.`);
    }
    save(); render();
  } catch (e) {
    signInView(/reject|cancel|denied/i.test(e.message) ? '' : esc(e.message));
  }
}

// ---------- shell ----------
function current() { return session.tokens.find((t) => t.mint === mint) || session.tokens[0]; }
function setupSwitch() {
  const sel = $('tokenSel'); $('switch').hidden = false;
  sel.innerHTML = session.tokens.map((t) => `<option value="${esc(t.mint)}">$${esc(t.ticker)}</option>`).join('');
  sel.value = mint; sel.disabled = session.tokens.length < 2;
  $('switchImg').src = `${API}/img/${encodeURIComponent(mint)}`;
  sel.onchange = () => { mint = sel.value; try { localStorage.setItem(KEY + '-mint', mint); } catch { /* ignore */ } route(); };
}
function tabsOn(tab) { $('tabs').hidden = false; document.querySelectorAll('.m-tabs a').forEach((a) => a.classList.toggle('on', a.dataset.tab === tab)); }
function render() {
  if (!session) return signInView();
  let saved = null; try { saved = localStorage.getItem(KEY + '-mint'); } catch { /* ignore */ }
  mint = session.tokens.some((t) => t.mint === saved) ? saved : session.tokens[0].mint;
  setupSwitch(); route();
}
function route() {
  if (!session) return signInView();
  const h = location.hash.replace('#', '') || 'home';
  if (h === 'fees') return feesView();
  if (h === 'perks') return perksView();
  if (h.startsWith('edit')) return editView(Number(h.split('-')[1] || 0));
  return homeView();
}
window.addEventListener('hashchange', route);
const loading = () => { app.innerHTML = '<p class="m-sub" style="padding:2rem 0;text-align:center">Loading…</p>'; };
const oops = (e) => { app.innerHTML = `<div class="m-msg">${esc(e.message)}</div><button class="m-btn ghost" type="button" id="retry">Try again</button>`; $('retry').onclick = route; };

// ---------- overview ----------
async function homeView() {
  tabsOn('home'); loading();
  try {
    const [o, pk] = await Promise.all([call('/api/merchant/overview?mint=' + encodeURIComponent(mint)), call('/api/merchant/perks?mint=' + encodeURIComponent(mint)).catch(() => null)]);
    const c = o.coin, t = current(), rate = c.solUsd;
    const page = `/launchpad/coin/?mint=${encodeURIComponent(mint)}`;
    const inReview = c.status === 'Attested';
    const reviewEnds = c.attestedAt + Math.max(c.holdSecs || 0, c.challengeSecs || 0);
    const chg = o.price?.change6h;
    const live = (pk?.perks || []).filter((x) => x.active).length + (pk?.member ? 1 : 0);
    const usesWeek = (pk?.perks || []).reduce((a, x) => a + (x.usesThisWeek || 0), 0);
    app.innerHTML = `
      <div class="m-hello"><p>${greeting()}</p><h1>${esc(c.business.name)}</h1></div>
      <div class="m-card dark">
        ${inReview ? `<p class="m-label">Your claim is in review</p>
          <div class="m-big">${SOL(Number(c.feesInVaultLamports) * (1 - (c.platformBps || 0) / 10000))}<small>SOL waiting for you ${usd(Number(c.feesInVaultLamports) * (1 - (c.platformBps || 0) / 10000), rate) ? '· about ' + usd(Number(c.feesInVaultLamports) * (1 - (c.platformBps || 0) / 10000), rate) : ''}</small></div>
          <div class="m-review"><span>Paid to <b>${esc(short(c.owner))}</b> automatically after the review ends:</span><b>${when(reviewEnds)}</b></div>
          <p class="m-sub">Fees earned during the review are included. After that, your share goes straight to your wallet with every trade.</p>`
        : `<p class="m-label">Creator fees paid to you</p>
          <div class="m-big">${SOL(c.businessPaidLamports)}<small>SOL${rate ? ' · about ' + usd(c.businessPaidLamports, rate) : ''}</small></div>
          <div class="m-stats">
            <div class="m-stat"><b>${SOL(c.ownerPaidLamports)}</b><span>claim payout</span></div>
            <div class="m-stat"><b>${SOL(BigInt(c.businessPaidLamports) - BigInt(c.ownerPaidLamports))}</b><span>direct since</span></div>
            <div class="m-stat"><b>${SOL(c.feesPendingAtPumpLamports)}</b><span>waiting at pump.fun</span></div>
          </div>
          <p class="m-sub">Fees go straight to your wallet ${esc(short(c.owner))} with every trade.${c.communityBps ? ` ${c.communityBps / 100}% of your share goes to ${esc(c.ticker)} holders, as you chose.` : ''}</p>`}
      </div>
      <div class="m-card">
        <div class="m-row"><p class="m-label">$${esc(c.ticker)}</p><span class="m-pill">Live</span></div>
        <div class="m-price"><b>${price(o.price?.usd)}</b>${chg === null || chg === undefined ? '' : `<span class="m-chg ${chg >= 0 ? 'up' : 'down'}">${chg >= 0 ? '+' : ''}${Number(chg).toFixed(1)}% <small>last 6 h</small></span>`}</div>
        <div class="m-stats" style="grid-template-columns:repeat(2,minmax(0,1fr))">
          <div class="m-stat"><b>${o.holders ?? c.holders ?? '–'}</b><span>holders</span></div>
          <div class="m-stat"><b>${o.newHoldersThisWeek === null || o.newHoldersThisWeek === undefined ? '–' : '+' + o.newHoldersThisWeek}</b><span>new holders this week</span></div>
        </div>
        <div class="m-row"><a class="m-btn ghost" href="${page}">Your page</a><a class="m-btn ghost" href="https://pump.fun/coin/${encodeURIComponent(mint)}" target="_blank" rel="noopener">pump.fun</a><button class="m-btn ghost" type="button" id="share">Share</button></div>
      </div>
      <div class="m-card">
        <div class="m-row"><p class="m-label">Your perks</p><span class="m-pill warm">${live} live</span></div>
        <p class="m-sub">${pk?.canEdit === false ? 'You can add perks for your holders once your claim is complete.' : usesWeek ? `Holders used your perks <b>${usesWeek} time${usesWeek === 1 ? '' : 's'}</b> this week.` : live ? 'Your perks are live on your page.' : 'Thank your holders with a perk: a discount, a freebie, something only they get.'}</p>
        <a class="m-btn gold wide" href="#perks">${live ? 'Manage perks' : 'Add a perk'}</a>
      </div>
      <p class="m-sub" style="text-align:center">Signed in as ${esc(short(session.wallet))} · <a href="#" id="out">Sign out</a></p>`;
    $('out').onclick = (e) => { e.preventDefault(); signOut(); };
    $('share').onclick = async () => {
      const url = location.origin + page;
      try { if (navigator.share) await navigator.share({ title: `$${c.ticker} on PunchCard`, url }); else { await navigator.clipboard.writeText(url); $('share').textContent = 'Link copied'; } } catch { /* cancelled */ }
    };
  } catch (e) { oops(e); }
}

// ---------- fees ----------
async function feesView() {
  tabsOn('fees'); loading();
  try {
    const o = await call('/api/merchant/overview?mint=' + encodeURIComponent(mint)), c = o.coin;
    const direct = BigInt(c.businessPaidLamports) - BigInt(c.ownerPaidLamports);
    app.innerHTML = `
      <div class="m-hello"><p>Every payment is on chain</p><h1>Creator fees</h1></div>
      <div class="m-card">
        <div class="m-stats"><div class="m-stat"><b>${SOL(c.businessPaidLamports)}</b><span>paid to you</span></div><div class="m-stat"><b>${SOL(c.feesCommunityPaidLamports)}</b><span>paid to holders</span></div><div class="m-stat"><b>${SOL(c.feesPlatformLamports)}</b><span>PunchCard fee</span></div></div>
        <div>
          ${c.status === 'Attested' ? `<div class="m-pay"><b>Claim payout (in review)</b><b>${SOL(Number(c.feesInVaultLamports) * (1 - (c.platformBps || 0) / 10000))} SOL</b><span>Paid automatically after ${when(c.attestedAt + Math.max(c.holdSecs || 0, c.challengeSecs || 0))}</span></div>` : ''}
          ${BigInt(c.ownerPaidLamports) > 0n ? `<div class="m-pay"><b>Claim payout</b><b>${SOL(c.ownerPaidLamports)} SOL</b><span>Everything held for you before your claim</span></div>` : ''}
          ${direct > 0n ? `<div class="m-pay"><b>Direct from pump.fun</b><b>${SOL(direct)} SOL</b><span>Your share of every trade since your claim</span></div>` : ''}
          <div class="m-pay"><b>Waiting at pump.fun</b><b>${SOL(c.feesPendingAtPumpLamports)} SOL</b><span>Sent to you with the next distribution</span></div>
          ${c.communityBps ? `<div class="m-pay"><b>Building for holders</b><b>${SOL(BigInt(c.feesCommunityLamports) - BigInt(c.feesCommunityPaidLamports))} SOL</b><span>${c.communityBps / 100}% of your share, paid in holder rounds</span></div>` : ''}
        </div>
        <a class="m-btn ghost" href="https://solscan.io/account/${encodeURIComponent(c.owner)}${DEVNET ? '?cluster=devnet' : ''}" target="_blank" rel="noopener">See every payment on Solscan</a>
      </div>
      <p class="m-sub">Creator fees come from trading on pump.fun, so they go up and down with activity. PunchCard's 10% service fee is what keeps launching affordable for your fans.</p>`;
  } catch (e) { oops(e); }
}

// ---------- perks ----------
let perksCache = null;
const EVERY = { once: 'Once per holder', day: 'Once a day', week: 'Once a week', month: 'Once a month' };
async function perksView() {
  tabsOn('perks'); loading();
  try {
    const pk = perksCache = await call('/api/merchant/perks?mint=' + encodeURIComponent(mint)), t = current();
    app.innerHTML = `
      <div class="m-hello"><p>Thank your holders</p><h1>Your perks</h1></div>
      ${pk.canEdit ? '' : '<div class="m-msg">You can add perks once your claim is complete (after the review period).</div>'}
      <ul class="m-list">${pk.perks.map((x) => `
        <li class="m-perk"><div class="m-row"><b>${esc(x.title)}</b><span class="m-pill ${x.active ? '' : 'paused'}">${x.active ? 'Live' : 'Paused'}</span></div>
          ${x.description ? `<p>${esc(x.description)}</p>` : ''}
          <div class="meta"><span class="m-pill warm">Hold $${x.minUsd} of ${esc(t.ticker)}</span><span class="m-pill warm">${EVERY[x.every]}</span><span class="m-pill warm">${x.kind === 'online' ? 'Online code' : 'In person'}</span></div>
          <p style="font-size:.78rem">${x.kind === 'online' ? `${x.codesLeft} of ${x.codesTotal} codes left · ` : ''}used ${x.uses} time${x.uses === 1 ? '' : 's'}</p>
          ${pk.canEdit ? `<div class="acts"><a class="m-btn ghost" href="#edit-${x.id}">Edit</a><button class="m-btn ghost" type="button" data-act="${x.active ? 'pause' : 'resume'}" data-id="${x.id}">${x.active ? 'Pause' : 'Resume'}</button><button class="m-btn ghost" type="button" data-act="delete" data-id="${x.id}">Delete</button></div>` : ''}
        </li>`).join('')}
        ${pk.fixedPerks.map((x) => `<li class="m-perk"><div class="m-row"><b>${esc(x.title)}</b><span class="m-pill">Live</span></div><p>Set up with PunchCard. Ask us to change it.</p><div class="meta"><span class="m-pill warm">Hold $${x.minUsd}</span><span class="m-pill warm">In person</span></div></li>`).join('')}
      </ul>
      ${!pk.perks.length && !pk.fixedPerks.length ? '<p class="m-sub">No perks yet. Holders love a reason to hold: a free item, a discount, early access.</p>' : ''}
      <div class="m-card">
        <div class="m-toggle"><div><p class="m-label">PunchCard Member perk</p><p class="m-sub">10% off for anyone holding $50 of PUNCH. Puts your business in front of every PunchCard member.</p></div>
          <button type="button" class="m-sw ${pk.member ? '' : 'off'}" role="switch" aria-checked="${pk.member}" id="member" ${pk.canEdit ? '' : 'disabled'} aria-label="PunchCard Member perk"></button></div>
      </div>
      ${pk.canEdit ? '<a class="m-btn wide" href="#edit-0">Add a perk</a>' : ''}
      <p class="m-sub" id="pmsg" role="status"></p>`;
    app.querySelectorAll('[data-act]').forEach((b) => b.onclick = async () => {
      if (b.dataset.act === 'delete' && b.textContent !== 'Tap again to delete') { b.textContent = 'Tap again to delete'; return; }
      b.classList.add('m-busy');
      try { await call('/api/merchant/perks/state', { mint, id: Number(b.dataset.id), action: b.dataset.act }); perksView(); } catch (e) { $('pmsg').textContent = e.message; b.classList.remove('m-busy'); }
    });
    const sw = $('member');
    if (pk.canEdit) sw.onclick = async () => {
      sw.classList.add('m-busy');
      try { await call('/api/merchant/member', { mint, on: !pk.member }); perksView(); } catch (e) { $('pmsg').textContent = e.message; sw.classList.remove('m-busy'); }
    };
  } catch (e) { oops(e); }
}

// ---------- perk editor ----------
async function editView(id) {
  tabsOn('perks');
  if (!perksCache) { loading(); try { perksCache = await call('/api/merchant/perks?mint=' + encodeURIComponent(mint)); } catch (e) { return oops(e); } }
  const x = id ? perksCache.perks.find((p) => p.id === id) : null, t = current();
  if (id && !x) { location.hash = '#perks'; return; }
  const v = x || { title: '', description: '', minUsd: 50, every: 'once', kind: 'in_person', codesLeft: 0 };
  app.innerHTML = `
    <div class="m-hello"><p>${x ? 'Edit perk' : 'New perk'}</p><h1>What's the thank-you?</h1></div>
    <form id="pf" style="display:grid;gap:.9rem">
      <div class="m-field"><label for="t">Title</label><input id="t" value="${esc(v.title)}" maxlength="60" required placeholder="e.g. Free first month of coaching"><small>Short and clear. 60 characters max.</small></div>
      <div class="m-field"><label for="d">What it is</label><textarea id="d" maxlength="240" placeholder="e.g. Start any coaching plan with the first month on us.">${esc(v.description)}</textarea><small>Plain text, no links. 240 characters max.</small></div>
      <div class="m-field"><label for="h">Who qualifies</label><select id="h">${[10, 25, 50, 100, 250].map((n) => `<option value="${n}" ${n === v.minUsd ? 'selected' : ''}>Holds at least $${n} of ${esc(t.ticker)}</option>`).join('')}${[10, 25, 50, 100, 250].includes(v.minUsd) ? '' : `<option value="${v.minUsd}" selected>Holds at least $${v.minUsd} of ${esc(t.ticker)}</option>`}</select></div>
      <div class="m-field"><label for="o">How often</label><select id="o">${Object.entries(EVERY).map(([k, l]) => `<option value="${k}" ${k === v.every ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <div class="m-field"><label>Where</label>
        <div class="m-seg"><label><input type="radio" name="w" value="in_person" ${v.kind !== 'online' ? 'checked' : ''}>In person<small>Staff scan the holder's pass</small></label><label><input type="radio" name="w" value="online" ${v.kind === 'online' ? 'checked' : ''}>Online<small>The pass shows a discount code</small></label></div></div>
      <div class="m-field" id="codesF"><label for="c">Discount codes${x ? ' to add' : ''}</label><textarea id="c" placeholder="One code per line"></textarea>
        <small>Single-use codes from your shop, one per line. Each holder gets one per period.${x && v.kind === 'online' ? ` ${v.codesLeft} left now.` : ''}</small></div>
      <button class="m-btn wide" type="submit" id="save">${x ? 'Save changes' : 'Save and publish'}</button>
      <p class="m-sub" id="emsg" role="status" style="text-align:center">Shows on your token page right away. You can change or pause it any time.</p>
    </form>`;
  const sync = () => { $('codesF').hidden = app.querySelector('input[name="w"]:checked').value !== 'online'; };
  app.querySelectorAll('input[name="w"]').forEach((r) => r.onchange = sync); sync();
  $('pf').onsubmit = async (e) => {
    e.preventDefault();
    const kind = app.querySelector('input[name="w"]:checked').value;
    const body = { mint, id: id || undefined, title: $('t').value, description: $('d').value, minUsd: Number($('h').value), every: $('o').value, kind, codes: kind === 'online' ? $('c').value : '' };
    if (kind === 'online' && !x && !body.codes.trim()) { $('emsg').textContent = 'Add at least one discount code for an online perk.'; return; }
    $('save').classList.add('m-busy'); $('save').textContent = 'Saving…';
    try { await call('/api/merchant/perks', body); perksCache = null; location.hash = '#perks'; }
    catch (err) { $('emsg').textContent = err.message; $('save').classList.remove('m-busy'); $('save').textContent = x ? 'Save changes' : 'Save and publish'; }
  };
}

if ('serviceWorker' in navigator) navigator.serviceWorker.register('/merchant/sw.js', { scope: '/merchant/' }).catch(() => {});
render();
