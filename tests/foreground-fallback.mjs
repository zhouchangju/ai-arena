// Regression for the minimal foreground fallback (G1/R06).
//
// Two public-page states may borrow the front for a few seconds, at most once
// per task, and only while this workbench is still the active tab:
//
// - Gemini reported `send-pending` with `clickAttempted:false`, so the next
//   safe retry briefly activates its own bound page first;
// - DeepSeek clicked, moved to its own same-origin conversation address and the
//   read-only reconciliation has not matched this round's user message yet.
//
// A pre-dispatch readiness probe may additionally use one bounded foreground
// look when a public composer is late; that path has no dispatch intent yet and
// never fills or sends.
//
// Nothing is re-sent, the workbench comes back, and a user who already left the
// workbench is never pulled back. A fake `chrome.tabs` is used: no browser, no
// network, no real site.

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
      id: 'foreground-fallback-test',
      getURL: (path) => `chrome-extension://foreground-fallback-test/${path}`,
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
      url: 'chrome-extension://foreground-fallback-test/workspace.html#s=session',
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
          url: 'chrome-extension://foreground-fallback-test/workspace.html',
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

test('gemini keeps its pre-click retry and borrows the front once', async () => {
  const id = 'fb-gemini';
  makeSession(id, 'gemini');
  const openerId = fake.addOpener({ id: 401 });
  fake.reset();

  let submitCount = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') return { ok: true, status: 'ready' };
    if (command.type === 'arena.web.submit') {
      submitCount += 1;
      if (submitCount === 1) {
        return {
          ok: false,
          status: 'error',
          error: 'send-pending',
          detail: { phase: 'pre-click', clickAttempted: false, reason: 'hidden' },
        };
      }
      return { ok: true, status: 'submitted', detail: { userTurnVerified: true } };
    }
    if (command.type === 'arena.web.read') {
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
    await pumpUntil(() => submits().length >= 2);
    const seatTabId = fake.seatTabId(id, 'gemini');

    const active = activations(seatTabId);
    assert.equal(active.length, 1, 'the un-clicked Gemini page is shown once');
    assert.equal(fake.tabs.get(openerId).active, true, 'the workbench is back in front');
    assert.equal(fake.tabs.get(seatTabId).active, false);
    assert.ok(fake.run(id).dispatch[`${id}:r1:answer:gemini`].foregroundFallbackAt > 0);

    // Later ticks are read-only: no second fallback and no third send.
    for (let i = 0; i < 4; i += 1) {
      automation.pump();
      await wait(200);
    }
    assert.equal(submits().length, 2, 'only the original submit and one safe retry');
    assert.equal(activations(seatTabId).length, 1, 'the fallback stays one-per-task');
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('gemini keeps the front when the user already left the workbench', async () => {
  const id = 'fb-gemini-left';
  makeSession(id, 'gemini');
  const openerId = fake.addOpener({ id: 501, active: false });
  const userTabId = fake.addUserTab();
  fake.tabs.get(userTabId).active = true;
  fake.reset();

  let submitCount = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') return { ok: true, status: 'ready' };
    if (command.type === 'arena.web.submit') {
      submitCount += 1;
      return {
        ok: false,
        status: 'error',
        error: 'send-pending',
        detail: { phase: 'pre-click', clickAttempted: false, reason: 'hidden' },
      };
    }
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => submits().length >= 2);
    const seatTabId = fake.seatTabId(id, 'gemini');

    assert.equal(activations(seatTabId).length, 0, 'no tab is taken from the user');
    assert.equal(fake.tabs.get(userTabId).active, true);
    assert.equal(fake.tabs.get(openerId).active, false);
    assert.ok(submitCount >= 2, 'the safe pre-click retry still happens');
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('deepseek reads again after one front-visible reconciliation', async () => {
  const id = 'fb-deepseek';
  makeSession(id, 'deepseek');
  const openerId = fake.addOpener({ id: 601 });
  fake.reset();

  let reads = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') return { ok: true, status: 'ready' };
    if (command.type === 'arena.web.submit') {
      return {
        ok: false,
        status: 'error',
        error: 'submit-unconfirmed',
        detail: { clickAttempted: true },
      };
    }
    if (command.type === 'arena.web.read') {
      reads += 1;
      if (reads === 1) {
        return {
          ok: false,
          status: 'unknown',
          error: 'page-changed',
          detail: { reason: 'spa-navigation-unverified' },
        };
      }
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
    await pumpUntil(() => reads >= 2);
    const seatTabId = fake.seatTabId(id, 'deepseek');

    assert.equal(activations(seatTabId).length, 1, 'one read-only front-visible check');
    assert.equal(submits().length, 1, 'nothing is re-sent');
    assert.equal(fake.tabs.get(openerId).active, true, 'the workbench is back in front');
    assert.equal(fake.tabs.get(seatTabId).active, false);

    for (let i = 0; i < 3; i += 1) {
      automation.pump();
      await wait(200);
    }
    assert.equal(submits().length, 1, 'later reads still never resend');
    assert.equal(activations(seatTabId).length, 1);
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('a late public composer is probed again and shown once, before any dispatch', async () => {
  const id = 'fb-probe-late';
  makeSession(id, 'chatgpt');
  const openerId = fake.addOpener({ id: 701 });
  fake.reset();

  let probes = 0;
  let seatTabId = null;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') {
      probes += 1;
      seatTabId = seatTabId || fake.seatTabId(id, 'chatgpt');
      const shown = seatTabId
        ? fake.updates.some(
            ({ id: tab, changes }) => tab === seatTabId && changes.active === true,
          )
        : false;
      return shown
        ? { ok: true, status: 'ready' }
        : { ok: false, status: 'error', error: 'selector-missing' };
    }
    if (command.type === 'arena.web.submit') {
      return { ok: true, status: 'submitted', detail: { userTurnVerified: true } };
    }
    if (command.type === 'arena.web.read') {
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
    await pumpUntil(() => submits().length >= 1, 20000);
    seatTabId = seatTabId || fake.seatTabId(id, 'chatgpt');

    assert.ok(probes >= 5, 'the same probe is repeated while the composer is late');
    assert.equal(activations(seatTabId).length, 1, 'one bounded foreground look');
    assert.equal(fake.tabs.get(openerId).active, true, 'the workbench is back in front');
    assert.equal(fake.tabs.get(seatTabId).active, false);
    assert.equal(submits().length, 1, 'still exactly one submit');

    for (let i = 0; i < 4; i += 1) {
      automation.pump();
      await wait(200);
    }
    assert.equal(activations(seatTabId).length, 1, 'the probe look is not repeated');
    assert.equal(submits().length, 1, 'later ticks never resend');
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('a takeover during the readiness probe stops this seat without taking the front', async () => {
  const id = 'fb-probe-takeover';
  makeSession(id, 'chatgpt');
  const openerId = fake.addOpener({ id: 801 });
  fake.reset();

  let probes = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') {
      probes += 1;
      return { ok: false, status: 'error', error: 'selector-missing' };
    }
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => probes >= 2);
    await fake.send(
      { type: 'automation.takeover', id, provider: 'chatgpt' },
      openerId,
    );
    const atTakeover = probes;

    for (let i = 0; i < 10; i += 1) {
      automation.pump();
      await wait(200);
    }
    assert.equal(probes, atTakeover, 'the probe loop stops on takeover');
    assert.equal(fake.run(id).seats.chatgpt.takenOver, true);
    assert.equal(Object.keys(fake.run(id).dispatch).length, 0, 'no dispatch intent was created');
    const seatTabId = fake.seatTabId(id, 'chatgpt');
    assert.equal(activations(seatTabId).length, 0, 'the front is never taken');
    assert.equal(fake.tabs.get(openerId).active, true);
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});

test('pausing the discussion during the readiness probe stops it before any dispatch', async () => {
  const id = 'fb-probe-session-pause';
  const session = makeSession(id, 'chatgpt');
  const openerId = fake.addOpener({ id: 1001 });
  fake.reset();

  let probes = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') {
      probes += 1;
      return { ok: false, status: 'error', error: 'selector-missing' };
    }
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => probes >= 2);
    session.paused = true;
    const atPause = probes;

    for (let i = 0; i < 10; i += 1) {
      automation.pump();
      await wait(200);
    }
    assert.equal(probes, atPause, 'the readiness loop stops on a discussion pause');
    assert.equal(submits().length, 0, 'no prompt is sent');
    assert.equal(Object.keys(fake.run(id).dispatch).length, 0, 'no dispatch intent was created');
    assert.equal(fake.run(id).seats.chatgpt.status, 'session-paused');
    const seatTabId = fake.seatTabId(id, 'chatgpt');
    assert.equal(activations(seatTabId).length, 0, 'the front is never taken');
  } finally {
    session.paused = false;
    await fake.send({ type: 'automation.stop', id });
  }
});

test('a non-retryable readiness error pauses with the actual reason and no fill or send', async () => {
  const id = 'fb-probe-denied';
  makeSession(id, 'chatgpt');
  const openerId = fake.addOpener({ id: 901 });
  fake.reset();

  let probes = 0;
  fake.setDriver((command) => {
    if (command.type === 'arena.web.probe') {
      probes += 1;
      return { ok: false, status: 'error', error: 'not-authorized-page' };
    }
    return { ok: false, status: 'unknown', error: 'unexpected-command' };
  });

  try {
    await fake.send({ type: 'automation.start', id, windowId: 1 }, openerId);
    await pumpUntil(() => fake.run(id).seats.chatgpt?.status === 'paused');

    const seat = fake.run(id).seats.chatgpt;
    assert.equal(probes, 1, 'a login or unauthorized page is not retried');
    assert.match(seat.detail, /not-authorized-page/);
    assert.match(seat.detail, /未填入、未发送/);
    assert.equal(submits().length, 0);
    const seatTabId = fake.seatTabId(id, 'chatgpt');
    assert.equal(activations(seatTabId).length, 0);
  } finally {
    await fake.send({ type: 'automation.stop', id });
  }
});
