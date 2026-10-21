'use strict';

// בדיקות שילוב של החיבור המרוחק מול שרת relay אמיתי שרץ מקומית
// (`wrangler dev` מתוך relay/). כתובת השרת ב-RELAY_URL; בלעדיה הבדיקות
// מדולגות — הן אינן פונות לשרת הפרוס.
//
//   cd relay && npx wrangler dev --port 8799 --ip 127.0.0.1 --local
//   RELAY_URL=http://127.0.0.1:8799 node --test --test-force-exit plugin-test/

const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./load');
const { machine, otzaria, until, gate } = require('./fakes');

const RELAY = process.env.RELAY_URL;
const FILES = [
  'js/remote/sha256.js',
  'js/remote/protocol.js',
  'js/remote/hub.js',
  'js/remote/relay-transport.js',
  'js/remote/remote-link.js',
];

let clientSeq = 0;

/** מופע אחד של התוסף ("דף") על [host]. */
function page(host, kind, options) {
  const ctx = load(FILES);
  const client = 'c' + ++clientSeq;
  const call = otzaria(host, options);
  const link = ctx.RemoteLink.create({
    call,
    locks: host.locks.forClient(client),
    BroadcastChannel: null,
    relayUrl: RELAY,
  });
  link.setInstance(kind === 'background' ? 'background' : 'foreground:' + client);
  const p = { ctx, link, client, call, states: [], running: true, since: -1 };
  // מדמה את הלולאה של `SyncEngine`: `events` בלופ, `since` מתקדם רק אצל
  // המחזיק, והמתנה קצרה כשהמנוע אינו כאן. `{ pump: false }` — בלי לולאה:
  // מופע שמחזיק את המנוע אך אינו קורא ל-`events` כרגע.
  p.loop = options && options.pump === false ? Promise.resolve() : (async () => {
    while (p.running) {
      let state;
      try {
        state = await link.events(p.since);
      } catch (e) {
        await new Promise((r) => setTimeout(r, 100));
        continue;
      }
      if (!p.running) break;
      p.states.push(state);
      if (state.engineMine && typeof state.remoteSequence === 'number') p.since = state.remoteSequence;
      if (!state.engineMine) await new Promise((r) => setTimeout(r, 150));
    }
  })();
  p.stop = async () => {
    p.running = false;
    await link.shutdown();
  };
  /** "הדף נסגר": הנעילה משתחררת בלי שהקוד שלו מספיק לעשות דבר. */
  p.kill = () => {
    p.running = false;
    host.locks.kill(client);
  };
  return p;
}

const skip = RELAY ? false : 'RELAY_URL אינו מוגדר — אין שרת מקומי';

test('מוכנות בשני מחשבים: גרסאות והרשאות מגיעות עם זהות המנוע בפועל', { skip, timeout: 30000 }, async () => {
  const a = page(machine(), 'background');
  const b = page(machine(), 'foreground');
  const info = { pluginVersion: '7.0.0', appVersion: '0.9.98', network: true,
    syncAllowed: true, backgroundEnabled: true, engine: 'foreground' };
  a.link.setReadiness(info);
  b.link.setReadiness({ ...info, pluginVersion: '6.0.0', backgroundEnabled: false });
  const code = 'מוכנות ' + Math.random().toString(36).slice(2);
  try {
    await a.link.setRoom(code);
    await b.link.setRoom(code);
    await until(async () => (await a.link.hello()).peers.some(p => p.readiness), 15000);
    await until(async () => (await b.link.hello()).peers.some(p => p.readiness), 15000);
    const peerA = (await b.link.hello()).peers[0];
    const peerB = (await a.link.hello()).peers[0];
    assert.equal(peerA.readiness.engine, 'background');
    assert.equal(peerB.readiness.pluginVersion, '6.0.0');
    assert.equal(peerB.readiness.backgroundEnabled, false);
    assert.ok(peerA.readinessAt > 0);
  } finally { await a.stop(); await b.stop(); }
});

test('שני מחשבים בחדר אחד: נוכחות, מקום, הד ושולחן', { skip, timeout: 60000 }, async () => {
  const a = page(machine(), 'background');
  const b = page(machine(), 'foreground');
  const code = 'בדיקה ' + Math.random().toString(36).slice(2);
  try {
    await a.link.setRoom(code);
    await b.link.setRoom('  ' + code.replace(' ', '‏ ') + ' ');

    await until(async () => (await a.link.hello()).peers.length === 1, 15000, 'A רואה את B');
    await until(async () => (await b.link.hello()).peers.length === 1, 15000, 'B רואה את A');
    const helloA = await a.link.hello();
    assert.equal(helloA.relay.state, 'online');
    assert.equal(helloA.engine.owner, 'background');

    // מקום: A עובר דף, ו-B מקבל עדכון לנווט אליו — פעם אחת.
    await a.link.publish({ bookId: 'ברכות', index: 5, ref: 'ברכות ה' });
    const update = await until(
      () => b.states.find((s) => s.hasUpdate && s.remote && s.remote.location.bookId === 'ברכות'),
      10000,
      'עדכון מקום אצל B'
    );
    assert.equal(update.remote.location.index, 5);
    assert.equal(b.states.filter((s) => s.hasUpdate).length, 1);

    // ההד של הניווט אינו משודר בחזרה.
    const echo = await b.link.publish({ bookId: 'ברכות', index: 5 });
    assert.equal(echo.broadcast, false);

    // שולחן: הדיווח הראשון אינו משתף; ספר שנפתח אחריו — כן.
    await a.link.publishDesk({ tabs: [{ b: 'ברכות', i: 5 }], canClose: true });
    await b.link.publishDesk({ tabs: [], canClose: true });
    await a.link.publishDesk({ tabs: [{ b: 'ברכות', i: 5 }, { b: 'שבת', i: 2 }], canClose: true });
    const plan = await until(
      () => b.states.find((s) => s.desk && s.desk.open.some((e) => e.b === 'שבת')),
      10000,
      'תוכנית פתיחה אצל B'
    );
    assert.ok(!plan.desk.open.some((e) => e.b === 'ברכות'), 'ספר שהיה פתוח לפני ההתחברות נשאר פרטי');

    // יציאה מהחדר: B רואה פרידה, בלי להמתין לתפוגה.
    await a.link.setRoom('');
    await until(async () => (await b.link.hello()).peers.length === 0, 10000, 'B רואה את הפרידה');
  } finally {
    await a.stop();
    await b.stop();
  }
});

test('מנוע יחיד: הרקע לוקח מהלשונית, והמצב עובר איתו', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const peer = page(machine(), 'foreground');
  const tab = page(host, 'foreground');
  const code = 'מנוע ' + Math.random().toString(36).slice(2);
  let bg;
  try {
    await tab.link.setRoom(code);
    await peer.link.setRoom(code);
    await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
    await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא רואה אותנו');
    await tab.link.publishDesk({ tabs: [], canClose: true });
    await tab.link.publishDesk({ tabs: [{ b: 'פסחים', i: 1 }], canClose: true });
    await until(async () => (await tab.link.hello()).deskCount === 1, 5000, 'שולחן אצל הלשונית');
    // השמירה מושהית בשנייה; ממתינים שתיכתב.
    // המצב נשמר במפתח של תקופת המחזיק (`remote.state.<תקופה>.<אסימון>`).
    await until(
      () =>
        Array.from(host.storage.keys()).some(
          (k) => k.startsWith('remote.state.') && JSON.parse(host.storage.get(k)).state.desk.length === 1
        ),
      5000
    );

    bg = page(host, 'background');
    await until(() => bg.link.holdsEngine, 8000, 'הרקע לקח');
    await until(() => !tab.link.holdsEngine, 5000, 'הלשונית ויתרה');
    assert.ok(!(tab.link.holdsEngine && bg.link.holdsEngine), 'לעולם לא שניים');
    const state = await bg.link.hello();
    assert.equal(state.deskCount, 1, 'השולחן שוחזר במנוע החדש');
    assert.equal(state.engine.owner, 'background');
    const fromTab = await tab.link.publish({ bookId: 'פסחים', index: 3 });
    assert.equal(fromTab.engineMine, false, 'מי שאינו המחזיק אינו מדווח');

    // הלשונית מציגה את מה שהרקע כתב, כולל המחובר.
    await until(async () => (await tab.link.hello()).peers.length === 1, 15000, 'הלשונית רואה דרך האחסון');

    // הגדרה מהלשונית מגיעה למנוע שברקע.
    await tab.link.setSettings({ closePolicy: 'never' });
    await until(() => bg.link.holdsEngine && bg.states.some((s) => s.closePolicy === 'never'), 5000);
    await tab.link.setName('המחשב שלי');
    await until(async () => (await peer.link.hello()).peers.some((p) => p.name === 'המחשב שלי'), 25000, 'השם הגיע לחברותא');

    // הרקע מת — הלשונית נכנסת מעצמה, בלי פרידה ובלי תפוגה.
    bg.kill();
    await until(() => tab.link.holdsEngine, 8000, 'הלשונית חזרה');
    assert.equal((await tab.link.hello()).deskCount, 1);
  } finally {
    if (bg) bg.running = false;
    await tab.stop();
    await peer.stop();
  }
});

