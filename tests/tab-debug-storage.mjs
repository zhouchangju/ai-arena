import assert from 'node:assert/strict';
import test from 'node:test';
import { setImmediate } from 'node:timers/promises';

function fakeChrome() {
  const values = {};
  const reads = [];
  const removed = [];
  const writes = [];
  const local = {
    async get(key) {
      reads.push(key);
      if (key === null) return { ...values };
      return Object.hasOwn(values, key) ? { [key]: values[key] } : {};
    },
    async set(items) {
      writes.push(items);
      Object.assign(values, items);
    },
    async remove(keys) {
      removed.push(keys);
      for (const key of keys) delete values[key];
    },
  };
  globalThis.chrome = { runtime: {}, storage: { local } };
  return { values, reads, removed, writes, local };
}

// Automation recovery schedules a poll in the worker; it need not keep Node open.
const realSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = (...args) => realSetTimeout(...args).unref();
const { openProviderTab } = await import('../extension/background.js');

test('worker startup removes only legacy tab debug records and retries incomplete cleanup', async () => {
  const { values, reads, removed, writes, local } = fakeChrome();
  const migrationKey = 'arena.migration.tabDebugCleanup.v1';
  const legacy = {
    'dbg.1795312800000': { step: 'get', binding: 41, url: 'https://example.test/thread/one' },
    'dbg.1795312800001': { step: 'create-before', targetUrl: 'https://example.test/' },
    'dbg.1795312800002': { step: 'created', id: 42, pendingUrl: 'https://example.test/thread/two' },
  };
  const keep = {
    'arena.automation.v1': { config: {}, runs: {} },
    'arena.ui': { theme: 'dark' },
    'dbg.preferences': { step: 'get' },
    'dbg.1795312800003': { step: 'another-feature' },
    'dbg.1795312800004.extra': { step: 'created' },
  };
  Object.assign(values, keep, legacy);

  const remove = local.remove;
  local.remove = async () => {
    throw new Error('temporary storage error');
  };
  await import('../extension/background.js?tab-debug-storage-failed');
  await setImmediate();
  assert.deepEqual(values, { ...keep, ...legacy });
  assert.deepEqual(writes, []);
  local.remove = remove;

  await import('../extension/background.js?tab-debug-storage-retry');
  await setImmediate();
  assert.deepEqual(removed, [Object.keys(legacy)]);
  assert.deepEqual(values, { ...keep, [migrationKey]: true });

  await import('../extension/background.js?tab-debug-storage-completed');
  await setImmediate();
  assert.deepEqual(removed, [Object.keys(legacy)]);
  assert.deepEqual(writes, [{ [migrationKey]: true }]);
  assert.deepEqual(reads.filter((key) => key === null), [null, null]);
});

test('opening and reusing a seat tab creates no persistent debug entries', async () => {
  const { values, writes } = fakeChrome();
  const page = { id: 42, windowId: 1, url: 'https://chatgpt.com/c/private-thread' };
  const created = [];
  const focused = [];
  let binding;
  const overrides = {
    tabs: {
      async create(options) {
        created.push(options);
        return { ...page };
      },
      async get() {
        return { ...page };
      },
      async update(id) {
        focused.push(id);
      },
    },
    bindings: {
      async get() {
        return binding;
      },
      async set(_, value) {
        binding = value;
      },
    },
  };

  assert.equal(await openProviderTab('test-session', 'chatgpt', '', overrides), page.id);
  assert.equal(await openProviderTab('test-session', 'chatgpt', '', overrides), page.id);
  assert.equal(created.length, 1);
  assert.deepEqual(focused, [page.id]);
  assert.deepEqual(writes, []);
  assert.deepEqual(values, {});
});
