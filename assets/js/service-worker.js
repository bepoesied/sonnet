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
  const isAudio = request.destination === "audio";

  try {
    const cache = await caches.open(CACHE_NAME);
    const cachedResponse = await cache.match(cacheKey);

    if (cachedResponse) {
      if (request.headers.has("range") && cachedResponse.type !== "opaque") {
        return serveRange(cachedResponse, request);
      }
      return cachedResponse;
    }

    // Not in cache: Forward request and download full file in background
    const networkResponse = await fetch(request);

    // Only background-download if it's a 2xx response
    if (networkResponse.ok || networkResponse.type === "opaque") {
      const downloadPromise = (async () => {
        try {
          // If we already have a full 200 response and it's not opaque, we could use it.
          // But usually audio requests are range requests (206), so we need to fetch the full file.
          if (
            networkResponse.status === 200 &&
            networkResponse.type !== "opaque"
          ) {
            await cache.put(cacheKey, networkResponse.clone());
            return;
          }

          // Fetch full file. For opaque requests (like images without CORS),
          // we fetch with no-cors to ensure it works.
          const fetchOptions = {
            method: "GET",
            mode: networkResponse.type === "opaque" ? "no-cors" : "cors",
            credentials: request.credentials,
          };

          const response = await fetch(url.toString(), fetchOptions);
          if (response.ok || response.type === "opaque") {
            await cache.put(cacheKey, response);
          }
        } catch (err) {
          // Background download failed, that's okay.
        }
      })();
      event.waitUntil(downloadPromise);
    }

    return networkResponse;
  } catch (error) {
    return fetch(request);
  }
}

async function serveRange(response, request) {
  const buffer = await response.arrayBuffer();
  const rangeHeader = request.headers.get("range");
  const size = buffer.byteLength;

  // Parse range: bytes=start-end
  const parts = rangeHeader.replace(/bytes=/, "").split("-");
  let start = parseInt(parts[0], 10);
  let end = parts[1] ? parseInt(parts[1], 10) : size - 1;

  if (isNaN(start)) start = 0;
  if (isNaN(end)) end = size - 1;

  // Cap end at size - 1
  if (end >= size) end = size - 1;

  // If start is beyond size (416 Range Not Satisfiable)
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
      "Content-Type":
        response.headers.get("Content-Type") || "application/octet-stream",
    },
  });
}
