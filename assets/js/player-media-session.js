export const mediaSessionControls = {
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
      this.seek(this.constructor.SEEK_BACKWARD),
    );
    this.setMediaSessionAction("seekforward", () =>
      this.seek(this.constructor.SEEK_FORWARD),
    );
    this.setMediaSessionAction("previoustrack", () => this.jump(-1));
    this.setMediaSessionAction("nexttrack", () => this.jump(1));
  },

  setMediaSessionAction(action, handler) {
    try {
      navigator.mediaSession.setActionHandler(action, handler);
    } catch (e) {}
  },

  jump(n) {
    const idx = this.findChapterIndex(this.state.chapter?.id);
    if (idx !== -1 && this.book.chapters[idx + n]) {
      this.goTo(this.book.chapters[idx + n].id, 0, true);
    }
  },

  updatePlayState(on) {
    this.el["play-icon"]?.classList.toggle("hidden", on);
    this.el["pause-icon"]?.classList.toggle("hidden", !on);

    if ("mediaSession" in navigator) {
      navigator.mediaSession.playbackState = on ? "playing" : "paused";
    }
  },

  updateMediaPosition() {
    if (!("mediaSession" in navigator) || !this.engine.duration) return;

    try {
      navigator.mediaSession.setPositionState({
        duration: this.engine.duration,
        playbackRate: this.engine.active.playbackRate,
        position: this.engine.currentTime,
      });
    } catch (e) {}
  },
};
