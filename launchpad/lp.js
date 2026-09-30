// Shared helpers for the Community Launchpad pages: API, wallet, formatting.
// Wallets only SIGN; our backend submits, so the wallet's network setting doesn't matter.
export const API = 'https://punchcard-launchpad-devnet.quiet-mode-468e.workers.dev';
export const CLUSTER = 'devnet';

export const $ = (id) => document.getElementById(id);
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const sol = (lamports) => {
  const v = Number(lamports || 0) / 1e9;
  return v === 0 ? '0' : v < 0.001 ? v.toFixed(6) : v < 1 ? v.toFixed(4) : v.toFixed(3);
};
export const short = (k) => (k ? `${k.slice(0, 4)}…${k.slice(-4)}` : '');
export const explorer = (kind, id) => `https://solscan.io/${kind}/${id}${CLUSTER === 'devnet' ? '?cluster=devnet' : ''}`;

export async function api(path, body) {
  const r = await fetch(API + path, body ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {});
  let j = {};
  try { j = await r.json(); } catch { /* empty */ }
  if (!r.ok) throw new Error(j.error || `Request failed (${r.status})`);
  return j;
}

// ---------- Wallets ----------
// Any Solana wallet works. Modern wallets (Phantom, Solflare, Backpack, Glow, Jupiter, OKX, Coinbase…)
// announce themselves through the Wallet Standard; older ones only inject window globals.
// On a phone browser with no wallet, we offer to reopen this page inside a wallet app's browser.

const standardWallets = [];
{
  const register = (...ws) => {
    for (const w of ws) {
      const f = w.features || {};
      const solana = (w.chains || []).some((c) => c.startsWith('solana:'));
      if (solana && f['standard:connect'] && f['solana:signTransaction'] && !standardWallets.includes(w)) standardWallets.push(w);
    }
    return () => {};
  };
  window.addEventListener('wallet-standard:register-wallet', (e) => e.detail?.({ register }));
  try { window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', { detail: { register } })); } catch { /* old browser */ }
}

// Injected-only fallbacks, used when a wallet doesn't speak the Wallet Standard.
const LEGACY = [
  ['Phantom', () => window.phantom?.solana],
  ['Solflare', () => window.solflare],
  ['Backpack', () => window.backpack],
  ['Solana wallet', () => window.solana],
];

function listWallets() {
  const out = standardWallets.map((w) => ({ name: w.name, icon: w.icon, std: w }));
  const seen = new Set(out.map((w) => w.name.toLowerCase()));
  const legacyObjs = new Set();
  for (const [name, get] of LEGACY) {
    const p = get();
    if (!p || typeof p.connect !== 'function' || legacyObjs.has(p)) continue;
    legacyObjs.add(p);
    if (seen.has(name.toLowerCase()) || (name === 'Solana wallet' && out.length)) continue;
    out.push({ name, icon: null, legacy: p });
  }
  return out;
}

const isMobile = () => /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
const here = () => encodeURIComponent(location.href), origin = () => encodeURIComponent(location.origin);
const MOBILE_APPS = [
  ['Phantom', () => `https://phantom.app/ul/browse/${here()}?ref=${origin()}`],
  ['Solflare', () => `https://solflare.com/ul/v1/browse/${here()}?ref=${origin()}`],
  ['Backpack', () => `https://backpack.app/ul/v1/browse/${here()}?ref=${origin()}`],
];
const INSTALL = [['Phantom', 'https://phantom.app/download'], ['Solflare', 'https://solflare.com/download'], ['Backpack', 'https://backpack.app/downloads']];

let active = null; // { name, std?, legacy?, account?, address }
const LAST = 'pc-last-wallet';

/** Shows the wallet picker; resolves with the chosen wallet entry, or null if closed. */
function pickWallet(wallets) {
  return new Promise((resolve) => {
    const d = document.createElement('dialog');
    d.className = 'wallet-pick';
    const rows = wallets.length
      ? wallets.map((w, i) => `<button type="button" class="wallet-row" data-i="${i}">${w.icon ? `<img src="${esc(w.icon)}" alt="" width="32" height="32">` : '<span class="wallet-dot" aria-hidden="true"></span>'}<span>${esc(w.name)}</span></button>`).join('')
      : isMobile()
        ? `<p>No wallet in this browser. Open this page inside your wallet app:</p>${MOBILE_APPS.map(([n, u]) => `<a class="wallet-row" href="${esc(u())}"><span class="wallet-dot" aria-hidden="true"></span><span>Open in ${n}</span></a>`).join('')}<p class="status-line">Using another wallet? Open its app, go to its built-in browser and visit this page.</p>`
        : `<p>No Solana wallet found in this browser. Install one, then reload this page:</p>${INSTALL.map(([n, u]) => `<a class="wallet-row" href="${u}" target="_blank" rel="noopener"><span class="wallet-dot" aria-hidden="true"></span><span>Get ${n}</span></a>`).join('')}`;
    d.innerHTML = `<div class="wallet-inner"><h2>${wallets.length ? 'Choose your wallet' : 'Connect a Solana wallet'}</h2><div class="wallet-list">${rows}</div><button type="button" class="btn-secondary wallet-close">Cancel</button></div>`;
    const done = (v) => { d.close(); d.remove(); resolve(v); };
    d.addEventListener('click', (e) => {
      const row = e.target.closest('button.wallet-row');
      if (row) return done(wallets[Number(row.dataset.i)]);
      if (e.target.closest('.wallet-close') || e.target === d) done(null);
    });
    d.addEventListener('cancel', (e) => { e.preventDefault(); done(null); });
    document.body.appendChild(d);
    d.showModal();
  });
}

/** Lets the user pick any Solana wallet, connects it, and returns its address. */
export async function connectWallet() {
  // Wallets can register a moment after the page loads.
  if (!listWallets().length) await new Promise((r) => setTimeout(r, 400));
  const wallets = listWallets();
  let last = null; try { last = localStorage.getItem(LAST); } catch { /* private mode */ }
  wallets.sort((a, b) => (b.name === last) - (a.name === last));
  const w = wallets.length === 1 && isMobile() ? wallets[0] : await pickWallet(wallets);
  if (!w) throw new Error(wallets.length ? 'No wallet chosen.' : 'Connect a Solana wallet to continue.');
  if (w.std) {
    const { accounts } = await w.std.features['standard:connect'].connect();
    const account = accounts?.[0] || w.std.accounts?.[0];
    if (!account) throw new Error(`${w.name} didn't share an account.`);
    active = { ...w, account, address: account.address };
  } else {
    const r = await w.legacy.connect();
    active = { ...w, address: (r?.publicKey || w.legacy.publicKey).toString() };
  }
  try { localStorage.setItem(LAST, w.name); } catch { /* private mode */ }
  return active.address;
}

function need() { if (!active) throw new Error('Connect a wallet first.'); return active; }
const chainFor = (w) => (w.std.chains || []).includes(`solana:${CLUSTER}`) ? `solana:${CLUSTER}` : undefined;

export function b64ToBytes(b64) { return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); }
export function bytesToB64(bytes) { let s = ''; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); }

