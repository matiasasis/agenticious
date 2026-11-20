/** The bundled page is for 15-key decks: Back at the top left, then one key per preset. */
export const columns = 5;
export const slots = 14;
/** When the presets don't all fit, the last key turns the page. */
const perPage = slots - 1;

/** Keys count across, then down, starting after Back. */
export function slot({column, row}) { return row * columns + column - 1; }

export function pages(count) { return count <= slots ? 1 : Math.ceil(count / perPage); }

/** What a key shows: a preset, the page turner, or nothing. */
export function keyAt(index, presets, page) {
  if (presets.length <= slots) return presets[index] ? {preset: presets[index]} : {};
  if (index === perPage) return {more: true};
  const preset = presets[page * perPage + index];
  return preset ? {preset} : {};
}
