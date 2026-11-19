import {WebSocket} from 'ws';
import {Agenticious, defaultPort} from './agenticious.js';
import {DeckNavigation} from './navigation.js';
import {keyAt, pages, slot} from './deck.js';
import {actionNames, images, moreImage} from './icons.js';

const args = Object.fromEntries(Array.from({length: Math.floor((process.argv.length - 2) / 2)}, (_, index) => process.argv.slice(2 + index * 2, 4 + index * 2)));
// The same variable moves the app's own port.
const app = new Agenticious(Number(process.env.AGENTICIOUS_PORT) || defaultPort);
const deck = new WebSocket(`ws://127.0.0.1:${args['-port']}`);
const keys = new Map();
const navigation = new DeckNavigation((device, payload) => send('switchToProfile', args['-pluginUUID'], payload, device));
/** null while Agenticious can't be reached. */
let presets = null;
/** Each deck turns its own pages. */
const page = new Map();
let refreshing = false;

function send(event, context, payload, device) {
  if (deck.readyState === WebSocket.OPEN) deck.send(JSON.stringify({event, context, payload, device}));
}

/** The launcher keeps the app icon the manifest gives it. */
function imageFor(key) {
  if (key.kind === 'launcher') return undefined;
  if (key.kind === 'home') return images.home;
  if (!presets) return key.index === 0 ? images.offline : images.empty;
  const turned = page.get(key.device) ?? 0;
  const shown = keyAt(key.index, presets, turned);
  return shown.preset?.image ?? (shown.more ? moreImage(turned, pages(presets.length)) : images.empty);
}

function render() {
  for (const [context, key] of keys) {
    const image = imageFor(key);
    if (key.image === image) continue;
    key.image = image;
    send('setImage', context, {image, target: 0});
    send('setTitle', context, {title: '', target: 0});
  }
}

async function refresh() {
  if (refreshing) return;
  refreshing = true;
  try { presets = await app.presets(); }
  catch { presets = null; }
  finally { refreshing = false; }
  for (const [device, turned] of page) page.set(device, Math.min(turned, pages(presets?.length ?? 0) - 1));
  render();
}

async function press(event, key) {
  if (key.kind === 'launcher') { navigation.open(event.device); void refresh(); return; }
  if (key.kind === 'home') { navigation.home(event.device); return; }
  const turned = page.get(key.device) ?? 0;
  const shown = presets ? keyAt(key.index, presets, turned) : {};
  if (shown.more) { page.set(key.device, (turned + 1) % pages(presets.length)); render(); return; }
  if (!shown.preset) { send('showAlert', event.context); void refresh(); return; }
  try {
    await app.summon(shown.preset.id);
    // The Summon window is up and takes the keyboard; the deck goes back to what it was showing.
    navigation.home(event.device);
  } catch (error) {
    console.error(error.message);
    send('showAlert', event.context);
    void refresh();
  }
}

function receive(event) {
  const kind = event.action?.split('.').at(-1);
  if (!Object.hasOwn(actionNames, kind)) return;
  if (event.event === 'willAppear') {
    keys.set(event.context, {kind, device: event.device, index: slot(event.payload?.coordinates ?? {column: 0, row: 0})});
    if (kind === 'home') { navigation.visible(event.device, true); void refresh(); }
    render();
  }
  if (event.event === 'willDisappear') {
    keys.delete(event.context);
    if (kind === 'home') { navigation.visible(event.device, false); page.delete(event.device); }
  }
  if (event.event === 'keyDown' && keys.has(event.context)) void press(event, keys.get(event.context));
}

deck.on('open', () => deck.send(JSON.stringify({event: args['-registerEvent'], uuid: args['-pluginUUID']})));
deck.on('message', bytes => {
  let event;
  try { event = JSON.parse(bytes); } catch { return; }
  receive(event);
});
deck.on('error', error => console.error(error.message));
deck.on('close', () => process.exit(0));
// Presets are edited in the app; the page follows while it is on screen.
setInterval(() => { if (navigation.showing.size) void refresh(); }, 2000);
