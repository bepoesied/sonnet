export const playerUI = {
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
  },

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
  },

  setupListeners() {
    this.el["play-pause-btn"]?.addEventListener("click", () => this.toggle());
    this.el["rewind-btn"]?.addEventListener("click", () =>
      this.seek(this.constructor.SEEK_BACKWARD),
    );
    this.el["forward-btn"]?.addEventListener("click", () =>
      this.seek(this.constructor.SEEK_FORWARD),
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
  },

  renderUI() {
    this.renderChapterList();
    this.updateMediaMetadata();
    this.refreshAllChapterCacheStatus();
  },

  renderChapterList() {
    if (!this.el["chapter-list"]) return;
    this.el["chapter-list"].textContent = "";
    this.book.chapters.forEach((c) =>
      this.el["chapter-list"].append(this.createChapterItem(c)),
    );
  },

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
  },

  onSeekInput(e) {
    if (!this.engine.duration) return;
    this.state.isDragging = true;
    const time = this.seekBarValueToTime(parseFloat(e.target.value));
    if (this.el["current-time"]) {
      this.el["current-time"].textContent = this.formatSeconds(time);
    }
  },

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
  },

  seekedToEnd(time) {
    return time >= this.engine.duration - this.constructor.SEEK_THRESHOLD_END;
  },

  goToNextOrFinish() {
    const nextChapter = this.getNextChapter();
    if (nextChapter) {
      this.goTo(nextChapter.id, 0, this.state.isPlaying);
    } else {
      this.finish();
    }
  },

  seekBarValueToTime(value) {
    return (value / 100) * this.engine.duration;
  },

  onChapterClick(e) {
    const a = e.target.closest("a");
    if (a?.dataset.chapterId) {
      e.preventDefault();
      this.goTo(parseInt(a.dataset.chapterId), 0, true);
      this.closeAccordions();
    }
  },

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
  },

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
  },

  clearSleep() {
    this.state.sleepTarget = 0;
    this.state.sleepAccumulated = 0;
    if (this.el["sleep-timer-text"]) {
      this.el["sleep-timer-text"].textContent = "Sleep Timer";
    }
    this.el["cancel-sleep-timer"]?.classList.add("hidden");
  },

  handleAccordionSync(e) {
    if (e.target instanceof HTMLInputElement && e.target.checked) {
      [this.el["sleep-toggle"], this.el["chapters-toggle"]].forEach((t) => {
        if (t && t !== e.target) t.checked = false;
      });
    }
  },

  closeAccordions() {
    [this.el["sleep-toggle"], this.el["chapters-toggle"]].forEach((t) => {
      if (t) t.checked = false;
    });
  },

  updateActiveChapterUI() {
    if (!this.el["chapter-list"] || !this.state.chapter) return;
    this.el["chapter-list"].querySelectorAll("a").forEach((a) => {
      const active = a.dataset.chapterId === this.state.chapter.id.toString();
      a.classList.toggle("bg-primary/10", active);
      const title = a.querySelector("span:first-child");
      if (title) title.classList.toggle("text-primary", active);
    });
  },

  updateCompletionUI() {
    const comp = this.book.is_completed;
    this.el["book-completed-badge"]?.classList.toggle("hidden", !comp);
    this.el["time-controls"]?.classList.toggle("hidden", comp);
  },

  updateSeekBar(currentTime, duration) {
    if (this.el["seek-bar"]) {
      this.el["seek-bar"].value = ((currentTime / duration) * 100).toString();
    }
    if (this.el["current-time"]) {
      this.el["current-time"].textContent = this.formatSeconds(currentTime);
    }
  },

  onMetadataLoaded() {
    if (this.el["total-time"]) {
      this.el["total-time"].textContent = this.formatSeconds(
        this.engine.duration,
      );
    }
    this.checkCache();
  },

  formatSeconds(s) {
    if (!s || isNaN(s)) return "0:00";
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = Math.floor(s % 60);
    return h > 0
      ? `${h}:${m.toString().padStart(2, "0")}:${sec.toString().padStart(2, "0")}`
      : `${m}:${sec.toString().padStart(2, "0")}`;
  },

  showLayer(id) {
    ["loading", "error", "player-ui"].forEach((l) =>
      this.el[l]?.classList.add("hidden"),
    );
    this.el[id]?.classList.remove("hidden");
  },

  showErr(m) {
    this.showLayer("error");
    if (this.el["error-message"]) this.el["error-message"].textContent = m;
  },
};
