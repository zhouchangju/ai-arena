// Regression: manual "打开原页" reuses the bound seat tab instead of opening a
// duplicate conversation, and never focuses/navigates a tab that was
// repurposed. The worker is imported against a fake `chrome.tabs` + binding
// store, so no browser, IndexedDB or network is involved.
//
// Covered:
// - repeated open after load, including a new-chat route on the same origin;
// - two clicks before the first tab finished loading (joined attempt);
// - user navigated the bound tab to another site (fresh tab, old one untouched);
// - two loopback seats that differ only by port;
// - two seats sharing one fixture origin, separated by ?seat;
// - tab whose metadata is unreadable or already redirecting elsewhere;
// - fresh tabs inherit the requesting window, opener and Chrome tab group;
// - valid off-window bindings move in place; failed moves preserve the binding;
// - failed creation can retry; a lost group does not create a duplicate;
// - worker restart (fresh module instance, persisted binding only).

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

function stubChrome() {
  const listeners = () => ({ addListener() {} });
  globalThis.chrome = {
    runtime: {
      id: 'tab-reuse-test',
      getURL: (path) => `chrome-extension://tab-reuse-test/${path}`,
      onMessage: listeners(),
      onStartup: listeners(),
      onInstalled: listeners(),
    },
    tabs: {
      get: async () => {
        throw new Error('fake tabs: no tab');
      },
      create: async () => {
        throw new Error('fake tabs: unused');
      },
      update: async () => {},
      onUpdated: listeners(),
      onRemoved: listeners(),
      onReplaced: listeners(),
    },
    windows: { update: async () => {} },
    alarms: { create() {}, onAlarm: listeners() },
    storage: { local: { get: async () => ({}), set: async () => {} } },
    action: {},
  };
}

stubChrome();
const worker = await import('../extension/background.js');
const restartedWorker = await import('../extension/background.js?restart=1');

const FIXTURE = 'http://127.0.0.1:8765/web-driver-fixture.html';
const ENTRY_A = `${FIXTURE}?seat=A`;
const ENTRY_B = `${FIXTURE}?seat=B`;
const ENTRY_A_OTHER_PORT = 'http://127.0.0.1:8766/web-driver-fixture.html?seat=A';
const WORKSPACE = chrome.runtime.getURL('workspace.html');

function createTabsApi() {
  const tabs = new Map();
  const updates = [];
  const creates = [];
  const groups = [];
  const moves = [];
  let nextId = 1;

  const snapshot = (tab) => ({ ...tab });

  return {
    tabs,
    updates,
    creates,
    groups,
    moves,
    api: {
      async get(id) {
        if (!tabs.has(id)) throw new Error(`No tab with id ${id}`);
        return snapshot(tabs.get(id));
      },
      async create({ url, active, windowId, openerTabId }) {
        const id = nextId++;
        const tab = {
          id,
          windowId: windowId ?? 1,
          openerTabId,
          groupId: -1,
          url: '',
          pendingUrl: url,
          status: 'loading',
          active: Boolean(active),
        };
        tabs.set(id, tab);
        creates.push({ id, url, windowId, openerTabId });
        return snapshot(tab);
      },
      async group({ tabIds, groupId }) {
        groups.push({ tabIds, groupId });
        tabs.get(tabIds).groupId = groupId;
        return groupId;
      },
      async move(id, { windowId, index }) {
        const tab = tabs.get(id);
        moves.push({ id, windowId, index });
        Object.assign(tab, { windowId, openerTabId: undefined, groupId: -1 });
        return snapshot(tab);
      },
      async update(id, changes) {
        const tab = tabs.get(id);
        if (!tab) throw new Error(`No tab with id ${id}`);
        updates.push({ id, changes: { ...changes } });
        Object.assign(tab, changes);
        return snapshot(tab);
      },
    },
    /** Simulate the page committing a URL (what Chrome would report). */
    navigate(id, url) {
      const tab = tabs.get(id);
      assert.ok(tab, `tab ${id} exists`);
      tab.url = url;
      tab.pendingUrl = '';
      tab.status = 'complete';
    },
    /** Simulate the tab being mid-redirect to `url`. */
    redirecting(id, url) {
      const tab = tabs.get(id);
      assert.ok(tab, `tab ${id} exists`);
      tab.pendingUrl = url;
    },
    blankUrl(id) {
      const tab = tabs.get(id);
      tab.url = '';
      tab.pendingUrl = '';
    },
  };
}

