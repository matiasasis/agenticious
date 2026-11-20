import {cpSync, mkdirSync, rmSync, writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {actionNames, images} from './plugin/icons.js';
import {buildProfile} from './profile.js';

const plugin = path.resolve('dist/com.mati.agenticious.sdPlugin');
rmSync(plugin, {recursive: true, force: true});
mkdirSync(path.join(plugin, 'images'), {recursive: true});
cpSync('plugin', path.join(plugin, 'plugin'), {recursive: true});
cpSync('node_modules/ws', path.join(plugin, 'node_modules/ws'), {recursive: true});
writeFileSync(path.join(plugin, 'package.json'), JSON.stringify({type: 'module'}));

const stills = {home: images.home, preset: images.empty};
for (const [kind, image] of Object.entries(stills)) {
  writeFileSync(path.join(plugin, `images/${kind}.svg`), Buffer.from(image.split(',')[1], 'base64'));
}
// The launcher is the app's own icon, without the transparent margin a Dock icon carries.
for (const [name, size] of [['launcher.png', 144], ['launcher@2x.png', 288]]) {
  const icon = path.join(plugin, 'images', name);
  execFileSync('/usr/bin/sips', ['-c', '836', '836', '../Sources/Agenticious/Resources/BundleIcon.png', '--out', icon], {stdio: 'ignore'});
  execFileSync('/usr/bin/sips', ['-z', String(size), String(size), icon], {stdio: 'ignore'});
}
const tooltips = {
  launcher: 'Shows every Agenticious preset on the deck.',
  preset: 'Opens the Summon window on the preset shown. Lives on the Agenticious page.',
  home: 'Returns to the profile the deck was showing.'
};
const actions = Object.keys(actionNames).map(kind => ({UUID: `com.mati.agenticious.${kind}`,
  Name: actionNames[kind], Icon: `images/${kind}`, Tooltip: tooltips[kind],
  // Preset and Back only work on the bundled page, so only the launcher is offered for dragging onto a key.
  ...(kind === 'launcher' ? {} : {VisibleInActionsList: false}),
  Controllers: ['Keypad'], UserTitleEnabled: false, States: [{Image: `images/${kind}`, ShowTitle: false}]}));
writeFileSync(path.join(plugin, 'manifest.json'), JSON.stringify({Name: 'Agenticious',
  Author: 'Matias Asis', Description: 'Summon an Agenticious agent from any preset with one key.',
  Version: '0.1.0.0', UUID: 'com.mati.agenticious', SDKVersion: 2,
  CodePath: 'plugin/main.js', Nodejs: {Version: '20'}, Icon: 'images/launcher',
  Category: 'Agenticious', CategoryIcon: 'images/launcher',
  OS: [{Platform: 'mac', MinimumVersion: '14'}], Software: {MinimumVersion: '6.5'}, Actions: actions,
  Profiles: [{Name: 'profiles/Agenticious', DeviceType: 0, AutoInstall: false, DontAutoSwitchWhenInstalled: true, Readonly: false}]}, null, 2));
buildProfile(plugin);
console.log(`Built ${path.relative('.', plugin)}.`);
