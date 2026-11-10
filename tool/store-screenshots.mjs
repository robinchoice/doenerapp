// Composes the Play Store screenshots: one headline above each raw screen,
// so a redesign only needs new raw pictures and this one command.
// Raw pictures (1-karte.png … 6-freunde.png) live in docs/play/raw, taken
// from a phone; the composed ones land in docs/play/de for the Play listing.
// Run: npm install --no-save --prefix tool playwright && node tool/store-screenshots.mjs
import { copyFileSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = new URL('.', import.meta.url);
const RAW = new URL('../docs/play/raw/', HERE);
const OUT = new URL('../docs/play/de/', HERE);
const FONT = new URL('../app/assets/fonts/BricolageGrotesque.ttf', HERE);

// Number prefix of the raw file → headline, German only like the app.
const HEADLINES = {
  '1-karte': 'Döner in deiner Nähe entdecken',
  '2-start': 'Einchecken und zeigen, wo du isst',
  '3-ranking': 'Die besten Läden deiner Stadt',
  '4-laden': 'Alles über einen Laden: Bewertungen, Preise, Öffnungszeiten',
  '5-bewerten': 'Bewerten: Soße, Fleisch, Salat, Brot',
  '6-freunde': 'Sehen, wo deine Freunde essen',
};

// Play Store: PNG, at least 1080 px per side, aspect ratio within 2:1.
const WIDTH = 1080;
const HEIGHT = 1920;

mkdirSync(OUT, { recursive: true });
const files = readdirSync(RAW).filter((f) => /\.png$/i.test(f));
if (!files.length) throw new Error(`no raw screens in ${fileURLToPath(RAW)}`);

const font = readFileSync(FONT).toString('base64');
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 1 });
  for (const file of files) {
    const key = basename(file, extname(file));
    const headline = HEADLINES[key];
    if (!headline) {
      console.warn(`${file}: no headline, copied unchanged`);
      copyFileSync(new URL(file, RAW), new URL(file, OUT));
      continue;
    }
    const image = readFileSync(new URL(file, RAW)).toString('base64');
    await page.setContent(
      `<!doctype html><html><head><meta charset="utf-8"><style>
        @font-face { font-family: Bricolage; src: url(data:font/ttf;base64,${font}) format('truetype'); font-weight: 200 800; }
        * { margin: 0; }
        body { width: ${WIDTH}px; height: ${HEIGHT}px; background: #0E0D12; display: flex; flex-direction: column; padding: 96px 72px 72px; box-sizing: border-box; }
        h1 { font-family: Bricolage, 'Arial Narrow', sans-serif; font-weight: 800; font-stretch: 78%; font-size: 84px; line-height: 1.04; letter-spacing: -0.01em; color: #F2F0EA; }
        img { flex: 1; min-height: 0; width: 100%; object-fit: contain; object-position: top; margin-top: 64px; border-radius: 40px; }
      </style></head><body><h1>${headline}</h1><img src="data:image/png;base64,${image}"></body></html>`,
    );
    await page.evaluate(() => document.fonts.ready);
    writeFileSync(new URL(`${key}.png`, OUT), await page.screenshot());
    console.log(`${key}.png  ${headline}`);
  }

  // Feature graphics (1024×500) with the start screen, one per language.
  const icon = readFileSync(new URL('../app/assets/icon.png', HERE)).toString('base64');
  const wordmark = readFileSync(new URL('../app/assets/pleasance-wordmark.svg', HERE)).toString('base64');
  const start = readFileSync(new URL('2-start.png', RAW)).toString('base64');
  const FEATURE = {
    de: ['Der beste Döner', 'deiner Stadt.', 'Bewertet nach Soße, Fleisch, Salat und Brot – von Leuten aus deiner Gegend.', 'ein Werkzeug von'],
    en: ['The best döner', 'in your city.', 'Rated by sauce, meat, salad and bread – by people from your area.', 'a tool by'],
  };
  const feature = await browser.newPage({ viewport: { width: 1024, height: 500 }, deviceScaleFactor: 1 });
  for (const [lang, [h1, accent, lead, by]] of Object.entries(FEATURE)) {
    await feature.setContent(
      `<!doctype html><html><head><meta charset="utf-8"><style>
        @font-face { font-family: Bricolage; src: url(data:font/ttf;base64,${font}) format('truetype'); font-weight: 200 800; }
        * { margin: 0; box-sizing: border-box; }
        body { width: 1024px; height: 500px; overflow: hidden; background: #0E0D12; color: #F2F0EA; font-family: Bricolage, sans-serif; position: relative; }
        .brand { position: absolute; left: 64px; top: 52px; display: flex; align-items: center; gap: 16px; font-weight: 800; font-stretch: 78%; font-size: 30px; }
        .brand img { width: 48px; height: 48px; border-radius: 12px; }
        h1 { position: absolute; left: 64px; top: 136px; font-weight: 800; font-stretch: 78%; font-size: 70px; line-height: 1.02; }
        h1 span { background: linear-gradient(90deg, #F5A847, #E2C55A); -webkit-background-clip: text; color: transparent; }
        .rule { position: absolute; left: 64px; top: 312px; width: 120px; height: 4px; border-radius: 2px; background: linear-gradient(90deg, #F5A847, #E2C55A); }
        p { position: absolute; left: 64px; top: 340px; width: 420px; font-family: sans-serif; font-size: 19px; line-height: 1.45; color: #B9B6AE; }
        .by { position: absolute; left: 64px; top: 440px; display: flex; align-items: center; gap: 14px; font-family: sans-serif; font-size: 13px; color: #B9B6AE; }
        .by img { height: 14px; }
        .phone { position: absolute; right: 90px; top: 34px; width: 210px; padding: 9px; background: #1d1c22; border-radius: 40px; transform: rotate(4deg); box-shadow: 0 20px 60px #000a; }
        .phone img { display: block; width: 100%; border-radius: 32px; }
      </style></head><body>
        <div class="brand"><img src="data:image/png;base64,${icon}">Lieblingsdöner</div>
        <h1>${h1}<br><span>${accent}</span></h1><div class="rule"></div><p>${lead}</p>
        <div class="by">${by}<img src="data:image/svg+xml;base64,${wordmark}"></div>
        <div class="phone"><img src="data:image/png;base64,${start}"></div>
      </body></html>`,
    );
    await feature.evaluate(() => document.fonts.ready);
    writeFileSync(new URL(`../feature-${lang}.png`, OUT), await feature.screenshot());
    console.log(`feature-${lang}.png`);
  }
} finally {
  await browser.close();
}
