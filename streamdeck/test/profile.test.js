import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {buildProfile, profileActions} from '../profile.js';

test('the page is Back at the top left and a preset key everywhere else', () => {
  const actions = profileActions();
  assert.equal(Object.keys(actions).length, 15);
  assert.equal(actions['0,0'].UUID, 'com.mati.agenticious.home');
  for (const [position, action] of Object.entries(actions)) {
    if (position !== '0,0') assert.equal(action.UUID, 'com.mati.agenticious.preset', position);
  }
  assert.ok(actions['4,2']);
});

test('profile archive uses version 3 UUID page directories', t => {
  const directory = mkdtempSync(path.join(tmpdir(), 'agenticious-profile-test-'));
  t.after(() => rmSync(directory, {recursive: true, force: true}));
  buildProfile(directory);
  const archive = path.join(directory, 'profiles/Agenticious.streamDeckProfile');
  const entries = execFileSync('/usr/bin/unzip', ['-Z1', archive], {encoding: 'utf8'}).split('\n');
  const root = entries.find(name => /^[^/]+\/manifest.json$/.test(name));
  const read = name => JSON.parse(execFileSync('/usr/bin/unzip', ['-p', archive, name], {encoding: 'utf8'}));
  const manifest = read(root);
  assert.equal(manifest.Version, '3.0');
  assert.equal(manifest.PreconfiguredName, 'profiles/Agenticious');
  assert.equal(manifest.Device.UUID, '');
  const page = read(root.replace('manifest.json', `Profiles/${manifest.Pages.Current.toUpperCase()}/manifest.json`));
  assert.equal(Object.keys(page.Controllers[0].Actions).length, 15);
});
