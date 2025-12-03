const Uploaders = {};

Uploaders.S3 = function (entries, onViewError) {
  entries.forEach((entry) => {
    const xhr = new XMLHttpRequest();
    onViewError(() => xhr.abort());
    xhr.onload = () =>
      xhr.status === 200 ? entry.progress(100) : entry.error();
    xhr.onerror = () => entry.error();

    xhr.upload.addEventListener("progress", (event) => {
      if (event.lengthComputable) {
        const percent = Math.round((event.loaded / event.total) * 100);
        entry.progress(Math.min(percent, 100));
      }
    });

    const url = entry.meta.url;
    xhr.open("PUT", url, true);
    xhr.send(entry.file);
  });
};

export default Uploaders;
