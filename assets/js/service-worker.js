import { CacheableResponsePlugin } from "workbox-cacheable-response";
import { ExpirationPlugin } from "workbox-expiration";
import { RangeRequestsPlugin } from "workbox-range-requests";
import { registerRoute } from "workbox-routing";
import { CacheFirst } from "workbox-strategies";
import { CACHE_NAME, isCached } from "./cache-utils.js";

const log = (message, data) => {
  self.clients.matchAll().then((clients) => {
    clients.forEach((client) => {
      client.postMessage({ type: "SW_LOG", message, data });
    });
  });
};

const isPresignedUrl = ({ url }) => {
  return (
    url.searchParams.has("X-Amz-Signature") ||
    url.searchParams.has("Signature") ||
    url.searchParams.has("AWSAccessKeyId")
  );
};

function createCacheStrategy() {
  return new CacheFirst({
    cacheName: CACHE_NAME,
    matchOptions: {
      ignoreSearch: true,
    },
    plugins: [
      new CacheableResponsePlugin({
        statuses: [200],
      }),
      new RangeRequestsPlugin(),
      new ExpirationPlugin({
        maxEntries: 50,
        maxAgeSeconds: 30 * 24 * 60 * 60,
      }),
    ],
  });
}

async function cacheBookFiles(urls) {
  const cache = await caches.open(CACHE_NAME);

  for (const url of urls) {
    await cacheFileIfNotCached(cache, url);
  }
}

async function cacheFileIfNotCached(cache, url) {
  try {
    const cached = await isCached(cache, url);
    if (!cached) {
      await cacheFile(cache, url);
    }
  } catch (error) {
    logCacheError(url, error);
  }
}

async function cacheFile(cache, url) {
  log("[SW] Caching file", url);
  await cache.add(url);
  notifyClientsFileCached(url);
}

function notifyClientsFileCached(url) {
  self.clients.matchAll().then((clients) => {
    clients.forEach((client) => {
      client.postMessage({ type: "FILE_CACHED", url });
    });
  });
}

function logCacheError(url, error) {
  log("[SW] Failed to cache file", { url, error: error.message });
}

log("[SW] Service worker loaded");
registerRoute(isPresignedUrl, createCacheStrategy());

self.addEventListener("install", (event) => {
  log("[SW] Install");
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  log("[SW] Activate");
  event.waitUntil(self.clients.claim());
});

self.addEventListener("message", (event) => {
  if (event.data.type === "CACHE_BOOK_FILES") {
    cacheBookFiles(event.data.urls);
  }
});
