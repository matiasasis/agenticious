import {mkdirSync, mkdtempSync, writeFileSync, rmSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {actionNames} from './plugin/icons.js';
import {columns, slots} from './plugin/deck.js';

/** Back, then a preset key in every other position of a 15-key deck. */
export function profileActions() {
  return Object.fromEntries(Array.from({length: slots + 1}, (_, position) => {
    const kind = position === 0 ? 'home' : 'preset';
    return [`${position % columns},${Math.floor(position / columns)}`, {
      Name: actionNames[kind], UUID: `com.mati.agenticious.${kind}`, Settings: {}, State: 0,
      States: [{ShowTitle: false, Title: ''}], LinkedTitle: true
    }];
  }));
}

export function buildProfile(plugin) {
  const temporary = mkdtempSync(path.join(tmpdir(), 'agenticious-profile-'));
  const folder = '6C0E1F0A-58B7-4B6E-9D0B-7C2D8A4E5F31.sdProfile';
  const page = '3f7a2c1e-9b4d-4e8a-a6c5-1d2e3f4a5b6c';
  try {
    const root = path.join(temporary, folder);
    mkdirSync(path.join(root, 'Profiles', page.toUpperCase()), {recursive: true});
    writeFileSync(path.join(root, 'manifest.json'), JSON.stringify({Device: {Model: '20GAA9902', UUID: ''},
      Name: 'Agenticious', InstalledByPluginUUID: 'com.mati.agenticious', PreconfiguredName: 'profiles/Agenticious',
      Pages: {Current: page, Default: page, Pages: [page]}, Version: '3.0'}));
    writeFileSync(path.join(root, 'Profiles', page.toUpperCase(), 'manifest.json'), JSON.stringify({
      Controllers: [{Actions: profileActions(), Type: 'Keypad'}], Icon: '', Name: ''
    }));
    mkdirSync(path.join(plugin, 'profiles'), {recursive: true});
    rmSync(path.join(plugin, 'profiles/Agenticious.streamDeckProfile'), {force: true});
    execFileSync('/usr/bin/zip', ['-qr', path.join(plugin, 'profiles/Agenticious.streamDeckProfile'), folder], {cwd: temporary});
  } finally { rmSync(temporary, {recursive: true, force: true}); }
}
