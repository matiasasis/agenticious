import test from 'node:test';
import assert from 'node:assert/strict';
import {Agenticious, defaultPort} from '../plugin/agenticious.js';

function app(answer) {
  const requests = [];
  const client = new Agenticious(defaultPort, async (url, options) => {
    requests.push({url, method: options.method});
    return answer(url);
  });
  return {client, requests};
}
const ok = body => ({status: 200, json: async () => body});

test('presets come from the app in its order, without entries the deck could not show', async () => {
  const {client, requests} = app(() => ok({presets: [{id: 'reviewPR', name: 'Review PR', image: 'data:a'}, {id: 'broken'}, {id: 'custom', name: 'Custom task', image: 'data:b'}]}));
  assert.deepEqual((await client.presets()).map(preset => preset.id), ['reviewPR', 'custom']);
  assert.deepEqual(requests, [{url: 'http://127.0.0.1:47821/presets', method: 'GET'}]);
});

test('summoning posts the preset id, escaped', async () => {
  const {client, requests} = app(() => ok({ok: true}));
  await client.summon('DE16986F 6E91/43D9');
  assert.deepEqual(requests, [{url: 'http://127.0.0.1:47821/summon/DE16986F%206E91%2F43D9', method: 'POST'}]);
});

test('an app that is missing, older than the plugin, or without the preset is an error', async () => {
  await assert.rejects(app(() => { throw new Error('connect ECONNREFUSED'); }).client.presets());
  // An older app answers unknown paths with 204 and no body.
  await assert.rejects(app(() => ({status: 204, json: async () => { throw new Error('no body'); }})).client.presets());
  await assert.rejects(app(() => ok({})).client.presets());
  await assert.rejects(app(() => ok({ok: false})).client.summon('gone'));
});
