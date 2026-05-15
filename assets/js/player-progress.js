export const progressSync = {
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
  },

  updateLocalStorageProgress(cid, off, ts) {
    const progress = {
      cid,
      off,
      sig: this.progressSignature,
      ts: ts || new Date().toISOString(),
    };

    localStorage.setItem(this.progressKey, JSON.stringify(progress));

    return progress;
  },

  buildProgressSignature() {
    return JSON.stringify(
      this.book.chapters.map((chapter) => [
        chapter.id,
        chapter.media_asset_id,
        chapter.duration_ms,
      ]),
    );
  },

  getCurrentPositionMs() {
    return Math.floor(this.engine.currentTime * 1000);
  },

  async save(force = false) {
    if (!this.state.chapter) return;
    const off = this.getCurrentPositionMs();
    const local = this.updateLocalStorageProgress(this.state.chapter.id, off);

    if (
      !force &&
      Date.now() - this.state.lastSync < this.constructor.SYNC_INTERVAL_MS
    ) {
      return;
    }

    this.state.lastSync = Date.now();
    return this.saveLocalToServer(local, force);
  },

  async saveLocalToServer(local, force = false) {
    return this.api(
      "progress",
      { chapter_id: local.cid, offset_ms: local.off, updated_at: local.ts },
      force,
    );
  },

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
        Date.now() - this.state.lastManualSeek < this.constructor.SEEK_LOCK_MS;

      if (this.shouldSyncLocalToServer(local, remote)) {
        await this.saveLocalToServer(local);
      } else if (this.shouldSyncServerToLocal(local, remote, seekLock)) {
        this.syncPositionFromServer(remote);
      }
    } catch (e) {}

    setTimeout(
      () => this.state.isPlaying && this.sync(),
      this.constructor.SYNC_RETRY_MS,
    );
  },

  shouldSyncLocalToServer(local, remote) {
    return (
      remote.updated_at &&
      local &&
      new Date(local.ts) > new Date(remote.updated_at)
    );
  },

  shouldSyncServerToLocal(local, remote, seekLock) {
    return (
      !seekLock &&
      remote.chapter_id &&
      (!local || new Date(remote.updated_at) > new Date(local.ts))
    );
  },

  syncPositionFromServer(remote) {
    if (
      remote.chapter_id !== this.state.chapter.id ||
      Math.abs(remote.offset_ms - this.getCurrentPositionMs()) > 5000
    ) {
      this.goTo(remote.chapter_id, remote.offset_ms);
    }
  },

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
  },

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
  },
};