test('החלפת חדר פוסלת את החיבור הקודם', { skip, timeout: 60000 }, async () => {
  const a = page(machine(), 'background');
  const b = page(machine(), 'background');
  const c = page(machine(), 'background');
  const first = 'ראשון ' + Math.random().toString(36).slice(2);
  const second = 'שני ' + Math.random().toString(36).slice(2);
  try {
    await a.link.setRoom(first);
    await b.link.setRoom(first);
    await c.link.setRoom(second);
    await until(async () => (await a.link.hello()).peers.length === 1, 15000);
    await a.link.setRoom(second);
    await until(async () => (await a.link.hello()).peers.length === 1 && (await c.link.hello()).peers.length === 1, 15000, 'A בחדר השני');
    const peers = (await a.link.hello()).peers;
    const bId = (await b.link.hello()).deviceId;
    assert.ok(!peers.some((p) => p.id === bId), 'אין זכר לחדר הקודם');
    // מקום שנשלח עכשיו בחדר הראשון אינו מגיע ל-A.
    await b.link.publish({ bookId: 'עירובין', index: 9 });
    await new Promise((r) => setTimeout(r, 1500));
    assert.ok(!a.states.some((s) => s.remote && s.remote.location.bookId === 'עירובין'));
  } finally {
    await a.stop();
    await b.stop();
    await c.stop();
  }
});

test('הרשאת רשת כבויה מדווחת כחסימה ולא כ"אין שרת"', { timeout: 20000 }, async () => {
  const host = machine();
  const p = page(host, 'background', {
    denyNetwork: 'לתוסף אין הרשאת גישה לאינטרנט. ניתן להפעיל אותה בהגדרות, תחת ניהול תוספים.',
  });
  try {
    await p.link.setRoom('כלשהו');
    const state = await until(async () => {
      const s = await p.link.hello();
      return s.relay && s.relay.state === 'error' ? s : null;
    }, 8000);
    assert.equal(state.relay.errorKind, 'permission');
  } finally {
    await p.stop();
  }
});

test('מעבר לחיבור הישיר נפרד מהחדר מיד, ועוצר לפני ההחלפה', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const call = otzaria(host);
  const order = [];
  // הדף כפי שהוא באמת נטען: `Link` ו-`RemoteLink` הגלובליים, מול אוצריא
  // מדומה. בלי `navigator.locks` המנוע רץ במופע הרקע (נפילת האחורה).
  const ctx = load(FILES.concat(['js/link.js']), {
    Otzaria: { call: (m, a) => (m === 'network.fetchStream' ? call(m, Object.assign({}, a, { url: a.url.replace(/^https?:\/\/chavruta-relay\.chavruta\.workers\.dev/, RELAY) })) : call(m, a)) },
    SyncEngine: {
      stop: () => order.push('stop:' + ctx.Link.mode),
      start: () => order.push('start:' + ctx.Link.mode),
    },
  });
  const peer = page(machine(), 'background');
  const code = 'מעבר ' + Math.random().toString(36).slice(2);
  try {
    ctx.RemoteLink.setInstance('background');
    await ctx.Link.load();
    ctx.Link.watch(() => order.push('restarted:' + ctx.Link.mode));
    await ctx.Link.setMode('remote');
    await ctx.RemoteLink.setRoom(code);
    await peer.link.setRoom(code);
    // מנוע במופע הזה, כמו ש-SyncEngine היה מפעיל אותו.
    ctx.RemoteLink.events(-1);
    await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא רואה אותנו');

    await ctx.Link.setMode('local');
    await until(async () => (await peer.link.hello()).peers.length === 0, 5000, 'פרידה מיידית');
    assert.deepEqual(order, ['stop:local', 'restarted:remote', 'stop:remote', 'restarted:local']);
    assert.equal(ctx.Link.mode, 'local');
  } finally {
    await peer.stop();
  }
});

// --- רגרסיה: העברת המנוע בתוך חלון השמירה ---------------------------------

test('העברת המנוע לרקע מיד אחרי שינוי אינה מאבדת אותו', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const tab = page(host, 'foreground');
  let bg;
  try {
    await tab.link.setRoom('חלון ' + Math.random().toString(36).slice(2));
    await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
    await tab.link.publishDesk({ tabs: [{ b: 'ישן', i: 0 }], canClose: true });
    // העברה לשולחן — שינוי שאינו נגזר מדיווח הטאבים, ולכן אינו נבנה מחדש
    // בדיווח הבא אם הוא אבד.
    await tab.link.carryToDesk(['ישן']);
    assert.equal((await tab.link.hello()).deskCount, 1);
    // הרקע עולה **מיד**, בלי להמתין לשמירה.
    bg = page(host, 'background');
    await until(() => bg.link.holdsEngine, 10000, 'הרקע לקח');
    assert.equal((await bg.link.hello()).deskCount, 1, 'ההעברה לשולחן שרדה את החלפת המנוע');
  } finally {
    if (bg) await bg.stop();
    await tab.stop();
  }
});

test('מחזיק קודם שכתיבתו התעכבה אינו דורס את מצב המחזיק החדש', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const tabGate = gate();
  const tab = page(host, 'foreground', { gate: tabGate });
  let bg;
  let next;
  try {
    await tab.link.setRoom('גדר ' + Math.random().toString(36).slice(2));
    await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
    await tab.link.publishDesk({ tabs: [], canClose: true });
    // מכאן כל כתיבה של הלשונית תקועה בדרך (כמו לשונית מוקפאת).
    tabGate.close();
    await tab.link.publishDesk({ tabs: [{ b: 'של הלשונית', i: 0 }], canClose: true });
    await new Promise((r) => setTimeout(r, 1300)); // כל השהיית שמירה כבר עברה

    bg = page(host, 'background');
    await until(() => bg.link.holdsEngine, 15000, 'הרקע לקח');
    await bg.link.publishDesk({ tabs: [], canClose: true });
    await bg.link.publishDesk({ tabs: [{ b: 'של הרקע', i: 0 }], canClose: true });
    await new Promise((r) => setTimeout(r, 1300));
    // הכתיבה הישנה של הלשונית נוחתת עכשיו — אחרי הכתיבה של הרקע.
    tabGate.open();
    await new Promise((r) => setTimeout(r, 200));

    // מנוע שלישי, אחרי שהרקע נעלם: מה שהוא משחזר הוא המצב של הרקע.
    tab.running = false;
    host.locks.kill(tab.client);
    bg.kill();
    next = page(host, 'foreground');
    await until(() => next.link.holdsEngine, 10000, 'מנוע שלישי');
    const books = next.link.engineState().desk.map((e) => e.b);
    assert.deepEqual(books, ['של הרקע'], 'השולחן של הרקע, ולא של הלשונית הישנה');
  } finally {
    tabGate.open();
    if (next) await next.stop();
  }
});

// --- מסירת המנוע מהלשונית לרקע ---------------------------------------------

/** לשונית שמחזיקה את המנוע עם שולחן של ספר אחד. */
async function tabWithDesk(tab, book) {
  await tab.link.setRoom('מסירה ' + Math.random().toString(36).slice(2));
  await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
  await tab.link.publishDesk({ tabs: [], canClose: true });
  await tab.link.publishDesk({ tabs: [{ b: book, i: 0 }], canClose: true });
  await until(async () => (await tab.link.hello()).deskCount === 1, 5000, 'שולחן אצל הלשונית');
}

test('מסירה מסודרת: הלשונית משחררת בעצמה, בלי steal ובלי להמתין לתפוגה', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const tab = page(host, 'foreground');
  let bg;
  try {
    await tabWithDesk(tab, 'מגילה');
    const started = Date.now();
    bg = page(host, 'background');
    await until(() => bg.link.holdsEngine, 8000, 'הרקע לקח');
    const elapsed = Date.now() - started;
    await until(() => !tab.link.holdsEngine, 5000, 'הלשונית ויתרה');
    assert.equal(host.locks.steals, 0, 'המסירה הייתה מסודרת — לא נלקחה ב-steal');
    // סבב תיבה אחד (1.5 שניות) ועוד שמירה — הרבה לפני תפוגת 4 השניות.
    assert.ok(elapsed < 3000, 'המסירה ארכה ' + elapsed + ' מ"ש');
    assert.deepEqual(bg.link.engineState().desk.map((e) => e.b), ['מגילה'], 'השולחן עבר לרקע');
  } finally {
    if (bg) await bg.stop();
    await tab.stop();
  }
});

test('לשונית שאינה מצליחה לשמור — הרקע לוקח ב-steal אחרי התפוגה', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const tabGate = gate();
  const tab = page(host, 'foreground', { gate: tabGate });
  let bg;
  try {
    await tabWithDesk(tab, 'סוכה');
    // מכאן הלשונית אינה יכולה לסיים את השמירה, ולכן גם אינה מוסרת.
    tabGate.close();
    await tab.link.publishDesk({ tabs: [{ b: 'סוכה', i: 0 }, { b: 'ביצה', i: 0 }], canClose: true });

    const started = Date.now();
    bg = page(host, 'background');
    await new Promise((r) => setTimeout(r, 3000));
    assert.equal(bg.link.holdsEngine, false, 'לפני התפוגה הרקע עוד ממתין');
    assert.equal(tab.link.holdsEngine, true, 'והלשונית עוד מחזיקה');
    assert.equal(host.locks.steals, 0);

    await until(() => bg.link.holdsEngine, 8000, 'הרקע לקח אחרי התפוגה');
    const elapsed = Date.now() - started;
    assert.ok(elapsed >= 3900, 'נלקח אחרי ' + elapsed + ' מ"ש — לפני התפוגה');
    assert.equal(host.locks.steals, 1, 'נלקח ב-steal אחד');
    await until(() => !tab.link.holdsEngine, 5000, 'הלשונית איבדה את המנוע');
  } finally {
    tabGate.open();
    if (bg) await bg.stop();
    await tab.stop();
  }
});

