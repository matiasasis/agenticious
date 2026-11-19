import test from 'node:test';
import assert from 'node:assert/strict';
import {keyAt, pages, slot, slots} from '../plugin/deck.js';

const presets = count => Array.from({length: count}, (_, index) => ({id: `p${index}`, image: `image${index}`}));

test('keys count across then down, after Back at the top left', () => {
  assert.equal(slot({column: 1, row: 0}), 0);
  assert.equal(slot({column: 4, row: 0}), 3);
  assert.equal(slot({column: 0, row: 1}), 4);
  assert.equal(slot({column: 4, row: 2}), slots - 1);
});

test('presets that fit each get a key and the rest stay empty', () => {
  const seven = presets(7);
  assert.equal(pages(7), 1);
  assert.deepEqual(keyAt(0, seven, 0), {preset: seven[0]});
  assert.deepEqual(keyAt(6, seven, 0), {preset: seven[6]});
  assert.deepEqual(keyAt(7, seven, 0), {});
  const full = presets(slots);
  assert.equal(pages(slots), 1);
  assert.deepEqual(keyAt(slots - 1, full, 0), {preset: full[slots - 1]});
});

test('more presets than keys turn the last key into a page turner that reaches every preset', () => {
  const many = presets(15);
  assert.equal(pages(15), 2);
  assert.deepEqual(keyAt(slots - 1, many, 0), {more: true});
  assert.deepEqual(keyAt(12, many, 0), {preset: many[12]});
  assert.deepEqual(keyAt(0, many, 1), {preset: many[13]});
  assert.deepEqual(keyAt(1, many, 1), {preset: many[14]});
  assert.deepEqual(keyAt(2, many, 1), {});
  assert.deepEqual(keyAt(slots - 1, many, 1), {more: true});
  const seen = new Set();
  for (let page = 0; page < pages(40); page++) {
    for (let index = 0; index < slots; index++) {
      const id = keyAt(index, presets(40), page).preset?.id;
      if (id) { assert.ok(!seen.has(id)); seen.add(id); }
    }
  }
  assert.equal(seen.size, 40);
});
