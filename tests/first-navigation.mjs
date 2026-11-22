// Regression for the first navigation of a newly created seat tab.
//
// Chrome can keep a background tab's first navigation uncommitted, which the
// worker reports as "页面仍在跳转" until the readiness timeout. The worker may
// briefly activate exactly that bound tab after ~4s, then give the workbench
// back. These cases use a fake `chrome.tabs` so no browser or network is
// involved:
//
// - a stalled new tab is activated once, commits, and the workbench returns;
// - the tab is never re-navigated and the submit target stays the same tab;
// - if the user already left the workbench, nothing is activated;
// - if the user switches away during the brief activation, nothing is taken back.

import test from 'node:test';
import assert from 'node:assert/strict';

const realSetTimeout = globalThis.setTimeout;

function createChrome() {
  const listeners = [];
  const store = new Map();
  const tabs = new Map();
  const commands = [];
  const creates = [];
  const updates = [];
  let nextTabId = 1;
  let commitNextCreateMs = 0;
  let activationCommitMs = 0;
  let stealFocusAfterMs = 0;

  const snapshot = (tab) => ({ ...tab });

  const later = (fn, ms) => {
    const timer = realSetTimeout(fn, ms);
    if (timer && typeof timer.unref === 'function') timer.unref();
  };

  const commit = (tab, url) => {
    tab.url = url;
    tab.pendingUrl = '';
    tab.status = 'complete';
  };

  const api = {
    runtime: {
      id: 'first-navigation-test',
      getURL: (path) => `chrome-extension://first-navigation-test/${path}`,
      onMessage: { addListener: (fn) => listeners.push(fn) },
      onStartup: { addListener() {} },
      onInstalled: { addListener() {} },
      sendMessage: async () => undefined,
    },
    tabs: {
      async get(id) {
        if (!tabs.has(id)) throw new Error(`No tab with id ${id}`);
        return snapshot(tabs.get(id));
      },
      async create({ url, active, windowId, openerTabId }) {
        const id = nextTabId++;
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
        if (commitNextCreateMs) {
          const at = commitNextCreateMs;
          commitNextCreateMs = 0;
          later(() => {
            if (tab.status === 'loading' && tab.pendingUrl) commit(tab, tab.pendingUrl);
          }, at);
        }
        return snapshot(tab);
      },
      async update(id, changes) {
        const tab = tabs.get(id);
        if (!tab) throw new Error(`No tab with id ${id}`);
        updates.push({ id, changes: { ...changes }, at: Date.now() });
        if (changes.url) {
          tab.url = 'about:blank';
          tab.pendingUrl = changes.url;
          tab.status = 'loading';
        }
        if (changes.active === true) {
          for (const other of tabs.values()) other.active = false;
          tab.active = true;
          if (tab.pendingUrl) {
            if (activationCommitMs) {
              const at = activationCommitMs;
              later(() => {
                if (tab.pendingUrl) commit(tab, tab.pendingUrl);
              }, at);
            } else {
              commit(tab, tab.pendingUrl);
            }
          }
          if (stealFocusAfterMs) {
            const at = stealFocusAfterMs;
            stealFocusAfterMs = 0;
            later(() => {
              const user = [...tabs.values()].find(
                (candidate) => candidate.id !== id && candidate.url.startsWith('https://'),
              );
              if (!user) return;
              for (const candidate of tabs.values()) candidate.active = false;
              user.active = true;
            }, at);
          }
        }
        return snapshot(tab);
      },
      async group({ tabIds, groupId }) {
        tabs.get(tabIds).groupId = groupId;
        return groupId;
      },
      async sendMessage(tabId, command) {
        commands.push({ tabId, type: command.type, taskId: command.taskId });
        if (command.type === 'arena.web.probe') {
          return { ok: true, status: 'ready' };
        }
        return { ok: false, status: 'error', error: 'test-stop-after-navigation' };
      },
    },
    scripting: {
      async executeScript() {
        throw new Error('fake driver: no script injection');
      },
    },
    permissions: { async contains() { return true; } },
    storage: {
      local: {
        async get(key) {
          return store.has(key) ? { [key]: store.get(key) } : {};
        },
        async set(values) {
          for (const [key, value] of Object.entries(values)) store.set(key, value);
        },
      },
    },
    alarms: { create() {}, onAlarm: { addListener() {} } },
  };

  function addOpener({ id = 100, windowId = 1, active = true } = {}) {
    tabs.set(id, {
      id,
      windowId,
      groupId: -1,
      url: 'chrome-extension://first-navigation-test/workspace.html#s=session',
      pendingUrl: '',
      status: 'complete',
      active,
    });
    return id;
  }

  function addUserTab({ windowId = 1 } = {}) {
    const id = nextTabId++;
    tabs.set(id, {
      id,
      windowId,
      groupId: -1,
      url: 'https://example.invalid/user',
      pendingUrl: '',
      status: 'complete',
      active: false,
    });
    return id;
  }

  function send(message, openerTabId = 100) {
    return new Promise((resolve, reject) => {
      const handled = listeners[0](
        message,
        {
          id: api.runtime.id,
          url: 'chrome-extension://first-navigation-test/workspace.html',
          tab: { id: openerTabId, windowId: 1 },
        },
        (reply) => (reply && reply.ok === false ? reject(new Error(reply.error)) : resolve(reply)),
      );
      assert.equal(handled, true, 'the worker should handle its own message');
    });
  }

  return {
    api,
    tabs,
    commands,
    creates,
    updates,
    addOpener,
    addUserTab,
    send,
    resetTraces: () => {
      commands.length = 0;
      creates.length = 0;
      updates.length = 0;
    },
    commitNextCreateAfter: (ms) => { commitNextCreateMs = ms; },
    commitActivationAfter: (ms) => { activationCommitMs = ms; },
    stealFocusAfterActivation: (ms) => { stealFocusAfterMs = ms; },
  };
}

