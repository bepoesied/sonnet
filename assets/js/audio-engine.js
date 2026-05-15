export class AudioEngine {
  constructor() {
    this.audio = this._createAudioEl();
    this.nextUrl = null;
    this.isLocked = false;

    this.onTimeUpdate = null;
    this.onTrackEnded = null;
    this.onTrackChanged = null;
    this.onError = null;
    this.onMetadataLoaded = null;
    this.onPlay = null;
    this.onPause = null;
  }

  get active() {
    return this.audio;
  }
  get standby() {
    return null;
  }
  get duration() {
    return this.active.duration;
  }
  get currentTime() {
    return this.active.currentTime;
  }
  set currentTime(val) {
    this.active.currentTime = val;
  }
  get paused() {
    return this.active.paused;
  }

  _createAudioEl() {
    const audio = new Audio();
    audio.crossOrigin = "anonymous";
    audio.preload = "auto";

    audio.addEventListener("timeupdate", () => {
      if (audio === this.active) this._handleTimeUpdate();
    });

    audio.addEventListener("ended", () => {
      if (audio === this.active) this._handleEnded();
    });

    audio.addEventListener("error", () => {
      if (audio === this.active && this.onError) this.onError();
    });

    audio.addEventListener("loadedmetadata", () => {
      if (audio === this.active && this.onMetadataLoaded)
        this.onMetadataLoaded();
    });

    audio.addEventListener("canplay", () => {
      if (
        audio === this.active &&
        this.onMetadataLoaded &&
        audio.readyState >= 1
      ) {
        this.onMetadataLoaded();
      }
    });

    audio.addEventListener("play", () => {
      if (audio === this.active && this.onPlay) this.onPlay();
    });

    audio.addEventListener("pause", () => {
      if (audio === this.active && this.onPause) this.onPause();
    });

    return audio;
  }

  async load(url, startOffset = 0) {
    const el = this.active;
    el.src = url;
    el.load();

    if (startOffset > 0 && el.readyState >= 1) {
      el.currentTime = startOffset;
    }

    this.nextUrl = null;
  }

  preloadNext(url) {
    // Mobile browsers are prone to suspending playback when a backgrounded
    // page swaps between multiple Audio elements. Keep a single media element
    // authoritative and let the service worker/cache handle chapter readiness.
    this.nextUrl = url;
  }

  play() {
    return this.active.play();
  }

  pause() {
    this.active.pause();
  }

  toggle() {
    return this.active.paused ? this.play() : this.pause();
  }

  seek(time) {
    if (Number.isFinite(time)) this.active.currentTime = time;
  }

  _handleTimeUpdate() {
    const t = this.active.currentTime;
    const d = this.active.duration;

    if (this.onTimeUpdate) this.onTimeUpdate(t, d);
  }

  _handleEnded() {
    if (this.onTrackEnded) this.onTrackEnded();
  }
}
