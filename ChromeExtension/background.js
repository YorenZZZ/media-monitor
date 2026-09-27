// Relays media snapshots from content scripts to the Media Monitor native host,
// and commands from the host back to the right tab/frame.
const HOST = 'io.github.yorenzzz.media_monitor';
const STALE_MS = 3500;
const frames = new Map(); // "tabId:frameId" -> {tabId, frameId, items, seen}
let port = null;
let lastNonce = null;
let sending = false;
let sendAgain = false;

let retryMs = 2000;

function connect() {
  try {
    const p = chrome.runtime.connectNative(HOST);
    const connectedAt = Date.now();
    port = p;
    p.onMessage.addListener(dispatch);
    p.onDisconnect.addListener(() => {
      // Reading lastError marks it handled; otherwise Chrome logs "Unchecked runtime.lastError".
      const error = chrome.runtime.lastError?.message;
      if (error) console.warn(`Media Monitor native host (${HOST}): ${error}. Open Media Monitor once so it can register itself with Chrome.`);
      if (port === p) port = null;
      // Back off only while the host keeps failing to start; a long-lived connection resets it.
      retryMs = Date.now() - connectedAt > 10000 ? 2000 : Math.min(retryMs * 2, 30000);
      setTimeout(connect, retryMs);
    });
    send();
  } catch (error) {
    console.warn('Media Monitor native host:', error);
    port = null;
    setTimeout(connect, retryMs);
    retryMs = Math.min(retryMs * 2, 30000);
  }
}

async function collect() {
  const now = Date.now();
  const items = [];
  const titles = new Map();
  for (const [key, entry] of frames) {
    if (now - entry.seen > STALE_MS) { frames.delete(key); continue; }
    if (!titles.has(entry.tabId)) {
      try { titles.set(entry.tabId, (await chrome.tabs.get(entry.tabId)).title || ''); } catch (_) { frames.delete(key); continue; }
    }
    const tabTitle = titles.get(entry.tabId);
    for (const item of entry.items) {
      items.push({
        id: `${entry.tabId}:${entry.frameId}:${item.elementId}`,
        app: 'Google Chrome',
        // Media in iframes (embedded players) is better described by the tab title.
        title: entry.frameId === 0 ? item.title : (tabTitle || item.title),
        subtitle: item.artist ? `${item.artist} · ${item.subtitle}` : item.subtitle,
        position: item.position,
        duration: item.duration,
        playing: item.playing,
        seekable: item.seekable,
        canNext: !!item.canNext,
        canPrevious: !!item.canPrevious
      });
    }
  }
  return items;
}

// Coalesce bursts of snapshot messages into one post at a time.
async function send() {
  if (!port) return;
  if (sending) { sendAgain = true; return; }
  sending = true;
  try {
    do {
      sendAgain = false;
      const items = await collect();
      try { port?.postMessage({items}); } catch (_) { port = null; }
    } while (sendAgain && port);
  } finally {
    sending = false;
  }
}

function dispatch(command) {
  if (!command || typeof command.id !== 'string' || !command.action || command.nonce === lastNonce) return;
  lastNonce = command.nonce;
  const [tab, frame, ...rest] = command.id.split(':');
  const tabId = Number(tab), frameId = Number(frame), elementId = rest.join(':');
  if (!Number.isInteger(tabId) || !Number.isInteger(frameId)) return;
  if (command.action === 'focus') {
    chrome.tabs.update(tabId, {active: true})
      .then(t => chrome.windows.update(t.windowId, {focused: true}))
      .catch(() => {});
    return;
  }
  chrome.tabs.sendMessage(tabId, {action: command.action, value: command.value, elementId}, {frameId}).catch(() => {});
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== 'snapshot' || !sender.tab || !Array.isArray(message.items)) return;
  const key = `${sender.tab.id}:${sender.frameId}`;
  if (message.items.length) frames.set(key, {tabId: sender.tab.id, frameId: sender.frameId, items: message.items, seen: Date.now()});
  else frames.delete(key);
  send();
});

chrome.tabs.onRemoved.addListener(tabId => {
  for (const [key, entry] of frames) if (entry.tabId === tabId) frames.delete(key);
  send();
});

// Tabs opened before install/reload have no content script; inject so they work without a refresh.
chrome.runtime.onInstalled.addListener(async () => {
  const tabs = await chrome.tabs.query({url: chrome.runtime.getManifest().host_permissions});
  for (const tab of tabs) {
    chrome.scripting.executeScript({target: {tabId: tab.id, allFrames: true}, files: ['content.js']}).catch(() => {});
  }
});

// Heartbeat keeps the snapshot file fresh (the app ignores it after 5s) and prunes dead frames.
setInterval(send, 1000);
connect();
