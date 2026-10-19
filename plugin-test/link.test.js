'use strict';

// בחירת דרך החיבור (`link.js`): מפתח חסר הוא "החיבור הישיר", אבל קריאה
// שנכשלה אינה תשובה — ואסור שתחליף את המצב.

const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./load');

function setup() {
  const storage = new Map();
  // null = תקין; אחרת סוג הכשל. `fail` לקריאה, `setFail` לכתיבה.
  const behavior = { fail: null, setFail: null };
  const order = [];
  const Otzaria = {
    call(method, args) {
      if (method === 'storage.get') {
        if (behavior.fail === 'unsuccessful') {
          return Promise.resolve({ success: false, error: { code: 'error.internal', message: 'db busy' } });
        }
        if (behavior.fail === 'throws') return Promise.reject(new Error('bridge gone'));
        if (behavior.fail === 'empty') return Promise.resolve(undefined);
        return Promise.resolve({ success: true, data: storage.has(args.key) ? storage.get(args.key) : null });
      }
      if (method === 'storage.set') {
        if (behavior.setFail === 'unsuccessful') {
          return Promise.resolve({ success: false, error: { code: 'error.internal', message: 'db busy' } });
        }
        if (behavior.setFail === 'throws') return Promise.reject(new Error('bridge gone'));
        if (behavior.setFail === 'empty') return Promise.resolve(undefined);
        storage.set(args.key, args.value);
        return Promise.resolve({ success: true, data: true });
      }
      return Promise.resolve({ success: false });
    },
  };
  const ctx = load(['js/link.js'], {
    Otzaria,
    SyncEngine: { stop: () => order.push('stop'), start: () => order.push('start') },
    RemoteLink: { shutdown: () => (order.push('shutdown'), Promise.resolve()) },
    Companion: { name: 'companion' },
  });
  return { ctx, storage, behavior, order };
}

test('מפתח חסר — החיבור הישיר, ברירת המחדל', async () => {
  const s = setup();
  assert.equal(await s.ctx.Link.load(), 'local');
});

for (const kind of ['unsuccessful', 'throws', 'empty']) {
  test('קריאה שנכשלה (' + kind + ') שומרת את הבחירה הנוכחית', async () => {
    const s = setup();
    s.storage.set('connectionMode', 'remote');
    assert.equal(await s.ctx.Link.load(), 'remote');
    s.behavior.fail = kind;
    assert.equal(await s.ctx.Link.load(), 'remote', 'נשאר מרוחק');
    assert.equal(s.ctx.Link.mode, 'remote');
  });
}

test('בדיקה תקופתית שנכשלה אינה עוצרת ואינה מחליפה את המנוע', async () => {
  const s = setup();
  s.storage.set('connectionMode', 'remote');
  await s.ctx.Link.load();
  let restarted = 0;
  s.ctx.Link.watch(() => restarted++);
  s.behavior.fail = 'unsuccessful';
  await new Promise((r) => setTimeout(r, 2300)); // סבב בדיקה אחד לפחות
  assert.deepEqual(s.order, [], 'לא נעצר ולא נפרד');
  assert.equal(restarted, 0);
  assert.equal(s.ctx.Link.mode, 'remote');
});

// בחירה שלא נשמרה אינה בחירה: `storage.set` שנכשל אינו זורק, ו-`setMode`
// שממשיך ל-`check()` קורא את הערך הישן ואינו מחליף דבר — אבל **חוזר
// בהצלחה**, והמשתמש מקבל "עברתם" על החלפה שלא נשמרה. בכשל: דחייה, והמצב,
// הערך השמור והמנוע נשארים כמו שהם.
for (const kind of ['unsuccessful', 'throws', 'empty']) {
  test('שמירה שנכשלה (' + kind + ') נדחית ואינה מחליפה את המצב', async () => {
    const s = setup();
    assert.equal(await s.ctx.Link.load(), 'local');
    s.behavior.setFail = kind;
    await assert.rejects(s.ctx.Link.setMode('remote'));
    assert.equal(s.ctx.Link.mode, 'local', 'נשאר ישיר');
    assert.equal(s.storage.has('connectionMode'), false, 'לא נשמר דבר');
    assert.deepEqual(s.order, [], 'לא נעצר ולא הופעל דבר');
  });
}

test('שמירה שנכשלה מוסרת את הודעת השגיאה של אוצריא', async () => {
  const s = setup();
  await s.ctx.Link.load();
  s.behavior.setFail = 'unsuccessful';
  await assert.rejects(s.ctx.Link.setMode('remote'), /db busy/);
});

test('שמירה שהצליחה מחליפה את המצב', async () => {
  const s = setup();
  await s.ctx.Link.load();
  let changed = null;
  s.ctx.Link.watch((next, previous) => {
    changed = [next, previous];
  });
  await s.ctx.Link.setMode('remote');
  assert.equal(s.ctx.Link.mode, 'remote');
  assert.equal(s.storage.get('connectionMode'), 'remote');
  assert.deepEqual(s.order, ['stop']);
  assert.deepEqual(changed, ['remote', 'local']);
});
