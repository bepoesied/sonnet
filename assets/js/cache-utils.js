export const CACHE_NAME = "media-cache-v1";

/**
 * @param {Cache} cache
 * @param {string} url unstripped url
 * @returns if it is in the cache
 */
export async function isCached(cache, url) {
  return !!(await cache.match(url, { ignoreSearch: true }));
}

/**
 * Get URL path without query parameters
 * @param {string} url
 * @returns {string}
 */
export function getUrlPath(url) {
  const urlObj = new URL(url);
  return urlObj.origin + urlObj.pathname;
}

/**
 * Check if URL belongs to current book
 * @param {string} url
 * @param {string[]} currentBookUrls
 * @returns {boolean}
 */
export function isFromCurrentBook(url, currentBookUrls) {
  const path = getUrlPath(url);
  return currentBookUrls.some((bookUrl) => getUrlPath(bookUrl) === path);
}
