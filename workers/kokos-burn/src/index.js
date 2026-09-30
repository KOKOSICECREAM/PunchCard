// KOKOS burn — a Solana Pay transaction request for KOKOS Ice Cream's POS.
//
// The POS shows   solana:<this worker>?a=<raw>&r=<reference>&c=<cents>&e=<expiry>
// A wallet that scans it:
//   GET  → { label, icon }                         what the wallet shows before connecting
//   POST { account } → { transaction, message }    the burn for that account to sign
//
// The transaction is the payment: a Token-2022 BurnChecked of `a` base units of KOKOS from the
// customer's own account, carrying the POS's reference key (so the POS can find it) and a shop
// memo. The customer signs and sends it from their wallet. This worker holds no keys and no
// funds; it only builds an unsigned transaction. The POS independently checks on-chain that
// the burn is the KOKOS mint and at least `a`, so nothing here needs to be trusted for payment.
import { Connection, PublicKey, Transaction, TransactionInstruction } from '@solana/web3.js';

const KOKOS = {
  MINT: 'XrR9rqzFCBEcYoeyKrHV2uYFmEkwPCh6cxB3KuPCGd5',
  DECIMALS: 6,
  TOKEN_2022: 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb',
  ATA_PROGRAM: 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL',
  MEMO: 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr',
};
const SHOP = { label: 'KOKOS Ice Cream', icon: 'https://punchcard.club/kokos-skoop/kokos.png' };
// Solana's api.mainnet-beta blocks Cloudflare's network ("IP or provider is blocked"), and
// publicnode refuses token-balance lookups without a key — so the balance is read with plain
// getAccountInfo (served everywhere) and Solana Tracker's public RPC goes first.
const RPCS = ['https://rpc.solanatracker.io/public', 'https://solana-rpc.publicnode.com'];
const EXPIRY_GRACE = 30;          // seconds past the QR's expiry we still build a burn

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept, Accept-Encoding',
};
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS } });
const fmt = raw => (Number(raw) / 10 ** KOKOS.DECIMALS).toLocaleString('en-US', { maximumFractionDigits: 2 });

function parseRequest(url) {
  const q = url.searchParams;
  const a = q.get('a'), r = q.get('r'), c = Number(q.get('c')), e = Number(q.get('e'));
  if (!/^\d{1,20}$/.test(a || '') || BigInt(a) <= 0n) return { error: 'Invalid amount' };
  let reference;
  try { reference = new PublicKey(r); } catch { return { error: 'Invalid payment reference' }; }
  if (!Number.isFinite(c) || c <= 0 || !Number.isFinite(e)) return { error: 'Invalid payment request' };
  return { amount: BigInt(a), reference, cents: c, expiry: e };
}

async function withRpc(fn) {
  let last;
  for (const url of RPCS) {
    try { return await fn(new Connection(url, 'confirmed')); }
    catch (err) { last = err; console.warn('rpc attempt failed', url, String(err && err.message || err).slice(0, 160)); }
  }
  throw last;
}

// The customer's KOKOS account: their associated account if it holds enough, else any that does.
async function findSource(conn, owner, amount) {
  const ata = PublicKey.findProgramAddressSync(
    [owner.toBuffer(), new PublicKey(KOKOS.TOKEN_2022).toBuffer(), new PublicKey(KOKOS.MINT).toBuffer()],
    new PublicKey(KOKOS.ATA_PROGRAM))[0];
  let total = 0n;
  const info = await conn.getAccountInfo(ata);
  // A token account's amount is the u64 at byte 64 (same base layout in Token-2022).
  if (info && info.owner.toBase58() === KOKOS.TOKEN_2022 && info.data.length >= 72) {
    const b = new DataView(info.data.buffer, info.data.byteOffset + 64, 8).getBigUint64(0, true);
    if (b >= amount) return { src: ata, total: b };
    total = b;
  }
  // Rare: KOKOS held outside the associated account. Needs an indexed call; if the RPC refuses
  // it, report what the associated account holds.
  let res;
  try { res = await conn.getParsedTokenAccountsByOwner(owner, { mint: new PublicKey(KOKOS.MINT) }); }
  catch { return { src: null, total }; }
  let best = null;
  total = 0n;
  for (const acc of res.value) {
    const amt = BigInt(acc.account.data.parsed.info.tokenAmount.amount);
    total += amt;
    if (amt >= amount && (!best || amt > best.amt)) best = { pubkey: acc.pubkey, amt };
  }
  return { src: best ? best.pubkey : null, total };
}

function burnTransaction({ owner, source, amount, reference, memo, blockhash }) {
  const data = new Uint8Array(10);
  data[0] = 15;                                   // TokenInstruction::BurnChecked
  let v = amount;
  for (let i = 1; i <= 8; i++) { data[i] = Number(v & 0xffn); v >>= 8n; }
  data[9] = KOKOS.DECIMALS;
  const burn = new TransactionInstruction({
    programId: new PublicKey(KOKOS.TOKEN_2022),
    keys: [
      { pubkey: source, isSigner: false, isWritable: true },
      { pubkey: new PublicKey(KOKOS.MINT), isSigner: false, isWritable: true },
      { pubkey: owner, isSigner: true, isWritable: false },
      { pubkey: reference, isSigner: false, isWritable: false },   // found by the POS; ignored by the token program
    ],
    data: Buffer.from(data),
  });
  const note = new TransactionInstruction({ programId: new PublicKey(KOKOS.MEMO), keys: [], data: Buffer.from(memo, 'utf8') });
  return new Transaction({ feePayer: owner, recentBlockhash: blockhash }).add(burn, note);
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    if (request.method === 'GET') return json(SHOP);
    if (request.method !== 'POST') return json({ message: 'Method not allowed' }, 405);

    const req = parseRequest(url);
    if (req.error) return json({ message: req.error }, 400);
    if (Math.floor(Date.now() / 1000) > req.expiry + EXPIRY_GRACE) {
      return json({ message: 'This payment QR has expired — ask the cashier for a new one.' }, 400);
    }
    let owner;
    try { owner = new PublicKey((await request.json()).account); } catch { return json({ message: 'Invalid account' }, 400); }

    try {
      const { src, total } = await withRpc(c => findSource(c, owner, req.amount));
      if (!src) return json({ message: `Not enough KOKOS: this payment burns ${fmt(req.amount)}, your wallet has ${fmt(total)}.` }, 400);
      const { blockhash } = await withRpc(c => c.getLatestBlockhash('confirmed'));
      const usd = (req.cents / 100).toFixed(2);
      const tx = burnTransaction({ owner, source: src, amount: req.amount, reference: req.reference,
        memo: `KOKOS Ice Cream · POS payment · $${usd}`, blockhash });
      const transaction = tx.serialize({ requireAllSignatures: false, verifySignatures: false }).toString('base64');
      return json({ transaction, message: `Pay $${usd} at KOKOS Ice Cream by burning ${fmt(req.amount)} KOKOS` });
    } catch (err) {
      console.error('build failed', err && (err.stack || err.message || err));
      return json({ message: 'Could not build the payment right now — try again.' }, 502);
    }
  },
};