/** הלשונית והחברותא (במחשב אחר) בחדר אחד. */
async function joinRoom(tab, peer, label) {
  const code = label + ' ' + Math.random().toString(36).slice(2);
  await tab.link.setRoom(code);
  await peer.link.setRoom(code);
}

test('עדכון מקום שהגיע ועוד לא נמסר לתוסף שורד את מסירת המנוע', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const peer = page(machine(), 'background');
  // הלשונית מחזיקה את המנוע אך אינה קוראת ל-`events`: העדכון נשאר ממתין.
  const tab = page(host, 'foreground', { pump: false });
  let bg;
  try {
    await joinRoom(tab, peer, 'ממתין');
    // `publishDesk` מבקש את הנעילה בלי המתנה ארוכה. `events` היה עלול לקבל
    // את הנעילה עוד לפני שחזר, להמתין לשינוי — ולמסור את העדכון בעצמו.
    await tab.link.publishDesk({ tabs: [], canClose: true });
    await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
    await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא רואה אותנו');

    await peer.link.publish({ bookId: 'יומא', index: 7 });
    await until(
      async () => {
        const remote = (await tab.link.hello()).remote;
        return remote && remote.location.bookId === 'יומא';
      },
      10000,
      'המקום הגיע למנוע שבלשונית'
    );

    bg = page(host, 'background');
    await until(() => bg.link.holdsEngine, 8000, 'הרקע לקח');
    await until(() => bg.states.some((s) => s.engineMine), 5000, 'הלולאה של הרקע קיבלה מצב');
    await new Promise((r) => setTimeout(r, 1000)); // מסירה כפולה מאוחרת הייתה נראית כאן
    const updates = bg.states.filter((s) => s.hasUpdate);
    assert.equal(updates.length, 1, 'העדכון נמסר מהרקע — פעם אחת');
    assert.equal(updates[0].remote.location.bookId, 'יומא');
    assert.equal(updates[0].remote.location.index, 7);
  } finally {
    if (bg) await bg.stop();
    await tab.stop();
    await peer.stop();
  }
});

test('עדכון מקום שהלשונית כבר מסרה אינו נמסר שוב אחרי מסירת המנוע', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const peer = page(machine(), 'background');
  const tab = page(host, 'foreground');
  let bg;
  try {
    await joinRoom(tab, peer, 'נמסר');
    await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
    await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא רואה אותנו');

    await peer.link.publish({ bookId: 'תענית', index: 4 });
    await until(
      () => tab.states.find((s) => s.hasUpdate && s.remote && s.remote.location.bookId === 'תענית'),
      10000,
      'הלשונית מסרה את העדכון'
    );

    bg = page(host, 'background');
    await until(() => bg.link.holdsEngine, 8000, 'הרקע לקח');
    await until(() => bg.states.some((s) => s.engineMine), 5000, 'הלולאה של הרקע קיבלה מצב');
    await new Promise((r) => setTimeout(r, 1000));
    assert.equal(
      bg.states.filter((s) => s.hasUpdate && s.remote && s.remote.location.bookId === 'תענית').length,
      0,
      'מה שכבר נמסר אינו נמסר שוב'
    );
  } finally {
    if (bg) await bg.stop();
    await tab.stop();
    await peer.stop();
  }
});

// --- אישור המסירה מתייחס לעדכון שבתשובה, ולא לעדכון החי ------------------

test('עדכון שהגיע בזמן ש-events כותב את התשובה נמסר בסבב הבא', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const peer = page(machine(), 'background');
  // `getHook` מעכב קריאת אחסון אחת בתוך `describe` — אחרי שנלקחה תמונת
  // המצב ולפני שהתשובה חזרה. בדיוק שם יכול להגיע עדכון נוסף.
  let armed = false;
  let release = null;
  const tab = page(host, 'foreground', {
    pump: false,
    getHook: (key) => {
      if (!armed || key !== 'remote.identity') return null;
      armed = false;
      return new Promise((r) => (release = r));
    },
  });
  try {
    await joinRoom(tab, peer, 'באמצע');
    await tab.link.publishDesk({ tabs: [], canClose: true });
    await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
    await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא רואה אותנו');
    const remoteAt = async (index) => {
      const remote = (await tab.link.hello()).remote;
      return remote && remote.location.index === index;
    };

    await peer.link.publish({ bookId: 'שבת', index: 1 });
    await until(() => remoteAt(1), 10000, 'העדכון הראשון הגיע');

    armed = true;
    const first = tab.link.events(-1);
    await until(() => release, 5000, 'events עצר בתוך describe');
    await peer.link.publish({ bookId: 'שבת', index: 2 });
    await until(() => remoteAt(2), 10000, 'העדכון השני הגיע בזמן העצירה');
    release();

    const one = await first;
    assert.equal(one.hasUpdate, true);
    assert.equal(one.remote.location.index, 1, 'התשובה נושאת את העדכון שנלקח בתמונה');
    const two = await Promise.race([
      tab.link.events(one.remoteSequence),
      new Promise((r) => setTimeout(() => r(null), 4000)),
    ]);
    assert.ok(two, 'הסבב הבא חזר מיד — העדכון השני לא נרשם כנמסר');
    assert.equal(two.hasUpdate, true);
    assert.equal(two.remote.location.index, 2);
  } finally {
    if (release) release();
    await tab.stop();
    await peer.stop();
  }
});

// --- מונה events בהעברה הלוך וחזור --------------------------------------

test('הלוך וחזור: עדכון שלא נמסר אינו מוסתר במונה ישן, ומה שנמסר אינו חוזר', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const peer = page(machine(), 'background');
  const tab = page(host, 'foreground');
  let bg;
  try {
    await joinRoom(tab, peer, 'הלוך');
    await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
    await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא רואה אותנו');

    await peer.link.publish({ bookId: 'ביצה', index: 1 });
    await until(
      () => tab.states.find((s) => s.hasUpdate && s.remote.location.index === 1),
      10000,
      'הלשונית מסרה את הראשון'
    );

    // הרקע לוקח (במסירה מסודרת) ואינו קורא ל-`events`: העדכון הבא ממתין.
    // הלולאה של הלשונית ממשיכה, עם ה-`since` מתקופת ההחזקה שלה.
    bg = page(host, 'background', { pump: false });
    await bg.link.publishDesk({ tabs: [], canClose: true });
    await until(() => bg.link.holdsEngine, 8000, 'הרקע לקח');
    const since = tab.since;

    await peer.link.publish({ bookId: 'ביצה', index: 2 });
    await until(
      () =>
        Array.from(host.storage.keys()).some((k) => {
          if (!k.startsWith('remote.state.')) return false;
          const r = JSON.parse(host.storage.get(k)).state.received;
          return r && r.location.index === 2;
        }),
      10000,
      'העדכון השני נשמר במצב של הרקע'
    );

    // **עדיין בזמן שאינה בעלים**: ה-`since` שלה לא התקדם, והעדכון לא הגיע
    // אליה. (אחרי החזרה כבר מותר לו להתקדם — שם הבדיקה הזאת הייתה ריקה.)
    assert.equal(tab.link.holdsEngine, false, 'הלשונית אינה בעלים');
    assert.equal(tab.since, since, 'ה-since לא התקדם בזמן שלא החזיקה');
    assert.ok(
      !tab.states.some((s) => s.engineMine && s.remote && s.remote.location.index === 2),
      'שום תשובת בעלים עם העדכון השני לפני החזרה'
    );

    // הרקע נעלם; הלשונית חוזרת להחזיק — אותו מופע, עם ה-`since` מהתקופה הקודמת.
    bg.kill();
    await until(() => tab.link.holdsEngine, 10000, 'הלשונית חזרה להחזיק');
    const second = await until(
      () => tab.states.find((s) => s.hasUpdate && s.remote.location.index === 2),
      6000,
      'העדכון השני נמסר אחרי החזרה'
    );
    assert.ok(second);
    await new Promise((r) => setTimeout(r, 1000));
    assert.equal(tab.states.filter((s) => s.hasUpdate && s.remote.location.index === 1).length, 1, 'הראשון לא נמסר שוב');
    assert.equal(tab.states.filter((s) => s.hasUpdate && s.remote.location.index === 2).length, 1, 'השני נמסר פעם אחת');
  } finally {
    if (bg) bg.kill();
    await tab.stop();
    await peer.stop();
  }
});

// --- תשובה של מנוע שעבר באמצע events --------------------------------------

