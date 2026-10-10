// Screenshot one asz conversation for review or a blog post.
//
//   node shoot.cjs <asz-ui-url> <conversation-id> <out-dir> [--prompt-talk N] [--idle-talk N]
//
// Writes, at a 1280 px viewport and 2x scale so UI text survives an ~800 px column:
//   list.png          the conversation list
//   conversation.png  every talk of the conversation, cropped to the transcript
//   turn.png          talk --prompt-talk (default 2) expanded: its model and tool steps
//   prompt.png        the Prompt tab of that talk's last model call, messages open
//   idle-prompt.png   with --idle-talk N: the Prompt tab of talk N's first model call
//   api/*.json        every /api response the pages loaded (token counts, ids)
//
// Needs Playwright: NODE_PATH pointing at a node_modules with `playwright`, and
// PW_EXE at a Chrome/Chromium binary if Playwright's own browser is not installed.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const [U, C, OUT, ...rest] = process.argv.slice(2);
if (!U || !C || !OUT) { console.error('usage: shoot.cjs <ui-url> <conversation-id> <out-dir> [--prompt-talk N] [--idle-talk N]'); process.exit(1); }
const opt = (name, dflt) => { const i = rest.indexOf(name); return i >= 0 ? Number(rest[i + 1]) : dflt; };
const PROMPT_TALK = opt('--prompt-talk', 2);
const IDLE_TALK = opt('--idle-talk', 0);
fs.mkdirSync(path.join(OUT, 'api'), { recursive: true });

// Grow the viewport until nothing under `sel` scrolls, so one element screenshot
// holds all of it: the panes size themselves to the window (the popped-out
// inspector is fixed at a share of it), and the scrolling element can be any
// descendant. Scroll positions are reset to the top afterwards.
async function fit(page, sel) {
  for (let i = 0; i < 8; i++) {
    const extra = await page.evaluate((s) => {
      let max = 0;
      for (const root of document.querySelectorAll(s)) {
        for (const el of [root, ...root.querySelectorAll('*')]) {
          const oy = getComputedStyle(el).overflowY;
          if (oy === 'auto' || oy === 'scroll') max = Math.max(max, el.scrollHeight - el.clientHeight);
        }
      }
      return max;
    }, sel);
    if (extra <= 2) break;
    const v = page.viewportSize();
    await page.setViewportSize({ width: v.width, height: Math.min(Math.ceil(v.height + extra * 1.3) + 24, 12000) });
    await page.waitForTimeout(400);
  }
  await page.evaluate((s) => {
    for (const root of document.querySelectorAll(s)) for (const el of [root, ...root.querySelectorAll('*')]) el.scrollTop = 0;
    window.scrollTo(0, 0);
  }, sel);
}

(async () => {
  const browser = await chromium.launch(process.env.PW_EXE ? { executablePath: process.env.PW_EXE } : {});
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2 });
  let n = 0;
  page.on('response', async (r) => {
    if (!new URL(r.url()).pathname.startsWith('/api/')) return;
    try { fs.writeFileSync(path.join(OUT, 'api', `${String(++n).padStart(2, '0')}-${new URL(r.url()).pathname.replace(/\W+/g, '_')}.json`), await r.text()); } catch {}
  });
  const open = async (url) => { await page.goto(url, { waitUntil: 'networkidle' }); await page.waitForTimeout(1200); };
  const shot = async (loc, name) => { await loc.screenshot({ path: path.join(OUT, name) }); console.log('ok', name); };

  // The Prompt tab of a model call, popped out wide, with its messages open.
  const promptOf = async (title, name) => {
    await title.click();
    await page.waitForTimeout(500);
    await page.locator('.acv-tab', { hasText: 'Prompt' }).click();
    await page.waitForTimeout(800);
    const load = page.getByText(/Load the prompt/i);
    if (await load.count()) { await load.first().click(); await page.waitForTimeout(2500); }
    await page.locator('.acv-pop-btn').first().click();   // the inspector, popped out wide
    await page.waitForTimeout(600);
    await fit(page, '.acv-inspector');
    await shot(page.locator('.acv-inspector'), name);
    await page.setViewportSize({ width: 1280, height: 900 });
  };
  // Model-call titles of talk N (1-based), after expanding it.
  const callsOf = async (talk) => {
    await page.getByText('show what the agent did').nth(talk - 1).click();
    await page.waitForTimeout(800);
    return page.locator('.acv-fold', { hasText: 'hide what the agent did' }).locator('xpath=following-sibling::*[1]').locator('.acv-title.acv-kind-model');
  };

  await open(`${U}/`);
  await page.setViewportSize({ width: 1280, height: 640 });
  await shot(page, 'list.png');
  await page.setViewportSize({ width: 1280, height: 900 });

  await open(`${U}/c/${C}`);
  await fit(page, '.acv-transcript');
  await shot(page.locator('.acv-transcript'), 'conversation.png');
  await page.setViewportSize({ width: 1280, height: 900 });

  await open(`${U}/c/${C}`);
  let calls = await callsOf(PROMPT_TALK);
  await fit(page, '.acv-transcript');
  const human = page.locator('.acv-card.acv-human').nth(PROMPT_TALK - 1);
  const reply = page.locator('.acv-card.acv-agent').nth(PROMPT_TALK - 1);
  const a = await human.boundingBox(), b = await reply.boundingBox();
  if (a && b) {
    const t = await page.locator('.acv-transcript').boundingBox();
    await page.screenshot({ path: path.join(OUT, 'turn.png'), clip: { x: t.x, y: a.y - 8, width: t.width, height: b.y + b.height - a.y + 16 } });
    console.log('ok turn.png');
  }
  await page.setViewportSize({ width: 1280, height: 900 });
  await open(`${U}/c/${C}`);
  calls = await callsOf(PROMPT_TALK);
  await promptOf(calls.last(), 'prompt.png');

  if (IDLE_TALK) {
    await open(`${U}/c/${C}`);
    calls = await callsOf(IDLE_TALK);
    await promptOf(calls.first(), 'idle-prompt.png');
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
