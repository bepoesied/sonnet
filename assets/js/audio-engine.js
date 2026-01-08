export class AudioEngine {
  constructor() {
    this.buffers = [this._createAudioEl(), this._createAudioEl()];
    this.activeIdx = 0;
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
    return this.buffers[this.activeIdx];
  }
  get standby() {
    return this.buffers[this.activeIdx ^ 1];
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

    this.standby.pause();
    this.standby.src = "";
    this.nextUrl = null;
  }

  preloadNext(url) {
    if (this.nextUrl === url) return;
    this.nextUrl = url;
    const el = this.standby;
    el.src = url;
    el.load();
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
    if (this.standby.src && this.standby.readyState >= 2) {
      const oldActive = this.active;
      this.activeIdx = this.activeIdx ^ 1;

      this.active
        .play()
        .then(() => {
          if (this.onTrackChanged) this.onTrackChanged(this.active.src);
        })
        .catch(() => {});

      oldActive.pause();
      oldActive.currentTime = 0;
      oldActive.src = "";
    } else {
      if (this.onTrackEnded) this.onTrackEnded();
    }
  }
}
