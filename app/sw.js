// BUMP THIS ON EVERY RELEASE of index.html. The page only reloads itself when a new
// service worker takes over, and the browser only installs a new one when this file's
// bytes change. Leave it alone and an installed app brought back from the background
// keeps running the previous build until it is fully closed.
// PunchCard app (was the KOKOS customer dapp; its skoop-v1..v10 history lives in the
// KOKOS website repo).
// v1 2026-09-27: first PunchCard build — merchant-aware, PunchCard branding.
const CACHE='pc-app-v1';

// Third-party libs are version-pinned URLs — safe to serve from cache forever.
const CDN=[
  'https://cdn.jsdelivr.net/npm/ethers@6.13.4/dist/ethers.umd.min.js',
  'https://cdn.jsdelivr.net/npm/html5-qrcode@2.3.8/html5-qrcode.min.js',
  'https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js',
  'https://cdn.jsdelivr.net/npm/@walletconnect/modal@2.6.2/dist/index.umd.js',
  'https://cdn.jsdelivr.net/npm/@walletconnect/ethereum-provider@2.10.0/dist/index.umd.js',
];
const ASSETS=['./','./index.html','./manifest.json','./icon-192.png','./icon-512.png','./icon-maskable.png',
              './apple-touch-icon.png','/brand/punchcard.svg','/kokos-skoop/skoop.png',...CDN];

// Never intercept: live chain/price/wallet traffic and fonts.
const BYPASS=['mainnet.base.org','walletconnect','coinbase.com','geckoterminal','walletlink',
              'fonts.gstatic.com','fonts.googleapis.com','basescan.org'];

self.addEventListener('install',e=>{
  e.waitUntil(
    caches.open(CACHE)
      // One bad CDN response must not fail the whole install.
      .then(c=>Promise.all(ASSETS.map(a=>c.add(a).catch(()=>{}))))
      .then(()=>self.skipWaiting())
  );
});

self.addEventListener('activate',e=>{
  e.waitUntil(
    caches.keys().then(keys=>Promise.all(
      keys.filter(k=>k!==CACHE).map(k=>caches.delete(k))
    )).then(()=>self.clients.claim())
  );
});

self.addEventListener('fetch',e=>{
  const req=e.request;
  if(req.method!=='GET')return;
  const url=req.url;
  if(BYPASS.some(h=>url.includes(h)))return;

  // App shell (navigations + index.html): network-first, but only briefly.
  // This app moves real money — an installed PWA must never be pinned to a stale
  // build. It's also used standing at a counter on shop wifi, so we never let a slow
  // network hold up first paint: after SHELL_TIMEOUT we serve cache and let the
  // fetch finish in the background to refresh it for next launch.
  const SHELL_TIMEOUT=2500;
  const isShell=req.mode==='navigate'||url.includes('index.html')||new URL(url).pathname.endsWith('/');
  if(isShell){
    e.respondWith((async()=>{
      const cached=await caches.match('./index.html');
      const net=fetch(req).then(res=>{
        if(res&&res.status===200)caches.open(CACHE).then(c=>c.put('./index.html',res.clone()));
        return res;
      });
      // Keep the update alive past the response we hand back.
      e.waitUntil(net.catch(()=>{}));
      if(!cached)return net.catch(()=>caches.match('./'));
      const timeout=new Promise(r=>setTimeout(()=>r(null),SHELL_TIMEOUT));
      const winner=await Promise.race([net.catch(()=>null),timeout]);
      return winner||cached;
    })());
    return;
  }

  // Everything else (icons, manifest, pinned CDN libs): cache-first.
  e.respondWith(
    caches.match(req).then(cached=>{
      if(cached)return cached;
      return fetch(req).then(res=>{
        if(res&&res.status===200){
          const clone=res.clone();
          caches.open(CACHE).then(c=>c.put(req,clone));
        }
        return res;
      }).catch(()=>cached);
    })
  );
});
