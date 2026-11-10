// App Store screenshots: photographs the design studio's demo app (`?bare`,
// made-up data) at iPhone 6.9" and iPad 13" size, puts a headline above each
// screen and writes docs/store/ios/de-DE/{iphone,ipad}/. `server/tool/app_store.dart
// screenshots` uploads them. The map stays out: the studio has no Google key.
// Clicks are coordinates in the layout, check the pictures after UI changes.
//
//   (cd app && flutter build web -t lib/design_main.dart -o build/design)
//   npm install --no-save --prefix tool playwright && node tool/app-store-screenshots.mjs
//
// CanvasKit loads from gstatic.com, so this needs the network.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = new URL('.', import.meta.url);
const BUILD = fileURLToPath(new URL('../app/build/design/', HERE));
const OUT = new URL('../docs/store/ios/de-DE/', HERE);
const FONT = new URL('../app/assets/fonts/BricolageGrotesque.ttf', HERE);
const PORT = 8097;

// Viewport in points, scale to the pixel size Apple asks for.
const DEVICES = {
  iphone: { width: 440, height: 956, scale: 3, tab: { start: [44, 880], ranking: [132, 880], profil: [396, 880] }, shop: [118, 458], rate: [165, 724] },
  ipad: { width: 1032, height: 1376, scale: 2, tab: { start: [48, 160], ranking: [48, 220], profil: [48, 420] }, shop: [324, 434], rate: [460, 831] },
};

const SCREENS = [
  ['1-start', 'Die Top 3 in deiner Nähe', (d) => [d.tab.start]],
  ['2-ranking', 'Die besten Läden deiner Stadt', (d) => [d.tab.ranking]],
  ['3-laden', 'Alles über einen Laden: Bewertungen, Preise, Öffnungszeiten', (d) => [d.tab.ranking, d.shop]],
  ['4-bewerten', 'Bewerten: Soße, Fleisch, Salat, Brot', (d) => [d.tab.ranking, d.shop, d.rate]],
  ['5-profil', 'Deine Läden, Check-ins und Freunde', (d) => [d.tab.profil]],
];

const TYPES = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.json': 'application/json', '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.otf': 'font/otf', '.png': 'image/png' };
const server = createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  const file = path.endsWith('/') ? `${path}index.html` : path;
  try {
    const body = await readFile(join(BUILD, file));
    res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end();
  }
}).listen(PORT);

const font = readFileSync(FONT).toString('base64');
const browser = await chromium.launch();
try {
  for (const [name, device] of Object.entries(DEVICES)) {
    const dir = new URL(`${name}/`, OUT);
    mkdirSync(dir, { recursive: true });
    const width = device.width * device.scale;
    const height = device.height * device.scale;
    for (const [key, headline, clicks] of SCREENS) {
      const app = await browser.newPage({ viewport: { width: device.width, height: device.height }, deviceScaleFactor: device.scale });
      await app.goto(`http://localhost:${PORT}/?bare`);
      await app.waitForTimeout(12000);
      for (const [x, y] of clicks(device)) {
        await app.mouse.click(x, y);
        await app.waitForTimeout(2000);
      }
      const raw = (await app.screenshot()).toString('base64');
      await app.close();

      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
      const pad = Math.round(width * 0.067);
      await page.setContent(
        `<!doctype html><html><head><meta charset="utf-8"><style>
          @font-face { font-family: Bricolage; src: url(data:font/ttf;base64,${font}) format('truetype'); font-weight: 200 800; }
          * { margin: 0; }
          body { width: ${width}px; height: ${height}px; background: #0E0D12; display: flex; flex-direction: column; align-items: center; padding: ${pad * 1.3}px ${pad}px ${pad}px; box-sizing: border-box; }
          h1 { align-self: stretch; font-family: Bricolage, 'Arial Narrow', sans-serif; font-weight: 800; font-stretch: 78%; font-size: ${Math.round(width * 0.078)}px; line-height: 1.04; letter-spacing: -0.01em; color: #F2F0EA; }
          img { flex: 1; min-height: 0; max-width: 100%; object-fit: contain; object-position: top; margin-top: ${pad * 0.8}px; border-radius: ${Math.round(width * 0.037)}px; }
        </style></head><body><h1>${headline}</h1><img src="data:image/png;base64,${raw}"></body></html>`,
      );
      await page.evaluate(() => document.fonts.ready);
      writeFileSync(new URL(`${key}.png`, dir), await page.screenshot());
      await page.close();
      console.log(`${name}/${key}.png  ${headline}`);
    }
  }
} finally {
  await browser.close();
  server.close();
}
