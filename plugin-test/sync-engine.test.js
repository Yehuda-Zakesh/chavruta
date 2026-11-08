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

/**
 * מנוע מזווג מול אוצריא מדומה. `active` הוא שם השולחן הפעיל, ו-`deskApi`
 * כבוי מדמה גרסת אוצריא בלי ממשק שולחנות.
 */
function pairedEngine({ active, deskApi = true, updates = [] }) {
  const calls = [];
  const published = [];
  const handlers = {};
  const world = { active };
  const queue = updates.slice();
  const { SyncEngine } = load(['js/sync-engine.js'], {
    Otzaria: {
      on(name, handler) { handlers[name] = handler; },
      off(name) { delete handlers[name]; },
      async call(method, args) {
        calls.push({ method, args });
        if (method.startsWith('workspace.') && !deskApi) throw new Error('unknown method');
        if (method === 'workspace.list') return { success: true, data: [] };
        if (method === 'workspace.getActive') return { success: true, data: { name: world.active } };
        if (method === 'reader.getCurrentRef') {
          return { success: true, data: { currentBookId: 'שלי', currentIndex: 7 } };
        }
        if (method === 'reader.getCurrentState') return { success: true, data: { openTabs: [] } };
        return { success: true, data: true };
      },
    },
    Link: { api: {
      setInstance() {}, releaseEngine() {}, async publishDesk() {},
      async publish(location) { published.push(location); },
      async events() {
        const next = queue.shift();
        if (!next) return new Promise(() => {});
        return Object.assign({ engineMine: true, paired: true, remoteSequence: 1 }, next);
      },
    } },
  });
  const opened = () => calls.filter(c => c.method === 'reader.openBook').map(c => c.args.bookId);
  return { SyncEngine, calls, published, handlers, world, opened };
}

const FROM_PARTNER = {
  hasUpdate: true,
  peers: [{ id: 'חבר' }],
  remote: { fromId: 'חבר', location: { bookId: 'של החברותא', index: 3 } },
};

test('פתיחה מחוץ לשולחן המשותף אינה מעבירה אליו', async () => {
  const e = pairedEngine({ active: 'פרטי', updates: [{}] });
  try {
    e.SyncEngine.start('background');
    await until(() => e.calls.some(c => c.method === 'workspace.getActive'), 2000);
    await new Promise(r => setTimeout(r, 100));
    assert.equal(e.calls.some(c => c.method === 'workspace.create'), false);
  } finally { e.SyncEngine.stop(); }
});

test('מחוץ לשולחן המשותף מקום הלימוד אינו נשלח ואינו נקלט', async () => {
  const e = pairedEngine({ active: 'פרטי', updates: [FROM_PARTNER] });
  try {
    e.SyncEngine.start('background');
    await until(() => e.calls.filter(c => c.method === 'workspace.getActive').length >= 3, 2000);
    await new Promise(r => setTimeout(r, 100));
    assert.deepEqual(e.published, []);
    assert.deepEqual(e.opened(), []);
  } finally { e.SyncEngine.stop(); }
});

test('בתוך השולחן המשותף מקום הלימוד מסתנכרן בשני הכיוונים', async () => {
  const e = pairedEngine({ active: 'חברותא', updates: [FROM_PARTNER] });
  try {
    e.SyncEngine.start('background');
    await until(() => e.published.length > 0 && e.opened().length > 0, 2000);
    assert.equal(e.published[0].bookId, 'שלי');
    assert.deepEqual(e.opened(), ['של החברותא']);
  } finally { e.SyncEngine.stop(); }
});

test('אוצריא בלי ממשק שולחנות ממשיכה לסנכרן מקום לימוד', async () => {
  const e = pairedEngine({ active: 'פרטי', deskApi: false, updates: [FROM_PARTNER] });
  try {
    e.SyncEngine.start('background');
    await until(() => e.published.length > 0 && e.opened().length > 0, 2000);
    assert.deepEqual(e.opened(), ['של החברותא']);
  } finally { e.SyncEngine.stop(); }
});

test('כניסה לשולחן מצטרפת לחברותא שזזה בינתיים, בלי לדווח את המקום הישן', async () => {
  const e = pairedEngine({ active: 'פרטי', updates: [FROM_PARTNER] });
  try {
    e.SyncEngine.start('background');
    await until(() => e.handlers['workspace.changed'], 2000);
    await new Promise(r => setTimeout(r, 100));
    e.world.active = 'חברותא';
    e.handlers['workspace.changed']({});
    await until(() => e.opened().length > 0, 2000);
    assert.deepEqual(e.opened(), ['של החברותא']);
    assert.deepEqual(e.published, []);
  } finally { e.SyncEngine.stop(); }
});

test('כניסה לשולחן בלי עדכון ממתין מדווחת את המקום הנוכחי', async () => {
  const e = pairedEngine({ active: 'פרטי', updates: [{}] });
  try {
    e.SyncEngine.start('background');
    await until(() => e.handlers['workspace.changed'], 2000);
    await new Promise(r => setTimeout(r, 100));
    e.world.active = 'חברותא';
    e.handlers['workspace.changed']({});
    await until(() => e.published.length > 0, 2000);
    assert.equal(e.published[0].bookId, 'שלי');
    assert.deepEqual(e.opened(), []);
  } finally { e.SyncEngine.stop(); }
});

test('עדכון ממי שכבר התנתק אינו גורר בכניסה לשולחן', async () => {
  const e = pairedEngine({ active: 'פרטי', updates: [Object.assign({}, FROM_PARTNER, { peers: [] })] });
  try {
    e.SyncEngine.start('background');
    await until(() => e.handlers['workspace.changed'], 2000);
    await new Promise(r => setTimeout(r, 100));
    e.world.active = 'חברותא';
    e.handlers['workspace.changed']({});
    await until(() => e.published.length > 0, 2000);
    assert.deepEqual(e.opened(), []);
  } finally { e.SyncEngine.stop(); }
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
