// PunchCard Perk Pass (customer side). openPerkPass({ mint, perkId }) connects the wallet, asks it to sign a
// one-time message (no transaction, tokens never move), gets a short-lived pass from the backend and shows it
// full screen: business, perk, holdings, a live clock, a countdown and a branded QR the staff scan at
// /pass/?id=… (the server re-checks it there). No emoji: PunchCard icons only.
import { api, esc, short, connectWallet, signMessage, signTextAsTx } from '/launchpad/lp.js';
import { qrImg } from '/launchpad/qr.js';

const pad = (n) => String(n).padStart(2, '0');
let timer = 0;

function overlay() {
  let el = document.getElementById('perkPass');
  if (!el) {
    el = document.createElement('div');
    el.id = 'perkPass'; el.className = 'pp'; el.setAttribute('role', 'dialog'); el.setAttribute('aria-modal', 'true'); el.hidden = true;
    document.body.appendChild(el);
  }
  return el;
}
function close() { clearInterval(timer); const el = overlay(); el.hidden = true; el.innerHTML = ''; }

function showMessage(html) {
  const el = overlay();
  el.innerHTML = `<div class="pp-card pp-msg"><div class="pp-brand"><img src="/brand/punchcard.svg" alt="" width="28" height="28"><span>Punch<b>Card</b> Perk Pass</span></div>${html}<button class="btn-secondary pp-close" type="button">Close</button></div>`;
  el.hidden = false;
  el.querySelector('.pp-close').onclick = close;
}

function showPass(p) {
  const el = overlay(), url = `https://punchcard.club/pass/?id=${p.id}`;
  el.innerHTML = `<div class="pp-card">
    <div class="pp-brand"><img src="/brand/punchcard.svg" alt="" width="28" height="28"><span>Punch<b>Card</b> Perk Pass</span></div>
    <div class="pp-biz">${esc(p.business)}</div>
    <div class="pp-perk">${esc(p.perk)}</div>
    <div class="pp-holes" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i></div>
    <div class="pp-clock" id="ppClock" aria-label="Live clock">--:--:--</div>
    <div class="pp-qr"><img id="ppQr" alt="QR code for the staff to scan"></div>
    <div class="pp-meta"><span>Holder <b class="mono">${esc(short(p.wallet))}</b></span><span>Holds <b>$${Number(p.holdingsUsd || 0).toFixed(2)}</b> of ${esc(p.ticker)}</span></div>
    <div class="pp-bar"><span id="ppBar"></span></div>
    <div class="pp-left" id="ppLeft"></div>
    <p class="pp-hint">Show this to the staff. They scan the code to confirm it${p.oneTime ? ` and redeem it (once every ${p.everyDays} days)` : ''}.</p>
    <button class="btn-secondary pp-close" type="button">Done</button>
  </div>`;
  el.hidden = false;
  el.querySelector('.pp-close').onclick = close;
  qrImg(url).then((u) => { const i = document.getElementById('ppQr'); if (i) i.src = u; });
  // Live clock + countdown (the clock moving is how staff can tell it's not a screenshot; the server check is what counts).
  const skew = p.serverTime - Math.floor(Date.now() / 1000), total = p.expiresAt - p.issuedAt;
  const tick = () => {
    const d = new Date(), left = p.expiresAt - (Math.floor(Date.now() / 1000) + skew);
    const c = document.getElementById('ppClock'); if (!c) return clearInterval(timer);
    c.textContent = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    document.getElementById('ppBar').style.width = `${Math.max(0, (left / total) * 100)}%`;
    if (left <= 0) {
      clearInterval(timer);
      document.getElementById('ppLeft').textContent = 'This pass expired. Get a new one when you’re at the counter.';
      el.querySelector('.pp-card').classList.add('expired');
    } else document.getElementById('ppLeft').textContent = `Valid for ${Math.floor(left / 60)}:${pad(left % 60)}`;
  };
  tick(); clearInterval(timer); timer = setInterval(tick, 250);
}

/** Customer flow. `status` (optional) is an element for progress text. */
export async function openPerkPass({ mint, perkId, status }) {
  const say = (t) => { if (status) status.textContent = t; };
  try {
    say('Connecting your wallet…');
    const wallet = await connectWallet();
    say('Getting your pass ready…');
    const ch = await api('/api/perks/challenge', { mint, perkId, wallet });
    say('Approve the message in your wallet (it’s free and nothing is sent)…');
    let proof;
    try { proof = { signature: await signMessage(ch.message) }; }
    catch (e) {
      if (/reject|cancel|denied/i.test(e.message)) throw e;
      say('Your wallet can’t sign messages. Approve it as a transaction instead (it’s never sent and costs nothing)…');
      proof = { signedTx: await signTextAsTx(wallet, ch.message) };
    }
    say('Checking your holdings…');
    const pass = await api('/api/perks/pass', { nonce: ch.nonce, ...proof });
    say('');
    showPass(pass);
  } catch (e) {
    say('');
    if (/reject|cancel|denied/i.test(e.message)) return;
    showMessage(`<p class="pp-why">${esc(e.message)}</p>`);
  }
}
