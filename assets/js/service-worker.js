const CACHE_NAME = "media-cache-v1";

self.addEventListener("install", (event) => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(clients.claim());
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const urlString = request.url;
  if (!urlString.startsWith("http")) return;

  let url;
  try {
    url = new URL(urlString);
  } catch (err) {
    return;
  }

  if (isPresignedUrl(url)) {
    event.respondWith(handlePresignedRequest(event, url));
  }
});

function isPresignedUrl(url) {
  try {
    return (
      url.searchParams.has("X-Amz-Signature") ||
      url.searchParams.has("Signature") ||
      url.searchParams.has("AWSAccessKeyId")
    );
  } catch (e) {
    return false;
  }
}

function getCacheKey(url) {
  const keyUrl = new URL(url);
  keyUrl.search = "";
  keyUrl.hash = "";
  return keyUrl.toString();
}

async function handlePresignedRequest(event, url) {
  const request = event.request;
  const cacheKey = getCacheKey(url);

  try {
    const cache = await caches.open(CACHE_NAME);
    const cachedResponse = await cache.match(cacheKey);

    if (cachedResponse) {
      if (request.headers.has("range") && cachedResponse.type !== "opaque") {
        return serveRange(cachedResponse, request);
      }
      return cachedResponse;
    }

    // Not in cache: Fetch via network
    const networkResponse = await fetch(request);

    // If it's a 200 or 206, and we're not currently background-caching this file,
    // we should fetch the whole thing for the cache.
    if (networkResponse.ok || networkResponse.status === 206) {
      event.waitUntil(
        backgroundCache(cacheKey, url.toString(), request.credentials),
      );
    }

    return networkResponse;
  } catch (error) {
    return fetch(request);
  }
}

async function backgroundCache(cacheKey, url, credentials) {
  const cache = await caches.open(CACHE_NAME);
  const existing = await cache.match(cacheKey);
  if (existing) return;

  try {
    const response = await fetch(url, {
      method: "GET",
      credentials: credentials,
      mode: "cors", // Force cors to ensure we can read the response/serve ranges
    });

    if (response.ok) {
      await cache.put(cacheKey, response);
    }
  } catch (err) {
    // Background fetch failed
  }
}

async function serveRange(response, request) {
  const buffer = await response.arrayBuffer();
  const rangeHeader = request.headers.get("range");
  const size = buffer.byteLength;

  const parts = rangeHeader.replace(/bytes=/, "").split("-");
  let start = parseInt(parts[0], 10);
  let end = parts[1] ? parseInt(parts[1], 10) : size - 1;

  if (isNaN(start)) start = 0;
  if (isNaN(end)) end = size - 1;
  if (end >= size) end = size - 1;

  if (start >= size) {
    return new Response(null, {
      status: 416,
      headers: { "Content-Range": `bytes */${size}` },
    });
  }

  const chunk = buffer.slice(start, end + 1);

  return new Response(chunk, {
    status: 206,
    headers: {
      "Content-Range": `bytes ${start}-${end}/${size}`,
      "Accept-Ranges": "bytes",
      "Content-Length": chunk.byteLength,
      "Content-Type": response.headers.get("Content-Type") || "audio/mpeg",
    },
  });
}
