const DEBOUNCE_MS = 2 * 1000;

export const AudioPlayer = {
  mounted() {
    this.lastUpdate = 0;
    this.lastBookId = this.el.dataset.bookId;

    this.el.addEventListener("timeupdate", (e) => {
      const now = Date.now();
      // Throttle updates to every 2 seconds
      if (now - this.lastUpdate > DEBOUNCE_MS) {
        this.lastUpdate = now;
        this.pushEvent("save_position", {
          id: this.el.dataset.bookId,
          position_ms: Math.floor(this.el.currentTime * 1000),
        });
        this.updatePositionState();
      }
    });

    this.el.addEventListener("play", () => {
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = "playing";
      }
      this.updatePositionState();
    });

    this.el.addEventListener("pause", (e) => {
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = "paused";
      }
      const now = Date.now();
      this.lastUpdate = now;
      this.pushEvent("save_position", {
        id: this.el.dataset.bookId,
        position_ms: Math.floor(this.el.currentTime * 1000),
      });
      this.updatePositionState();
    });

    this.el.addEventListener("ended", (e) => {
      this.pushEvent("ended", {
        id: this.el.dataset.bookId,
      });
    });

    this.el.addEventListener("seeked", () => {
      this.pushEvent("save_position", {
        id: this.el.dataset.bookId,
        position_ms: Math.floor(this.el.currentTime * 1000),
      });
      this.updatePositionState();
    });

    // Handle initial position
    const startAt = parseInt(this.el.dataset.startAt || "0", 10);
    if (startAt > 0) {
      this.el.currentTime = startAt / 1000;
    }

    this.updateMediaSession();
  },

  updated() {
    // If the book changed but the element was reused, update position
    const startAt = parseInt(this.el.dataset.startAt || "0", 10);
    if (this.el.dataset.bookId !== this.lastBookId) {
      this.lastBookId = this.el.dataset.bookId;
      this.el.currentTime = startAt / 1000;
      this.updateMediaSession();
    } else {
      // Metadata might have changed (e.g. chapter title)
      this.updateMediaSession();
    }
  },

  updateMediaSession() {
    if ("mediaSession" in navigator) {
      const { title, author, coverUrl, chapterTitle } = this.el.dataset;

      navigator.mediaSession.metadata = new MediaMetadata({
        title: chapterTitle || title,
        artist: author,
        album: title,
        artwork: coverUrl
          ? [
              { src: coverUrl, sizes: "96x96", type: "image/jpeg" },
              { src: coverUrl, sizes: "128x128", type: "image/jpeg" },
              { src: coverUrl, sizes: "192x192", type: "image/jpeg" },
              { src: coverUrl, sizes: "256x256", type: "image/jpeg" },
              { src: coverUrl, sizes: "384x384", type: "image/jpeg" },
              { src: coverUrl, sizes: "512x512", type: "image/jpeg" },
            ]
          : [],
      });

      navigator.mediaSession.setActionHandler("play", () => this.el.play());
      navigator.mediaSession.setActionHandler("pause", () => this.el.pause());
      navigator.mediaSession.setActionHandler("seekbackward", () => {
        this.el.currentTime = Math.max(this.el.currentTime - 10, 0);
      });
      navigator.mediaSession.setActionHandler("seekforward", () => {
        this.el.currentTime = Math.min(
          this.el.currentTime + 10,
          this.el.duration,
        );
      });
      navigator.mediaSession.setActionHandler("seekto", (details) => {
        if (details.fastSeek && "fastSeek" in this.el) {
          this.el.fastSeek(details.seekTime);
        } else {
          this.el.currentTime = details.seekTime;
        }
      });
      navigator.mediaSession.setActionHandler("previoustrack", () => {
        this.pushEvent("previous_chapter", { id: this.el.dataset.bookId });
      });
      navigator.mediaSession.setActionHandler("nexttrack", () => {
        this.pushEvent("next_chapter", { id: this.el.dataset.bookId });
      });
      navigator.mediaSession.setActionHandler("stop", () => {
        this.pushEvent("stop", {});
      });
    }
  },

  updatePositionState() {
    if (
      "mediaSession" in navigator &&
      "setPositionState" in navigator.mediaSession
    ) {
      if (this.el.duration && !isNaN(this.el.duration)) {
        navigator.mediaSession.setPositionState({
          duration: this.el.duration,
          playbackRate: this.el.playbackRate,
          position: this.el.currentTime,
        });
      }
    }
  },

  destroyed() {
    if ("mediaSession" in navigator) {
      navigator.mediaSession.metadata = null;
      navigator.mediaSession.playbackState = "none";
      [
        "play",
        "pause",
        "seekbackward",
        "seekforward",
        "seekto",
        "previoustrack",
        "nexttrack",
        "stop",
      ].forEach((action) =>
        navigator.mediaSession.setActionHandler(action, null),
      );
    }
  },
};

export default {
  AudioPlayer,
};
