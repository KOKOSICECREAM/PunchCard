// Community business page: renders into <main id="main"> for ?mint= or <body data-mint>.
import { honourPill, ICONS } from '/launchpad/icons.js';
import { $, esc, api, API, sol, short, explorer, countdown } from '/launchpad/lp.js';

const params = new URLSearchParams(location.search);
const mint = params.get('mint') || document.body.dataset.mint || ''; // dedicated pages set data-mint
const now = () => Math.floor(Date.now() / 1000);
const hostOf = (u) => { try { return new URL(u).hostname.replace(/^www\./, ''); } catch { return ''; } };

function statusOf(c) {
  if (c.status === 'HandedOver') return { pill: 'owned', label: 'Claimed by the owner', text: `Verified owner ${short(c.owner)} receives this token's creator fees directly from pump.fun.` };
  if (c.status === 'Attested') {
    const ends = c.attestedAt + Math.max(c.holdSecs || 0, c.challengeSecs || 0);
    const held = (c.holdSecs || 0) > (c.challengeSecs || 0);
    return { pill: 'attested', label: held ? 'Owner verified: extended review' : 'Owner verified: 24-hour check', ends,
      text: `An owner verified this business${c.inTime ? '' : ' after the 30 days, so they receive future fees only'}. Payout to ${short(c.owner)} happens automatically when the check window ends.` };
  }
  if (c.deadline && now() >= c.deadline) return { pill: 'holders', label: 'Unclaimed: holders share the fees', text: 'The owner didn’t claim within 30 days, so this token’s holders share its creator fees until an owner claims.' };
  return { pill: 'open', label: 'Waiting for the owner', ends: c.deadline, text: `Creator fees are held for ${esc(c.business.name)}. The owner has until the deadline to claim them; after that, holders share them.` };
}

function perksHtml(c, perks) {
  if (perks.length) return perks.map((x) => `<div class="cp-perk"><span class="need">Hold $${esc(x.minUsd)} of ${esc(c.ticker)}</span><b>${esc(x.title)}</b>
    <small>${x.oneTime ? `Once every ${esc(x.everyDays)} days. ` : ''}Show your PunchCard Perk Pass at the counter.</small>
    <button class="btn-primary pass-btn" type="button" data-perk="${esc(x.id)}">Get my PunchCard Perk Pass</button><span class="pass-status" role="status"></span></div>`).join('');
  return `<div class="cp-perk soon"><span class="need">Coming soon</span><b>PunchCard Perk Pass</b>
    <small>${c.status === 'HandedOver' ? `${esc(c.business.name)} can add a thank-you for ${esc(c.ticker)} holders here.` : `Perks are chosen by the owner. Once ${esc(c.business.name)} claims this page, they can add a thank-you for ${esc(c.ticker)} holders.`}</small></div>`;
}

