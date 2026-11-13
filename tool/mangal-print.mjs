import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync } from 'node:fs';
import { chromium } from 'playwright';

const placeId = process.argv[2];
if (process.argv.length > 3 || (placeId !== undefined && !/^[A-Za-z0-9_-]{1,300}$/.test(placeId))) {
  throw new Error('Usage: node tool/mangal-print.mjs [placeId]');
}
const root = new URL('../', import.meta.url);
const out = new URL('docs/mangal/', root);
const target = `https://doener-api.pleasance.org/${placeId ? `b/${placeId}` : '#test'}`;
const qr = execFileSync('dart', ['--packages=server/.dart_tool/package_config.json', 'tool/mangal_qr.dart', target], { cwd: root, encoding: 'utf8' });
const font = readFileSync(new URL('app/assets/fonts/BricolageGrotesque.ttf', root)).toString('base64');
const icon = readFileSync(new URL('app/assets/icon.png', root)).toString('base64');
const copy = {
  de: {
    flyer: 'Wartest eh?', poster: 'Wie war dein<br>Mangal-Döner?',
    intro: 'Dein erster Mangal-Döner.<br>Deine ehrliche Meinung.',
    detail: 'Soße, Fleisch, Salat und Brot benoten.<br>Für das Döner-Ranking von Freiburg.',
    cta: placeId ? 'Erst essen. Dann bewerten.' : 'Scannen &amp; mittesten',
    access: placeId ? 'Kostenlos im Browser. Ohne App-Download.<br>Mit E-Mail anmelden und loslegen.' : 'Die Registrierung ist noch geschlossen.<br>Jetzt als Tester bewerben.',
    footer: 'Eine unabhängige Aktion von Lieblingsdöner.',
  },
  en: {
    flyer: 'Still waiting?', poster: 'How was your<br>Mangal döner?',
    intro: 'Your first Mangal döner.<br>Your honest opinion.',
    detail: 'Rate the sauce, meat, salad and bread.<br>Help build Freiburg’s döner ranking.',
    cta: placeId ? 'Eat first. Then rate it.' : 'Scan &amp; join the test',
    access: placeId ? 'Free in your browser. No app download.<br>Sign in by email to get started.' : 'Registration is still closed.<br>Apply to become a tester.',
    footer: 'An independent initiative by Lieblingsdöner.',
  },
};

mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
try {
  for (const [lang, c] of Object.entries(copy)) {
    for (const format of ['flyer', 'poster']) {
      const poster = format === 'poster';
      const page = await browser.newPage();
      await page.setContent(`<!doctype html><html lang="${lang}"><meta charset="utf-8">
        <title>Lieblingsdöner · Mangal Freiburg · ${format} · ${lang}</title>
        <style>
          @font-face { font-family: Bricolage; src: url(data:font/ttf;base64,${font}); font-weight: 200 800; font-stretch: 75% 100%; }
          @page { size: ${poster ? '210mm 297mm' : '105mm 148mm'}; margin: 0; }
          * { box-sizing: border-box; margin: 0; }
          body { width: ${poster ? 210 : 105}mm; height: ${poster ? 297 : 148}mm; padding: ${poster ? 10 : 5}mm; background: white; print-color-adjust: exact; -webkit-print-color-adjust: exact; }
          main { height: 100%; padding: ${poster ? 15 : 7}mm; background: #0E0D12; color: #F2F0EA; font-family: Bricolage, sans-serif; display: flex; flex-direction: column; }
          .brand { display: flex; align-items: center; gap: ${poster ? 4 : 2}mm; font-weight: 790; font-stretch: 78%; font-size: ${poster ? 9 : 4.8}mm; }
          .brand img { width: ${poster ? 16 : 8}mm; height: ${poster ? 16 : 8}mm; border-radius: ${poster ? 4 : 2}mm; }
          .location { margin-top: ${poster ? 12 : 7}mm; font-size: ${poster ? 4.2 : 2.7}mm; color: #D6D3DD; line-height: 1.4; }
          h1 { margin-top: ${poster ? 7 : 4}mm; font-weight: 800; font-stretch: 78%; letter-spacing: -.025em; line-height: 1.03; font-size: ${poster ? 18 : 12.5}mm; color: #F3BA4D; }
          .intro { margin-top: ${poster ? 7 : 4}mm; font-size: ${poster ? 7 : 5}mm; font-weight: 750; line-height: 1.15; }
          .detail { margin-top: ${poster ? 6 : 3}mm; font-size: ${poster ? 5 : 3.25}mm; line-height: 1.35; }
          .bottom { margin-top: auto; }
          .cta { margin-bottom: ${poster ? 5 : 3}mm; font-weight: 800; font-size: ${poster ? 7 : 4.3}mm; }
          .scan { display: flex; align-items: center; gap: ${poster ? 9 : 4}mm; }
          .qr { width: ${poster ? 64 : 32}mm; height: ${poster ? 64 : 32}mm; flex: none; background: white; }
          .qr svg { display: block; width: 100%; height: 100%; }
          .access { font-size: ${poster ? 4.5 : 3}mm; line-height: 1.4; }
          .link { margin-top: ${poster ? 4 : 2}mm; font-size: ${poster ? 4 : 2.6}mm; color: #D6D3DD; }
          footer { margin-top: ${poster ? 8 : 4}mm; font-size: ${poster ? 3.2 : 2.25}mm; color: #D6D3DD; }
        </style>
        <main><div class="brand"><img src="data:image/png;base64,${icon}" alt="">Lieblingsdöner</div>
          <p class="location">MANGAL DÖNER x LP10 · FREIBURG<br>Bertoldstraße 51</p>
          <h1>${c[format]}</h1>${poster ? '' : `<p class="intro">${c.intro}</p>`}
          <p class="detail">${c.detail}</p>
          <div class="bottom"><p class="cta">${c.cta}</p><div class="scan"><div class="qr">${qr}</div><p class="access">${c.access}</p></div>
          <p class="link">doener-api.pleasance.org</p><footer>${c.footer}</footer></div>
        </main></html>`);
      await page.evaluate(() => document.fonts.ready);
      const fits = await page.evaluate(() => {
        const main = document.querySelector('main');
        return main.scrollHeight <= main.clientHeight && [...document.querySelectorAll('main *')].every(el => el.getBoundingClientRect().right <= main.getBoundingClientRect().right);
      });
      if (!fits) throw new Error(`Content overflows: ${format}-${lang}`);
      const file = new URL(`${format}-${poster ? 'a4' : 'a6'}-${lang}.pdf`, out);
      await page.pdf({ path: file.pathname, preferCSSPageSize: true, printBackground: true });
      await page.close();
      console.log(file.pathname);
    }
  }
} finally {
  await browser.close();
}
console.log(`QR target: ${target}${placeId ? '' : ' (tester application; regenerate with placeId before printing for opening day)'}`);
