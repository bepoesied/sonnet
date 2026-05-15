import { AudioEngine } from "./audio-engine.js";
import { cacheActions } from "./player-cache.js";
import { mediaSessionControls } from "./player-media-session.js";
import { progressSync } from "./player-progress.js";
import { playerUI } from "./player-ui.js";

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

    this.engine.onTimeUpdate = () => this.onTimeUpdate();
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
        }, this.constructor.LOAD_TIMEOUT_MS);

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
    if (this.el["current-chapter-title"]) {
      this.el["current-chapter-title"].textContent = chapter.title;
    }
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
      if (!this.engine.active.src) {
        this.engine.active.src = this.state.chapter.audio_url;
      }
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

  updateSleepTimer(delta) {
    if (this.state.sleepTarget <= 0 || !this.state.isPlaying || delta <= 0) {
      return;
    }

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

  close() {
    this.engine.pause();
    this.save(true);
    window.location.href = "/library";
  }
}

Object.assign(
  AudioPlayer.prototype,
  cacheActions,
  mediaSessionControls,
  progressSync,
  playerUI,
);

document.addEventListener("DOMContentLoaded", () => {
  new AudioPlayer();
});
