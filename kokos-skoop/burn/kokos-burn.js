// Shared by the customer burn page and its tests: build the one transaction a KOKOS payment is.
// A Token-2022 BurnChecked from the payer's KOKOS account, with the POS's payment reference as an
// extra read-only key (the Solana Pay convention: the POS finds the transaction by that key), and
// a memo naming the shop. Needs `solanaWeb3` (browser global) or require('@solana/web3.js').
(function (root) {
  const KOKOS = {
    MINT: 'XrR9rqzFCBEcYoeyKrHV2uYFmEkwPCh6cxB3KuPCGd5',
    DECIMALS: 6,
    TOKEN_2022: 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb',
    MEMO: 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr',
  };
  const ATA_PROGRAM = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
  function ata(W, owner) {
    return W.PublicKey.findProgramAddressSync(
      [owner.toBuffer(), new W.PublicKey(KOKOS.TOKEN_2022).toBuffer(), new W.PublicKey(KOKOS.MINT).toBuffer()],
      new W.PublicKey(ATA_PROGRAM))[0];
  }
  // The payer's KOKOS account. Wallets and pump.fun keep KOKOS in the owner's associated account,
  // which is derived — no indexed RPC call. Only if that one is short do we list all their accounts.
  async function findSource(conn, W, owner, amount) {
    const a = ata(W, owner);
    try {
      const b = await conn.getTokenAccountBalance(a);
      const have = BigInt(b.value.amount);
      if (have >= amount) return { src: a, total: have };
    } catch (e) { /* no associated account */ }
    return findSourceIndexed(conn, W, owner, amount);
  }
  async function findSourceIndexed(conn, W, owner, amount) {
    const res = await conn.getParsedTokenAccountsByOwner(owner, { mint: new W.PublicKey(KOKOS.MINT) });
    const accts = res.value.map(a => ({ pubkey: a.pubkey, amount: BigInt(a.account.data.parsed.info.tokenAmount.amount) }))
      .sort((a, b) => (b.amount > a.amount ? 1 : -1));
    const total = accts.reduce((s, a) => s + a.amount, 0n);
    const src = accts.find(a => a.amount >= amount);
    return { src: src ? src.pubkey : null, total };
  }
  function buildBurnTx(W, { owner, source, amount, reference, memo, blockhash }) {
    const data = new Uint8Array(10);
    data[0] = 15;                                   // TokenInstruction::BurnChecked
    let v = BigInt(amount);
    for (let i = 1; i <= 8; i++) { data[i] = Number(v & 0xffn); v >>= 8n; }
    data[9] = KOKOS.DECIMALS;
    const burn = new W.TransactionInstruction({
      programId: new W.PublicKey(KOKOS.TOKEN_2022),
      keys: [
        { pubkey: source, isSigner: false, isWritable: true },
        { pubkey: new W.PublicKey(KOKOS.MINT), isSigner: false, isWritable: true },
        { pubkey: owner, isSigner: true, isWritable: false },
        // Not read by the token program (only multisig owners use extra accounts); it is here so
        // the POS can find this transaction with getSignaturesForAddress(reference).
        { pubkey: new W.PublicKey(reference), isSigner: false, isWritable: false },
      ],
      data,
    });
    const note = new W.TransactionInstruction({
      programId: new W.PublicKey(KOKOS.MEMO), keys: [],
      data: new TextEncoder().encode(memo),
    });
    const tx = new W.Transaction({ feePayer: owner, recentBlockhash: blockhash }).add(burn, note);
    return tx;
  }
  const api = { KOKOS, ata, findSource, buildBurnTx };
  if (typeof module !== 'undefined') module.exports = api; else root.KokosBurn = api;
})(this);
