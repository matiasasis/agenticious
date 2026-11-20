import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import {WebSocketServer} from 'ws';
import {images} from '../plugin/icons.js';
import {profile} from '../plugin/navigation.js';

const main = fileURLToPath(new URL('../plugin/main.js', import.meta.url));
const presets = [{id: 'custom', name: 'Custom task', image: 'data:custom'}, {id: 'review PR', name: 'Review PR', image: 'data:review'}];

/** A stand-in Stream Deck and a stand-in Agenticious, with the real plugin process between them. */
async function fixture(t, {running = true} = {}) {
  const requests = [];
  const app = createServer((request, response) => {
    requests.push(`${request.method} ${request.url}`);
    if (!running) { response.writeHead(204).end(); return; }
    response.writeHead(200, {'Content-Type': 'application/json'});
    response.end(JSON.stringify(request.url === '/presets' ? {presets} : {ok: true}));
  });
  await once(app.listen(0, '127.0.0.1'), 'listening');
  const deck = new WebSocketServer({port: 0, host: '127.0.0.1'});
  await once(deck, 'listening');
  const plugin = spawn(process.execPath, [main, '-port', deck.address().port, '-pluginUUID', 'plugin-uuid', '-registerEvent', 'registerPlugin', '-info', '{}'],
    {env: {...process.env, AGENTICIOUS_PORT: app.address().port}, stdio: 'ignore'});
  t.after(() => { plugin.kill(); deck.close(); app.close(); });
  const [socket] = await once(deck, 'connection');
  const sent = [];
  const waiting = [];
  socket.on('message', bytes => {
    sent.push(JSON.parse(bytes));
    for (const check of waiting.splice(0)) check();
  });
  /** Resolves with the first message the plugin sends that matches. */
  const expect = matches => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`plugin never sent it; got ${JSON.stringify(sent.map(message => [message.event, message.context]))}`)), 4000);
    const check = () => {
      const found = sent.find(matches);
      if (found) { clearTimeout(timer); resolve(found); } else waiting.push(check);
    };
    check();
  });
  const deckSays = (event, kind, context, coordinates) => socket.send(JSON.stringify({
    event, action: `com.mati.agenticious.${kind}`, context, device: 'deck', payload: {coordinates}
  }));
  return {requests, sent, expect, deckSays};
}

test('one key opens the page, the page shows every preset, and a preset key summons it and goes back', async t => {
  const {requests, sent, expect, deckSays} = await fixture(t);
  assert.deepEqual(await expect(message => message.event === 'registerPlugin'), {event: 'registerPlugin', uuid: 'plugin-uuid'});

  deckSays('willAppear', 'launcher', 'launcher-key', {column: 1, row: 2});
  deckSays('keyDown', 'launcher', 'launcher-key', {column: 1, row: 2});
  assert.deepEqual(await expect(message => message.event === 'switchToProfile'), {event: 'switchToProfile', context: 'plugin-uuid', device: 'deck', payload: {profile}});

  // The deck is now on the page: Back, then a key for each position.
  deckSays('willAppear', 'home', 'back', {column: 0, row: 0});
  deckSays('willAppear', 'preset', 'first', {column: 1, row: 0});
  deckSays('willAppear', 'preset', 'second', {column: 2, row: 0});
  deckSays('willAppear', 'preset', 'third', {column: 3, row: 0});
  await expect(message => message.event === 'setImage' && message.context === 'back' && message.payload.image === images.home);
  await expect(message => message.event === 'setImage' && message.context === 'first' && message.payload.image === 'data:custom');
  await expect(message => message.event === 'setImage' && message.context === 'second' && message.payload.image === 'data:review');
  await expect(message => message.event === 'setImage' && message.context === 'third' && message.payload.image === images.empty);

  deckSays('keyDown', 'preset', 'second', {column: 2, row: 0});
  assert.deepEqual((await expect(message => message.event === 'switchToProfile' && !message.payload.profile)).payload, {});
  assert.ok(requests.includes('POST /summon/review%20PR'), requests.join(', '));
  // The launcher keeps the app icon from the manifest.
  assert.ok(!sent.some(message => message.event === 'setImage' && message.context === 'launcher-key'));
});

test('without the app the page says so and a key press only alerts', async t => {
  const {requests, sent, expect, deckSays} = await fixture(t, {running: false});
  deckSays('willAppear', 'home', 'back', {column: 0, row: 0});
  deckSays('willAppear', 'preset', 'first', {column: 1, row: 0});
  deckSays('willAppear', 'preset', 'second', {column: 2, row: 0});
  await expect(message => message.event === 'setImage' && message.context === 'first' && message.payload.image === images.offline);
  await expect(message => message.event === 'setImage' && message.context === 'second' && message.payload.image === images.empty);
  deckSays('keyDown', 'preset', 'first', {column: 1, row: 0});
  await expect(message => message.event === 'showAlert' && message.context === 'first');
  assert.ok(!requests.some(request => request.startsWith('POST')));
  assert.ok(!sent.some(message => message.event === 'switchToProfile'));
});