test('events שהמנוע עבר בזמן ש-describe המתין — engineMine:false, בלי ניווט ובלי שולחן', { skip, timeout: 60000 }, async () => {
  const host = machine();
  const peer = page(machine(), 'background');
  let armed = false;
  let release = null;
  const tab = page(host, 'foreground', {
    pump: false,
    getHook: (key) => {
      if (!armed || key !== 'remote.identity') return null;
      armed = false;
      return new Promise((r) => (release = r));
    },
  });
  let bg;
  try {
    await joinRoom(tab, peer, 'עבר');
    await tab.link.publishDesk({ tabs: [], canClose: true });
    await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
    await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא רואה אותנו');

    // יש מה למסור: מקום, וספר לפתוח.
    await peer.link.publishDesk({ tabs: [], canClose: true });
    await peer.link.publishDesk({ tabs: [{ b: 'מגילה', i: 0 }], canClose: true });
    await peer.link.publish({ bookId: 'פסחים', index: 3 });
    await until(async () => {
      const h = await tab.link.hello();
      return h.deskCount === 1 && h.remote && h.remote.location.bookId === 'פסחים';
    }, 10000, 'המקום והשולחן הגיעו ללשונית');

    armed = true;
    const pending = tab.link.events(-1);
    await until(() => release, 5000, 'events עצר בתוך describe');

    bg = page(host, 'background');
    await until(() => bg.link.holdsEngine, 8000, 'הרקע לקח');
    await until(() => !tab.link.holdsEngine, 5000, 'הלשונית ויתרה');
    release();

    const stale = await pending;
    assert.equal(stale.engineMine, false, 'המופע הישן אינו בעלים');
    assert.equal(stale.hasUpdate, false, 'אין הוראת ניווט');
    assert.ok(!stale.desk || (stale.desk.open.length === 0 && stale.desk.close.length === 0), 'אין הוראות שולחן');

    // המנוע החדש מוסר את שניהם — המופע הישן לא רשם אותם כנמסרים.
    await until(
      () => bg.states.find((s) => s.hasUpdate && s.remote.location.bookId === 'פסחים'),
      10000,
      'הרקע מסר את המקום'
    );
    await until(
      () => bg.states.find((s) => s.desk && s.desk.open.some((e) => e.b === 'מגילה')),
      10000,
      'הרקע מסר את תוכנית השולחן'
    );
    await new Promise((r) => setTimeout(r, 1000));
    assert.equal(bg.states.filter((s) => s.hasUpdate).length, 1, 'המקום נמסר פעם אחת');
  } finally {
    if (release) release();
    if (bg) await bg.stop();
    await tab.stop();
    await peer.stop();
  }
});

// --- החלפת חדר באמצע events: תשובה מהתקופה שנעזבה נפסלת -------------------
//
// המנוע נשאר אותו אובייקט, ולכן בדיקת הבעלות אינה תופסת את זה. הקריאה
// מעוכבת **רק בתוך `describe`** (לפי מחסנית הקריאה): הבדיקה התקופתית של
// התיבה קוראת את אותם מפתחות, ואסור שהיא תיתפס במקום הקריאה של `events`.

/** קורא ל-`events` עד שתשובה עונה על [pred], או נכשל אחרי [ms]. */
async function eventsUntil(tab, since, pred, ms, label) {
  const deadline = Date.now() + ms;
  let from = since;
  const seen = [];
  while (Date.now() < deadline) {
    const left = deadline - Date.now();
    const r = await Promise.race([tab.link.events(from), new Promise((res) => setTimeout(() => res(null), left))]);
    if (!r) break;
    seen.push(r);
    if (pred(r)) return { hit: r, seen };
    if (r.engineMine && typeof r.remoteSequence === 'number') from = r.remoteSequence;
  }
  throw new Error('timeout: ' + label);
}

const instructs = (r) => r.hasUpdate || (r.desk && (r.desk.open.length > 0 || r.desk.close.length > 0));

async function switchDuringEvents(key, rooms) {
  const host = machine();
  const peer = page(machine(), 'background');
  let armed = false;
  let release = null;
  const tab = page(host, 'foreground', {
    pump: false,
    getHook: (k) => {
      if (!armed || k !== key || !new Error().stack.includes('describe')) return null;
      armed = false;
      return new Promise((r) => (release = r));
    },
  });
  const suffix = Math.random().toString(36).slice(2);
  const codes = { 'א': 'חדר א ' + suffix, 'ב': 'חדר ב ' + suffix };
  const s = { host, peer, tab, codes, release: () => release && release() };
  await tab.link.setRoom(codes['א']);
  await peer.link.setRoom(codes['א']);
  await tab.link.publishDesk({ tabs: [], canClose: true });
  await until(() => tab.link.holdsEngine, 5000, 'הלשונית מחזיקה');
  await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא רואה אותנו');

  // בחדר א׳: ספר לפתוח ומקום לנווט אליו — שניהם טרם נמסרו.
  await peer.link.publishDesk({ tabs: [], canClose: true });
  await peer.link.publishDesk({ tabs: [{ b: 'מגילה', i: 0 }], canClose: true });
  await peer.link.publish({ bookId: 'פסחים', index: 3 });
  await until(async () => {
    const h = await tab.link.hello();
    return h.deskCount === 1 && h.remote && h.remote.location.bookId === 'פסחים';
  }, 10000, 'המקום והשולחן של חדר א׳ הגיעו');

  armed = true;
  const pending = tab.link.events(-1);
  await until(() => release, 5000, 'events עצר בתוך describe');
  for (const room of rooms) {
    const hash = tab.ctx.RemoteProtocol.hashRoomCode(tab.ctx.RemoteProtocol.normalizeRoomCode(codes[room]));
    await tab.link.setRoom(codes[room]);
    await until(() => tab.link.engineState() && tab.link.engineState().roomHash === hash, 5000, 'המנוע עבר לחדר ' + room);
  }
  release();
  s.stale = await pending;
  // התשובה שייכת לתקופת החדר הנוכחית (נבנתה מחדש), ולא לזו שנעזבה.
  s.epochNow = (await tab.link.hello()).roomEpoch;
  return s;
}

async function teardown(s) {
  s.release();
  await s.tab.stop();
  await s.peer.stop();
}

/** בחדר הנוכחי עדכון תקין עדיין נמסר. */
async function currentRoomDelivers(s, room, since, index) {
  if (room !== 'א') {
    await s.peer.link.setRoom(s.codes[room]);
    await until(async () => (await s.peer.link.hello()).peers.length === 1, 15000, 'החברותא בחדר ' + room);
  }
  await s.peer.link.publish({ bookId: 'ראש השנה', index });
  const { hit } = await eventsUntil(
    s.tab,
    since,
    (r) => r.hasUpdate && r.remote.location.bookId === 'ראש השנה' && r.remote.location.index === index,
    15000,
    'עדכון בחדר הנוכחי נמסר'
  );
  return hit;
}

test('החלפת חדר אחרי צילום המצב ולפני סיום describe — אין הוראות מחדר א׳', { skip, timeout: 90000 }, async () => {
  const s = await switchDuringEvents('remote.identity', ['ב']);
  try {
    assert.ok(!instructs(s.stale), 'שום ניווט, פתיחה או סגירה מהחדר שנעזב: ' + JSON.stringify({ u: s.stale.hasUpdate, d: s.stale.desk }));
    assert.ok(!(s.stale.remote && s.stale.remote.location.bookId === 'פסחים'), 'המצב שבתשובה אינו של חדר א׳');
    assert.equal(s.stale.roomEpoch, s.epochNow, 'התשובה מהתקופה הנוכחית');
    await currentRoomDelivers(s, 'ב', s.stale.remoteSequence, 11);
  } finally {
    await teardown(s);
  }
});

test('החלפת חדר בין בניית תוכנית השולחן לצילום המצב — אין תוכנית ישנה עם מצב חדש', { skip, timeout: 90000 }, async () => {
  const s = await switchDuringEvents('remote.config', ['ב']);
  try {
    assert.ok(!instructs(s.stale), 'אין תוכנית מחדר א׳: ' + JSON.stringify({ u: s.stale.hasUpdate, d: s.stale.desk }));
    assert.equal(s.stale.roomEpoch, s.epochNow, 'התוכנית והמצב מאותה תקופה');
    await currentRoomDelivers(s, 'ב', s.stale.remoteSequence, 12);
  } finally {
    await teardown(s);
  }
});

test('א׳→ב׳→א׳ בזמן הקריאה — התשובה נפסלת, ומה שבחדר א׳ עכשיו עדיין נמסר', { skip, timeout: 90000 }, async () => {
  const s = await switchDuringEvents('remote.identity', ['ב', 'א']);
  try {
    // העדכון של חדר א׳ (פסחים) שייך לתקופה שנעזבה; בתקופה החדשה ההצטרפות
    // היא ראשונה ואין ניווט. תוכנית שולחן *מהתקופה הנוכחית* מותרת.
    assert.equal(s.stale.hasUpdate, false, 'אין ניווט מהתקופה הקודמת');
    assert.equal(s.stale.roomEpoch, s.epochNow, 'התשובה מהתקופה הנוכחית');
    // החברותא עדיין פותחת את "מגילה"; כשאנחנו חוזרים היא משדרת את השולחן שוב.
    // אישור מסירה מהתקופה הקודמת היה מסמן את התוכנית הזאת כ"נמסרה".
    const opensMegila = (r) => r.engineMine && r.desk && r.desk.open.some((e) => e.b === 'מגילה');
    const { hit } = opensMegila(s.stale) ? { hit: s.stale } : await eventsUntil(
      s.tab,
      s.stale.remoteSequence,
      opensMegila,
      15000,
      'תוכנית הפתיחה של התקופה הנוכחית נמסרה'
    );
    await currentRoomDelivers(s, 'א', hit.remoteSequence, 13);
  } finally {
    await teardown(s);
  }
});