async function load() {
  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(mint)) { $('main').innerHTML = '<p class="notice bad">No token address in the link.</p>'; return; }
  let c;
  try { c = await api('/api/coins/' + mint); } catch (e) { $('main').innerHTML = `<p class="notice bad">${esc(e.message)}</p>`; return; }
  const [prof, perkCfg] = await Promise.all([api(`/api/coins/${mint}/profile`).catch(() => ({})), api(`/api/perks?mint=${mint}`).catch(() => ({}))]);
  const perks = perkCfg.perks || [], site = prof.site || null, host = site?.host || hostOf(c.business.website);
  document.title = `${c.business.name} · ${c.coinName} ($${c.ticker}) — PunchCard`;
  const st = statusOf(c), claimed = c.status === 'HandedOver' || c.status === 'Attested';
  const newNote = params.get('new') ? `<div class="notice ok"><b>It’s live.</b> Share this page with ${esc(c.business.name)} so the owner can claim their fees. <button class="btn-secondary" id="copyLink" type="button" style="margin-left:0.5rem">Copy link</button></div>` : '';
  const removedNote = c.hidden ? `<div class="notice warn"><b>Removed from PunchCard’s listings.</b> This token no longer appears on PunchCard (for example, at the business’s request). It still exists and may still trade on pump.fun; PunchCard can’t delete or change it.</div>` : '';
  const retiredNote = c.retired ? `<div class="notice warn"><b>Retired.</b> This business’s slot was released so a legitimate token can launch for it. This token still exists on pump.fun; any fees it holds still follow the published rules.</div>` : '';
  // Link a featured page, unless this is it.
  const story = prof.featuredPage && new URL(prof.featuredPage, location.href).pathname !== location.pathname ? `<div><a class="btn-secondary" href="${esc(prof.featuredPage)}">Read the ${esc(c.business.name)} story</a></div>` : '';
  const words = site?.description ? `
    <section class="cp-sec">
      <p class="cp-lbl">In their own words</p>
      <div class="cp-words${site.image ? ' has-img' : ''}">
        <div><blockquote>${esc(site.description)}</blockquote><p class="cp-credit">From <a href="${esc(c.business.website)}" target="_blank" rel="noopener">${esc(host)}</a></p></div>
        ${site.image ? `<figure><img src="${esc(site.image)}" alt="From ${esc(host)}" loading="lazy" referrerpolicy="no-referrer" onerror="this.closest('figure').remove()"><figcaption class="cp-credit">Image: ${esc(host)}</figcaption></figure>` : ''}
      </div>
      ${story}
    </section>` : story;
  $('main').innerHTML = `
    ${removedNote}${retiredNote}${newNote}
    <section class="cp-hero">
      <div>
        <div class="cp-kicker">${c.business.city ? esc(c.business.city) + ' · ' : ''}Community page</div>
        <h1>${esc(c.business.name)}</h1>
        <p class="cp-token">${c.coinName.trim().toLowerCase() === c.business.name.trim().toLowerCase() ? '' : esc(c.coinName) + ' · '}<b>$${esc(c.ticker)}</b></p>
        ${c.description ? `<p class="cp-thanks">“${esc(c.description)}”</p>` : `<p class="cp-thanks">A thank-you to the people behind ${esc(c.business.name)}, from their community.</p>`}
        <div class="cp-ctas">
          <a class="btn-primary sol" href="https://pump.fun/coin/${esc(mint)}" target="_blank" rel="noopener">Get $${esc(c.ticker)} on pump.fun</a>
          ${c.business.website ? `<a class="btn-secondary" href="${esc(c.business.website)}" target="_blank" rel="noopener">Visit ${esc(host || 'their site')}</a>` : ''}
          ${prof.mapsUrl ? `<a class="btn-secondary" href="${esc(prof.mapsUrl)}" target="_blank" rel="noopener">Directions</a>` : ''}
        </div>
        <div class="cp-badge">${claimed ? `<span class="pill owned">Verified business</span>` : `<span class="pill open">Made by the community</span><span>Own ${esc(c.business.name)}? <a href="/launchpad/claim/?mint=${esc(mint)}">Claim this page</a></span>`}${c.burnTier ? ' ' + honourPill(c.burnTier) : ''}</div>
      </div>
      <div class="cp-art"><img src="${API}/img/${esc(mint)}" alt="${esc(c.business.name)}" onerror="this.parentNode.style.display='none'"></div>
    </section>
    ${words}
    <section class="cp-sec">
      <p class="cp-lbl">For ${esc(c.ticker)} holders</p>
      <h2>A little thank-you back.</h2>
      <div class="cp-perks">${perksHtml(c, perks)}</div>
      <p class="status-line">Perks are customer rewards chosen by the business and can change. Holding a token isn’t an investment in the business or PunchCard.</p>
    </section>
    <section class="panel">
      <h2>The numbers, live</h2>
      <div><span class="pill ${st.pill}">${st.label}</span>${st.ends && st.ends > now() ? ` <span class="status-line" id="cd"></span>` : ''}</div>
      <p>${st.text}</p>
      <div class="stats">
        <div class="stat"><small>${c.status === 'HandedOver' ? 'Saved for holders' : 'Held for the business'}</small><b>${sol(c.feesInVaultLamports)} SOL</b></div>
        <div class="stat"><small>Waiting at pump.fun</small><b>${sol(c.feesPendingAtPumpLamports)} SOL</b></div>
        <div class="stat"><small>Paid to the owner</small><b>${sol(c.businessPaidLamports ?? c.ownerPaidLamports)} SOL</b></div>
      </div>
      <div class="btn-row">
        ${c.status === 'Open' ? `<a class="btn-primary sol" href="/launchpad/claim/?mint=${esc(mint)}">I own this business</a>` : ''}
        <button class="btn-secondary" id="payout" type="button">Pay out now</button>
        <a class="btn-secondary" href="${explorer('token', mint)}" target="_blank" rel="noopener">View on Solscan</a>
      </div>
      <p class="status-line" id="payoutStatus" role="status"></p>
    </section>
    <section class="panel">
      ${c.status === 'Attested'
        ? `<h2>Is this claim wrong?</h2><p>If you own ${esc(c.business.name)} and didn’t make this claim, tell us now. We can stop it while it’s under review.</p>`
        : `<h2>Report this token</h2><p class="status-line">Is it using your business, brand or image without permission? Tell us and we’ll review it. We can remove it from PunchCard’s listings and stop any claim under review, but we can’t delete it from pump.fun.</p>`}
      <div class="field"><label for="reason">What’s wrong?</label><textarea id="reason" maxlength="1000"></textarea></div>
      <div class="field"><label for="contact">How can we reach you?</label><input id="contact" maxlength="200" placeholder="Email or phone"></div>
      <div class="btn-row"><button class="${c.status === 'Attested' ? 'btn-primary' : 'btn-secondary'}" id="report" type="button">${c.status === 'Attested' ? 'Report this claim' : 'Report this token'}</button><span class="status-line" id="reportStatus"></span></div>
    </section>
    <section class="panel">
      <h2>Details</h2>
      <p class="status-line">${esc(c.business.address || '')}${c.business.website ? ` · <a href="${esc(c.business.website)}" target="_blank" rel="noopener">${esc(host)}</a>` : ''}</p>
      <p class="status-line">Token <span class="mono">${esc(mint)}</span></p>
      <p class="status-line">Launched by <span class="mono">${esc(short(c.launcher))}</span>${c.launchedAt ? ' on ' + new Date(c.launchedAt * 1000).toLocaleDateString() : ''}${c.deadline && !claimed ? ` · claim deadline ${new Date(c.deadline * 1000).toLocaleString()}` : ''}</p>
      ${Number(c.launchBurnTokens || 0) > 0 ? `<p class="status-line">${ICONS.flame} <b>Fair launch:</b> the launcher's ${(c.firstBuyLamports / 1e9).toLocaleString()} SOL first buy was capped at 0.5% of the supply; <b>${Math.round(Number(c.launchBurnTokens) / 1e6).toLocaleString()} tokens were burned</b> at launch.${c.burnTier ? ` ${honourPill(c.burnTier)}` : ''}</p>` : ''}
      ${c.launcherReward?.eligible ? `<p class="status-line">${ICONS.door} <b>Bring them in reward:</b> the business joined, so this token's launcher earns ${c.launcherReward.rateBps / 100}% of PunchCard's fee from it, paid weekly · earned ${sol(c.launcherReward.earnedLamports)} SOL, paid ${sol(c.launcherReward.paidLamports)} SOL. <a href="/launchpad/how/#bring-them-in">How it works</a></p>` : ''}
      <p class="status-line">This page is written by the community${claimed ? ' and the verified owner' : ''}; text and images marked with a website come from the business's own site. Creator fee split: ${c.platformBps ? `${(10000 - c.platformBps) / 100}% for the business · ${c.platformBps / 100}% PunchCard service fee` : '100% for the business'}. pump.fun keeps its own trading fees. Community tokens are tradable and can lose value.</p>
    </section>`;

  if (st.ends && st.ends > now()) { const tick = () => { const el = $('cd'); if (el) el.textContent = `· ${countdown(st.ends)} left`; }; tick(); setInterval(tick, 1000); }
  $('copyLink')?.addEventListener('click', () => { const u = location.origin + location.pathname + '?mint=' + mint; navigator.clipboard.writeText(u).then(() => ($('copyLink').textContent = 'Copied'), () => ($('copyLink').outerHTML = `<span class="mono">${esc(u)}</span>`)); });
  document.querySelectorAll('.pass-btn').forEach((b) => b.addEventListener('click', async () => {
    const { openPerkPass } = await import('/launchpad/perk-pass.js');
    b.disabled = true; try { await openPerkPass({ mint, perkId: b.dataset.perk, status: b.nextElementSibling }); } finally { b.disabled = false; }
  }));
  $('payout').addEventListener('click', async () => {
    $('payout').disabled = true; $('payoutStatus').textContent = 'Paying out…';
    try {
      const r = await api(`/api/coins/${mint}/payout`, {});
      $('payoutStatus').textContent = r.done.length ? `Done: ${r.done.map((d) => d.action).join(', ')}. Updating…` : r.note;
      if (r.done.length) setTimeout(load, 2500);
    } catch (e) { $('payoutStatus').textContent = e.message; }
    finally { $('payout').disabled = false; }
  });
  $('report')?.addEventListener('click', async () => {
    $('report').disabled = true;
    try { await api(`/api/coins/${mint}/report`, { reason: $('reason').value, contact: $('contact').value }); $('reportStatus').textContent = 'Thanks. We’ve been alerted and will review it.'; }
    catch (e) { $('reportStatus').textContent = e.message; $('report').disabled = false; }
  });
}
load();
