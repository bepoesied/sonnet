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
 * @property {Object} sleep - Sleep timer state
 * @property {string|null} sleep.mode - 'time' or 'end-of-chapter'
 * @property {number} sleep.remaining - Seconds remaining until pause
 * @property {number} lastSync - Timestamp of last API sync
 * @property {number} lastPosition - Cached audio currentTime
 * @property {number} lastManualSeek - Timestamp of last user seek
 */

class AudioPlayer {
  constructor() {
    this.root = document.getElementById("player-root");
    if (!this.root) return;

    /** @type {BookData} */
    this.book = JSON.parse(this.root.dataset.book);
    this.audio = new Audio();
    this.audio.crossOrigin = "anonymous";
    this.audio.preload = "auto";
    this.csrf = document.querySelector("meta[name='csrf-token']")?.content;

    /** @type {PlayerState} */
    this.state = {
      chapter: null,
      isPlaying: false,
      isPending: false,
      isDragging: false,
      sleep: { mode: null, remaining: 0 },
      lastSync: 0,
      lastPosition: 0,
      lastManualSeek: 0,
    };

    this.init();
  }

  init() {
    this.bindElements();
    this.setupListeners();
    this.loadInitialState();
  }

  bindElements() {
    const ids = [
      "player-ui",
      "loading",
      "error",
      "error-message",
      "book-cover-container",
      "book-cover",
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
      "cached-indicator",
      "time-controls",
      "sleep-toggle",
      "chapters-toggle",
    ];
    this.el = {};
    ids.forEach((id) => {
      this.el[id] = document.getElementById(id);
    });
  }

  setupListeners() {
    this.el["play-pause-btn"]?.addEventListener("click", () => this.toggle());
    this.el["rewind-btn"]?.addEventListener("click", () => this.seek(-11));
    this.el["forward-btn"]?.addEventListener("click", () => this.seek(10));
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

    // Handle exclusive accordion expansion
    [this.el["sleep-toggle"], this.el["chapters-toggle"]].forEach((toggle) => {
      toggle?.addEventListener("change", (e) => this.handleAccordionSync(e));
    });

    // Delegated click for sleep options
    document.addEventListener("click", (e) => {
      const btn = e.target.closest(".sleep-option");
      if (btn) this.setSleep(btn.dataset.minutes);
    });

    this.audio.addEventListener("timeupdate", () => this.onTimeUpdate());
    this.audio.addEventListener("loadedmetadata", () =>
      this.onMetadataLoaded(),
    );
    this.audio.addEventListener("play", () => this.updatePlayState(true));
    this.audio.addEventListener("pause", () => this.updatePlayState(false));
    this.audio.addEventListener("ended", () => this.onEnded());
    this.audio.addEventListener("error", () =>
      this.showErr("Audio failed to load"),
    );

    window.addEventListener(
      "beforeunload",
      () => this.state.isPlaying && this.save(true),
    );
  }

  async loadInitialState() {
    try {
      this.renderUI();
      const local = JSON.parse(
        localStorage.getItem(`progress_${this.book.id}`),
      );
      const remote = this.book.progress;
      let start = remote;

      // Select newest position between local and server (Newest Wins)
      if (
        local &&
        (!remote || new Date(local.ts) > new Date(remote.updated_at))
      ) {
        start = { chapter_id: local.cid, offset_ms: local.off };
      }

      const chapterId = start?.chapter_id || this.book.chapters[0]?.id;
      const offsetMs = start?.offset_ms || 0;

      if (chapterId) await this.goTo(chapterId, offsetMs);

      this.updateCompletionUI();
      this.showLayer("player-ui");
      this.sync();
    } catch (e) {
      this.showErr("Failed to initialize player");
    }
  }

  renderUI() {
    if (this.book.cover_url && this.el["book-cover"]) {
      this.el["book-cover"].src = this.book.cover_url;
      this.el["book-cover-container"]?.classList.remove("hidden");
    }

    if (this.el["chapter-list"]) {
      this.el["chapter-list"].textContent = "";
      this.book.chapters.forEach((c) => {
        const item = this.createChapterItem(c);
        this.el["chapter-list"].append(item);
      });
    }
    this.updateMediaMetadata();
  }

