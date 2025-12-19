export const AudioPlayer = {
  mounted() {
    this.lastUpdate = 0;

    this.el.addEventListener("timeupdate", (e) => {
      const now = Date.now();
      // Throttle updates to every 5 seconds
      if (now - this.lastUpdate > 5000) {
        this.lastUpdate = now;
        this.pushEvent("save_position", {
          id: this.el.dataset.bookId,
          position: this.el.currentTime,
        });
      }
    });

    // Handle initial position
    const startAt = parseFloat(this.el.dataset.startAt || "0");
    if (startAt > 0) {
      this.el.currentTime = startAt;
    }
  },

  updated() {
    // If the book changed but the element was reused, update position
    const startAt = parseFloat(this.el.dataset.startAt || "0");
    if (this.el.dataset.bookId !== this.lastBookId) {
      this.lastBookId = this.el.dataset.bookId;
      this.el.currentTime = startAt;
    }
  },
};

export default {
  AudioPlayer,
};
