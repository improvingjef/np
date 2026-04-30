/**
 * Helper for the Np Playwright runner. Loads the fixture written by
 * `mix np.playwright` from the path in NP_FIXTURE_PATH.
 *
 * Usage in a Playwright test:
 *
 *   import { test, expect } from '@playwright/test';
 *   import { loadFixture, runId, scenarioId } from 'np/priv/js/np.fixture.js';
 *
 *   test(scenarioId(), async ({ page }) => {
 *     const f = loadFixture();
 *     // f.bindings.translator.display.email, etc.
 *     // f.prompt.title, f.prompt.body, f.prompt.goto
 *     await page.goto(f.prompt.goto);
 *     // ... drive the browser through the steps the prompt describes
 *   });
 */

import fs from 'node:fs';

export function loadFixture() {
  const path = process.env.NP_FIXTURE_PATH;
  if (!path) {
    throw new Error(
      'NP_FIXTURE_PATH not set. Run tests via `mix np.playwright SCENARIO_ID`.'
    );
  }
  return JSON.parse(fs.readFileSync(path, 'utf-8'));
}

export function runId() {
  return process.env.NP_RUN_ID;
}

export function scenarioId() {
  return process.env.NP_SCENARIO_ID;
}
