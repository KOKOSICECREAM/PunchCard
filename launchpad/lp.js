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

export function provider() {
  const p = window.phantom?.solana || window.solflare || window.backpack || window.solana;
  return p && typeof p.connect === 'function' ? p : null;
}

export async function connectWallet() {
  const p = provider();
  if (!p) {
    throw new Error('No Solana wallet found. Install Phantom (phantom.app), or open this page inside the Phantom app.');
  }
  const r = await p.connect();
  return (r?.publicKey || p.publicKey).toString();
}

export function b64ToBytes(b64) { return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); }
export function bytesToB64(bytes) { let s = ''; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); }

/** Ask the wallet to sign a base64 v0 transaction we built; returns the signed tx as base64. */
export async function signTx(b64) {
  const p = provider();
  const tx = window.solanaWeb3.VersionedTransaction.deserialize(b64ToBytes(b64));
  const signed = await p.signTransaction(tx);
  return bytesToB64(signed.serialize());
}

/** Ask the wallet to sign a text message; returns the signature as base64. */
export async function signMessage(text) {
  const p = provider();
  const r = await p.signMessage(new TextEncoder().encode(text), 'utf8');
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