function createBindings() {
  const entries = new Map();
  return {
    entries,
    store: {
      async get(key) {
        return entries.get(key) || null;
      },
      async set(key, value) {
        entries.set(key, value);
      },
      async drop(key) {
        entries.delete(key);
      },
    },
  };
}

function harness() {
  const tabsWrap = createTabsApi();
  const bindings = createBindings();
  const windows = { updates: [], async update(id, info) { this.updates.push({ id, info }); } };
  const deps = { tabs: tabsWrap.api, bindings: bindings.store, windows };
  const open = (provider, url, module = worker) =>
    module.openProviderTab('session-1', provider, url, deps);
  return { ...tabsWrap, bindings, windows, deps, open };
}

function bindingTabId(bindings, provider) {
  const value = bindings.entries.get(`session-1::${provider}`);
  return value ? value.tabId : null;
}

test('repeated open focuses the same tab and allows new-chat routes', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  assert.equal(h.creates.length, 1);

  h.navigate(first, ENTRY_A);
  const newChat = `${FIXTURE}?seat=A&speed=slow`;
  h.navigate(first, newChat);

  const second = await h.open('local-a', ENTRY_A);
  assert.equal(second, first);
  assert.equal(h.creates.length, 1, 'no duplicate conversation');
  assert.deepEqual(
    h.tabs.get(first).url,
    newChat,
    'extension must not navigate a tab it reuses',
  );
  assert.ok(
    h.updates.every(({ changes }) => !('url' in changes)),
    'reuse only activates the tab, never rewrites its URL',
  );
  assert.equal(bindingTabId(h.bindings, 'local-a'), first);
});

test('two clicks before the tab finished loading create one tab', async () => {
  const h = harness();
  const [a, b] = await Promise.all([
    h.open('local-a', ENTRY_A),
    h.open('local-a', ENTRY_A),
  ]);
  assert.equal(a, b);
  assert.equal(h.creates.length, 1);

  // The tab is still loading (url empty, pendingUrl set): a third click reuses.
  const c = await h.open('local-a', ENTRY_A);
  assert.equal(c, a);
  assert.equal(h.creates.length, 1);
});

test('a fresh tab opens from the requesting workbench and same-window bindings stay in place', async () => {
  const h = harness();
  h.deps.sourceTab = { id: 27, windowId: 42, groupId: 5 };
  const first = await h.open('local-a', ENTRY_A);
  assert.deepEqual(h.creates, [{ id: first, url: ENTRY_A, windowId: 42, openerTabId: 27 }]);
  assert.deepEqual(h.groups, [{ tabIds: first, groupId: 5 }]);

  assert.equal(await h.open('local-a', ENTRY_A), first);
  assert.equal(h.creates.length, 1);
  assert.deepEqual(h.groups, [{ tabIds: first, groupId: 5 }]);
  assert.deepEqual(h.moves, []);
  assert.deepEqual(h.windows.updates, [{ id: 42, info: { focused: true } }]);

  h.deps.sourceTab = { id: 28, windowId: 43, groupId: 6 };
  h.navigate(first, 'https://example.com/');
  const fresh = await h.open('local-a', ENTRY_A);
  assert.deepEqual(h.creates[1], { id: fresh, url: ENTRY_A, windowId: 43, openerTabId: 28 });
  assert.deepEqual(h.groups[1], { tabIds: fresh, groupId: 6 });
});

