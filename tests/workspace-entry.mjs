// Regression: a toolbar click reuses the open workspace instead of opening a
// second copy, so an ongoing draft and its `#s=<session>` route are never
// replaced. The worker is imported against a fake `chrome.tabs` /
// `chrome.windows`, so no browser, IndexedDB or network is involved.
//
// Covered:
// - no workspace yet: exactly one tab is created;
// - workspace already open (hash route, in-memory draft): only activated, and
//   focused in its own window, with no navigation/reload/URL write;
// - two clicks before the first tab exists: one attempt, one tab;
// - stale tab (closed between query and focus): a fresh tab is opened;
// - workspace in another window is reused, not duplicated;
// - the query is filtered to this extension's own page and every answer is
//   re-verified (other origin, other extension id, `workspace.html.evil`,
//   a tab navigating away, unreadable metadata);
// - a browser that rejects the filtered query opens one tab and never lists
//   the user's other tabs.

import test from 'node:test';
import assert from 'node:assert/strict';

const realSetTimeout = globalThis.setTimeout;
// automation.js schedules a poll timer on install; unref it so the test file
// does not keep Node alive after the assertions finish.
globalThis.setTimeout = (fn, ms, ...args) => {
  const timer = realSetTimeout(fn, ms, ...args);
  if (timer && typeof timer.unref === 'function') timer.unref();
  return timer;
};

const EXT_ID = 'workspace-entry-test';
const BASE = `chrome-extension://${EXT_ID}/workspace.html`;

let clickListener = null;
const chromeApi = {
  runtime: {
    id: EXT_ID,
    getURL: (path) => `chrome-extension://${EXT_ID}/${path}`,
    onMessage: { addListener() {} },
    onStartup: { addListener() {} },
    onInstalled: { addListener() {} },
  },
  tabs: {
    query: async () => [],
    get: async () => {
      throw new Error('fake tabs: no get');
    },
    create: async () => {
      throw new Error('fake tabs: create not configured');
    },
    update: async () => {},
  },
  windows: { update: async () => {} },
  alarms: { create() {}, onAlarm: { addListener() {} } },
  storage: { local: { get: async () => ({}), set: async () => {} } },
  action: {
    onClicked: {
      addListener(listener) {
        clickListener = listener;
      },
    },
  },
};
globalThis.chrome = chromeApi;

const worker = await import('../extension/background.js');

/** Fake tabs API: records calls and lets each case choose the tab universe. */
function fakeBrowser(tabs = [], options = {}) {
  const calls = { query: [], create: [], update: [], windows: [] };
  let nextId = 100;
  const universe = tabs.map((tab) => ({ ...tab }));

  const api = {
    async query(filter) {
      calls.query.push({ ...filter });
      if (options.queryThrows) throw new Error('Invalid value for argument 1');
      if (options.queryAllUnfiltered && !(filter && filter.url)) {
        // A fake that ignores the filter would expose every tab; the helper must
        // still only trust the workspace page.
        return universe.map((tab) => ({ ...tab }));
      }
      const pattern = filter && typeof filter.url === 'string' ? filter.url : null;
      if (!pattern) return [];
      const prefix = pattern.replace(/\*$/, '');
      return universe
        .filter((tab) => (tab.pendingUrl || tab.url || '').startsWith(prefix))
        .map((tab) => ({ ...tab }));
    },
    async create({ url, active }) {
      calls.create.push({ url, active });
      if (options.createFails) throw new Error('cannot create');
      const tab = { id: nextId++, windowId: 1, url, active: Boolean(active), lastAccessed: 1 };
      universe.push(tab);
      return { ...tab };
    },
    async update(id, changes) {
      calls.update.push({ id, changes: { ...changes } });
      if (options.updateFails) throw new Error(`No tab with id ${id}`);
      const tab = universe.find((entry) => entry.id === id);
      if (!tab) throw new Error(`No tab with id ${id}`);
      Object.assign(tab, changes);
      return { ...tab };
    },
  };

  const windows = {
    async update(windowId, changes) {
      calls.windows.push({ windowId, changes: { ...changes } });
    },
  };

  return { api, windows, calls, universe };
}

