// "Verify a token": is this contract address an official PunchCard launch? The backend checks for the
// coin record that only PunchCard's on-chain program can create. mountVerify(el) renders the box.
import { API, esc } from '/launchpad/lp.js';

const PUNCH = '8HJY9GTiEGgPoUAs3YSRiwLUukZKhKcH1ngqLB8qcBxx';
const OK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="m7.5 12.5 3 3 6-6.5"/></svg>';
const NO = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M12 7v6m0 4h.01"/></svg>';

export function mountVerify(el, { autofocus = false } = {}) {
  el.innerHTML = `<form class="vf-form" novalidate>
      <label class="vf-label" for="vfIn">Paste a token’s contract address (CA)</label>
      <div class="vf-row"><input id="vfIn" class="vf-in mono" placeholder="e.g. F2vgsmDb5VjB9X3S66Py4gLqfCndsAnD3QesixPhQQzi" autocomplete="off" spellcheck="false"><button class="btn-primary sol" type="submit">Verify</button></div>
    </form><div class="vf-out" role="status" aria-live="polite"></div>`;
  const form = el.querySelector('form'), input = el.querySelector('input'), out = el.querySelector('.vf-out');
  const show = (cls, html) => { out.className = 'vf-out ' + cls; out.innerHTML = html; };
  async function check(mint) {
    mint = String(mint || '').trim();
    if (!mint) return show('', '');
    if (mint === PUNCH) return show('ok', `${OK}<div><b>This is $PUNCH, the official PunchCard token.</b> It’s PunchCard’s own membership token (not a launchpad launch). <a href="/punch/">About PUNCH</a></div>`);
    show('wait', 'Checking Solana…');
    try {
      const r = await fetch(`${API}/api/verify?mint=${encodeURIComponent(mint)}`), j = await r.json();
      if (!r.ok) return show('bad', `${NO}<div>${esc(j.error || 'Couldn’t check that address.')}</div>`);
      if (j.test) return show('bad', `${NO}<div><b>PunchCard test token, not a business.</b> PunchCard made this token to test wallet compatibility. It has no business, page or perks. Please don’t buy it.</div>`);
      if (!j.official) return show('bad', `${NO}<div><b>Not a PunchCard launch.</b> This token wasn’t launched on the PunchCard Launchpad. Official PunchCard tokens always have a PunchCard record on Solana.</div>`);
      show('ok', `${OK}<div><b>Official PunchCard launch, verified on Solana.</b><br>${j.ticker ? `<b>$${esc(j.ticker)}</b> · ` : ''}${esc(j.business || '')}${j.city ? ', ' + esc(j.city) : ''}
        <div class="vf-links"><a href="${esc(j.page)}">Open its PunchCard page</a><a href="https://solscan.io/account/${esc(j.record)}" target="_blank" rel="noopener">See the on-chain record</a></div>
        ${j.hidden ? '<small>Note: this token has been removed from PunchCard’s listings.</small>' : ''}</div>`);
    } catch { show('bad', `${NO}<div>Couldn’t reach PunchCard just now. Try again in a moment.</div>`); }
  }
  form.addEventListener('submit', (e) => { e.preventDefault(); check(input.value); });
  input.addEventListener('paste', () => setTimeout(() => check(input.value), 0));
  const fromUrl = new URLSearchParams(location.search).get('mint');
  if (fromUrl) { input.value = fromUrl; check(fromUrl); } else if (autofocus) input.focus();
}