test('a valid off-window binding returns with the same tab, conversation, and workbench relationship', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  const conversation = `${ENTRY_A}&conversation=42`;
  h.navigate(first, conversation);
  const source = { id: 27, windowId: 42, groupId: 5, url: `${WORKSPACE}#s=session-1` };
  h.deps.sourceTab = source;
  h.tabs.set(source.id, source);

  assert.equal(await h.open('local-a', ENTRY_A), first);
  assert.deepEqual(h.moves, [{ id: first, windowId: source.windowId, index: -1 }]);
  assert.deepEqual(h.updates, [
    { id: first, changes: { openerTabId: source.id } },
    { id: first, changes: { active: true } },
  ]);
  assert.deepEqual(h.groups, [{ tabIds: first, groupId: source.groupId }]);
  assert.deepEqual(h.windows.updates, [{ id: source.windowId, info: { focused: true } }]);
  assert.equal(h.tabs.get(first).url, conversation);
  assert.equal(bindingTabId(h.bindings, 'local-a'), first);
  assert.equal(h.creates.length, 1);
});

test('a stale workbench or rejected move leaves the old binding without activating its window', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  const source = { id: 27, windowId: 42, groupId: 5, url: WORKSPACE };
  h.deps.sourceTab = source;
  h.tabs.set(source.id, { ...source, windowId: 43 });
  await assert.rejects(h.open('local-a', ENTRY_A), /工作台窗口已变更/);
  assert.deepEqual(h.moves, []);

  h.tabs.set(source.id, source);
  h.api.move = async () => { throw new Error('Tabs cannot be edited right now'); };
  await assert.rejects(h.open('local-a', ENTRY_A), /无法把已打开的原页移回/);
  assert.deepEqual(h.updates, []);
  assert.deepEqual(h.groups, []);
  assert.deepEqual(h.windows.updates, []);
  assert.equal(bindingTabId(h.bindings, 'local-a'), first);
  assert.equal(h.creates.length, 1);
  assert.equal(h.tabs.get(first).windowId, 1);
});

test('an opener failure after a successful move retries in place', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  const source = { id: 27, windowId: 42, groupId: -1, url: WORKSPACE };
  h.deps.sourceTab = source;
  h.tabs.set(source.id, source);
  const update = h.api.update;
  h.api.update = async () => { throw new Error('Browser rejected the opener'); };

  await assert.rejects(h.open('local-a', ENTRY_A), /浏览器未能将原页关联/);
  assert.equal(h.tabs.get(first).windowId, source.windowId);
  assert.equal(bindingTabId(h.bindings, 'local-a'), first);
  assert.deepEqual(h.windows.updates, []);

  h.api.update = update;
  assert.equal(await h.open('local-a', ENTRY_A), first);
  assert.equal(h.tabs.get(first).openerTabId, source.id);
  assert.equal(h.moves.length, 1);
  assert.equal(h.creates.length, 1);
});

test('a same-window binding recovers its opener and group without moving or duplicating', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  h.tabs.get(first).groupId = 9;
  const source = { id: 27, windowId: 1, groupId: 5, url: WORKSPACE };
  h.deps.sourceTab = source;
  h.tabs.set(source.id, source);

  assert.equal(await h.open('local-a', ENTRY_A), first);
  assert.deepEqual(h.moves, []);
  assert.deepEqual(h.groups, [{ tabIds: first, groupId: source.groupId }]);
  assert.equal(h.tabs.get(first).openerTabId, source.id);
  assert.equal(h.creates.length, 1);
});

