import { registerRoute } from "workbox-routing";
import { CacheFirst } from "workbox-strategies";
import { RangeRequestsPlugin } from "workbox-range-requests";
import { CacheableResponsePlugin } from "workbox-cacheable-response";
import { ExpirationPlugin } from "workbox-expiration";

const CACHE_NAME = "media-cache-v1";

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

const createCacheStrategy = () => {
  return new CacheFirst({
    cacheName: CACHE_NAME,
    matchOptions: {
      ignoreSearch: true,
      ignoreVary: true,
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
};

const stripUrl = (url) => {
  const cacheUrl = new URL(url);
  cacheUrl.search = "";
  cacheUrl.hash = "";
  return cacheUrl.toString();
};

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