const fake = createChrome();
globalThis.chrome = fake.api;

const { installAutomation } = await import('../extension/automation.js');

const SESSION = {
  id: 'session',
  stage: 'answer',
  round: 1,
  providers: ['local-a'],
  tasks: [
    {
      id: 'session:r1:answer:local-a',
      provider: 'local-a',
      status: 'pending',
      prompt: '只有一个待答问题',
    },
  ],
  history: [],
};

const automation = installAutomation({
  getSession: async () => SESSION,
  act: async () => SESSION,
});

await fake.send({
  type: 'automation.config',
  provider: 'local-a',
  config: {
    url: 'http://127.0.0.1:8877/fixture.html',
    selectors: {
      input: '#composer',
      send: '#send',
      user: '.turn.user .msg',
      answer: '.turn.answer .msg',
    },
  },
});

async function startSeat(sessionId, openerTabId = 100) {
  await fake.send({ type: 'automation.start', id: sessionId, windowId: 1 }, openerTabId);
  // The worker launches each seat separately; pump() only starts them.
  await automation.pump();
}

const stopSeat = (sessionId) => fake.send({ type: 'automation.stop', id: sessionId });

function waitFor(predicate, timeout = 15000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeout;
    const tick = () => {
      let value = false;
      try {
        value = predicate();
      } catch {
        value = false;
      }
      if (value) return resolve(value);
      if (Date.now() >= deadline) return reject(new Error('waitFor timed out'));
      realSetTimeout(tick, 50);
    };
    tick();
  });
}

function seatUpdates(tabId) {
  return fake.updates.filter(({ id }) => id === tabId);
}

test('a stalled first navigation is activated once and the workbench returns', async () => {
  try {
    fake.resetTraces();
    const openerId = fake.addOpener();
    await startSeat('run-stall');

    await waitFor(() => fake.commands.some(({ type }) => type === 'arena.web.submit'));
    const createdId = fake.creates.at(-1).id;
    const urlUpdates = seatUpdates(createdId).filter(({ changes }) => 'url' in changes);
    assert.equal(urlUpdates.length, 1, 'the tab is navigated exactly once');

    const activeUpdates = seatUpdates(createdId).filter(({ changes }) => changes.active === true);
    assert.equal(activeUpdates.length, 1, 'the stalled tab was activated once');
    assert.ok(
      activeUpdates[0].at - urlUpdates[0].at >= 3500,
      `activation waited for the grace period (${activeUpdates[0].at - urlUpdates[0].at}ms)`,
    );

    assert.equal(fake.tabs.get(createdId).url, 'http://127.0.0.1:8877/fixture.html');
    assert.equal(fake.tabs.get(openerId).active, true, 'the workbench is back in front');
    assert.equal(fake.tabs.get(createdId).active, false);
    assert.equal(fake.commands.filter(({ type }) => type === 'arena.web.submit').length, 1);
    assert.ok(
      fake.commands.every(({ tabId }) => tabId === createdId),
      'probe and submit stay on the same bound tab',
    );
  } finally {
    await stopSeat('run-stall');
  }
});

test('a slow navigation is not activated when the user already left the workbench', async () => {
  try {
    fake.resetTraces();
    const openerId = fake.addOpener({ id: 201, active: false });
    const userTabId = fake.addUserTab();
    fake.tabs.get(userTabId).active = true;
    fake.commitNextCreateAfter(5000);

    const createsBefore = fake.creates.length;
    await startSeat('run-left', 201);
    await waitFor(() => fake.creates.length > createsBefore, 5000);
    await waitFor(
      () => fake.tabs.get(fake.creates[createsBefore].id).url === 'http://127.0.0.1:8877/fixture.html',
      12000,
    );

    const createdId = fake.creates[createsBefore].id;
    assert.equal(
      seatUpdates(createdId).filter(({ changes }) => changes.active === true).length,
      0,
      'the worker did not take focus from another tab',
    );
    assert.equal(fake.tabs.get(openerId).active, false);
    assert.equal(fake.tabs.get(userTabId).active, true);
    assert.equal(fake.tabs.get(createdId).url, 'http://127.0.0.1:8877/fixture.html');
  } finally {
    await stopSeat('run-left');
  }
});

test('a user switch during the brief activation is not taken back', async () => {
  try {
    fake.resetTraces();
    const openerId = fake.addOpener({ id: 301 });
    fake.addUserTab();
    fake.commitActivationAfter(700);
    fake.stealFocusAfterActivation(300);

    await startSeat('run-switch', 301);
    await waitFor(() => fake.commands.some(({ type }) => type === 'arena.web.submit'));

    assert.equal(
      seatUpdates(openerId).filter(({ changes }) => changes.active === true).length,
      0,
      'the workbench was not forced back while the user was elsewhere',
    );
  } finally {
    await stopSeat('run-switch');
  }
});
