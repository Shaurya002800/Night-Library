/* Native on-device QR decoding. Camera frames and selected images never leave the device. */
(() => {
  const button = document.getElementById('scan-button');
  if (!button) return;
  const video = document.getElementById('scanner-video');
  const status = document.getElementById('scanner-status');
  const photo = document.getElementById('qr-photo');
  let stream = null;
  let active = false;
  let starting = false;
  let generation = 0;
  let detector;
  const stop = () => {
    generation += 1;
    active = false;
    starting = false;
    if (stream) stream.getTracks().forEach(track => track.stop());
    stream = null;
    video.srcObject = null;
    video.hidden = true;
    button.disabled = false;
    button.textContent = 'Scan QR with camera';
  };
  const decoder = async () => {
    if (detector) return detector;
    if (!('BarcodeDetector' in window)) throw new Error('decoder unavailable');
    const formats = await BarcodeDetector.getSupportedFormats();
    if (!formats.includes('qr_code')) throw new Error('QR decoder unavailable');
    detector = new BarcodeDetector({formats:['qr_code']});
    return detector;
  };
  const accept = token => {
    const value = token.trim();
    if (!/^NLP-[A-Z0-9-]{1,56}$/.test(value) || value.length > 60) {
      status.textContent = 'This QR is not a recognized library pass.';
      return false;
    }
    document.getElementById('pass_token').value = value;
    stop();
    status.textContent = 'Token captured. Review it and select Verify & record return.';
    document.getElementById('pass_token').focus();
    return true;
  };
  window.addEventListener('pagehide',stop);
  document.addEventListener('visibilitychange',() => { if (document.hidden) stop(); });
  button.addEventListener('click',async () => {
    if (active || starting) { stop(); status.textContent = 'Camera stopped.'; return; }
    const run = ++generation;
    starting = true;
    button.disabled = true;
    try {
      const reader = await decoder();
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('camera unavailable');
      const opened = await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'}},audio:false});
      if (run !== generation) { opened.getTracks().forEach(track => track.stop()); return; }
      stream = opened;
      video.srcObject = stream;
      video.hidden = false;
      await video.play();
      if (run !== generation) return;
      starting = false;
      active = true;
      button.disabled = false;
      button.textContent = 'Stop camera';
      status.textContent = 'Point the camera at a library pass.';
      const scan = async () => {
        if (!active || run !== generation) return;
        try {
          const codes = await reader.detect(video);
          if (!active || run !== generation) return;
          if (codes.length && accept(codes[0].rawValue)) return;
          window.setTimeout(scan,250);
        } catch (_) { stop(); status.textContent = 'Could not read the camera. Paste the token or use a USB scanner.'; }
      };
      scan();
    } catch (_) {
      stop();
      status.textContent = 'Camera or native QR decoding unavailable. Paste a decoded token or use a USB QR scanner.';
    }
  });
  photo.addEventListener('change',async () => {
    const file = photo.files[0];
    if (!file) return;
    stop();
    let image;
    try {
      if (!file.type.startsWith('image/') || file.size>8*1024*1024) throw new Error('invalid file');
      const reader = await decoder();
      image = await createImageBitmap(file);
      if (image.width*image.height>20000000) throw new Error('image too large');
      const codes = await reader.detect(image);
      if (!codes.length) status.textContent = 'No QR was found. Choose a clearer image or paste the token.';
      else accept(codes[0].rawValue);
    } catch (_) {
      status.textContent = 'This image could not be read. Use a browser with native QR support, a USB scanner, or paste the token. Maximum image size: 8 MB.';
    } finally {
      if (image) image.close();
      photo.value = '';
    }
  });
})();
