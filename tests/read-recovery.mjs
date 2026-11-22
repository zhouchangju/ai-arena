// Regression for the read-lane foreground recovery (G3/R06).
//
// The read lane may borrow the front for at most 3–5 s once per task, and only
// for two situations:
//
// - a confirmed transport timeout of `arena.web.read` (the page never answered
//   the module's own read call), and
// - a clicked round that stays in `verifying` on its own bound page past the
//   stuck window without proving this round's user message.
//
// It is read-only: no submit is ever called from this path. The run must still
// be enabled, the seat must not be paused/taken over, the tab must still match
// its bound origin, and the workbench must still be the active tab. If the
// retry does not recover the round, the seat becomes a per-seat pause; a user
// who already moved elsewhere is never pulled back.
//
// A fake `chrome.tabs` is used: no browser, no network, no real site.

import test from 'node:test';
import assert from 'node:assert/strict';

const realSetTimeout = globalThis.setTimeout;
const wait = (ms) => new Promise((resolve) => realSetTimeout(resolve, ms));

function createChrome() {
  const listeners = [];
  const store = new Map();
  const tabs = new Map();
  const commands = [];
  const updates = [];
  let nextTabId = 1;
  let driver = () => ({ ok: false, status: 'error', error: 'no-driver' });

  const snapshot = (tab) => ({ ...tab });

  const api = {
    runtime: {
      id: 'read-recovery-test',
      getURL: (path) => `chrome-extension://read-recovery-test/${path}`,
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
      async create({ url = 'about:blank', active = false, windowId = 1, openerTabId } = {}) {
        const id = nextTabId++;
        const tab = {
          id,
          windowId,
          openerTabId,
          groupId: -1,
          url,
          pendingUrl: '',
          status: 'complete',
          active: Boolean(active),
        };
        tabs.set(id, tab);
        return snapshot(tab);
      },
      async update(id, changes) {
        const tab = tabs.get(id);
        if (!tab) throw new Error(`No tab with id ${id}`);
        updates.push({ id, changes: { ...changes } });
        if (changes.url) {
          tab.url = changes.url;
          tab.pendingUrl = '';
          tab.status = 'complete';
        }
        if (changes.active === true) {
          for (const other of tabs.values()) other.active = false;
          tab.active = true;
        }
        return snapshot(tab);
      },
      async sendMessage(tabId, command) {
        commands.push({ tabId, type: command.type, taskId: command.taskId });
        return driver(command);
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

  const addOpener = ({ id = 100, active = true } = {}) => {
    tabs.set(id, {
      id,
      windowId: 1,
      groupId: -1,
      url: 'chrome-extension://read-recovery-test/workspace.html#s=session',
      pendingUrl: '',
      status: 'complete',
      active,
    });
    return id;
  };

  const addUserTab = () => {
    const id = nextTabId++;
    tabs.set(id, {
      id,
      windowId: 1,
      groupId: -1,
      url: 'https://example.invalid/user',
      pendingUrl: '',
      status: 'complete',
      active: false,
    });
    return id;
  };

  const send = (message, openerTabId = 100) =>
    new Promise((resolve, reject) => {
      const handled = listeners[0](
        message,
        {
          id: api.runtime.id,
          url: 'chrome-extension://read-recovery-test/workspace.html',
          tab: { id: openerTabId, windowId: 1 },
        },
        (reply) => (reply && reply.ok === false ? reject(new Error(reply.error)) : resolve(reply)),
      );
      assert.equal(handled, true, 'the worker handles its own message');
    });

  return {
    api,
    tabs,
    commands,
    updates,
    addOpener,
    addUserTab,
    send,
    setDriver: (fn) => { driver = fn; },
    run: (id) => {
      const value = store.get('arena.automation.v1');
      return (value && value.runs && value.runs[id]) || null;
    },
    seatTabId: (id, provider) => {
      const run = store.get('arena.automation.v1')?.runs?.[id];
      return run?.tabs?.[provider]?.tabId ?? null;
    },
    reset: () => {
      commands.length = 0;
      updates.length = 0;
    },
  };
}

const fake = createChrome();
globalThis.chrome = fake.api;

const { installAutomation } = await import('../extension/automation.js');

const sessions = new Map();
const automation = installAutomation({
  getSession: async (id) => sessions.get(id),
  act: async (id) => sessions.get(id),
});

function makeSession(id, provider) {
  const session = {
    id,
    stage: 'answer',
    round: 1,
    providers: [provider],
    tasks: [
      {
        id: `${id}:r1:answer:${provider}`,
        provider,
        status: 'pending',
        prompt: '本轮问题正文',
      },
    ],
    history: [],
  };
  sessions.set(id, session);
  return session;
}

async function pumpUntil(predicate, timeout = 25000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    automation.pump();
    if (predicate()) return;
    await wait(200);
  }
  throw new Error('pumpUntil timed out');
}

const activations = (tabId) =>
  fake.updates.filter(({ id, changes }) => id === tabId && changes.active === true);

const submits = () => fake.commands.filter(({ type }) => type === 'arena.web.submit');

const taskIdOf = (id, provider) => `${id}:r1:answer:${provider}`;

test('a confirmed read timeout borrows the front once, then reads again', async () => {
  const id = 'rr-timeout';
  makeSession(id, 'gemini');
  const openerId = fake.addOpener({ id: 701 });
  fake.reset();

  let reads = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') return { ok: true, status: 'ready' };
    if (command.type === 'arena.web.submit') {
      return { ok: true, status: 'submitted', detail: { userTurnVerified: true } };
    }
    if (command.type === 'arena.web.read') {
      reads += 1;
      if (reads === 1) throw new Error('网页驱动调用超时');
      return {
        ok: true,
        status: 'pending',
        detail: { userTurnVerified: true, reason: 'answer-empty' },
      };
    }
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => fake.seatTabId(id, 'gemini') !== null);
    const seatTabId = fake.seatTabId(id, 'gemini');
    await pumpUntil(
      () =>
        reads >= 2 &&
        fake.run(id)?.seats?.gemini?.paused === false &&
        fake.tabs.get(openerId).active === true,
    );

    assert.equal(submits().length, 1, 'the read lane never re-sends');
    assert.equal(activations(seatTabId).length, 1, 'one read-only front look per task');
    assert.equal(fake.tabs.get(seatTabId).active, false);
    assert.ok(fake.run(id).dispatch[taskIdOf(id, 'gemini')].readRecoveryAt > 0);
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('a second read timeout after that look leaves the seat for takeover', async () => {
  const id = 'rr-timeout-twice';
  makeSession(id, 'gemini');
  const openerId = fake.addOpener({ id: 801 });
  fake.reset();

  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') return { ok: true, status: 'ready' };
    if (command.type === 'arena.web.submit') {
      return { ok: true, status: 'submitted', detail: { userTurnVerified: true } };
    }
    if (command.type === 'arena.web.read') throw new Error('网页驱动调用超时');
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => fake.seatTabId(id, 'gemini') !== null);
    const seatTabId = fake.seatTabId(id, 'gemini');
    await pumpUntil(() => fake.run(id)?.seats?.gemini?.paused === true);

    assert.equal(submits().length, 1, 'a read timeout never re-sends');
    assert.equal(activations(seatTabId).length, 1, 'the recovery stays one per task');
    assert.match(fake.run(id).seats.gemini.detail, /读取回答失败/);
    assert.equal(fake.tabs.get(openerId).active, true);
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('a clicked same-address verifying round gets one front look, then takeover', async () => {
  const id = 'rr-verifying';
  makeSession(id, 'deepseek');
  const openerId = fake.addOpener({ id: 901 });
  fake.reset();

  let reads = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') return { ok: true, status: 'ready' };
    if (command.type === 'arena.web.submit') {
      return {
        ok: true,
        status: 'submitted',
        detail: { userTurnVerified: false },
      };
    }
    if (command.type === 'arena.web.read') {
      reads += 1;
      return {
        ok: true,
        status: 'pending',
        detail: { userTurnVerified: false, reason: 'answer-empty' },
      };
    }
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  const taskId = taskIdOf(id, 'deepseek');
  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => fake.seatTabId(id, 'deepseek') !== null);
    const seatTabId = fake.seatTabId(id, 'deepseek');
    await pumpUntil(
      () => fake.run(id)?.dispatch?.[taskId]?.verifyingSince > 0,
    );

    // Pretend this round has stayed unproven past the stuck window.
    fake.run(id).dispatch[taskId].verifyingSince = Date.now() - 60000;
    await pumpUntil(
      () =>
        fake.run(id)?.dispatch?.[taskId]?.readRecoveryAt > 0 &&
        fake.run(id)?.seats?.deepseek?.paused === false &&
        fake.tabs.get(openerId).active === true,
    );

    assert.equal(submits().length, 1, 'verifying recovery never re-sends');
    assert.equal(activations(seatTabId).length, 1, 'one front look for the stuck round');
    await pumpUntil(() => reads >= 2);
    assert.ok(reads >= 2, 'the read lane reads again after the look');

    // The one look did not prove the turn: it stays read-only and is handed over.
    fake.run(id).dispatch[taskId].readRecoveryAt = Date.now() - 60000;
    await pumpUntil(() => fake.run(id)?.seats?.deepseek?.paused === true);

    assert.equal(submits().length, 1);
    assert.equal(activations(seatTabId).length, 1, 'no second front look');
    assert.match(fake.run(id).seats.deepseek.detail, /长时间未核对到本轮用户消息/);
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('a verified Gemini round without the native completion marker gets one read-only look', async () => {
  const id = 'rr-completion-signal';
  makeSession(id, 'gemini');
  const openerId = fake.addOpener({ id: 1101 });
  fake.reset();

  let reads = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') return { ok: true, status: 'ready' };
    if (command.type === 'arena.web.submit') {
      return { ok: true, status: 'submitted', detail: { userTurnVerified: true } };
    }
    if (command.type === 'arena.web.read') {
      reads += 1;
      // The page body is already the site's short title, so the driver keeps
      // answering `completion-signal-missing`; only its stability clock grows.
      return {
        ok: true,
        status: 'pending',
        detail: {
          userTurnVerified: true,
          reason: 'completion-signal-missing',
          partialChars: 11,
          stableMs: reads >= 3 ? 9000 : 2000,
          preview: { text: '明确判断与主要理由', chars: 11 },
        },
      };
    }
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  const taskId = taskIdOf(id, 'gemini');
  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => fake.seatTabId(id, 'gemini') !== null);
    const seatTabId = fake.seatTabId(id, 'gemini');

    // Stable text below the threshold is still a plain preview wait.
    await pumpUntil(() => reads >= 2);
    assert.equal(activations(seatTabId).length, 0, 'short stability does not borrow the front');

    await pumpUntil(
      () =>
        fake.run(id)?.dispatch?.[taskId]?.readRecoveryAt > 0 &&
        fake.tabs.get(openerId).active === true,
    );

    assert.equal(submits().length, 1, 'the completion look never re-sends');
    assert.equal(activations(seatTabId).length, 1, 'one bounded read-only front look');
    assert.equal(fake.tabs.get(seatTabId).active, false, 'the workbench gets the front back');
    assert.equal(fake.run(id).seats.gemini.paused, false, 'the seat keeps waiting');
    assert.equal(fake.run(id).seats.gemini.status, 'streaming');
    assert.match(fake.run(id).seats.gemini.detail, /等待生成结束/);
    assert.equal(fake.run(id).seats.gemini.preview.chars, 11, 'the snippet stays a preview');
    assert.equal(sessions.get(id).tasks[0].status, 'pending', 'a title is never saved as the answer');

    // Reading the original page continues and the look stays one per task.
    const readsAfterLook = reads;
    await pumpUntil(() => reads > readsAfterLook);
    assert.equal(activations(seatTabId).length, 1, 'no second front look');
    assert.equal(submits().length, 1);
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('a read timeout keeps the front when the user already left the workbench', async () => {
  const id = 'rr-left';
  makeSession(id, 'gemini');
  const openerId = fake.addOpener({ id: 1001, active: false });
  const userTabId = fake.addUserTab();
  fake.tabs.get(userTabId).active = true;
  fake.reset();

  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') return { ok: true, status: 'ready' };
    if (command.type === 'arena.web.submit') {
      return { ok: true, status: 'submitted', detail: { userTurnVerified: true } };
    }
    if (command.type === 'arena.web.read') throw new Error('网页驱动调用超时');
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => fake.seatTabId(id, 'gemini') !== null);
    const seatTabId = fake.seatTabId(id, 'gemini');
    await pumpUntil(() => fake.run(id)?.seats?.gemini?.paused === true);

    assert.equal(activations(seatTabId).length, 0, 'no tab is taken from the user');
    assert.equal(fake.tabs.get(userTabId).active, true);
    assert.equal(fake.tabs.get(openerId).active, false);
    assert.equal(submits().length, 1);
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});