// --- פקודות ממתינות שייכות לתקופת ההצטרפות שבה נוצרו -----------------------
//
// הרקע מחזיק את המנוע; הלשונית שומרת פקודות באחסון. הסבב של התיבה ברקע
// מעוכב בנקודות מדויקות: קריאת ההגדרות (לפני שהחדר החדש מוחל) וקריאת
// הפקודה עצמה. הרקע אינו קורא ל-`events` (`pump: false`), ולכן הקריאות
// היחידות שלו להגדרות ולפקודות הן של התיבה.

const CMD = 'remote.cmd.';

async function inboxHarness(label) {
  const host = machine();
  const hold = { config: false, cmd: false, remove: null, failState: false };
  const released = {};
  const bgGate = gate();
  const bg = page(host, 'background', {
    pump: false,
    gate: bgGate,
    // `hold.failState`: כל כתיבה של המצב (`remote.state.*`) נכשלת — ורק היא.
    setFail: (k) => hold.failState && k.startsWith('remote.state.'),
    // `hold.remove` = 'before' | 'after': מעכב את מחיקת הפקודה הבאה, או רק את התשובה.
    removeHook: (k) => {
      if (!hold.remove || !k.startsWith(CMD)) return null;
      const when = hold.remove;
      hold.remove = null;
      return { when, wait: new Promise((r) => (released.remove = r)) };
    },
    getHook: (k) => {
      const which = hold.config && k === 'remote.config' ? 'config' : hold.cmd && k.startsWith(CMD) ? 'cmd' : null;
      if (!which) return null;
      hold[which] = false;
      return new Promise((r) => (released[which] = r));
    },
  });
  const tab = page(host, 'foreground', { pump: false });
  const peer = page(machine(), 'background');
  const suffix = Math.random().toString(36).slice(2);
  const P = bg.ctx.RemoteProtocol;
  const h = {
    host,
    bg,
    tab,
    peer,
    hold,
    released,
    code: (room) => label + ' ' + room + ' ' + suffix,
    carries: 0,
    pendingCommands: () => Array.from(host.storage.keys()).filter((k) => k.startsWith(CMD)).length,
  };
  h.hash = (room) => P.hashRoomCode(P.normalizeRoomCode(h.code(room)));
  // סופרים ביצועי carry בכל המופעים של המחשב הזה.
  h.bgGate = bgGate;
  /** סופר ביצועי carry במופע [p] (בנפרד), וגם בסך הכול. */
  h.count = (p) => {
    p.carries = 0;
    // הביצוע עצמו: `prepareCarry` כשקיים (`carryToDesk` עובר דרכו), אחרת `carryToDesk`.
    const proto = p.ctx.RemoteHub.prototype;
    const name = proto.prepareCarry ? 'prepareCarry' : 'carryToDesk';
    const original = proto[name];
    proto[name] = function (ids) {
      h.carries++;
      p.carries++;
      return original.call(this, ids);
    };
    return p;
  };
  h.count(bg);
  h.count(tab);
  /** עוצר את הסבב הבא של התיבה ברקע בקריאת [which], וממתין שייעצר שם. */
  h.stopAt = async (which) => {
    released[which] = null;
    hold[which] = true;
    await until(() => released[which], 5000, 'התיבה נעצרה ב-' + which);
  };
  h.release = (which) => {
    hold[which] = false;
    if (released[which]) released[which]();
  };
  h.engineRoom = () => bg.link.engineState() && bg.link.engineState().roomHash;
  h.teardown = async () => {
    h.release('config');
    h.release('cmd');
    h.release('remove');
    bgGate.open();
    await bg.stop();
    await tab.stop();
    await peer.stop();
  };
  return h;
}

/** הרקע מחזיק בחדר [room] עם ספר פרטי [book]; החברותא בחדר [peerRoom]. */
async function inboxSetup(h, room, book, peerRoom) {
  await h.tab.link.setRoom(h.code(room));
  await h.bg.link.publishDesk({ tabs: [], canClose: true });
  await until(() => h.bg.link.holdsEngine, 5000, 'הרקע מחזיק');
  await until(() => h.engineRoom() === h.hash(room), 5000, 'המנוע בחדר ' + room);
  await h.bg.link.publishDesk({ tabs: [{ b: book, i: 0 }], canClose: true });
  await h.peer.link.setRoom(h.code(peerRoom));
  await h.peer.link.publishDesk({ tabs: [], canClose: true });
}

async function peerSees(peer, book) {
  const s = peer.link.engineState();
  return !!s && s.desk.some((e) => e.b === book && e.o !== false);
}

test('פקודות: carry מחדר א׳ אינו משתף ספר בחדר ב׳ — גם לא אצל החברותא שם', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('נשיאה');
  try {
    await inboxSetup(h, 'א', 'קידושין', 'ב');
    await h.stopAt('config');
    await h.tab.link.carryToDesk(['קידושין']); // נשמר בחדר א׳
    await h.tab.link.setRoom(h.code('ב'));
    h.release('config'); // הסבב מחיל את חדר ב׳, ואז מגיע לפקודה
    await until(() => h.engineRoom() === h.hash('ב'), 5000, 'המנוע בחדר ב׳');
    await until(async () => (await h.peer.link.hello()).peers.length === 1, 15000, 'החברותא בחדר ב׳ רואה אותנו');
    await until(() => h.pendingCommands() === 0, 5000, 'הפקודה טופלה');
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal(h.carries, 0, 'הפקודה הישנה לא בוצעה');
    assert.ok(!h.bg.link.engineState().desk.some((e) => e.b === 'קידושין'), 'הספר לא שותף בחדר ב׳');
    assert.equal(await peerSees(h.peer, 'קידושין'), false, 'והחברותא בחדר ב׳ אינה רואה אותו');
  } finally {
    await h.teardown();
  }
});

test('פקודות: החלפת חדר בזמן קריאת הפקודה מהאחסון — הפקודה נפסלת', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('קריאה');
  try {
    await inboxSetup(h, 'א', 'גיטין', 'א');
    await until(async () => (await h.peer.link.hello()).peers.length === 1, 15000, 'החברותא בחדר א׳');
    await h.stopAt('config');
    await h.tab.link.carryToDesk(['גיטין']);
    h.hold.cmd = true;
    h.release('config'); // הסבב קורא את חדר א׳, ונעצר בקריאת הפקודה
    await until(() => h.released.cmd, 5000, 'נעצר בקריאת הפקודה');
    await h.tab.link.setRoom(h.code('ב'));
    h.release('cmd');
    await until(() => h.pendingCommands() === 0, 5000, 'הפקודה טופלה');
    await until(() => h.engineRoom() === h.hash('ב'), 8000, 'המנוע עבר לחדר ב׳');
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal(h.carries, 0, 'הפקודה מהתקופה שנעזבה לא בוצעה');
    assert.equal(await peerSees(h.peer, 'גיטין'), false, 'החברותא בחדר א׳ לא קיבלה את הספר');
  } finally {
    await h.teardown();
  }
});

test('פקודות: dismissClose ישן אינו מבטל בקשת סגירה בחדר החדש', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('ביטול');
  try {
    await inboxSetup(h, 'א', 'נזיר', 'ב');
    await h.stopAt('config');
    await h.tab.link.dismissClose('סוטה'); // "לא לסגור" — בחדר א׳
    await h.tab.link.setRoom(h.code('ב'));
    h.hold.cmd = true;
    h.release('config'); // חדר ב׳ מוחל; הסבב נעצר בקריאת הפקודה הישנה
    await until(() => h.released.cmd, 5000, 'נעצר בקריאת הפקודה');
    await until(async () => (await h.peer.link.hello()).peers.length === 1, 15000, 'החברותא בחדר ב׳ רואה אותנו');

    // בחדר ב׳: "סוטה" משותף ופתוח אצלנו, והחברותא סוגרת אותו — בקשת סגירה.
    await h.bg.link.publishDesk({ tabs: [{ b: 'נזיר', i: 0 }, { b: 'סוטה', i: 0 }], canClose: true });
    await until(() => peerSees(h.peer, 'סוטה'), 10000, 'החברותא רואה את סוטה');
    await h.peer.link.publishDesk({ tabs: [{ b: 'סוטה', i: 0 }], canClose: true });
    await h.peer.link.publishDesk({ tabs: [], canClose: true });
    await until(
      () => h.bg.link.engineState().desk.some((e) => e.b === 'סוטה' && e.o === false),
      10000,
      'בקשת הסגירה הגיעה'
    );

    h.release('cmd');
    await until(() => h.pendingCommands() === 0, 5000, 'הפקודה טופלה');
    await new Promise((r) => setTimeout(r, 500));
    assert.ok(!h.bg.link.engineState().dismissed.includes('סוטה'), 'בקשת הסגירה בחדר ב׳ לא בוטלה');
  } finally {
    await h.teardown();
  }
});

test('פקודות: א׳→ב׳→א׳ אינו מחיה פקודה ישנה', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('חזרה');
  try {
    await inboxSetup(h, 'א', 'סנהדרין', 'א');
    await until(async () => (await h.peer.link.hello()).peers.length === 1, 15000, 'החברותא בחדר א׳');
    await h.stopAt('config');
    await h.tab.link.carryToDesk(['סנהדרין']);
    await h.tab.link.setRoom(h.code('ב'));
    await h.tab.link.setRoom(h.code('א'));
    h.release('config');
    await until(() => h.pendingCommands() === 0, 5000, 'הפקודה טופלה');
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal(h.carries, 0, 'הפקודה מהתקופה הקודמת של חדר א׳ לא קמה לתחייה');
    assert.equal(await peerSees(h.peer, 'סנהדרין'), false);
  } finally {
    await h.teardown();
  }
});

