// Photographs the public landing page into docs/screenshots after each deploy
// (see deploy.yml), pleasance.org shows them. The web app under /app needs a
// login and stays out, so the pictures never show user data.
// Run: npm install --no-save --prefix tool playwright && node tool/screenshots.mjs [url]
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { chromium } from 'playwright';

const BASE = process.argv[2] ?? 'https://doener-api.pleasance.org';
const OUT = new URL('../docs/screenshots/', import.meta.url);

// name → path per locale
const PAGES = { home: { de: '/', en: '/en' } };
const DEVICES = {
  desktop: { viewport: { width: 1440, height: 900 } },
  phone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
};

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();
try {
  // Playwright only writes PNG and JPEG, Chromium's canvas encodes WebP
  const converter = await browser.newPage();
  const webp = async (png) =>
    Buffer.from(
      await converter.evaluate(
        async (src) => {
          const img = new Image();
          img.src = src;
          await img.decode();
          const canvas = document.createElement('canvas');
          canvas.width = img.width;
          canvas.height = img.height;
          canvas.getContext('2d').drawImage(img, 0, 0);
          return canvas.toDataURL('image/webp', 0.85).split(',')[1];
        },
        `data:image/png;base64,${png.toString('base64')}`,
      ),
      'base64',
    );

  for (const [device, options] of Object.entries(DEVICES)) {
    for (const [name, paths] of Object.entries(PAGES)) {
      for (const [locale, path] of Object.entries(paths)) {
        const context = await browser.newContext({ ...options, locale, colorScheme: 'light' });
        const page = await context.newPage();
        await page.goto(new URL(path, BASE).href, { waitUntil: 'networkidle' });
        await page.evaluate(() => document.fonts.ready);
        const file = `${name}-${device}-${locale}.webp`;
        writeFileSync(new URL(file, OUT), await webp(await page.screenshot()));
        console.log(file);
        await context.close();
      }
    }
  }
} finally {
  await browser.close();
}
