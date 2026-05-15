import { CACHE_NAME, isCached } from "./cache-utils.js";
import { AudioEngine } from "./audio-engine.js";

/**
 * @typedef {Object} Chapter
 * @property {number} id
 * @property {string} title
 * @property {number} start_ms
 * @property {number} end_ms
 * @property {number} media_asset_id
 * @property {string} audio_url
 * @property {number} duration_ms
 */

/**
 * @typedef {Object} BookData
 * @property {number} id
 * @property {string} title
 * @property {string} cover_url
 * @property {Chapter[]} chapters
 * @property {boolean} is_completed
 * @property {Object} [progress]
 */

/**
 * @typedef {Object} PlayerState
 * @property {Chapter|null} chapter - Current active chapter
 * @property {boolean} isPlaying - Toggle state for playback
 * @property {boolean} isPending - Guard during async loads
 * @property {boolean} isDragging - Guard for seek bar updates
 * @property {number} sleepTarget - Target accumulated time in seconds
 * @property {number} sleepAccumulated - Accumulated time in seconds since sleep set
 * @property {number} lastSync - Timestamp of last API sync
 * @property {number} lastPosition - Cached audio currentTime
 * @property {number} lastManualSeek - Timestamp of last user seek
 */

class AudioPlayer {
  static SEEK_FORWARD = 10;
  static SEEK_BACKWARD = -11;
  static SEEK_THRESHOLD_END = 0.5;
  static SYNC_INTERVAL_MS = 30000;
  static SYNC_RETRY_MS = 60000;
  static SEEK_LOCK_MS = 10000;
  static LOAD_TIMEOUT_MS = 10000;
  static CACHE_LOOKAHEAD = 4;

  constructor() {
    this.root = document.getElementById("player-root");
    if (!this.root) return;

    this.book = JSON.parse(this.root.dataset.book);
    this.engine = new AudioEngine();
    this.csrf = document.querySelector("meta[name='csrf-token']")?.content;
    this.progressKey = `progress_${this.book.id}`;
    this.progressSignature = this.buildProgressSignature();

    this.state = {
      chapter: null,
      isPlaying: false,
      isPending: false,
      isDragging: false,
      sleepTarget: 0,
      sleepAccumulated: 0,
      lastSync: 0,
      lastPosition: 0,
      lastManualSeek: 0,
    };

    this.el = {};

    this.engine.onTimeUpdate = (cur, dur) => this.onTimeUpdate();
    this.engine.onTrackEnded = () => this.onEnded();
    this.engine.onTrackChanged = () => this.handleSeamlessChapterChange();
    this.engine.onError = () => this.showErr("Playback failed");
    this.engine.onMetadataLoaded = () => this.onMetadataLoaded();
    this.engine.onPlay = () => this.updatePlayState(true);
    this.engine.onPause = () => this.updatePlayState(false);

    this.init();
  }

  init() {
    this.bindElements();
    this.setupListeners();
    this.loadInitialState();
  }

  createIcon(iconName, className = "size-4") {
    const iconPaths = {
      "hero-arrow-down-tray": [
        "M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5M16.5 12 12 16.5m0 0L7.5 12m4.5 4.5V3",
      ],
    };

    const paths = iconPaths[iconName];
    if (!paths) return null;

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("fill", "none");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("stroke-width", "1.5");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("class", className);

    paths.forEach((d) => {
      const path = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "path",
      );
      path.setAttribute("stroke-linecap", "round");
      path.setAttribute("stroke-linejoin", "round");
      path.setAttribute("d", d);
      svg.appendChild(path);
    });

