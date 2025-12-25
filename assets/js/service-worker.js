const CACHE_NAME = "media-cache-v1";

function log(message, data) {
  console.log(message, data);
  self.clients
    .matchAll({ type: "window", includeUncontrolled: true })
    .then((clients) => {
      clients.forEach((client) =>
        client.postMessage({ type: "SW_LOG", message, data }),
      );
    });
}

let cachePromise = null;

self.addEventListener("install", (event) => {
  self.skipWaiting();
  log("[SW] Service worker installed", new Date().toISOString());
});

self.addEventListener("activate", (event) => {
  event.waitUntil(clients.claim());
  log("[SW] Service worker activated", new Date().toISOString());
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

async function getCache() {
  if (!cachePromise) {
    cachePromise = caches.open(CACHE_NAME);
  }
  return cachePromise;
}

async function getCachedResponse(cacheKey) {
  const cache = await getCache();
  return cache.match(cacheKey);
}

function forwardRequest(request) {
  return fetch(request);
}

function cacheFullFile(cacheKey, url, credentials) {
  (async () => {
    try {
      const cache = await getCache();
      const existing = await cache.match(cacheKey);
      if (existing) {
        log("[SW] Already cached, skipping:", cacheKey);
        return;
      }

      log("[SW] Downloading full file:", cacheKey);
      const response = await fetch(url, {
        method: "GET",
        credentials: credentials,
        mode: "cors",
      });

      if (response.ok) {
        await cache.put(cacheKey, response);
        log(
          "[SW] Cached successfully:",
          `${cacheKey} Size: ${response.headers.get("Content-Length")}`,
        );
      }
    } catch (err) {
      log("[SW] Cache failed:", `${cacheKey} ${err}`);
    }
  })();
}

function isRangeRequest(request) {
  return request.headers.has("range");
}

function parseRangeHeader(rangeHeader, contentSize) {
  const parts = rangeHeader.replace(/bytes=/, "").split("-");
  let start = parseInt(parts[0], 10);
  let end = parts[1] ? parseInt(parts[1], 10) : contentSize - 1;

  if (isNaN(start)) start = 0;
  if (isNaN(end)) end = contentSize - 1;
  if (end >= contentSize) end = contentSize - 1;

  if (start >= contentSize) {
    return null;
  }

  return { start, end };
}

function createRangeTransformStream(start, end) {
  const totalBytes = end - start + 1;
  let bytesSkipped = 0;
  let bytesSent = 0;

  return new TransformStream({
    transform(chunk, controller) {
      const view = new Uint8Array(chunk);

      if (bytesSkipped < start) {
        const remainingToSkip = start - bytesSkipped;
        if (view.length <= remainingToSkip) {
          bytesSkipped += view.length;
          return;
        }

        const relevantStart = remainingToSkip;
        const relevantBytes = view.slice(relevantStart);
        bytesSkipped = start;

        const bytesToForward = Math.min(
          relevantBytes.length,
          totalBytes - bytesSent,
        );
        if (bytesToForward > 0) {
          controller.enqueue(relevantBytes.slice(0, bytesToForward));
          bytesSent += bytesToForward;
        }
      } else {
        const bytesToForward = Math.min(view.length, totalBytes - bytesSent);
        if (bytesToForward > 0) {
          controller.enqueue(view.slice(0, bytesToForward));
          bytesSent += bytesToForward;
        }
      }

      if (bytesSent >= totalBytes) {
        controller.terminate();
      }
    },
  });
}

async function serveRangeFromCache(cachedResponse, request) {
  const rangeHeader = request.headers.get("range");
  const contentSize = parseInt(
    cachedResponse.headers.get("Content-Length"),
    10,
  );

  if (isNaN(contentSize)) {
    return forwardRequest(request);
  }

  const range = parseRangeHeader(rangeHeader, contentSize);
  if (!range) {
    return new Response(null, {
      status: 416,
      headers: { "Content-Range": `bytes */${contentSize}` },
    });
  }

  const { start, end } = range;
  const transformStream = createRangeTransformStream(start, end);

  const clonedResponse = cachedResponse.clone();
  const transformedStream = clonedResponse.body.pipeThrough(transformStream);

  return new Response(transformedStream, {
    status: 206,
    headers: {
      "Content-Range": `bytes ${start}-${end}/${contentSize}`,
      "Accept-Ranges": "bytes",
      "Content-Length": `${end - start + 1}`,
      "Content-Type":
        cachedResponse.headers.get("Content-Type") || "audio/mpeg",
    },
  });
}

async function handlePresignedRequest(event, url) {
  const request = event.request;
  const cacheKey = getCacheKey(url);

  log("[SW] Handling presigned URL:", cacheKey);

  try {
    const cachedResponse = await getCachedResponse(cacheKey);

    if (cachedResponse) {
      log(
        "[SW] Cache HIT:",
        cacheKey + (isRangeRequest(request) ? " (range)" : " (full)"),
      );
      if (isRangeRequest(request)) {
        return serveRangeFromCache(cachedResponse, request);
      }
      return cachedResponse;
    }

    log("[SW] Cache MISS, forwarding:", cacheKey);
    const networkPromise = forwardRequest(request);

    networkPromise.then((response) => {
      if (response.ok || response.status === 206) {
        log("[SW] Background caching started:", cacheKey);
        cacheFullFile(cacheKey, url.toString(), request.credentials);
      }
    });

    return networkPromise;
  } catch (error) {
    log("[SW] Error:", error);
    return forwardRequest(request);
  }
}
