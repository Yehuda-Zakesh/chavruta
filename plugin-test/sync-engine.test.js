'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./load');
const { until } = require('./fakes');

test('בקשת סגירה מהרקע פותחת את דף התוסף ומעבירה את שמות הספרים', async () => {
  const messages = [];
  let first = true;
  const { SyncEngine } = load(['js/sync-engine.js'], {
    Otzaria: {
      on() {}, off() {},
      async call(method, args) {
        if (method === 'reader.getCurrentState') return { success: true, data: { openTabs: [] } };
        if (method === 'workspace.list') return { success: true, data: [] };
        if (method === 'workspace.getActive') return { success: true, data: { name: 'חברותא' } };
        if (method === 'ui.showMessage') messages.push(args);
        return { success: true, data: true };
      },
    },
    Link: { api: {
      setInstance() {}, releaseEngine() {}, publishDesk() {},
      async events() {
        if (!first) return new Promise(() => {});
        first = false;
        return { engineMine: true, paired: true, closePolicy: 'ask', desk: { close: [{ b: 'ברכות' }] } };
      },
    } },
  });
  try {
    SyncEngine.start('background');
    await until(() => messages.some(m => m.tapPayload), 2000);
    const question = messages.find(m => m.tapPayload);
    assert.equal(question.tapOpenPlugin, true);
    assert.deepEqual(Array.from(question.tapPayload.deskCloses), ['ברכות']);
  } finally { SyncEngine.stop(); }
});

for (const partial of [false, true]) test('סגירת כמה ספרים מהסוף להתחלה; כשל חלקי=' + partial, async () => {
  const closed = [];
  const { SyncEngine } = load(['js/sync-engine.js'], {
    Otzaria: {
      async call(method, args) {
        if (method === 'reader.getCurrentState') return {
          success: true, data: { openTabs: [
            { type: 'book', bookId: 'ברכות' }, { type: null }, { type: 'book', bookId: 'שבת' },
          ] },
        };
        if (method === 'reader.closeTab') {
          closed.push(args.index);
          if (partial && args.index === 0) return { success: false };
        }
        return { success: true, data: true };
      },
    },
  });
  assert.equal(await SyncEngine.closeBooksByName(['ברכות', 'שבת']), !partial);
  assert.deepEqual(closed, [2, 0]);
});
