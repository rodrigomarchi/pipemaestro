// Rasterizes apps/pipe_maestro_web/priv/static/images/favicon.svg into
// priv/static/favicon.ico (16, 32 and 48 px PNG entries) with the Chromium
// Playwright already installs. Run it through `make favicon`.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";

const SIZES = [16, 32, 48];
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../apps/pipe_maestro_web/priv/static");
const svg = readFileSync(resolve(root, "images/favicon.svg"), "utf8");

async function rasterize(): Promise<Buffer[]> {
  const browser = await chromium.launch();
  try {
    const pngs: Buffer[] = [];
    for (const size of SIZES) {
      const page = await browser.newPage({ viewport: { width: size, height: size } });
      const src = `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;
      await page.setContent(
        `<html><body style="margin:0;background:transparent">` +
          `<img src="${src}" width="${size}" height="${size}" style="display:block"></body></html>`,
      );
      await page.locator("img").evaluate((img: HTMLImageElement) => img.decode());
      pngs.push(await page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } }));
      await page.close();
    }
    return pngs;
  } finally {
    await browser.close();
  }
}

// ICONDIR, one ICONDIRENTRY per image, then the PNGs themselves.
function ico(pngs: Buffer[]): Buffer {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(pngs.length, 4);

  let offset = 6 + 16 * pngs.length;
  const entries = pngs.map((png, i) => {
    const entry = Buffer.alloc(16);
    entry.writeUInt8(SIZES[i] % 256, 0);
    entry.writeUInt8(SIZES[i] % 256, 1);
    entry.writeUInt16LE(1, 4);
    entry.writeUInt16LE(32, 6);
    entry.writeUInt32LE(png.length, 8);
    entry.writeUInt32LE(offset, 12);
    offset += png.length;
    return entry;
  });

  return Buffer.concat([header, ...entries, ...pngs]);
}

const out = resolve(root, "favicon.ico");
writeFileSync(out, ico(await rasterize()));
console.log(`favicon.ico written: ${out}`);
