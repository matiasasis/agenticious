import test from 'node:test';
import assert from 'node:assert/strict';
import {DeckNavigation, profile} from '../plugin/navigation.js';

function fixture() {
  const calls = [];
  const navigation = new DeckNavigation((device, payload) => {
    calls.push({device, payload});
    navigation.visible(device, !!payload.profile);
  });
  return {navigation, calls};
}

test('the launcher opens the page once and Back returns to the previous profile', () => {
  const {navigation, calls} = fixture();
  navigation.open('deck');
  navigation.open('deck');
  assert.deepEqual(calls, [{device: 'deck', payload: {profile}}]);
  navigation.home('deck');
  assert.deepEqual(calls[1], {device: 'deck', payload: {}});
});

test('Back does nothing away from the page, where it would leave the profile in use', () => {
  const {navigation, calls} = fixture();
  navigation.home('deck');
  navigation.open(undefined);
  assert.equal(calls.length, 0);
  // Reached by hand in the Stream Deck app rather than through the launcher.
  navigation.visible('deck', true);
  navigation.open('deck');
  assert.equal(calls.length, 0);
  navigation.home('deck');
  navigation.home('deck');
  assert.equal(calls.length, 1);
});

test('a deck with no profile to go back to stays on the page, and Back keeps working', t => {
  t.mock.timers.enable({apis: ['setTimeout']});
  const calls = [];
  // Stream Deck ignores the switch: no key disappears, so nothing tells the plugin the page has gone.
  const navigation = new DeckNavigation((device, payload) => calls.push({device, payload}));
  navigation.visible('deck', true);
  navigation.home('deck');
  navigation.home('deck');
  assert.equal(calls.length, 1, 'a second press right away is the same request');
  assert.ok(navigation.showing.has('deck'), 'still on the page, so it keeps following the app');
  t.mock.timers.tick(1000);
  navigation.home('deck');
  assert.equal(calls.length, 2);
});

test('each deck is tracked on its own', () => {
  const {navigation, calls} = fixture();
  navigation.open('one');
  navigation.home('two');
  assert.equal(calls.length, 1);
  navigation.open('two');
  navigation.home('one');
  assert.deepEqual(calls.map(call => call.device), ['one', 'two', 'one']);
});