test('no workspace open yet: the click creates exactly one tab', async () => {
  const fake = fakeBrowser([]);
  const result = await worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });

  assert.equal(result.created, true);
  assert.deepEqual(fake.calls.create, [{ url: BASE, active: true }]);
  assert.deepEqual(fake.calls.update, [], 'a new tab is already active');
  assert.equal(fake.calls.query.length, 2, 'focused window first, then all windows');
  assert.ok(fake.calls.query.every((filter) => filter.url === `${BASE}*`));
});

test('open workspace is activated, not replaced: hash route and draft survive', async () => {
  const open = {
    id: 7,
    windowId: 3,
    url: `${BASE}#s=abc123`,
    active: false,
    lastAccessed: 500,
  };
  const fake = fakeBrowser([open]);
  const result = await worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });

  assert.equal(result.created, false);
  assert.equal(result.tabId, 7);
  assert.deepEqual(fake.calls.create, [], 'no second workspace');
  // Only `active` is written: no url, no reload, so `#s=abc123` and the page's
  // in-memory draft stay as they were.
  assert.deepEqual(fake.calls.update, [{ id: 7, changes: { active: true } }]);
  assert.deepEqual(fake.calls.windows, [{ windowId: 3, changes: { focused: true } }]);
});

test('two rapid toolbar clicks share one open', async () => {
  let releaseCreate;
  const gate = new Promise((resolve) => {
    releaseCreate = resolve;
  });
  const fake = fakeBrowser([]);
  const slowCreate = fake.api.create;
  fake.api.create = async (props) => {
    await gate;
    return slowCreate(props);
  };

  const first = worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });
  const second = worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });
  releaseCreate();
  const [a, b] = await Promise.all([first, second]);

  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(fake.calls.create, [{ url: BASE, active: true }]);
  assert.equal(a.tabId, b.tabId);
});

test('the real toolbar listener opens one workspace for a double click', async () => {
  assert.equal(typeof clickListener, 'function', 'action.onClicked is wired');
  let releaseCreate;
  const gate = new Promise((resolve) => {
    releaseCreate = resolve;
  });
  const fake = fakeBrowser([]);
  const slowCreate = fake.api.create;
  const originalQuery = chromeApi.tabs.query;
  const originalCreate = chromeApi.tabs.create;
  const originalUpdate = chromeApi.tabs.update;
  const originalWindowsUpdate = chromeApi.windows.update;
  chromeApi.tabs.query = fake.api.query;
  chromeApi.tabs.update = fake.api.update;
  chromeApi.windows.update = fake.windows.update;
  chromeApi.tabs.create = async (props) => {
    await gate;
    return slowCreate(props);
  };

  try {
    clickListener();
    clickListener();
    releaseCreate();
    for (let i = 0; i < 50 && fake.calls.create.length === 0; i += 1) {
      await new Promise((resolve) => setImmediate(resolve));
    }
    await new Promise((resolve) => setImmediate(resolve));
  } finally {
    chromeApi.tabs.query = originalQuery;
    chromeApi.tabs.create = originalCreate;
    chromeApi.tabs.update = originalUpdate;
    chromeApi.windows.update = originalWindowsUpdate;
  }

  assert.deepEqual(fake.calls.create, [{ url: BASE, active: true }]);
});

test('a stale tab that cannot be focused leads to one fresh tab', async () => {
  const fake = fakeBrowser([{ id: 5, windowId: 1, url: BASE, active: false }], {
    updateFails: true,
  });
  const result = await worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });

  assert.equal(result.created, true);
  assert.deepEqual(fake.calls.create, [{ url: BASE, active: true }]);
  assert.deepEqual(fake.calls.windows, [], 'never focus the window of a dead tab');
});

