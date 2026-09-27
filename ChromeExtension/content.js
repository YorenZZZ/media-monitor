// Reports HTML <audio>/<video> state for this frame and applies commands from Media Monitor.
// Guard against double injection (manifest injection + scripting.executeScript on install).
if (!window.__mediaMonitorBridge) {
  window.__mediaMonitorBridge = true;

  const ids = new WeakMap();
  let nextId = 1;
  let reported = false;
  let timer;

  // Site "next/previous" buttons, used because content scripts cannot trigger
  // the page's own Media Session action handlers.
  const SITE_CONTROLS = [
    {host: /(^|\.)youtube\.com$/, next: '.ytp-next-button', previous: '.ytp-prev-button'},
    {host: /(^|\.)bilibili\.com$/, next: '.bpx-player-ctrl-next', previous: '.bpx-player-ctrl-prev'},
    {host: /(^|\.)music\.163\.com$/, next: '.nxt', previous: '.prv'},
    {host: /(^|\.)y\.qq\.com$/, next: '.btn_big_next', previous: '.btn_big_prev'},
    {host: /(^|\.)open\.spotify\.com$/, next: '[data-testid="control-button-skip-forward"]', previous: '[data-testid="control-button-skip-back"]'},
    {host: /(^|\.)soundcloud\.com$/, next: '.skipControl__next', previous: '.skipControl__previous'}
  ];

  const idFor = element => {
    if (!ids.has(element)) ids.set(element, String(nextId++));
    return ids.get(element);
  };

  const siteButton = kind => {
    const site = SITE_CONTROLS.find(s => s.host.test(location.hostname));
    const button = site && document.querySelector(site[kind]);
    return button && !button.disabled && button.getAttribute('aria-disabled') !== 'true' && button.getClientRects().length > 0 ? button : null;
  };

  // Muted looping/autoplay clips are page decoration or hover previews, not something the user is listening to.
  const isDecorative = element => (element.muted && (element.loop || element.autoplay)) ||
    (element instanceof HTMLVideoElement && element.muted && element.getBoundingClientRect().width < 2);

  function snapshot() {
    const metadata = navigator.mediaSession?.metadata;
    const canNext = !!siteButton('next');
    const canPrevious = !!siteButton('previous');
    return [...document.querySelectorAll('audio, video')]
      .filter(element => !isDecorative(element))
      .map(element => ({
        elementId: idFor(element),
        title: metadata?.title || document.title || location.hostname,
        artist: metadata?.artist || '',
        subtitle: location.hostname,
        position: Number(element.currentTime) || 0,
        duration: Number.isFinite(element.duration) ? element.duration : 0,
        playing: !element.paused && !element.ended,
        seekable: Number.isFinite(element.duration) && element.duration > 0,
        canNext,
        canPrevious
      }))
      .filter(item => item.playing || item.position > 0.5);
  }

  function report() {
    const items = snapshot();
    // Stay quiet in frames that never had media, but send one empty report when media goes away.
    if (!items.length && !reported) return;
    reported = items.length > 0;
    try {
      chrome.runtime.sendMessage({type: 'snapshot', items}).catch(() => {});
    } catch (_) {
      // Extension was reloaded; this orphaned script can no longer talk to it.
      clearInterval(timer);
    }
  }

  // This runs in every frame of every page, so it only polls while the frame has media to report;
  // media events (captured on the document, as they do not bubble) wake it up again.
  function tick() {
    report();
    if (!reported && timer) { clearInterval(timer); timer = null; }
  }
  function wake() {
    report();
    if (reported && !timer) timer = setInterval(tick, 1000);
  }
  for (const type of ['play', 'playing', 'pause', 'ended', 'seeked', 'loadedmetadata', 'emptied']) {
    document.addEventListener(type, wake, true);
  }
  wake();

  chrome.runtime.onMessage.addListener(command => {
    if (command.action === 'next' || command.action === 'previous') {
      siteButton(command.action)?.click();
    } else {
      const element = [...document.querySelectorAll('audio, video')].find(e => ids.get(e) === String(command.elementId));
      if (!element) return;
      if (command.action === 'toggle') {
        if (element.paused) element.play().catch(() => {}); else element.pause();
      } else if (command.action === 'seek') {
        const value = Number(command.value);
        if (Number.isFinite(value)) element.currentTime = Math.min(Math.max(0, value), element.duration || value);
      }
    }
    setTimeout(wake, 150);
  });
}