test('a bound tab repurposed while the workbench is checked is not moved or activated', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  const source = { id: 27, windowId: 42, groupId: 5, url: WORKSPACE };
  h.deps.sourceTab = source;
  h.tabs.set(source.id, source);
  const get = h.api.get;
  h.api.get = async (id) => {
    if (id === source.id) h.navigate(first, 'https://example.com/');
    return get(id);
  };

  await assert.rejects(h.open('local-a', ENTRY_A), /原页已变更/);
  assert.deepEqual(h.moves, []);
  assert.deepEqual(h.updates, []);
  assert.deepEqual(h.windows.updates, []);
  assert.equal(h.creates.length, 1);
});

test('creation failure makes no binding or off-window retry and allows a later open', async () => {
  const h = harness();
  h.deps.sourceTab = { id: 27, windowId: 42, groupId: -1 };
  const create = h.api.create;
  const attempts = [];
  h.api.create = async (properties) => {
    attempts.push(properties);
    throw new Error('No window with id 42');
  };
  await assert.rejects(h.open('local-a', ENTRY_A), /No window/);
  assert.deepEqual(attempts, [{ url: ENTRY_A, active: true, windowId: 42, openerTabId: 27 }]);
  assert.equal(bindingTabId(h.bindings, 'local-a'), null);

  h.api.create = create;
  h.deps.sourceTab = { id: 27, windowId: 43, groupId: -1 };
  const fresh = await h.open('local-a', ENTRY_A);
  assert.equal(bindingTabId(h.bindings, 'local-a'), fresh);
  assert.deepEqual(h.groups, []);
});

test('a disappearing group leaves the created tab bound and reusable', async () => {
  const h = harness();
  h.deps.sourceTab = { id: 27, windowId: 42, groupId: 5 };
  h.api.group = async () => { throw new Error('No group with id 5'); };
  const first = await h.open('local-a', ENTRY_A);
  assert.equal(h.tabs.get(first).groupId, -1);
  assert.equal(bindingTabId(h.bindings, 'local-a'), first);
  h.tabs.set(27, { id: 27, windowId: 42, groupId: -1, url: WORKSPACE });
  assert.equal(await h.open('local-a', ENTRY_A), first);
  assert.equal(h.creates.length, 1);
});

test('a tab repurposed to another site is left alone and a fresh tab opens', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  h.navigate(first, 'https://example.com/elsewhere');
  const updatesBefore = h.updates.length;
  const windowsBefore = h.windows.updates.length;

  const second = await h.open('local-a', ENTRY_A);
  assert.notEqual(second, first);
  assert.equal(h.creates.length, 2);
  assert.equal(h.tabs.get(first).url, 'https://example.com/elsewhere');
  assert.equal(
    h.updates.slice(updatesBefore).filter(({ id }) => id === first).length,
    0,
    'the repurposed tab must not be focused or navigated',
  );
  assert.equal(h.windows.updates.length, windowsBefore);
  assert.equal(bindingTabId(h.bindings, 'local-a'), second);
});

test('loopback seats are compared by origin including port', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  h.navigate(first, 'http://127.0.0.1:8766/web-driver-fixture.html?seat=A');

  const second = await h.open('local-a', ENTRY_A);
  assert.notEqual(second, first, 'port 8766 is not port 8765');
  assert.equal(h.creates.length, 2);
  assert.equal(h.tabs.get(first).url, ENTRY_A_OTHER_PORT);
  assert.equal(h.creates[1].url, ENTRY_A);
});

test('both seats on one shared fixture origin stay on their own seat', async () => {
  const h = harness();
  const a = await h.open('local-a', ENTRY_A);
  const b = await h.open('local-b', ENTRY_B);
  assert.notEqual(a, b);
  assert.equal(h.creates.length, 2);
  assert.equal(h.tabs.get(a).pendingUrl, ENTRY_A);
  assert.equal(h.tabs.get(b).pendingUrl, ENTRY_B);
  assert.equal(bindingTabId(h.bindings, 'local-a'), a);
  assert.equal(bindingTabId(h.bindings, 'local-b'), b);

  // Reopening A must pick A even though a B tab exists in the same origin.
  h.navigate(a, ENTRY_A);
  h.navigate(b, ENTRY_B);
  assert.equal(await h.open('local-a', ENTRY_A), a);
  assert.equal(await h.open('local-b', ENTRY_B), b);
  assert.equal(h.creates.length, 2);

  // The A tab was repurposed to seat B: never focus it for local-a.
  h.navigate(a, ENTRY_B);
  const fresh = await h.open('local-a', ENTRY_A);
  assert.notEqual(fresh, a);
  assert.equal(h.tabs.get(a).url, ENTRY_B, 'repurposed tab untouched');
  assert.equal(h.creates.length, 3);
  assert.equal(h.creates[2].url, ENTRY_A);
});

