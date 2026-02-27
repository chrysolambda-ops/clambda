#!/usr/bin/env node
/**
 * playwright-bridge.js — Playwright subprocess bridge for Clawmacs
 *
 * Protocol: JSON-over-stdin/stdout, one object per line.
 *
 * Request:  { "id": "1", "command": "navigate", "params": { "url": "https://..." } }
 * Response: { "id": "1", "ok": true, "result": <value> }
 *           { "id": "1", "ok": false, "error": "message" }
 *
 * Commands:
 *   launch    { headless: bool }            → null
 *   navigate  { url: string }               → null
 *   snapshot  {}                            → accessibility tree string
 *   screenshot { path: string? }            → saved path or base64 string
 *   click     { selector: string }          → null
 *   type      { selector: string, text: string } → null
 *   evaluate  { js: string }                → serialized JS result
 *   close     {}                            → null
 *
 * Prerequisites:
 *   npm install          (in browser/ directory)
 *   npx playwright install chromium
 */

'use strict';

const { chromium } = require('playwright');
const readline = require('readline');
const fs = require('fs');

let browser = null;
let page = null;

// ─── reply helpers ─────────────────────────────────────────────────────────────

function reply(id, result) {
  process.stdout.write(JSON.stringify({ id, ok: true, result: result ?? null }) + '\n');
}

function replyError(id, error) {
  const msg = (error instanceof Error) ? error.message : String(error);
  process.stdout.write(JSON.stringify({ id, ok: false, error: msg }) + '\n');
}

// ─── command handlers ──────────────────────────────────────────────────────────

async function cmdLaunch(id, params) {
  if (browser) {
    return reply(id, null); // already launched
  }
  const headless = params && params.headless !== false; // default true
  browser = await chromium.launch({ headless });
  const context = await browser.newContext();
  page = await context.newPage();
  reply(id, null);
}

async function cmdNavigate(id, params) {
  if (!page) throw new Error('Browser not launched. Call launch first.');
  const url = params && params.url;
  if (!url) throw new Error('navigate requires params.url');
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  reply(id, null);
}

async function cmdSnapshot(id, _params) {
  if (!page) throw new Error('Browser not launched. Call launch first.');
  // Use ariaSnapshot (Playwright >= 1.47) or fall back to page title + URL
  try {
    // page.locator('body').ariaSnapshot() returns an ARIA YAML string
    const tree = await page.locator('body').ariaSnapshot();
    reply(id, tree);
  } catch (e) {
    // Fallback: return URL + title + visible text for older Playwright
    const url = page.url();
    const title = await page.title();
    const text = await page.evaluate(() => document.body ? document.body.innerText : '');
    reply(id, `URL: ${url}\nTitle: ${title}\n\n${text}`);
  }
}

async function cmdScreenshot(id, params) {
  if (!page) throw new Error('Browser not launched. Call launch first.');
  const path = params && params.path;
  if (path) {
    await page.screenshot({ path, fullPage: false });
    reply(id, path);
  } else {
    // Return base64 PNG
    const buffer = await page.screenshot({ fullPage: false });
    reply(id, buffer.toString('base64'));
  }
}

async function cmdClick(id, params) {
  if (!page) throw new Error('Browser not launched. Call launch first.');
  const selector = params && params.selector;
  if (!selector) throw new Error('click requires params.selector');
  await page.click(selector, { timeout: 10000 });
  reply(id, null);
}

async function cmdType(id, params) {
  if (!page) throw new Error('Browser not launched. Call launch first.');
  const selector = params && params.selector;
  const text = (params && params.text != null) ? params.text : '';
  if (!selector) throw new Error('type requires params.selector');
  await page.click(selector, { timeout: 10000 });
  await page.fill(selector, text);
  reply(id, null);
}

async function cmdEvaluate(id, params) {
  if (!page) throw new Error('Browser not launched. Call launch first.');
  const js = params && params.js;
  if (!js) throw new Error('evaluate requires params.js');
  const result = await page.evaluate(js);
  reply(id, result);
}

async function cmdClose(id, _params) {
  if (browser) {
    await browser.close();
    browser = null;
    page = null;
  }
  reply(id, null);
  // Give stdout a moment to flush, then exit
  setTimeout(() => process.exit(0), 100);
}

// ─── dispatch ──────────────────────────────────────────────────────────────────

const COMMANDS = {
  launch:     cmdLaunch,
  navigate:   cmdNavigate,
  snapshot:   cmdSnapshot,
  screenshot: cmdScreenshot,
  click:      cmdClick,
  type:       cmdType,
  evaluate:   cmdEvaluate,
  close:      cmdClose,
};

async function dispatch(line) {
  let req;
  try {
    req = JSON.parse(line.trim());
  } catch (e) {
    process.stderr.write(`[bridge] JSON parse error: ${e.message}\n`);
    return;
  }

  const { id = '?', command, params } = req;
  const handler = COMMANDS[command];
  if (!handler) {
    replyError(id, `Unknown command: ${command}`);
    return;
  }

  try {
    await handler(id, params || {});
  } catch (err) {
    replyError(id, err);
  }
}

// ─── main ──────────────────────────────────────────────────────────────────────

const rl = readline.createInterface({
  input: process.stdin,
  output: null,
  terminal: false,
});

rl.on('line', (line) => {
  if (line.trim()) dispatch(line);
});

rl.on('close', async () => {
  if (browser) {
    try { await browser.close(); } catch (_) {}
  }
  process.exit(0);
});

// Announce readiness on stderr (CL side ignores this stream)
process.stderr.write('[bridge] playwright-bridge ready\n');
