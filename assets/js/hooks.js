const DEBOUNCE_MS = 2 * 1000;

export const AudioPlayer = {
  mounted() {
    this.lastUpdate = 0;

    this.el.addEventListener("timeupdate", (e) => {
      const now = Date.now();
      // Throttle updates to every 5 seconds
      if (now - this.lastUpdate > DEBOUNCE_MS) {
        this.lastUpdate = now;
        this.pushEvent("save_position", {
          id: this.el.dataset.bookId,
          position_ms: Math.floor(this.el.currentTime * 1000),
        });
      }
    });

    this.el.addEventListener("pause", (e) => {
      const now = Date.now();
      this.lastUpdate = now;
      this.pushEvent("save_position", {
        id: this.el.dataset.bookId,
        position_ms: Math.floor(this.el.currentTime * 1000),
      });
    });

    this.el.addEventListener("ended", (e) => {
      this.pushEvent("ended", {
        id: this.el.dataset.bookId,
      });
    });

    // Handle initial position
    const startAt = parseInt(this.el.dataset.startAt || "0", 10);
    if (startAt > 0) {
      this.el.currentTime = startAt / 1000;
    }
  },

  updated() {
    // If the book changed but the element was reused, update position
    const startAt = parseInt(this.el.dataset.startAt || "0", 10);
    if (this.el.dataset.bookId !== this.lastBookId) {
      this.lastBookId = this.el.dataset.bookId;
      this.el.currentTime = startAt / 1000;
    }
  },
};

export default {
  AudioPlayer,
};
