const CACHE_NAME = "go-partage-shell-v9";
const APP_SHELL = [
  "/GO-Partage/",
  "/GO-Partage/index.html",
  "/GO-Partage/manifest.webmanifest",
  "/GO-Partage/app-icon.svg",
  "/GO-Partage/fond-go-partage.svg?v=10"
];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).then(response => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then(cache => cache.put("/GO-Partage/index.html", copy));
        return response;
      }).catch(() => caches.match("/GO-Partage/index.html"))
    );
    return;
  }

  if (url.pathname.startsWith("/GO-Partage/")) {
    event.respondWith(
      caches.match(request).then(cached => cached || fetch(request).then(response => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
        }
        return response;
      }))
    );
  }
});