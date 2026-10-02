// Runs only against the invented fixture host in companion_preview.py.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  const browser = await chromium.launch({headless: true,
    ...(process.env.TRANSCRIPTED_TEST_BROWSER ? {executablePath: process.env.TRANSCRIPTED_TEST_BROWSER} : {})});
  const page = await browser.newPage({viewport: {width: 1200, height: 1050}});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const output = path.resolve(__dirname, '../../.agent-review/visuals');
  fs.mkdirSync(output, {recursive: true});
  let checks = 0;
  const check = (condition, message) => {assert(condition, message); checks++;};
  let frame;
  const textIs = async (id, value) => frame.waitForFunction(({id,value}) => document.getElementById(id)?.textContent.includes(value), {id,value});
  const hostClear = async () => page.waitForFunction(() => document.getElementById('host-context').textContent.startsWith('No context attached.'));
  const settled = async () => frame.waitForFunction(() => !document.getElementById('refresh').disabled);
  const screenshot = name => page.screenshot({path: path.join(output, name), fullPage: true});
  try {
    const url = process.env.TRANSCRIPTED_PREVIEW_URL || 'http://127.0.0.1:8773';
    await page.request.post(url + '/native-availability', {data: {available: true}});
    const status = await (await page.request.post(url + '/tool', {data: {name: 'get_recording_status', arguments: {}}})).json();
    if (status.structuredContent?.capture_active) {
      await page.request.post(url + '/tool', {data: {name: 'stop_meeting', arguments: {session_id: status.structuredContent.session_id}}});
    }
    await page.goto(url);
    check((await page.locator('header strong').innerText()).includes('invented samples only'), 'fixture provenance visible');
    frame = page.frames().find(f => f.url().includes('/app.html'));
    await textIs('connection-label', 'Connected');
    check(await frame.locator('#start').isEnabled(), 'native control available');
    check(!(await frame.locator('#share').isChecked()), 'new call sharing off');
    await screenshot('companion-ready-light.png');

    await frame.locator('#tab-context').click();
    await frame.locator('.context-item').first().click();
    await frame.locator('#next').waitFor({state: 'visible'});
    await frame.locator('#next').click();
    await textIs('passage-text', 'three volunteers');
    check((await page.locator('#host-context').innerText()).startsWith('No context attached'), 'browsing does not attach');
    await frame.locator('#attach').click();
    await page.waitForFunction(() => document.getElementById('host-context').textContent.includes('selected_passage'));
    check((await page.locator('#host-context').innerText()).includes('three volunteers'), 'selected source attached');
    check(!(await page.locator('#host-context').innerText()).includes('invented meeting for the companion'), 'adjacent source not attached');
    await frame.locator('#ask').click();
    await page.waitForFunction(() => document.getElementById('host-context').textContent.includes('Question payload only'));
    check((await page.locator('#host-context').innerText()).includes('three volunteers'), 'question carries selected evidence');
    await screenshot('companion-saved-context.png');
    await frame.locator('#remove-context').click();
    await hostClear();

    await frame.locator('#tab-live').click();
    await frame.locator('#start').click();
    await textIs('recording-title', 'Recording');
    await settled();
    check(!(await frame.locator('#share').isChecked()), 'start does not enable live sharing');
    await frame.locator('#share').check();
    await page.waitForFunction(() => document.getElementById('host-context').textContent.includes('live_meeting'));
    check((await frame.locator('#live-transcript').innerText()).includes('synthetic live'), 'real MCP live fixture read rendered');
    const attachedLive = () => page.evaluate(() => JSON.parse(document.getElementById('host-context').textContent).structuredContent.live_meeting);
    let live = await attachedLive();
    check(live.partial_window === true && live.provisional === true, 'attached text declares partial provisional window');
    check(live.metadata.context_gap === true && live.metadata.dropped_windows === 2 && live.metadata.dropped_audio_buffers === 1, 'known preview gaps reach model context');
    check(live.metadata.preview_lag_seconds === 8.5 && live.metadata.pending_windows === 1, 'lag and backlog reach model context');
    check(Number.isFinite(live.metadata.snapshot_at_unix_seconds) && Number.isFinite(live.metadata.latest_text_at_unix_seconds) && live.metadata.live_status === 'listening', 'recognition freshness reaches model context');
    check(live.metadata.error_code === 'inference_failed', 'processing error reaches model context');
    await page.waitForFunction(() => JSON.parse(document.getElementById('host-context').textContent).structuredContent?.live_meeting?.attached_last_sequence === 3);
    live = await attachedLive();
    await page.waitForFunction(({snapshot}) => {
      const value = JSON.parse(document.getElementById('host-context').textContent).structuredContent?.live_meeting;
      return value?.attached_last_sequence === 3 && value.metadata.snapshot_at_unix_seconds > snapshot;
    }, {snapshot: live.metadata.snapshot_at_unix_seconds});
    live = await attachedLive();
    check(live.segments.length === 3 && live.attached_first_sequence === 1 && live.attached_last_sequence === 3, 'empty incremental read refreshes metadata without duplicating segments');
    check(live.metadata.error_code === null, 'recovery clears omitted optional processing error');
    await screenshot('companion-live-light.png');
    await page.locator('#preview-dark').check();
    await frame.waitForFunction(() => document.documentElement.dataset.theme === 'dark');
    await screenshot('companion-live-dark.png');

    await frame.locator('#share').uncheck(); await settled(); await hostClear();
    await page.locator('#preview-delay-context').check();
    await frame.locator('#share').check();
    await page.locator('#preview-release-context').waitFor({state: 'visible'});
    await page.waitForFunction(() => !document.getElementById('preview-release-context').disabled);
    await frame.locator('#share').uncheck(); await settled();
    await page.locator('#preview-release-context').click();
    await hostClear();
    check(!(await frame.locator('#share').isChecked()), 'pending context acknowledgement cannot restore sharing');
    check(!(await frame.locator('#live-transcript').innerText()).includes('synthetic live'), 'pending context cleared from view');

    await page.locator('#preview-delay-live').check();
    await frame.locator('#share').check();
    await page.waitForFunction(() => !document.getElementById('preview-release-live').disabled);
    await frame.locator('#share').uncheck(); await settled();
    await page.locator('#preview-release-live').click();
    await hostClear();
    check(!(await frame.locator('#share').isChecked()), 'delayed live reply cannot restore sharing');
    check(!(await frame.locator('#live-transcript').innerText()).includes('synthetic live'), 'delayed live reply discarded');

    await page.locator('#preview-disconnect').check();
    await frame.locator('#refresh').click();
    await textIs('connection-label', 'Disconnected');
    check(await frame.locator('#start').isDisabled(), 'disconnected controls disabled');
    await screenshot('companion-disconnected.png');
    await page.locator('#preview-disconnect').uncheck();
    await frame.locator('#refresh').click(); await textIs('connection-label', 'Connected');
    await frame.locator('#stop').click(); await textIs('recording-title', 'Ready');
    await settled();
    check(await frame.locator('#share').isDisabled(), 'finished call sharing disabled');

    await page.setViewportSize({width: 390, height: 844});
    await screenshot('companion-mobile.png');
    check(await frame.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'mobile has no horizontal overflow');
    await page.locator('#preview-limited').check();
    await page.waitForFunction(() => document.getElementById('app').src.includes('restart='));
    frame = page.frames().find(f => f.url().includes('/app.html'));
    await textIs('notice', 'host');
    check(await frame.locator('#start').isDisabled(), 'unsupported host control disabled');
    check(await frame.locator('#share').isDisabled(), 'unsupported host sharing disabled');
    check(errors.length === 0, 'no uncaught browser errors: ' + errors.join('; '));
    console.log(JSON.stringify({passed: true, checks, screenshots: output, evidence: 'Invented native fixture, real MCP binary, simulated host; no model or physical capture.'}, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => {console.error(error); process.exit(1);});
