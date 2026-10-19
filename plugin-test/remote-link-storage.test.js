'use strict';

// קריאת אחסון שנכשלה (`success: false` — שגיאה פנימית או הגבלת קצב של
// אוצריא) אינה "אין ערך": היא אינה מוציאה מהחדר, אינה ממציאה מזהה מכשיר
// חדש ואינה מתחילה משולחן ריק. אינן צריכות שרת: השרת כאן אינו קיים (או
// RELAY_URL אם הוגדר), והבדיקות אינן תלויות בו.

const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./load');
const { machine, otzaria, until } = require('./fakes');

const RELAY = process.env.RELAY_URL || 'http://127.0.0.1:9';
const FILES = [
  'js/remote/sha256.js',
  'js/remote/protocol.js',
  'js/remote/hub.js',
  'js/remote/relay-transport.js',
  'js/remote/remote-link.js',
];

let clientSeq = 0;

/** מופע שקריאות `storage.get` שלו נכשלות כש-[failGet] מחזירה אמת. */
function page(host, kind, failGet) {
  const ctx = load(FILES);
  const client = 's' + ++clientSeq;
  const inner = otzaria(host);
  const call = (method, args) => {
    if (method === 'storage.get' && failGet && failGet(args.key)) {
      return Promise.resolve({ success: false, error: { code: 'error.rate_limited', message: 'rate limited' } });
    }
    return inner(method, args);
  };
  const link = ctx.RemoteLink.create({
    call,
    locks: host.locks.forClient(client),
    BroadcastChannel: null,
    relayUrl: RELAY,
  });
  link.setInstance(kind === 'background' ? 'background' : 'foreground:' + client);
  const p = { link, client, running: true, since: -1 };
  // כמו הלולאה של `SyncEngine`: `since` מתקדם, כדי ש-`events` ימתין לשינוי
  // ולא יחזור מיד בלולאה שמרעיבה את הטיימרים.
  p.loop = (async () => {
    while (p.running) {
      try {
        const state = await link.events(p.since);
        if (state.engineMine && typeof state.remoteSequence === 'number') p.since = state.remoteSequence;
        await new Promise((r) => setTimeout(r, state.engineMine ? 0 : 100));
      } catch (e) {
        await new Promise((r) => setTimeout(r, 100));
      }
    }
  })();
  p.stop = async () => {
    p.running = false;
    await link.shutdown();
  };
  return p;
}

test('קריאת הגדרות שנכשלה אינה מוציאה את המנוע מהחדר', { timeout: 20000 }, async () => {
  const host = machine();
  let failing = false;
  const p = page(host, 'background', (key) => failing && key === 'remote.config');
  try {
    await p.link.setRoom('חדר ' + Math.random().toString(36).slice(2));
    await until(() => p.link.holdsEngine && p.link.engineState().roomHash, 5000, 'בחדר');
    const roomHash = p.link.engineState().roomHash;
    failing = true;
    await new Promise((r) => setTimeout(r, 3500)); // לפחות שני סבבי תיבה
    assert.equal(p.link.engineState().roomHash, roomHash, 'עדיין באותו חדר');
    failing = false;
    await new Promise((r) => setTimeout(r, 1700));
    assert.equal(p.link.engineState().roomHash, roomHash);
  } finally {
    await p.stop();
  }
});

test('קריאת מזהה שנכשלה אינה ממציאה מזהה מכשיר חדש', { timeout: 20000 }, async () => {
  const host = machine();
  host.storage.set('remote.identity', JSON.stringify({ deviceId: 'aaaabbbbccccdddd' }));
  let failures = 3;
  const p = page(host, 'background', (key) => key === 'remote.identity' && failures-- > 0);
  try {
    await until(() => p.link.holdsEngine, 8000, 'המנוע עלה אחרי הכשלים');
    assert.ok(failures <= 0, 'הקריאה אכן נכשלה');
    assert.equal(JSON.parse(host.storage.get('remote.identity')).deviceId, 'aaaabbbbccccdddd');
    assert.equal((await p.link.hello()).deviceId, 'aaaabbbbccccdddd');
  } finally {
    await p.stop();
  }
});

test('קריאת מצב שנכשלה אינה מתחילה משולחן ריק', { timeout: 20000 }, async () => {
  const host = machine();
  const first = page(host, 'background');
  await first.link.setRoom('שולחן ' + Math.random().toString(36).slice(2));
  await until(() => first.link.holdsEngine, 5000, 'הראשון מחזיק');
  await first.link.publishDesk({ tabs: [{ b: 'ישן', i: 0 }], canClose: true });
  await first.link.carryToDesk(['ישן']);
  assert.equal(first.link.engineState().desk.length, 1);
  first.running = false;
  await first.link.releaseEngine();
  host.locks.kill(first.client);

  let failures = 2;
  const second = page(host, 'background', (key) => /^remote\.state\.\d+\./.test(key) && failures-- > 0);
  try {
    await until(() => second.link.holdsEngine, 8000, 'השני מחזיק');
    assert.ok(failures <= 0, 'הקריאה אכן נכשלה');
    assert.deepEqual(second.link.engineState().desk.map((e) => e.b), ['ישן']);
  } finally {
    await second.stop();
  }
});
