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
} finally {
  await browser.close();
}
