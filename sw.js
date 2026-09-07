// Cache de la app. Subir el numero de version cada vez que se toca index.html,
// asi los celulares agarran la version nueva.
const VERSION = "mnc-v1";
const ARCHIVOS = ["./", "./index.html", "./manifest.json"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(ARCHIVOS)));
  self.skipWaiting();
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(ks =>
      Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k))))
  );
  self.clients.claim();
});

self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);

  // Las llamadas a Supabase nunca se cachean: o hay red, o la app las encola.
  if(url.hostname.endsWith("supabase.co")) return;
  if(e.request.method !== "GET") return;

  // Red primero, cache como respaldo.
  e.respondWith(
    fetch(e.request)
      .then(r => {
        const copia = r.clone();
        caches.open(VERSION).then(c => c.put(e.request, copia));
        return r;
      })
      .catch(() => caches.match(e.request).then(r => r || caches.match("./index.html")))
  );
});