test('פקודות: העברת מנוע בלי החלפת חדר — הפקודה נשמרת ומבוצעת פעם אחת', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('העברה');
  try {
    await inboxSetup(h, 'א', 'מכות', 'א');
    await until(async () => (await h.peer.link.hello()).peers.length === 1, 15000, 'החברותא בחדר א׳');
    await h.stopAt('config'); // הרקע לא יגיע לפקודה
    await h.tab.link.carryToDesk(['מכות']);
    // הלשונית ממתינה בתור; הרקע מוותר, והלשונית מקבלת את המנוע.
    const taking = h.tab.link.publishDesk({ tabs: [{ b: 'מכות', i: 0 }], canClose: true }).catch(() => null);
    await new Promise((r) => setTimeout(r, 100));
    await h.bg.link.releaseEngine();
    await taking;
    await until(() => h.tab.link.holdsEngine, 8000, 'הלשונית מחזיקה');
    await until(() => peerSees(h.peer, 'מכות'), 10000, 'הספר שותף בחדר א׳');
    h.release('config'); // הסבב הישן של הרקע ממשיך — ואסור שיבצע שוב
    await until(() => h.pendingCommands() === 0, 5000, 'הפקודה נמחקה');
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal(h.carries, 1, 'בוצעה פעם אחת בדיוק');
  } finally {
    await h.teardown();
  }
});

// --- תקופת ההצטרפות קובעת גם את מצב המנוע ואת השחזור ----------------------
//
// ההצטרפות בחדר א׳ משאירה שולחן משותף (ספר "ברכות"), עדכון שנמסר (דף 1)
// ועדכון שעוד ממתין (דף 2). החברותא יוצאת מהחדר, כדי שאיש לא ישדר את
// השולחן מחדש — כל מה שיופיע אחר כך יכול לבוא רק מהמצב המקומי.

async function joinSetup(h) {
  await h.tab.link.setRoom(h.code('א'));
  await h.bg.link.publishDesk({ tabs: [], canClose: true });
  await until(() => h.bg.link.holdsEngine, 5000, 'הרקע מחזיק');
  await until(() => h.engineRoom() === h.hash('א'), 5000, 'המנוע בחדר א׳');
  // הדיווח הראשון של המנוע פרטי; ספר שנפתח אחריו משותף.
  await h.bg.link.publishDesk({ tabs: [], canClose: true });
  await h.bg.link.publishDesk({ tabs: [{ b: 'ברכות', i: 0 }], canClose: true });
  await h.peer.link.setRoom(h.code('א'));
  await until(async () => (await h.bg.link.hello()).peers.length === 1, 15000, 'הרקע רואה את החברותא');

  await h.peer.link.publish({ bookId: 'שבת', index: 1 });
  await until(async () => {
    const r = (await h.bg.link.hello()).remote;
    return r && r.location.index === 1;
  }, 10000, 'דף 1 הגיע');
  const delivered = await h.bg.link.events(-1);
  assert.equal(delivered.hasUpdate, true, 'דף 1 נמסר');
  await h.peer.link.publish({ bookId: 'שבת', index: 2 });
  await until(async () => {
    const r = (await h.bg.link.hello()).remote;
    return r && r.location.index === 2;
  }, 10000, 'דף 2 הגיע וממתין');
  await h.peer.link.setRoom('');
  await until(async () => (await h.bg.link.hello()).peers.length === 0, 10000, 'החברותא יצאה');

  const s = h.bg.link.engineState();
  assert.ok(s.desk.some((e) => e.b === 'ברכות' && e.o !== false), 'שולחן משותף');
  assert.equal(s.received.location.index, 2, 'עדכון ממתין');
  assert.equal(s.delivered.location.index, 1, 'אישור מסירה');
}

/** אין שאריות מההצטרפות שנעזבה. */
function assertFreshJoin(state, label) {
  assert.deepEqual(Array.from(state.desk, (e) => e.b), [], label + ': שולחן לא הוחיה');
  assert.equal(state.received, null, label + ': עדכון ממתין לא הוחיה');
  assert.equal(state.delivered.location, null, label + ': אישור מסירה לא הוחיה');
}

test('הצטרפות: א׳→ב׳→א׳ כשקריאת ההגדרות של המנוע מעוכבת — הצטרפות חדשה ונקייה', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('הצטרפות-פעיל');
  try {
    await joinSetup(h);
    await h.stopAt('config');
    await h.tab.link.setRoom(h.code('ב'));
    await h.tab.link.setRoom(h.code('א'));
    h.release('config'); // המנוע רואה רק את א׳ — אבל באסימון חדש
    await new Promise((r) => setTimeout(r, 2500)); // סבב נוסף לפחות
    assert.equal(h.engineRoom(), h.hash('א'));
    assertFreshJoin(h.bg.link.engineState(), 'מנוע פעיל');
    const r = await h.bg.link.events(-1);
    assert.equal(r.hasUpdate, false, 'אין ניווט לעדכון מההצטרפות הקודמת');
  } finally {
    await h.teardown();
  }
});

test('הצטרפות: א׳→ב׳→א׳ כשאין מחזיק מנוע — המנוע הבא אינו משחזר את ההצטרפות הקודמת', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('הצטרפות-ריק');
  let next;
  try {
    await joinSetup(h);
    await h.bg.link.releaseEngine();
    await h.tab.link.setRoom(h.code('ב'));
    await h.tab.link.setRoom(h.code('א'));
    next = page(h.host, 'background', { pump: false });
    const r = await next.link.events(-1);
    assert.equal(r.engineMine, true);
    assert.equal(r.hasUpdate, false, 'אין ניווט לעדכון מההצטרפות הקודמת');
    assertFreshJoin(next.link.engineState(), 'מנוע חדש');
  } finally {
    if (next) await next.stop();
    await h.teardown();
  }
});

test('הצטרפות: העברת מנוע באותה הצטרפות משמרת שולחן, עדכון ממתין ואישור מסירה', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('הצטרפות-אותה');
  let next;
  try {
    await joinSetup(h);
    await h.bg.link.releaseEngine();
    next = page(h.host, 'background', { pump: false });
    const state = await (async () => {
      await next.link.publishDesk({ tabs: [{ b: 'ברכות', i: 0 }], canClose: true });
      return next.link.engineState();
    })();
    assert.ok(state.desk.some((e) => e.b === 'ברכות' && e.o !== false), 'השולחן נשמר');
    assert.equal(state.received.location.index, 2, 'העדכון הממתין נשמר');
    assert.equal(state.delivered.location.index, 1, 'אישור המסירה נשמר');
    const r = await next.link.events(-1);
    assert.equal(r.hasUpdate, true, 'העדכון הממתין נמסר');
    assert.equal(r.remote.location.index, 2);
  } finally {
    if (next) await next.stop();
    await h.teardown();
  }
});

// --- פקודה אינה הולכת לאיבוד בהעברת מנוע, ואינה מבוצעת פעמיים --------------

/** הרקע מחזיק בחדר א׳ עם ספר פרטי; החברותא בחדר; הלשונית שומרת carry. */
async function commandSetup(h, book) {
  await inboxSetup(h, 'א', book, 'א');
  await until(async () => (await h.peer.link.hello()).peers.length === 1, 15000, 'החברותא בחדר א׳');
}

test('פקודה: המחיקה בוצעה, התשובה עליה מעוכבת, והבעלות עוברת — הפקודה מבוצעת פעם אחת', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('מחיקה-אחרי');
  let next;
  try {
    await commandSetup(h, 'עירובין');
    h.hold.remove = 'after';
    await h.tab.link.carryToDesk(['עירובין']);
    await until(() => h.released.remove, 5000, 'מחיקת הפקודה מעוכבת');
    assert.equal(h.pendingCommands(), 0, 'המפתח כבר נמחק באחסון');

    await h.bg.link.releaseEngine();
    next = h.count(page(h.host, 'background', { pump: false }));
    await next.link.publishDesk({ tabs: [{ b: 'עירובין', i: 0 }], canClose: true });
    await until(() => next.link.holdsEngine, 8000, 'המנוע עבר');
    h.release('remove');
    await new Promise((r) => setTimeout(r, 2000));

    assert.equal(h.carries, 1, 'בוצעה פעם אחת בדיוק');
    assert.ok(next.link.engineState().desk.some((e) => e.b === 'עירובין' && e.o !== false), 'המצב שעבר כולל את הביצוע');
    await until(() => peerSees(h.peer, 'עירובין'), 10000, 'החברותא רואה את הספר');
  } finally {
    if (next) await next.stop();
    await h.teardown();
  }
});