test('unreadable or in-flight-redirect metadata never reuses a tab', async () => {
  const h = harness();
  const first = await h.open('local-a', ENTRY_A);
  h.blankUrl(first);
  const second = await h.open('local-a', ENTRY_A);
  assert.notEqual(second, first);
  assert.equal(h.creates.length, 2);

  h.navigate(second, ENTRY_A);
  h.redirecting(second, 'https://example.com/login');
  const third = await h.open('local-a', ENTRY_A);
  assert.notEqual(third, second, 'a redirect away is a repurposed tab');
  assert.equal(h.creates.length, 3);
  assert.equal(h.tabs.get(second).pendingUrl, 'https://example.com/login');
});

test('binding survives a worker restart and still reuses the tab', async () => {
  const h = harness();
  const first = await worker.openProviderTab('session-1', 'local-a', ENTRY_A, h.deps);
  h.navigate(first, ENTRY_A);

  // Fresh module instance = empty in-memory open map, same persistent binding.
  const reused = await restartedWorker.openProviderTab(
    'session-1',
    'local-a',
    ENTRY_A,
    h.deps,
  );
  assert.equal(reused, first);
  assert.equal(h.creates.length, 1, 'restart must not open a second conversation');

  // After the restart, a repurposed tab still forces a fresh one.
  h.navigate(first, 'https://example.com/');
  const fresh = await restartedWorker.openProviderTab(
    'session-1',
    'local-a',
    ENTRY_A,
    h.deps,
  );
  assert.notEqual(fresh, first);
  assert.equal(h.creates.length, 2);
});

test('concurrent opens of different seats stay independent', async () => {
  const h = harness();
  const [a, b] = await Promise.all([
    h.open('local-a', ENTRY_A),
    h.open('local-b', ENTRY_B),
  ]);
  assert.notEqual(a, b);
  assert.equal(h.creates.length, 2);
  assert.equal(bindingTabId(h.bindings, 'local-a'), a);
  assert.equal(bindingTabId(h.bindings, 'local-b'), b);
});

test('pure matcher requires exact origin and seat', () => {
  const { tabMatchesEntry } = worker;
  assert.equal(
    tabMatchesEntry({ url: 'https://chatgpt.com/c/123' }, 'https://chatgpt.com/'),
    true,
    'new chat route on the same origin is reusable',
  );
  assert.equal(
    tabMatchesEntry({ url: 'https://chatgpt.com.evil.test/' }, 'https://chatgpt.com/'),
    false,
  );
  assert.equal(
    tabMatchesEntry({ pendingUrl: ENTRY_A }, ENTRY_A),
    true,
    'pendingUrl is enough while the tab is still loading',
  );
  assert.equal(
    tabMatchesEntry({ url: 'about:blank', pendingUrl: ENTRY_A }, ENTRY_A),
    true,
    'a newly created tab reports about:blank plus the real pendingUrl',
  );
  assert.equal(tabMatchesEntry({ url: ENTRY_B }, ENTRY_A), false, 'other seat');
  assert.equal(tabMatchesEntry({ url: ENTRY_A, pendingUrl: ENTRY_B }, ENTRY_A), false);
  assert.equal(tabMatchesEntry({ url: '', pendingUrl: '' }, ENTRY_A), false);
});