    return svg;
  }

  bindElements() {
    const ids = [
      "player-ui",
      "loading",
      "error",
      "error-message",
      "current-time",
      "total-time",
      "seek-bar",
      "play-pause-btn",
      "play-icon",
      "pause-icon",
      "rewind-btn",
      "forward-btn",
      "sleep-timer-text",
      "chapter-list",
      "current-chapter-title",
      "book-completed-badge",
      "cancel-sleep-timer",
      "time-controls",
      "sleep-toggle",
      "chapters-toggle",
      "download-book-btn",
      "clear-played-btn",
      "clear-other-books-btn",
    ];
    ids.forEach((id) => {
      this.el[id] = document.getElementById(id);
    });
  }

  setupListeners() {
    this.el["play-pause-btn"]?.addEventListener("click", () => this.toggle());
    this.el["rewind-btn"]?.addEventListener("click", () =>
      this.seek(AudioPlayer.SEEK_BACKWARD),
    );
    this.el["forward-btn"]?.addEventListener("click", () =>
      this.seek(AudioPlayer.SEEK_FORWARD),
    );
    this.el["cancel-sleep-timer"]?.addEventListener("click", () =>
      this.clearSleep(),
    );

    this.el["seek-bar"]?.addEventListener("input", (e) => this.onSeekInput(e));
    this.el["seek-bar"]?.addEventListener("change", (e) =>
      this.onSeekChange(e),
    );

    this.el["chapter-list"]?.addEventListener("click", (e) =>
      this.onChapterClick(e),
    );

    [this.el["sleep-toggle"], this.el["chapters-toggle"]].forEach((toggle) => {
      toggle?.addEventListener("change", (e) => this.handleAccordionSync(e));
    });

    this.el["download-book-btn"]?.addEventListener("click", () =>
      this.downloadEntireBook(),
    );
    this.el["clear-played-btn"]?.addEventListener("click", () =>
      this.clearPlayedChapters(),
    );
    this.el["clear-other-books-btn"]?.addEventListener("click", () =>
      this.clearOtherBooks(),
    );

    document.addEventListener("click", (e) => {
      const btn = e.target.closest(".sleep-option");
      if (btn) this.setSleep(btn.dataset.minutes);
    });

    window.addEventListener(
      "beforeunload",
      () => this.state.isPlaying && this.save(true),
    );

    if ("serviceWorker" in navigator) {
      navigator.serviceWorker.addEventListener("message", (e) => {
        if (e.data.type === "FILE_CACHED") {
          this.checkCache();
          this.updateChapterCacheStatus(e.data.url);
        }
        if (e.data.type === "CACHE_CLEARED") {
          this.refreshAllChapterCacheStatus();
        }
        if (e.data.type === "PLAYED_CHAPTERS_CLEARED") {
          this.refreshAllChapterCacheStatus();
        }
        if (e.data.type === "OTHER_BOOKS_CLEARED") {
          this.refreshAllChapterCacheStatus();
        }
      });
    }
  }

  async loadInitialState() {
    try {
      this.renderUI();
      const { chapterId, offsetMs } = this.getStartingPosition();
      if (chapterId) await this.goTo(chapterId, offsetMs);

      this.updateCompletionUI();
      this.showLayer("player-ui");
      this.sync();
    } catch (e) {
      this.showErr("Failed to initialize player");
    }
  }

  getStartingPosition() {
    const local = this.getLocalStorageProgress();
    const remote = this.book.progress;
    let start = remote;

    if (
      local &&
      (!remote || new Date(local.ts) > new Date(remote.updated_at))
    ) {
      start = { chapter_id: local.cid, offset_ms: local.off };
    }

    return {
      chapterId: start?.chapter_id || this.book.chapters[0]?.id,
      offsetMs: start?.offset_ms || 0,
    };
  }

  renderUI() {
    this.renderChapterList();
    this.updateMediaMetadata();
    this.refreshAllChapterCacheStatus();
  }

  renderChapterList() {
    if (!this.el["chapter-list"]) return;
    this.el["chapter-list"].textContent = "";
    this.book.chapters.forEach((c) =>
      this.el["chapter-list"].append(this.createChapterItem(c)),
    );
  }

  createChapterItem(c) {
    const li = document.createElement("li");
    li.className = "border-b border-base-content/5 last:border-0";

    const a = document.createElement("a");
    a.href = "#";
    a.dataset.chapterId = c.id.toString();
    a.dataset.audioUrl = c.audio_url;
    a.className =
      "flex justify-between py-4 px-6 hover:bg-primary/5 active:bg-primary/10 transition-colors font-sans group";

    const title = document.createElement("span");
    title.className =
      "text-sm group-hover:text-primary transition-colors pr-4 font-semibold flex-1 flex items-center gap-2";
    title.textContent = c.title;

    const cacheIcon = document.createElement("span");
    cacheIcon.className = "chapter-cache-icon hidden shrink-0";
    const iconSvg = this.createIcon(
      "hero-arrow-down-tray",
      "size-4 text-primary",
    );
    if (iconSvg) {
      cacheIcon.appendChild(iconSvg);
    }
    title.append(cacheIcon);

    const dur = document.createElement("span");
    dur.className = "text-xs opacity-50 font-mono tabular-nums";
    dur.textContent = this.formatSeconds(c.duration_ms / 1000);

    a.append(title, dur);
    li.append(a);
    return li;
  }

  async goTo(cid, ms = 0, autoPlay = false) {
    const chapter = this.findChapter(cid);
    if (!chapter || this.state.isPending) return;

    await this.loadAudioIfNeeded(chapter);
    this.setPosition(ms || 0);
    this.updateChapter(chapter);
    this.checkCache();

    this.cacheCurrentAndNext();

    const nextChapter = this.getNextChapter();
    if (nextChapter) {
      this.engine.preloadNext(nextChapter.audio_url);
    }

    if (autoPlay || this.state.isPlaying) await this.play();
  }

  findChapter(cid) {
    return this.book.chapters.find((x) => x.id === cid);
  }

  async loadAudioIfNeeded(chapter) {
    if (this.state.chapter?.id === chapter.id) {
      return;
    }

    this.state.isPending = true;
    try {
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          reject(new Error("Timeout loading audio"));
        }, AudioPlayer.LOAD_TIMEOUT_MS);

        const metadataHandler = () => {
          clearTimeout(timeout);
          this.engine.active.removeEventListener(
            "loadedmetadata",
            metadataHandler,
          );
          this.engine.active.removeEventListener("canplay", metadataHandler);
          this.engine.active.removeEventListener("error", errorHandler);
          resolve();
        };

        const errorHandler = () => {
          clearTimeout(timeout);
          this.engine.active.removeEventListener(
            "loadedmetadata",
            metadataHandler,
          );
          this.engine.active.removeEventListener("canplay", metadataHandler);
          this.engine.active.removeEventListener("error", errorHandler);
          reject();
        };

        this.engine.active.addEventListener("loadedmetadata", metadataHandler, {
          once: true,
        });
        this.engine.active.addEventListener("canplay", metadataHandler, {
          once: true,
        });
        this.engine.active.addEventListener("error", errorHandler, {
          once: true,
        });

        this.engine.load(chapter.audio_url);
      });
    } catch (e) {
      this.showErr("Failed to load audio");
      throw e;
    } finally {
      this.state.isPending = false;
    }
  }

  setPosition(ms) {
    this.engine.currentTime = ms / 1000;
    this.state.lastPosition = this.engine.currentTime;
  }

  updateChapter(chapter) {
    this.state.chapter = chapter;
    if (this.el["current-chapter-title"])
      this.el["current-chapter-title"].textContent = chapter.title;
    this.updateActiveChapterUI();
    this.updateMediaMetadata();
  }

  async play() {
    if (this.state.isPending || !this.state.chapter) return;

    if (this.book.is_completed) {
      this.book.is_completed = false;
      this.updateCompletionUI();
      this.api("incomplete");
      return this.goTo(this.book.chapters[0].id, 0, true);
    }

    try {
      this.state.isPending = true;
      if (!this.engine.active.src)
        this.engine.active.src = this.state.chapter.audio_url;
      await this.engine.play();
      this.state.isPlaying = true;
    } catch (e) {
      if (e.name !== "AbortError") this.showErr("Playback failed");
    } finally {
      this.state.isPending = false;
    }
  }

  pause() {
    this.engine.pause();
    this.state.isPlaying = false;
    this.save();
  }

  toggle() {
    this.engine.paused ? this.play() : this.pause();
  }

  seek(s) {
    if (!this.engine.duration) return;
    const oldTime = this.engine.currentTime;
    this.engine.currentTime = Math.max(
      0,
      Math.min(this.engine.currentTime + s, this.engine.duration),
    );
    const seekDelta = this.engine.currentTime - oldTime;
    if (seekDelta > 0 && this.state.sleepTarget > 0) {
      this.state.sleepAccumulated += seekDelta;
      this.updateSleepDisplay();
      if (this.state.sleepAccumulated >= this.state.sleepTarget) {
        this.pause();
        this.clearSleep();
      }
    }
    this.recordSeek();
  }

  seekTo(seconds) {
    if (!this.engine.duration) return;
    const oldTime = this.engine.currentTime;
    this.engine.currentTime = Math.max(
      0,
      Math.min(seconds, this.engine.duration),
    );
    const seekDelta = this.engine.currentTime - oldTime;
    if (seekDelta > 0 && this.state.sleepTarget > 0) {
      this.state.sleepAccumulated += seekDelta;
      this.updateSleepDisplay();
      if (this.state.sleepAccumulated >= this.state.sleepTarget) {
        this.pause();
        this.clearSleep();
      }
    }
    this.recordSeek();
    this.save();
  }

  recordSeek() {
    this.state.lastPosition = this.engine.currentTime;
    this.state.lastManualSeek = Date.now();
  }

  onTimeUpdate() {
    const { duration, currentTime } = this.engine;
    if (!duration || !this.state.chapter) return;

    if (!this.state.isDragging) {
      this.updateSeekBar(currentTime, duration);
    }

    const delta = this.state.lastPosition
      ? currentTime - this.state.lastPosition
      : 0;
    this.state.lastPosition = currentTime;

    this.handleSleepTimer(delta);
    this.updateMediaPosition();
    this.save();
  }

  updateSeekBar(currentTime, duration) {
    if (this.el["seek-bar"])
      this.el["seek-bar"].value = ((currentTime / duration) * 100).toString();
    if (this.el["current-time"])
      this.el["current-time"].textContent = this.formatSeconds(currentTime);
  }

  updateSleepTimer(delta) {
    if (this.state.sleepTarget <= 0 || !this.state.isPlaying || delta <= 0)
      return;

    this.state.sleepAccumulated += delta;
    this.updateSleepDisplay();

    if (this.state.sleepAccumulated >= this.state.sleepTarget) {
      this.pause();
      this.clearSleep();
    }
  }

  handleSleepTimer(delta) {
    this.updateSleepTimer(delta);
  }

  getLocalStorageProgress() {
    try {
      const progress = JSON.parse(localStorage.getItem(this.progressKey));

      if (!progress || progress.sig !== this.progressSignature) {
        return null;
      }

      return progress;
    } catch (e) {
      return null;
    }
  }

  updateLocalStorageProgress(cid, off, ts) {
    localStorage.setItem(
      this.progressKey,
      JSON.stringify({
        cid,
        off,
        sig: this.progressSignature,
        ts: ts || new Date().toISOString(),
      }),
    );
  }

  buildProgressSignature() {
    return JSON.stringify(
      this.book.chapters.map((chapter) => [
        chapter.id,
        chapter.media_asset_id,
        chapter.duration_ms,
      ]),
    );
  }

  getCurrentPositionMs() {
    return Math.floor(this.engine.currentTime * 1000);
  }

  findChapterIndex(id) {
    return this.book.chapters.findIndex((c) => c.id === id);
  }

  onEnded() {
    const nextChapter = this.getNextChapter();
    if (nextChapter) {
      this.goTo(nextChapter.id, 0, this.state.isPlaying);
    } else {
      this.finish();
    }
  }

  getNextChapter() {
    const idx = this.findChapterIndex(this.state.chapter.id);
    return idx !== -1 && idx < this.book.chapters.length - 1
      ? this.book.chapters[idx + 1]
      : null;
  }

  finish() {
    if (this.book.is_completed) return;
    this.book.is_completed = true;
    this.pause();
    this.api("complete");
    this.updateCompletionUI();
    this.updateLocalStorageProgress(
      this.state.chapter.id,
      Math.floor(this.engine.duration * 1000),
    );
  }

  handleSeamlessChapterChange() {
    const next = this.getNextChapter();
    if (next) {
      this.updateChapter(next);

      this.cacheCurrentAndNext();

      const future = this.getNextChapter();
      if (future) {
        this.engine.preloadNext(future.audio_url);
      }

      this.save(true);
    }
  }

  onSeekInput(e) {
    if (!this.engine.duration) return;
    this.state.isDragging = true;
    const time = this.seekBarValueToTime(parseFloat(e.target.value));
    if (this.el["current-time"])
      this.el["current-time"].textContent = this.formatSeconds(time);
  }

  onSeekChange(e) {
    if (!this.engine.duration) return;
    const time = this.seekBarValueToTime(parseFloat(e.target.value));

    if (this.seekedToEnd(time)) {
      this.engine.currentTime = this.engine.duration;
      if (this.el["seek-bar"]) this.el["seek-bar"].value = "100";
      this.goToNextOrFinish();
    } else {
      this.seekTo(time);
    }
    this.state.isDragging = false;
  }

  seekedToEnd(time) {
    return time >= this.engine.duration - AudioPlayer.SEEK_THRESHOLD_END;
  }

  goToNextOrFinish() {
    const nextChapter = this.getNextChapter();
    if (nextChapter) {
      this.goTo(nextChapter.id, 0, this.state.isPlaying);
    } else {
      this.finish();
    }
  }

  seekBarValueToTime(value) {
    return (value / 100) * this.engine.duration;
  }

  onChapterClick(e) {
    const a = e.target.closest("a");
    if (a?.dataset.chapterId) {
      e.preventDefault();
      this.goTo(parseInt(a.dataset.chapterId), 0, true);
      this.closeAccordions();
    }
  }

  setSleep(minutes) {
    this.clearSleep();
    let target;

    if (minutes === "end-of-chapter") {
      target = this.state.chapter.duration_ms / 1000 - this.engine.currentTime;
    } else {
      target = parseInt(minutes) * 60;
    }

    this.state.sleepTarget = Math.max(0, target);
    this.state.sleepAccumulated = 0;
    this.updateSleepDisplay();
    this.el["cancel-sleep-timer"]?.classList.remove("hidden");
    this.closeAccordions();
  }

  updateSleepDisplay() {
    if (!this.el["sleep-timer-text"]) return;
    const remaining = Math.max(
      0,
      this.state.sleepTarget - this.state.sleepAccumulated,
    );
    const s = Math.ceil(remaining);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const text = h > 0 ? `${h}h ${m}m` : m > 0 ? `${m}m` : `${s}s`;
    this.el["sleep-timer-text"].textContent = `Sleep: ${text}`;
  }

  clearSleep() {
    this.state.sleepTarget = 0;
    this.state.sleepAccumulated = 0;
    if (this.el["sleep-timer-text"])
      this.el["sleep-timer-text"].textContent = "Sleep Timer";
    this.el["cancel-sleep-timer"]?.classList.add("hidden");
  }

  handleAccordionSync(e) {
    if (e.target instanceof HTMLInputElement && e.target.checked) {
      [this.el["sleep-toggle"], this.el["chapters-toggle"]].forEach((t) => {
        if (t && t !== e.target) t.checked = false;
      });
    }
  }

  closeAccordions() {
    [this.el["sleep-toggle"], this.el["chapters-toggle"]].forEach((t) => {
      if (t) t.checked = false;
    });
  }

  updateActiveChapterUI() {
    if (!this.el["chapter-list"] || !this.state.chapter) return;
    this.el["chapter-list"].querySelectorAll("a").forEach((a) => {
      const active = a.dataset.chapterId === this.state.chapter.id.toString();
      a.classList.toggle("bg-primary/10", active);
      const title = a.querySelector("span:first-child");
      if (title) title.classList.toggle("text-primary", active);
    });
  }

  updateCompletionUI() {
    const comp = this.book.is_completed;
    this.el["book-completed-badge"]?.classList.toggle("hidden", !comp);
    this.el["time-controls"]?.classList.toggle("hidden", comp);
  }

  async save(force = false) {
    if (!this.state.chapter) return;
    const off = this.getCurrentPositionMs();
    this.updateLocalStorageProgress(this.state.chapter.id, off);

    if (
      !force &&
      Date.now() - this.state.lastSync < AudioPlayer.SYNC_INTERVAL_MS
    )
      return;
    this.state.lastSync = Date.now();
    return this.api(
      "progress",
      { chapter_id: this.state.chapter.id, offset_ms: off },
      force,
    );
  }

  async sync() {
    try {
      const res = await this.fetchWithAuth(
        `/api/books/${this.book.id}/progress`,
        { headers: { "X-CSRF-Token": this.csrf } },
      );

      if (!res) return;

      const remote = await res.json();
      const local = this.getLocalStorageProgress();
      const seekLock =
        Date.now() - this.state.lastManualSeek < AudioPlayer.SEEK_LOCK_MS;

      if (this.shouldSyncLocalToServer(local, remote)) {
        this.save();
      } else if (this.shouldSyncServerToLocal(local, remote, seekLock)) {
        this.syncPositionFromServer(remote);
      }
    } catch (e) {}
    setTimeout(
      () => this.state.isPlaying && this.sync(),
      AudioPlayer.SYNC_RETRY_MS,
    );
  }

  shouldSyncLocalToServer(local, remote) {
    return (
      remote.updated_at &&
      local &&
      new Date(local.ts) > new Date(remote.updated_at)
    );
  }

  shouldSyncServerToLocal(local, remote, seekLock) {
    return (
      !seekLock &&
      remote.chapter_id &&
      (!local || new Date(remote.updated_at) > new Date(local.ts))
    );
  }

  syncPositionFromServer(remote) {
    if (
      remote.chapter_id !== this.state.chapter.id ||
      Math.abs(remote.offset_ms - this.getCurrentPositionMs()) > 5000
    ) {
      this.goTo(remote.chapter_id, remote.offset_ms);
    }
  }

  async api(path, body = {}, alive = false) {
    await this.fetchWithAuth(`/api/books/${this.book.id}/${path}`, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrf,
      },
      body: JSON.stringify(body),
      keepalive: alive,
    });
  }

  async fetchWithAuth(url, options) {
    try {
      const res = await fetch(url, options);

      if (res.status === 401 || res.status === 403) {
        window.location.href = `/auth/oidc?${new URLSearchParams({
          user_return_to: window.location.pathname + window.location.search,
        })}`;
        return null;
      }

      return res;
    } catch (e) {
      return null;
    }
  }

  async checkCache() {
    if (!("caches" in window) || !this.state.chapter) return;
    try {
      const cache = await caches.open(CACHE_NAME);
      const cached = await isCached(cache, this.state.chapter.audio_url);
      this.updateChapterCacheStatus(this.state.chapter.audio_url);
    } catch (e) {}
  }

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
  }

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
  }

  setChapterCacheIcon(link, isCached) {
    const icon = link.querySelector(".chapter-cache-icon");
    if (icon) {
      icon.classList.toggle("hidden", !isCached);
    }
  }

  postToServiceWorker(message) {
    if (!("serviceWorker" in navigator)) return;
    navigator.serviceWorker.ready.then((registration) => {
      registration.active.postMessage(message);
    });
  }

  cacheCurrentAndNext() {
    if (!this.state.chapter) return;

    const currentIndex = this.findChapterIndex(this.state.chapter.id);
    const urlsToCache = [];

    for (
      let i = currentIndex;
      i < currentIndex + AudioPlayer.CACHE_LOOKAHEAD;
      i++
    ) {
      if (i >= 0 && i < this.book.chapters.length) {
        urlsToCache.push(this.book.chapters[i].audio_url);
      }
    }

    if (urlsToCache.length > 0) {
      this.postToServiceWorker({ type: "CACHE_URLS", urls: urlsToCache });
    }
  }

  downloadEntireBook() {
    const urls = this.book.chapters.map((c) => c.audio_url);
    this.postToServiceWorker({ type: "CACHE_ENTIRE_BOOK", urls: urls });
  }

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
  }

  clearOtherBooks() {
    const currentBookUrls = this.book.chapters.map((c) => c.audio_url);
    this.postToServiceWorker({
      type: "CLEAR_OTHER_BOOKS",
      currentBookUrls: currentBookUrls,
    });
  }

  updateMediaMetadata() {
    if (!("mediaSession" in navigator)) return;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: this.book.title,
      artist: this.book.author,
      album: this.state.chapter?.title,
      artwork: this.book.cover_url
        ? [{ src: this.book.cover_url, sizes: "512x512", type: "image/jpeg" }]
        : [],
    });

    this.setMediaSessionAction("play", () => this.play());
    this.setMediaSessionAction("pause", () => this.pause());
    this.setMediaSessionAction("seekto", (details) => {
      if (details.seekTime) this.seekTo(details.seekTime);
    });
    this.setMediaSessionAction("seekbackward", () =>
      this.seek(AudioPlayer.SEEK_BACKWARD),
    );
    this.setMediaSessionAction("seekforward", () =>
      this.seek(AudioPlayer.SEEK_FORWARD),
    );
    this.setMediaSessionAction("previoustrack", () => this.jump(-1));
    this.setMediaSessionAction("nexttrack", () => this.jump(1));
  }

  setMediaSessionAction(action, handler) {
    try {
      navigator.mediaSession.setActionHandler(action, handler);
    } catch (e) {}
  }

  jump(n) {
    const idx = this.findChapterIndex(this.state.chapter?.id);
    if (idx !== -1 && this.book.chapters[idx + n])
      this.goTo(this.book.chapters[idx + n].id, 0, true);
  }

  updatePlayState(on) {
    this.el["play-icon"]?.classList.toggle("hidden", on);
    this.el["pause-icon"]?.classList.toggle("hidden", !on);

    if ("mediaSession" in navigator) {
      navigator.mediaSession.playbackState = on ? "playing" : "paused";
    }
  }

  updateMediaPosition() {
    if (!("mediaSession" in navigator) || !this.engine.duration) return;
    try {
      navigator.mediaSession.setPositionState({
        duration: this.engine.duration,
        playbackRate: this.engine.active.playbackRate,
        position: this.engine.currentTime,
      });
    } catch (e) {}
  }

  onMetadataLoaded() {
    if (this.el["total-time"])
      this.el["total-time"].textContent = this.formatSeconds(
        this.engine.duration,
      );
    this.checkCache();
  }

  formatSeconds(s) {
    if (!s || isNaN(s)) return "0:00";
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = Math.floor(s % 60);
    return h > 0
      ? `${h}:${m.toString().padStart(2, "0")}:${sec.toString().padStart(2, "0")}`
      : `${m}:${sec.toString().padStart(2, "0")}`;
  }

  showLayer(id) {
    ["loading", "error", "player-ui"].forEach((l) =>
      this.el[l]?.classList.add("hidden"),
    );
    this.el[id]?.classList.remove("hidden");
  }

  showErr(m) {
    this.showLayer("error");
    if (this.el["error-message"]) this.el["error-message"].textContent = m;
  }

  close() {
    this.engine.pause();
    this.save(true);
    window.location.href = "/library";
  }
}

document.addEventListener("DOMContentLoaded", () => {
  new AudioPlayer();
});