  /** @param {Chapter} c */
  createChapterItem(c) {
    const li = document.createElement("li");
    li.className = "border-b border-base-content/5 last:border-0";

    const a = document.createElement("a");
    a.href = "#";
    a.dataset.chapterId = c.id.toString();
    a.className =
      "flex justify-between py-4 px-6 hover:bg-primary/5 active:bg-primary/10 transition-colors font-sans group";

    const title = document.createElement("span");
    title.className =
      "text-sm group-hover:text-primary transition-colors pr-4 font-semibold flex-1";
    title.textContent = c.title;

    const dur = document.createElement("span");
    dur.className = "text-xs opacity-50 font-mono tabular-nums";
    dur.textContent = this.format(c.duration_ms / 1000);

    a.append(title, dur);
    li.append(a);
    return li;
  }

  /**
   * @param {number} cid
   * @param {number} ms
   * @param {boolean} autoPlay
   */
  async goTo(cid, ms = 0, autoPlay = false) {
    const chapter = this.book.chapters.find((x) => x.id === cid);
    if (!chapter || this.state.isPending) return;

    if (this.state.chapter?.media_asset_id !== chapter.media_asset_id) {
      this.state.isPending = true;
      this.audio.src = chapter.audio_url;
      await new Promise((r) => {
        this.audio.addEventListener("loadedmetadata", r, { once: true });
        this.audio.load();
      });
      this.state.isPending = false;
    }

    this.audio.currentTime = (ms || chapter.start_ms) / 1000;
    this.state.lastPosition = this.audio.currentTime;
    this.state.chapter = chapter;

    if (this.el["current-chapter-title"])
      this.el["current-chapter-title"].textContent = chapter.title;

    this.updateActiveChapterUI();
    this.updateMediaMetadata();
    this.checkCache();
    if (autoPlay || this.state.isPlaying) await this.play();
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
      if (!this.audio.src) this.audio.src = this.state.chapter.audio_url;
      await this.audio.play();
      this.state.isPlaying = true;
    } catch (e) {
      if (e.name !== "AbortError") this.showErr("Playback failed");
    } finally {
      this.state.isPending = false;
    }
  }

  pause() {
    this.audio.pause();
    this.state.isPlaying = false;
    this.save();
  }

  toggle() {
    this.audio.paused ? this.play() : this.pause();
  }

  /** @param {number} s */
  seek(s) {
    if (!this.audio.duration) return;
    this.audio.currentTime = Math.max(
      0,
      Math.min(this.audio.currentTime + s, this.audio.duration),
    );
    this.state.lastPosition = this.audio.currentTime;
    this.state.lastManualSeek = Date.now();
  }

  onTimeUpdate() {
    const { duration, currentTime } = this.audio;
    if (!duration || !this.state.chapter) return;

    if (!this.state.isDragging) {
      if (this.el["seek-bar"])
        this.el["seek-bar"].value = ((currentTime / duration) * 100).toString();
      if (this.el["current-time"])
        this.el["current-time"].textContent = this.format(currentTime);
    }

    const delta = this.state.lastPosition
      ? currentTime - this.state.lastPosition
      : 0;
    this.state.lastPosition = currentTime;

    this.handleSleepTimer(delta);
    this.handleChapterBoundary(currentTime * 1000);
    this.updateMediaPosition();
    this.save(); // Throttled internally
  }

  /** @param {number} delta */
  handleSleepTimer(delta) {
    if (!this.state.sleep.mode || delta <= 0 || delta >= 1) return;

    if (this.state.sleep.mode === "end-of-chapter") {
      this.state.sleep.remaining = Math.max(
        0,
        (this.state.chapter.end_ms - this.audio.currentTime * 1000) / 1000,
      );
    } else {
      this.state.sleep.remaining = Math.max(
        0,
        this.state.sleep.remaining - delta,
      );
    }

    this.updateSleepDisplay();
    if (this.state.sleep.remaining <= 0) {
      this.pause();
      this.clearSleep();
      if (this.state.sleep.mode === "end-of-chapter")
        this.audio.currentTime = (this.state.chapter.end_ms - 1) / 1000;
    }
  }

  /** @param {number} ms */
  handleChapterBoundary(ms) {
    const next = this.book.chapters.find(
      (c) =>
        c.media_asset_id === this.state.chapter.media_asset_id &&
        ms >= c.start_ms &&
        ms < c.end_ms,
    );

    if (next && next.id !== this.state.chapter.id) {
      this.state.chapter = next;
      if (this.el["current-chapter-title"])
        this.el["current-chapter-title"].textContent = next.title;
      this.updateActiveChapterUI();
      this.save(true);
      this.updateMediaMetadata();
    }
  }

  onEnded() {
    const idx = this.book.chapters.findIndex(
      (c) => c.id === this.state.chapter.id,
    );
    if (idx !== -1 && idx < this.book.chapters.length - 1) {
      this.goTo(this.book.chapters[idx + 1].id, 0, this.state.isPlaying);
    } else {
      this.finish();
    }
  }

  finish() {
    if (this.book.is_completed) return;
    this.book.is_completed = true;
    this.pause();
    this.api("complete");
    this.updateCompletionUI();

    const ts = new Date().toISOString();
    localStorage.setItem(
      `progress_${this.book.id}`,
      JSON.stringify({
        cid: this.state.chapter.id,
        off: Math.floor(this.audio.duration * 1000),
        ts,
      }),
    );
  }

  onSeekInput(e) {
    if (!this.audio.duration) return;
    this.state.isDragging = true;
    const time = (parseFloat(e.target.value) / 100) * this.audio.duration;
    if (this.el["current-time"])
      this.el["current-time"].textContent = this.format(time);
  }

  onSeekChange(e) {
    if (!this.audio.duration) return;
    this.state.isDragging = false;
    const time = (parseFloat(e.target.value) / 100) * this.audio.duration;

    if (time >= this.audio.duration - 0.5) {
      this.audio.currentTime = this.audio.duration;
      if (this.el["seek-bar"]) this.el["seek-bar"].value = "100";
      this.finish();
    } else {
      this.audio.currentTime = time;
    }
    this.state.lastPosition = this.audio.currentTime;
    this.state.lastManualSeek = Date.now();
  }

  onChapterClick(e) {
    const a = e.target.closest("a");
    if (a?.dataset.chapterId) {
      e.preventDefault();
      this.goTo(parseInt(a.dataset.chapterId), 0, true);
      this.closeAccordions();
    }
  }

  /** @param {string} m */
  setSleep(m) {
    this.clearSleep();
    this.state.sleep.mode = m === "end-of-chapter" ? "end-of-chapter" : "time";
    this.state.sleep.remaining =
      m === "end-of-chapter"
        ? (this.state.chapter.end_ms - this.audio.currentTime * 1000) / 1000
        : parseInt(m) * 60;

    this.updateSleepDisplay();
    this.el["cancel-sleep-timer"]?.classList.remove("hidden");
    this.closeAccordions();
  }

  updateSleepDisplay() {
    if (!this.state.sleep.mode || !this.el["sleep-timer-text"]) return;
    const s = Math.ceil(this.state.sleep.remaining);
    const h = Math.floor(s / 3600),
      m = Math.floor((s % 3600) / 60);
    const text = h > 0 ? `${h}h ${m}m` : m > 0 ? `${m}m` : `${s}s`;
    this.el["sleep-timer-text"].textContent = `Sleep: ${text}`;
  }

  clearSleep() {
    this.state.sleep = { mode: null, remaining: 0 };
    if (this.el["sleep-timer-text"])
      this.el["sleep-timer-text"].textContent = "Sleep Timer";
    this.el["cancel-sleep-timer"]?.classList.add("hidden");
  }

  /** @param {Event} e */
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
    const off = Math.floor(this.audio.currentTime * 1000);
    localStorage.setItem(
      `progress_${this.book.id}`,
      JSON.stringify({
        cid: this.state.chapter.id,
        off,
        ts: new Date().toISOString(),
      }),
    );

    if (!force && Date.now() - this.state.lastSync < 30000) return;
    this.state.lastSync = Date.now();
    return this.api(
      "progress",
      { chapter_id: this.state.chapter.id, offset_ms: off },
      force,
    );
  }

  async sync() {
    try {
      const res = await fetch(`/api/books/${this.book.id}/progress`, {
        headers: { "X-CSRF-Token": this.csrf },
      });
      const remote = await res.json();
      const local = JSON.parse(
        localStorage.getItem(`progress_${this.book.id}`),
      );
      const seekLock = Date.now() - this.state.lastManualSeek < 10000;

      if (
        remote.updated_at &&
        local &&
        new Date(local.ts) > new Date(remote.updated_at)
      ) {
        this.save();
      } else if (
        !seekLock &&
        remote.chapter_id &&
        (!local || new Date(remote.updated_at) > new Date(local.ts))
      ) {
        if (
          remote.chapter_id !== this.state.chapter.id ||
          Math.abs(remote.offset_ms - this.audio.currentTime * 1000) > 5000
        ) {
          this.goTo(remote.chapter_id, remote.offset_ms);
        }
      }
    } catch (e) {}
    setTimeout(() => this.state.isPlaying && this.sync(), 60000);
  }

  async api(path, body = {}, alive = false) {
    try {
      await fetch(`/api/books/${this.book.id}/${path}`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrf,
        },
        body: JSON.stringify(body),
        keepalive: alive,
      });
    } catch (e) {}
  }

  async checkCache() {
    if (!("caches" in window) || !this.state.chapter) return;
    try {
      const url = new URL(this.state.chapter.audio_url);
      url.search = "";
      url.hash = "";
      const match = await (
        await caches.open("media-cache-v1")
      ).match(url.toString());
      this.el["cached-indicator"]?.classList.toggle("opacity-100", !!match);
      this.el["cached-indicator"]?.classList.toggle("opacity-0", !match);
    } catch (e) {}
    if (
      !this.el["cached-indicator"]?.classList.contains("opacity-100") &&
      this.state.isPlaying
    ) {
      setTimeout(() => this.checkCache(), 5000);
    }
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
    const actions = {
      play: () => this.play(),
      pause: () => this.pause(),
      seekbackward: (details) => this.seek(-(details.seekOffset || 11)),
      seekforward: (details) => this.seek(details.seekOffset || 10),
      seekto: (details) => {
        if (details.seekTime !== undefined) {
          this.audio.currentTime = details.seekTime;
          this.state.lastPosition = this.audio.currentTime;
          this.updateMediaPosition();
        }
      },
      previoustrack: () => this.jump(-1),
      nexttrack: () => this.jump(1),
    };
  }

  jump(n) {
    const idx = this.book.chapters.findIndex(
      (c) => c.id === this.state.chapter?.id,
    );
    if (this.book.chapters[idx + n])
      this.goTo(this.book.chapters[idx + n].id, 0, true);
  }

  /** @param {boolean} on - Playback status */
  updatePlayState(on) {
    this.el["play-icon"]?.classList.toggle("hidden", on);
    this.el["pause-icon"]?.classList.toggle("hidden", !on);

    if ("mediaSession" in navigator) {
      navigator.mediaSession.playbackState = on ? "playing" : "paused";
    }
  }

  updateMediaPosition() {
    if (!("mediaSession" in navigator) || !this.audio.duration) return;
    try {
      navigator.mediaSession.setPositionState({
        duration: this.audio.duration,
        playbackRate: this.audio.playbackRate,
        position: this.audio.currentTime,
      });
    } catch (e) {}
  }

  onMetadataLoaded() {
    if (this.el["total-time"])
      this.el["total-time"].textContent = this.format(this.audio.duration);
    this.checkCache();
  }

  format(s) {
    if (!s || isNaN(s)) return "0:00";
    const h = Math.floor(s / 3600),
      m = Math.floor((s % 3600) / 60),
      sec = Math.floor(s % 60);
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
    this.pause();
    this.save(true);
    window.location.href = "/library";
  }
}

document.addEventListener("DOMContentLoaded", () => {
  new AudioPlayer();
});