test('פקודה: בוצעה אך השמירה לא הספיקה לפני שהבעלות נלקחה — המנוע הבא מבצע, פעם אחת', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('שמירה-אבדה');
  let next;
  try {
    await commandSetup(h, 'פסחים');
    await h.stopAt('config');
    await h.tab.link.carryToDesk(['פסחים']);
    h.bgGate.close(); // מכאן אף שמירה של הרקע אינה מגיעה לאחסון
    h.release('config');
    await until(() => h.bg.carries === 1, 5000, 'הרקע ביצע בזיכרון');
    h.bg.kill(); // הדף מת לפני שהשמירה הגיעה

    next = h.count(page(h.host, 'background', { pump: false }));
    await next.link.publishDesk({ tabs: [{ b: 'פסחים', i: 0 }], canClose: true });
    await until(() => next.link.holdsEngine, 8000, 'המנוע עבר');
    await until(() => h.pendingCommands() === 0, 8000, 'הפקודה הושלמה ונמחקה');
    await new Promise((r) => setTimeout(r, 2000)); // עוד סבבים — בלי ביצוע נוסף
    h.bgGate.open(); // הכתיבה המאוחרת של המת נוחתת בתקופה ישנה

    assert.equal(next.carries, 1, 'במצב ששרד הפקודה בוצעה פעם אחת');
    assert.ok(next.link.engineState().desk.some((e) => e.b === 'פסחים' && e.o !== false), 'הספר משותף');
    await until(() => peerSees(h.peer, 'פסחים'), 10000, 'החברותא רואה את הספר');
  } finally {
    if (next) await next.stop();
    await h.teardown();
  }
});

test('פקודה: נשמרה כמבוצעת, והבעלות עברה לפני המחיקה — המנוע הבא אינו מבצע שוב', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('מחיקה-לפני');
  let next;
  try {
    await commandSetup(h, 'יבמות');
    h.hold.remove = 'before';
    await h.tab.link.carryToDesk(['יבמות']);
    await until(() => h.released.remove, 5000, 'המחיקה מעוכבת לפניה');
    assert.equal(h.pendingCommands(), 1, 'המפתח עדיין באחסון');

    await h.bg.link.releaseEngine();
    next = h.count(page(h.host, 'background', { pump: false }));
    await next.link.publishDesk({ tabs: [{ b: 'יבמות', i: 0 }], canClose: true });
    await until(() => next.link.holdsEngine, 8000, 'המנוע עבר');
    await until(() => h.pendingCommands() === 0, 8000, 'המנוע הבא מחק בלי לבצע');
    h.release('remove');
    await new Promise((r) => setTimeout(r, 2000));

    assert.equal(h.carries, 1, 'בוצעה פעם אחת בדיוק');
    assert.equal(next.carries, 0, 'המנוע הבא לא ביצע שוב');
    assert.ok(next.link.engineState().desk.some((e) => e.b === 'יבמות' && e.o !== false));
  } finally {
    if (next) await next.stop();
    await h.teardown();
  }
});

// --- סימון בזיכרון אינו הוכחה; ניסיון חוזר אינו גובר על החברותא ------------

/** ממתין עד [ms] ל-[predicate]; מחזיר אם התקיים (בלי להיכשל). */
async function within(predicate, ms) {
  try {
    await until(predicate, ms);
    return true;
  } catch (e) {
    return false;
  }
}

/** החברותא פותחת את [book] אצלה, וסוגרת אותו — סגירה מאוחרת לפתיחה שלנו. */
async function peerOpensAndCloses(h, book) {
  await h.peer.link.publishDesk({ tabs: [{ b: book, i: 0 }], canClose: true });
  await h.peer.link.publishDesk({ tabs: [], canClose: true });
  await until(
    () => h.peer.link.engineState().desk.some((e) => e.b === book && e.o === false),
    5000,
    'החברותא סגרה'
  );
  return h.peer.states.length;
}

/** הוראת פתיחה של [book] אצל החברותא מאז [from]. */
function peerToldToOpen(h, book, from) {
  return h.peer.states.slice(from).some((s) => s.desk && s.desk.open.some((e) => e.b === book));
}

test('פקודה: כתיבת המצב נכשלת לאורך כמה סבבים — הפקודה אינה נמחקת, ואחרי העברה התוצאה קיימת', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('כתיבה-נכשלת');
  let next;
  try {
    await commandSetup(h, 'בבא קמא');
    await h.stopAt('config');
    await h.tab.link.carryToDesk(['בבא קמא']);
    h.hold.failState = true; // מכאן כל כתיבה של remote.state נכשלת
    h.release('config');
    await until(() => h.bg.carries === 1, 5000, 'בוצעה בזיכרון');
    await new Promise((r) => setTimeout(r, 4000)); // לפחות שני סבבי תיבה (1.5 שניות)
    assert.equal(h.pendingCommands(), 1, 'הפקודה לא נמחקה — הביצוע לא נשמר');

    await h.bg.link.releaseEngine();
    next = h.count(page(h.host, 'background', { pump: false }));
    await next.link.publishDesk({ tabs: [{ b: 'בבא קמא', i: 0 }], canClose: true });
    await until(() => next.link.holdsEngine, 8000, 'המנוע עבר');
    await until(() => h.pendingCommands() === 0, 8000, 'הפקודה הושלמה');
    assert.ok(
      next.link.engineState().desk.some((e) => e.b === 'בבא קמא' && e.o !== false),
      'הפקודה והתוצאה לא נעלמו יחד'
    );
    await until(() => peerSees(h.peer, 'בבא קמא'), 10000, 'החברותא רואה את הספר');
  } finally {
    h.hold.failState = false;
    if (next) await next.stop();
    await h.teardown();
  }
});

test('פקודה: הביצוע הראשון לא נשמר, החברותא סגרה בינתיים — הניסיון החוזר אינו פותח שוב', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('ניסיון-חוזר');
  let next;
  try {
    await commandSetup(h, 'בבא מציעא');
    await until(() => h.peer.link.holdsEngine, 5000, 'החברותא מחזיקה');
    await h.stopAt('config');
    await h.tab.link.carryToDesk(['בבא מציעא']);
    h.bgGate.close(); // המצב של הרקע אינו מגיע לאחסון
    h.release('config');
    await until(() => h.bg.carries === 1, 5000, 'בוצעה בזיכרון');

    // אם הפתיחה הראשונה יצאה לפני שהביצוע נשמר — החברותא סוגרת אחריה.
    const sawFirst = await within(() => peerSees(h.peer, 'בבא מציעא'), 3000);
    const closedAt = sawFirst ? await peerOpensAndCloses(h, 'בבא מציעא') : h.peer.states.length;

    h.bg.kill(); // המנוע המקורי אובד לפני שמירת הביצוע
    next = h.count(page(h.host, 'background', { pump: false }));
    await next.link.publishDesk({ tabs: [{ b: 'בבא מציעא', i: 0 }], canClose: true });
    await until(() => next.link.holdsEngine, 8000, 'המנוע עבר');
    await until(() => h.pendingCommands() === 0, 8000, 'הפקודה הושלמה');
    await new Promise((r) => setTimeout(r, 3000));

    if (sawFirst) {
      assert.ok(
        h.peer.link.engineState().desk.some((e) => e.b === 'בבא מציעא' && e.o === false),
        'הסגירה של החברותא נשארה'
      );
      assert.equal(peerToldToOpen(h, 'בבא מציעא', closedAt), false, 'אין הוראת פתיחה חדשה');
    }
    // ומה שמבטיח את זה: פתיחה אינה משודרת לפני שהביצוע שלה נשמר. כך
    // ביצוע שאבד לא השאיר שום פעולה אצל החברותא, והניסיון החוזר הוא הראשון.
    assert.equal(sawFirst, false, 'שידור לפני שמירת הביצוע');
    assert.equal(next.carries, 1);
    await until(() => peerSees(h.peer, 'בבא מציעא'), 10000, 'הניסיון החוזר שותף');
  } finally {
    if (next) await next.stop();
    await h.teardown();
  }
});

test('פקודה: הביצוע נשמר ושודר, החברותא סגרה, והמנוע אבד לפני המחיקה — אין פתיחה חדשה', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('שודר-ונסגר');
  let next;
  try {
    await commandSetup(h, 'בבא בתרא');
    await until(() => h.peer.link.holdsEngine, 5000, 'החברותא מחזיקה');
    h.hold.remove = 'before';
    await h.tab.link.carryToDesk(['בבא בתרא']);
    await until(() => h.released.remove, 5000, 'נעצר לפני המחיקה');
    await until(() => peerSees(h.peer, 'בבא בתרא'), 10000, 'הפתיחה הגיעה לחברותא');
    const closedAt = await peerOpensAndCloses(h, 'בבא בתרא');

    h.bg.kill();
    next = h.count(page(h.host, 'background', { pump: false }));
    await next.link.publishDesk({ tabs: [{ b: 'בבא בתרא', i: 0 }], canClose: true });
    await until(() => next.link.holdsEngine, 8000, 'המנוע עבר');
    await until(() => h.pendingCommands() === 0, 8000, 'הפקודה נמחקה');
    await new Promise((r) => setTimeout(r, 3000));

    assert.equal(next.carries, 0, 'לא בוצעה שוב');
    assert.ok(
      h.peer.link.engineState().desk.some((e) => e.b === 'בבא בתרא' && e.o === false),
      'הסגירה של החברותא נשארה'
    );
    assert.equal(peerToldToOpen(h, 'בבא בתרא', closedAt), false, 'אין הוראת פתיחה חדשה');
  } finally {
    if (next) await next.stop();
    await h.teardown();
  }
});

// --- מחסום השמירה: פעולה ממתינה אינה יוצאת באף מסלול שידור ----------------

