import { CACHE_NAME, isCached } from "./cache-utils.js";

export const cacheActions = {
  async checkCache() {
    if (!("caches" in window) || !this.state.chapter) return;

    try {
      const cache = await caches.open(CACHE_NAME);
      await isCached(cache, this.state.chapter.audio_url);
      this.updateChapterCacheStatus(this.state.chapter.audio_url);
    } catch (e) {}
  },

  async updateChapterCacheStatus(url) {
    if (!this.el["chapter-list"]) return;

    try {
      const cache = await caches.open(CACHE_NAME);
      const cached = await isCached(cache, url);

      const chapterLinks = this.el["chapter-list"].querySelectorAll("a");
      chapterLinks.forEach((link) => {
        if (link.dataset.audioUrl === url) {
          this.setChapterCacheIcon(link, cached);
        }
      });
    } catch (e) {}
  },

  async refreshAllChapterCacheStatus() {
    if (!this.el["chapter-list"]) return;

    try {
      const cache = await caches.open(CACHE_NAME);

      const chapterLinks = this.el["chapter-list"].querySelectorAll("a");
      for (const link of chapterLinks) {
        const url = link.dataset.audioUrl;
        if (url) {
          const cached = await isCached(cache, url);
          this.setChapterCacheIcon(link, cached);
        }
      }
    } catch (e) {}
  },

  setChapterCacheIcon(link, isCached) {
    const icon = link.querySelector(".chapter-cache-icon");
    if (icon) {
      icon.classList.toggle("hidden", !isCached);
    }
  },

  postToServiceWorker(message) {
    if (!("serviceWorker" in navigator)) return;

    navigator.serviceWorker.ready.then((registration) => {
      registration.active.postMessage(message);
    });
  },

  cacheCurrentAndNext() {
    if (!this.state.chapter) return;

    const currentIndex = this.findChapterIndex(this.state.chapter.id);
    const urlsToCache = [];

    for (
      let i = currentIndex;
      i < currentIndex + this.constructor.CACHE_LOOKAHEAD;
      i++
    ) {
      if (i >= 0 && i < this.book.chapters.length) {
        urlsToCache.push(this.book.chapters[i].audio_url);
      }
    }

    if (urlsToCache.length > 0) {
      this.postToServiceWorker({ type: "CACHE_URLS", urls: urlsToCache });
    }
  },

  downloadEntireBook() {
    const urls = this.book.chapters.map((c) => c.audio_url);
    this.postToServiceWorker({ type: "CACHE_ENTIRE_BOOK", urls: urls });
  },

  clearPlayedChapters() {
    if (!this.state.chapter) return;

    const currentIndex = this.findChapterIndex(this.state.chapter.id);
    const playedUrls = [];

    for (let i = 0; i < currentIndex; i++) {
      if (i >= 0 && i < this.book.chapters.length) {
        playedUrls.push(this.book.chapters[i].audio_url);
      }
    }

    if (playedUrls.length > 0) {
      this.postToServiceWorker({
        type: "CLEAR_PLAYED_CHAPTERS",
        urls: playedUrls,
      });
    }
  },

  clearOtherBooks() {
    const currentBookUrls = this.book.chapters.map((c) => c.audio_url);
    this.postToServiceWorker({
      type: "CLEAR_OTHER_BOOKS",
      currentBookUrls: currentBookUrls,
    });
  },
};

export function clearServiceWorkerCache() {
  if (!("serviceWorker" in navigator)) return;

  navigator.serviceWorker.ready.then((registration) => {
    registration.active.postMessage({ type: "CLEAR_CACHE" });
  });
}