test('a workspace in another window is reused instead of duplicated', async () => {
  const fake = fakeBrowser([{ id: 11, windowId: 9, url: `${BASE}#s=xyz`, active: true }]);
  fake.api.query = async (filter) => {
    fake.calls.query.push({ ...filter });
    // Focused window has no workspace; the open one lives in window 9.
    if (filter.lastFocusedWindow) return [];
    return [{ id: 11, windowId: 9, url: `${BASE}#s=xyz`, active: true, lastAccessed: 10 }];
  };
  const result = await worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });

  assert.equal(result.created, false);
  assert.equal(result.tabId, 11);
  assert.deepEqual(fake.calls.create, []);
  assert.deepEqual(fake.calls.windows, [{ windowId: 9, changes: { focused: true } }]);
  assert.ok(fake.calls.query.every((filter) => filter.url === `${BASE}*`));
});

test('with several workspaces the active one wins, otherwise the most recent', () => {
  const older = { id: 1, url: `${BASE}#s=old`, active: false, lastAccessed: 100 };
  const newer = { id: 2, url: `${BASE}#s=new`, active: false, lastAccessed: 900 };
  const activeStale = { id: 3, url: BASE, active: true, lastAccessed: 1 };

  assert.equal(worker.pickWorkspaceTab([older, newer], BASE).id, 2);
  assert.equal(worker.pickWorkspaceTab([older, newer, activeStale], BASE).id, 3);
  assert.equal(worker.pickWorkspaceTab([], BASE), null);
});

test('only this extension\'s own workspace page is trusted', () => {
  const cases = [
    [BASE, true],
    [`${BASE}#s=abc123`, true],
    [`${BASE}?from=history#s=abc123`, true],
    ['chrome-extension://someone-else/workspace.html', false],
    [`chrome-extension://${EXT_ID}/workspace.html.evil`, false],
    [`chrome-extension://${EXT_ID}/other.html`, false],
    ['https://chatgpt.com/workspace.html', false],
    ['', false],
    [undefined, false],
  ];
  for (const [url, expected] of cases) {
    assert.equal(worker.isWorkspaceTabUrl(url, BASE), expected, String(url));
  }

  assert.equal(
    worker.isWorkspaceTabUrl(`chrome-extension://${EXT_ID}/workspace.html`, ''),
    false,
    'no base URL means no trust',
  );
});

test('a query answer containing unrelated tabs never focuses them', async () => {
  const fake = fakeBrowser([], { queryAllUnfiltered: true });
  fake.universe.push(
    { id: 21, windowId: 1, url: 'https://chatgpt.com/c/1', active: true, lastAccessed: 999 },
    { id: 22, windowId: 1, url: `chrome-extension://${EXT_ID}/workspace.html.evil`, active: false, lastAccessed: 999 },
    { id: 23, windowId: 1, url: `chrome-extension://${EXT_ID}/workspace.html`, pendingUrl: 'https://claude.ai/new', active: false, lastAccessed: 999 },
    { id: 24, windowId: 1, url: '', pendingUrl: '', active: false, lastAccessed: 999 },
  );
  const result = await worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });

  assert.equal(result.created, true);
  assert.deepEqual(fake.calls.update, []);
  assert.deepEqual(fake.calls.windows, []);
});

test('a browser without the filtered query opens one tab and lists nothing else', async () => {
  const fake = fakeBrowser([{ id: 31, windowId: 1, url: BASE, active: true }], {
    queryThrows: true,
  });
  const result = await worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });

  assert.equal(result.created, true);
  assert.ok(
    fake.calls.query.every((filter) => typeof filter.url === 'string'),
    'never queries without the workspace URL filter',
  );
});

test('a tab loading the workspace counts as the workspace', async () => {
  const fake = fakeBrowser([
    { id: 41, windowId: 2, url: 'about:blank', pendingUrl: `${BASE}#s=boot`, active: true },
  ]);
  const result = await worker.openWorkspaceTab({ tabs: fake.api, windows: fake.windows });

  assert.equal(result.created, false);
  assert.equal(result.tabId, 41);
  assert.deepEqual(fake.calls.create, []);
});