/** carry ממתין: הרקע ביצע בזיכרון, וכל כתיבה של המצב נכשלת. */
async function pendingCarryInRoom(h, book) {
  await commandSetup(h, book);
  await until(() => h.peer.link.holdsEngine, 5000, 'החברותא מחזיקה');
  await h.stopAt('config');
  await h.tab.link.carryToDesk([book]);
  h.hold.failState = true;
  h.release('config');
  await until(() => h.bg.carries === 1, 5000, 'בוצעה בזיכרון');
}

/** מחשב שלישי מצטרף לחדר א׳ של [h], וממתין שהרקע יראה אותו. */
async function thirdJoins(h) {
  const third = page(machine(), 'background');
  await third.link.setRoom(h.code('א'));
  await until(async () => (await h.bg.link.hello()).peers.length === 2, 15000, 'הרקע רואה את המצטרף');
  await until(async () => (await third.link.hello()).peers.length === 2, 15000, 'המצטרף רואה את כולם');
  return third;
}

test('מחסום שמירה: מכשיר שמצטרף בזמן שהשמירה נכשלת אינו מקבל את הספר', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('מחסום-הצטרפות');
  let third;
  try {
    await pendingCarryInRoom(h, 'ראש השנה');
    third = await thirdJoins(h); // ההצטרפות משדרת את השולחן כולו
    await new Promise((r) => setTimeout(r, 2000));
    assert.equal(await peerSees(third, 'ראש השנה'), false, 'המצטרף לא קיבל את הפעולה הממתינה');
    assert.equal(await peerSees(h.peer, 'ראש השנה'), false, 'וגם החברותא הקיימת לא');
    assert.equal(h.pendingCommands(), 1, 'הפקודה ממתינה');
  } finally {
    h.hold.failState = false;
    if (third) await third.stop();
    await h.teardown();
  }
});

test('מחסום שמירה: כשהשמירה מצליחה — הפעולה נמסרת בתוכן ובחותמת שנשמרו', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('מחסום-שחרור');
  try {
    await pendingCarryInRoom(h, 'תענית');
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal(await peerSees(h.peer, 'תענית'), false, 'לפני השמירה — לא יצאה');
    const inMemory = h.bg.link.engineState().desk.find((e) => e.b === 'תענית');

    h.hold.failState = false; // הכתיבה הבאה מצליחה
    await until(() => h.pendingCommands() === 0, 8000, 'הפקודה הושלמה');
    await until(() => peerSees(h.peer, 'תענית'), 10000, 'הפעולה נמסרה');
    const saved = Array.from(h.host.storage.keys())
      .filter((k) => k.startsWith('remote.state.'))
      .map((k) => JSON.parse(h.host.storage.get(k)).state.desk.find((e) => e.b === 'תענית'))
      .find(Boolean);
    const received = h.peer.link.engineState().desk.find((e) => e.b === 'תענית');
    assert.ok(saved, 'הפעולה במצב השמור');
    assert.deepEqual([received.s, received.w, received.o], [saved.s, saved.w, saved.o], 'מה שנמסר הוא מה שנשמר');
    assert.equal(saved.s, inMemory.s, 'אותה פעולה שהוכנה — לא פעולה חדשה');
  } finally {
    h.hold.failState = false;
    await h.teardown();
  }
});

test('מחסום שמירה: אובדן מנוע וסגירה של החברותא בין הניסיונות אינם פותחים מחדש', { skip, timeout: 90000 }, async () => {
  const h = await inboxHarness('מחסום-אובדן');
  let third;
  let next;
  try {
    await pendingCarryInRoom(h, 'מגילה');
    third = await thirdJoins(h);
    // אם הפעולה דלפה למצטרף, הוא סוגר אותה — פעולה מאוחרת של החברותא.
    const leaked = await within(() => peerSees(third, 'מגילה'), 2500);
    let closedAt = third.states.length;
    if (leaked) {
      await third.link.publishDesk({ tabs: [], canClose: true });
      await third.link.publishDesk({ tabs: [{ b: 'מגילה', i: 0 }], canClose: true });
      await third.link.publishDesk({ tabs: [], canClose: true });
      await until(() => third.link.engineState().desk.some((e) => e.b === 'מגילה' && e.o === false), 5000, 'המצטרף סגר');
      closedAt = third.states.length;
    }

    // המנוע אובד; המצב השמור אינו כולל את הביצוע. כשל הכתיבה נשאר: בכפיל
    // `kill` רק משחרר את הנעילה, והקוד של הדף "המת" היה כותב בהצלחה ברגע
    // שהכשל נפסק — דבר שדף שמת באמת אינו עושה.
    h.bg.kill();
    next = h.count(page(h.host, 'background', { pump: false }));
    await next.link.publishDesk({ tabs: [{ b: 'מגילה', i: 0 }], canClose: true });
    await until(() => next.link.holdsEngine, 8000, 'המנוע עבר');
    await until(() => h.pendingCommands() === 0, 8000, 'הפקודה הושלמה');
    await new Promise((r) => setTimeout(r, 3000));

    if (leaked) {
      assert.ok(
        third.link.engineState().desk.some((e) => e.b === 'מגילה' && e.o === false),
        'הסגירה של החברותא נשארה'
      );
      assert.ok(
        !third.states.slice(closedAt).some((s) => s.desk && s.desk.open.some((e) => e.b === 'מגילה')),
        'אין הוראת פתיחה חדשה'
      );
    }
    assert.equal(leaked, false, 'הפעולה דלפה לפני שנשמרה');
    assert.equal(next.carries, 1, 'הניסיון החוזר הוא הראשון שיצא');
    await until(() => peerSees(third, 'מגילה'), 10000, 'הספר שותף אחרי הניסיון החוזר');
  } finally {
    h.hold.failState = false;
    if (next) await next.stop();
    if (third) await third.stop();
    await h.teardown();
  }
});

// --- שידור שולחן במנות אינו זולג לחדר הבא ---------------------------------
//
// 30 ספרים משותפים בחדר א׳ — לפחות שלוש מנות. שליחת המנה הראשונה מעוכבת
// ברמת הרשת (`fetch` של אוצריא), החדר מתחלף לב׳, והשליחה משתחררת.

const THIRTY = Array.from({ length: 30 }, (_, i) => 'כרך ' + (i + 1));

test('שידור במנות: מעבר לחדר ב׳ באמצע השידור — החברותא בחדר ב׳ אינה מקבלת ספרים מחדר א׳', { skip, timeout: 90000 }, async () => {
  const host = machine();
  const held = { armed: false, release: null, watchConfig: false, configRead: false };
  const bg = page(host, 'background', {
    pump: false,
    // מסמן שהסבב של התיבה קרא את ההגדרות — כלומר המעבר לחדר החדש התחיל.
    getHook: (k) => {
      if (held.watchConfig && k === 'remote.config') held.configRead = true;
      return null;
    },
    fetch: async (url, init) => {
      const body = init && typeof init.body === 'string' ? init.body : '';
      if (held.armed && url.includes('/send') && body.includes('desk')) {
        held.armed = false;
        await new Promise((r) => (held.release = r));
      }
      return fetch(url, init);
    },
  });
  const tab = page(host, 'foreground', { pump: false });
  const peer = page(machine(), 'background');
  const suffix = Math.random().toString(36).slice(2);
  const P = bg.ctx.RemoteProtocol;
  const roomA = 'מנות א ' + suffix;
  const roomB = 'מנות ב ' + suffix;
  const engineRoom = () => bg.link.engineState() && bg.link.engineState().roomHash;
  try {
    await peer.link.setRoom(roomB);
    await tab.link.setRoom(roomA);
    await bg.link.publishDesk({ tabs: [], canClose: true });
    await until(() => bg.link.holdsEngine, 5000, 'הרקע מחזיק');
    await until(() => engineRoom() === P.hashRoomCode(P.normalizeRoomCode(roomA)), 5000, 'המנוע בחדר א׳');
    await bg.link.publishDesk({ tabs: [], canClose: true }); // הדיווח הראשון — פרטי

    held.armed = true;
    // 30 ספרים נפתחים אחרי הדיווח הראשון — משותפים, ומשודרים במנות.
    const sharing = bg.link.publishDesk({ tabs: THIRTY.map((b) => ({ b, i: 0 })), canClose: true }).catch(() => null);
    await until(() => held.release, 5000, 'המנה הראשונה מעוכבת');

    // המעבר מתחיל: הסבב קורא את ההגדרות ונפרד מחדר א׳. הפרידה ממתינה בתעבורה
    // מאחורי המנה המעוכבת, ולכן החדר מתחלף רק אחרי השחרור — באמצע השידור.
    held.watchConfig = true;
    await tab.link.setRoom(roomB);
    await until(() => held.configRead, 5000, 'הסבב קרא את חדר ב׳');
    await new Promise((r) => setTimeout(r, 300));
    held.release();
    await until(() => engineRoom() === P.hashRoomCode(P.normalizeRoomCode(roomB)), 8000, 'המנוע עבר לחדר ב׳');
    await sharing;
    await until(async () => (await peer.link.hello()).peers.length === 1, 15000, 'החברותא בחדר ב׳ רואה אותנו');
    await new Promise((r) => setTimeout(r, 2500));

    const leaked = peer.link.engineState().desk.filter((e) => THIRTY.includes(e.b)).map((e) => e.b);
    assert.deepEqual(leaked, [], 'ספרים מחדר א׳ הגיעו לחדר ב׳');
  } finally {
    if (held.release) held.release();
    await bg.stop();
    await tab.stop();
    await peer.stop();
  }
});
