export const actionNames = {launcher: 'Agenticious', preset: 'Preset', home: 'Back'};

// The app's own colours (`AgenticiousStyle`), so these sit beside the preset keys it draws.
const panel = '#1a1426';
const lime = '#b8f261';
const violet = '#c27df5';

/** The card every key on the page shares: the app's panel with its violet edge, the name on top and the symbol in its tile. */
function key(glyph, label = '', {color = violet, status = ''} = {}) {
  const tile = glyph ? `<g transform="translate(0 48)"><rect x="38" y="14" width="68" height="68" rx="18" fill="${color}" fill-opacity="0.12"/>${glyph}</g>` : '';
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${panel}"/><stop offset="1" stop-color="#3f2c58"/></linearGradient></defs><rect x="2" y="2" width="140" height="140" rx="22" fill="url(#g)" stroke="${violet}" stroke-opacity="0.45" stroke-width="2"/><text x="72" y="${status ? 30 : 38}" fill="${color}" text-anchor="middle" font-family="Arial Rounded MT Bold, Arial" font-size="18" font-weight="bold">${label}</text><text x="72" y="48" fill="${color}" fill-opacity="0.8" text-anchor="middle" font-family="Arial" font-size="13">${status}</text>${tile}</svg>`;
  return `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;
}

const stroke = color => `fill="none" stroke="${color}" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"`;
const sparkles = color => `<g fill="${color}"><path d="M68 28c2.6 14 6 17.4 20 20-14 2.6-17.4 6-20 20-2.6-14-6-17.4-20-20 14-2.6 17.4-6 20-20z"/><path d="M90 24c1.2 6 2 6.800 8 8-6 1.2-6.800 2-8 8-1.2-6-2-6.800-8-8 6-1.2 6.800-2 8-8z"/></g>`;

/** Preset keys come from the app, which draws each preset's own symbol; these are the keys around them. The
 * launcher is the app's icon, a file the build puts beside the manifest. */
export const images = {
  home: key(`<path d="M92 48H54m14-14L54 48l14 14" ${stroke(violet)}/>`, 'Back'),
  empty: key(''),
  offline: key(sparkles('#9aa0ad'), 'Agenticious', {color: '#9aa0ad', status: 'not running'}),
};

export function moreImage(page, count) {
  return key(`<path d="m64 34 14 14-14 14" ${stroke(lime)}/>`, 'More', {color: lime, status: `${page + 1} of ${count}`});
}
