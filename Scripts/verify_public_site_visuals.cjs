#!/usr/bin/env node

const fs = require("fs");
const http = require("http");
const path = require("path");
const { URL } = require("url");

let chromium;

try {
  ({ chromium } = require("playwright"));
} catch (error) {
  console.error("verify_public_site_visuals: Playwright is required.");
  console.error("Run with a Node environment that can resolve the playwright package.");
  console.error("In Codex, set NODE_PATH to the bundled node_modules path before running this script.");
  process.exit(2);
}

const args = process.argv.slice(2);

function usage() {
  console.error("Usage: node Scripts/verify_public_site_visuals.cjs [site_dir_or_url] [--widths 1024,1180,1462] [--height 900] [--screenshot-dir <dir>]");
}

function readOption(name, fallback) {
  const equalsPrefix = `${name}=`;
  const equalsValue = args.find((arg) => arg.startsWith(equalsPrefix));

  if (equalsValue) {
    return equalsValue.slice(equalsPrefix.length);
  }

  const index = args.indexOf(name);
  if (index === -1) {
    return fallback;
  }

  const value = args[index + 1];
  if (!value || value.startsWith("--")) {
    usage();
    process.exit(64);
  }

  return value;
}

const target = args.find((arg) => !arg.startsWith("--") && !args[args.indexOf(arg) - 1]?.startsWith("--")) || "site";
const widths = readOption("--widths", "1024,1180,1462")
  .split(",")
  .map((width) => Number.parseInt(width.trim(), 10))
  .filter((width) => Number.isFinite(width) && width > 0);
const height = Number.parseInt(readOption("--height", "900"), 10);
const screenshotDir = readOption("--screenshot-dir", null);

if (widths.length === 0 || !Number.isFinite(height) || height <= 0) {
  usage();
  process.exit(64);
}

function isUrl(value) {
  return /^https?:\/\//i.test(value);
}

function contentType(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  return {
    ".css": "text/css; charset=utf-8",
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".txt": "text/plain; charset=utf-8",
    ".xml": "application/xml; charset=utf-8"
  }[extension] || "application/octet-stream";
}

function startStaticServer(root) {
  const siteRoot = path.resolve(root);

  if (!fs.existsSync(siteRoot) || !fs.statSync(siteRoot).isDirectory()) {
    console.error(`verify_public_site_visuals: missing site directory: ${siteRoot}`);
    process.exit(66);
  }

  const server = http.createServer((request, response) => {
    const requestUrl = new URL(request.url, "http://127.0.0.1");
    const decodedPath = decodeURIComponent(requestUrl.pathname);
    const safePath = path.normalize(decodedPath).replace(/^(\.\.[/\\])+/, "");
    let filePath = path.join(siteRoot, safePath);

    if (!filePath.startsWith(siteRoot)) {
      response.writeHead(403);
      response.end("Forbidden");
      return;
    }

    if (fs.existsSync(filePath) && fs.statSync(filePath).isDirectory()) {
      filePath = path.join(filePath, "index.html");
    }

    fs.readFile(filePath, (error, data) => {
      if (error) {
        response.writeHead(404);
        response.end("Not found");
        return;
      }

      response.writeHead(200, { "Content-Type": contentType(filePath) });
      response.end(data);
    });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolve({
        baseUrl: `http://127.0.0.1:${port}/`,
        close: () => new Promise((closeResolve) => server.close(closeResolve))
      });
    });
  });
}

async function main() {
  const served = isUrl(target)
    ? { baseUrl: target, close: async () => {} }
    : await startStaticServer(target);

  if (screenshotDir) {
    fs.mkdirSync(screenshotDir, { recursive: true });
  }

  const browser = await chromium.launch({ headless: true });
  const failures = [];

  try {
    for (const width of widths) {
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
      await page.goto(`${served.baseUrl}${served.baseUrl.includes("?") ? "&" : "?"}visual-width=${width}`, { waitUntil: "networkidle" });

      const result = await page.evaluate(() => {
        const subhead = document.querySelector(".hero-subhead");
        const stage = document.querySelector(".hero-stage");

        if (!subhead) {
          return { ok: false, reason: "missing .hero-subhead" };
        }

        const rect = subhead.getBoundingClientRect();
        const style = window.getComputedStyle(subhead);
        const lineHeight = Number.parseFloat(style.lineHeight);
        const lineCount = lineHeight > 0 ? Math.round(rect.height / lineHeight) : null;
        const stageRect = stage ? stage.getBoundingClientRect() : null;
        const visualRight = Math.round(rect.left + subhead.scrollWidth);
        const stageClearance = stageRect ? Math.round(stageRect.left - visualRight) : null;

        return {
          ok: true,
          text: subhead.textContent.trim().replace(/\s+/g, " "),
          lineCount,
          lineHeight,
          fontSize: style.fontSize,
          whiteSpace: style.whiteSpace,
          clientWidth: subhead.clientWidth,
          scrollWidth: subhead.scrollWidth,
          overflowPx: subhead.scrollWidth - subhead.clientWidth,
          bodyWidth: document.documentElement.scrollWidth,
          viewportWidth: window.innerWidth,
          stageClearance,
          overlapsStage: Boolean(stageRect && stageRect.top < rect.bottom && visualRight > stageRect.left)
        };
      });

      if (screenshotDir) {
        await page.screenshot({
          path: path.join(screenshotDir, `quitgentle-home-hero-subhead-${width}w.png`),
          fullPage: false
        });
      }

      await page.close();

      if (!result.ok) {
        failures.push(`${width}px: ${result.reason}`);
        continue;
      }

      if (result.lineCount !== 1) {
        failures.push(`${width}px: .hero-subhead rendered ${result.lineCount} lines`);
      }

      if (result.overflowPx > 1) {
        failures.push(`${width}px: .hero-subhead overflows its box by ${result.overflowPx}px`);
      }

      if (result.bodyWidth > result.viewportWidth + 1) {
        failures.push(`${width}px: page has horizontal overflow (${result.bodyWidth}px body for ${result.viewportWidth}px viewport)`);
      }

      if (result.overlapsStage) {
        failures.push(`${width}px: .hero-subhead overlaps the hero device stage`);
      }

      console.log(
        `visual ok ${width}px: lineCount=${result.lineCount}, overflowPx=${result.overflowPx}, fontSize=${result.fontSize}, stageClearance=${result.stageClearance}`
      );
    }
  } finally {
    await browser.close();
    await served.close();
  }

  if (failures.length > 0) {
    console.error("verify_public_site_visuals: failed");
    failures.forEach((failure) => console.error(`- ${failure}`));
    console.error("If this only fails after a font or hero-width change, shorten the subhead before shrinking it below the current 1rem floor.");
    process.exit(1);
  }

  console.log("verify_public_site_visuals: ok");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
