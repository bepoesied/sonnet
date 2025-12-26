export const CACHE_NAME = "media-cache-v1";

/**
 * @param {Cache} cache
 * @param {string} url unstripped url
 * @returns if it is in the cache
 */
export async function isCached(cache, url) {
  return !!(await cache.match(url, { ignoreSearch: true }));
}
