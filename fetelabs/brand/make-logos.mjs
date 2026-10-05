#!/usr/bin/env node
// Draws every FeteLABS logo file the fork ships, from one place.
//
// The mark is the Fete Labs test tube exactly as fetelabs.ai draws it
// (its favicon.svg). The wordmark is "FeteLABS" in Rubik 800, outlined to
// paths so no file depends on a font being installed.
//
// Needs, in a scratch directory (not committed):
//   npm i opentype.js@1 playwright-core
//   Rubik 800 as a static TTF (Google Fonts CSS with an old user agent)
// Run:
//   FONT=/path/rubik800.ttf CHROME=/path/to/chromium \
//   NODE_PATH=/path/to/scratch/node_modules node fetelabs/brand/make-logos.mjs
import { createRequire } from 'node:module';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(join(process.env.NODE_PATH || '.', 'x.js'));
const opentype = require('opentype.js');
const { chromium } = require('playwright-core');

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const OUT = join(HERE, 'out');
mkdirSync(OUT, { recursive: true });

export const INK = '#0E0818';
export const CREAM = '#FFF6E6';
export const TEAL = '#1FB5A8';
export const LIME = '#9BE22D';
export const PINK = '#FF2E88';

const TUBE = 'M70 38V160A30 30 0 0 0 130 160V38Z';

// The tube with its liquid, no tile. Coordinates are fetelabs.ai's 200 box.
function tube(id) {
  return `<g transform="rotate(-12 100 110)">
  <path d="${TUBE}" fill="${INK}" stroke="${INK}" stroke-width="9" stroke-linejoin="round"/>
  <rect x="64" y="30" width="72" height="12" rx="6" fill="${INK}" stroke="${INK}" stroke-width="9"/>
  <defs><clipPath id="${id}"><path d="${TUBE}"/></clipPath></defs>
  <path d="${TUBE}" fill="${INK}"/>
  <g clip-path="url(#${id})">
    <path d="M44 100q14-16 28 0t28 0t28 0t28 0t28 0V210H44Z" fill="${TEAL}"/>
    <path d="M30 132q14-16 28 0t28 0t28 0t28 0t28 0V210H30Z" fill="${LIME}"/>
    <path d="M44 162q14-16 28 0t28 0t28 0t28 0t28 0V210H44Z" fill="${PINK}"/>
  </g>
  <circle cx="90" cy="74" r="5" fill="${LIME}" clip-path="url(#${id})"/>
  <rect x="64" y="30" width="72" height="12" rx="6" fill="${CREAM}"/>
  <path d="M82 56V84M82 96V102" stroke="${CREAM}" stroke-width="5" stroke-linecap="round"/>
</g>`;
}

// The app icon: the tube on the teal tile, verbatim from fetelabs.ai.
export function icon(id = 'fl') {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><title>FeteLABS</title>
<rect width="200" height="200" rx="46" fill="${TEAL}"/>
<g transform="translate(3.8 -6.76) scale(1.02)">${tube(id)}</g></svg>`;
}

// Full bleed, for iOS and Android masks (they round the corners themselves).
export function iconSquare(id = 'fls') {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><title>FeteLABS</title>
<rect width="200" height="200" fill="${TEAL}"/>
<g transform="translate(22 12) scale(0.8)">${tube(id)}</g></svg>`;
}

const font = opentype.loadSync(process.env.FONT);

function word(text, x, baseline, size, fill) {
  const p = font.getPath(text, x, baseline, size);
  const box = p.getBoundingBox();
  return { d: p.toPathData(2), fill, box, advance: font.getAdvanceWidth(text, size) };
}

// The lockup: tube, then "Fete" and "LABS". `ground` says which ground it
// sits on, which decides the colours of the two words.
export function lockup(ground, id = 'flk') {
  const size = 132;
  const baseline = 150;
  const x0 = 196;
  const fete = word('Fete', x0, baseline, size, ground === 'dark' ? CREAM : INK);
  const labs = word('LABS', x0 + fete.advance + 4, baseline, size, ground === 'dark' ? LIME : PINK);
  const right = Math.ceil(labs.box.x2) + 8;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${right} 200"><title>FeteLABS</title>
<g transform="translate(-8 -4)">${tube(id)}</g>
<path d="${fete.d}" fill="${fete.fill}"/>
<path d="${labs.d}" fill="${labs.fill}"/></svg>`;
}

async function png(browser, svg, w, h, file, { background = 'transparent', fit = 'contain' } = {}) {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  const src = `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;
  await page.setContent(`<html><body style="margin:0;background:${background}">
<img src="${src}" style="width:${w}px;height:${h}px;object-fit:${fit};display:block"></body></html>`);
  await page.locator('img').evaluate((img) => img.decode());
  await page.screenshot({ path: file, omitBackground: background === 'transparent' });
  await page.close();
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const files = {
    'icon.svg': icon(),
    'icon-square.svg': iconSquare(),
    'lockup-light-ground.svg': lockup('light'),
    'lockup-dark-ground.svg': lockup('dark'),
  };
  for (const [name, svg] of Object.entries(files)) writeFileSync(join(OUT, name), svg);

  const browser = await chromium.launch({ executablePath: process.env.CHROME });
  const W = (p) => join(ROOT, 'addons/web/static/img', p);
  const L = lockup('light');
  const D = lockup('dark');
  // Odoo's own file names, so every page that names them draws FeteLABS,
  // including the pages that run with no database (the database manager).
  await png(browser, icon(), 192, 192, W('odoo-icon-192x192.png'));
  await png(browser, icon(), 512, 512, W('odoo-icon-512x512.png'));
  await png(browser, iconSquare(), 512, 512, W('odoo-icon-ios.png'), { background: TEAL });
  await png(browser, L, 180, 79, W('logo.png'));
  await png(browser, L, 300, 131, W('logo2.png'));
  await png(browser, D, 627, 206, W('logo_inverse_white_206px.png'));
  await png(browser, L, 62, 20, W('odoo_logo_tiny.png'));
  await png(browser, L, 450, 120, join(ROOT, 'odoo/addons/base/static/img/res_company_logo.png'));
  await png(browser, icon(), 128, 128, join(ROOT, 'addons/fetelabs_branding/static/description/icon.png'));
  await png(browser, icon(), 16, 16, join(OUT, 'favicon-16.png'));
  await png(browser, icon(), 32, 32, join(OUT, 'favicon-32.png'));
  await png(browser, icon(), 48, 48, join(OUT, 'favicon-48.png'));
  writeFileSync(W('odoo-icon.svg'), icon('fli'));
  writeFileSync(W('odoo_logo.svg'), L);
  writeFileSync(W('odoo_logo_dark.svg'), D);
  await browser.close();
  console.log('drawn; build favicon.ico from out/favicon-{16,32,48}.png');
}