/** Ask the wallet to sign a base64 v0 transaction we built; returns the signed tx as base64. */
export async function signTx(b64) {
  const w = need();
  const bytes = b64ToBytes(b64);
  if (w.std) {
    const [out] = await w.std.features['solana:signTransaction'].signTransaction({ transaction: bytes, account: w.account, chain: chainFor(w) });
    return bytesToB64(out.signedTransaction);
  }
  const signed = await w.legacy.signTransaction(window.solanaWeb3.VersionedTransaction.deserialize(bytes));
  return bytesToB64(signed.serialize());
}

/** Ask the wallet to sign a text message; returns the signature as base64. */
export async function signMessage(text) {
  const w = need();
  const message = new TextEncoder().encode(text);
  if (w.std) {
    const f = w.std.features['solana:signMessage'];
    if (!f) throw new Error(`${w.name} can't sign messages. Try Phantom, Solflare or Backpack.`);
    const [out] = await f.signMessage({ account: w.account, message });
    return bytesToB64(out.signature);
  }
  const r = await w.legacy.signMessage(message, 'utf8');
  return bytesToB64(r.signature || r);
}

export function countdown(untilSecs) {
  const s = Math.max(0, untilSecs - Math.floor(Date.now() / 1000));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (s === 0) return 'ended';
  if (d > 0) return `${d} day${d === 1 ? '' : 's'} ${h} h`;
  if (h > 0) return `${h} h ${m} min`;
  return `${m} min ${s % 60} s`;
}

/** Square-crops and resizes an uploaded image to a 512px PNG (base64, no prefix). */
export function imageToPng(file, size = 512) {
  return new Promise((resolve, reject) => {
    if (!file) return resolve(null);
    const img = new Image();
    const url = URL.createObjectURL(file);
    img.onload = () => {
      const c = document.createElement('canvas'); c.width = size; c.height = size;
      const s = Math.min(img.width, img.height);
      c.getContext('2d').drawImage(img, (img.width - s) / 2, (img.height - s) / 2, s, s, 0, 0, size, size);
      URL.revokeObjectURL(url);
      resolve(c.toDataURL('image/png').split(',')[1]);
    };
    img.onerror = () => reject(new Error('That image could not be read.'));
    img.src = url;
  });
}
