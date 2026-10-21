'use strict';

// כללי המיזוג וההתנגשויות של ה-hub — אותם כללים של `SyncHub` במתאם.

const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./load');

const ctx = load(['js/remote/sha256.js', 'js/remote/protocol.js', 'js/remote/hub.js']);
const { RemoteHub, RemoteProtocol: P } = ctx;

function setup(options) {
  const sent = [];
  let clock = (options && options.now) || 1_760_000_000_000;
  // טיימרים תקופתיים נתפסים ואינם רצים; בדיקה מפעילה אותם בעצמה (`intervals`).
  const intervals = [];
  const noTimers = {
    setInterval: (f, ms) => (intervals.push({ f, ms }), intervals.length),
    clearInterval: () => {},
    setTimeout: (f, ms) => setTimeout(f, Math.min(ms, 20)),
    clearTimeout: (t) => clearTimeout(t),
  };
  const hub = new RemoteHub({
    deviceId: 'aaaa',
    deviceName: 'כאן',
    // `options.send(m)` — תשובת התעבורה להודעה (למשל הבטחה מעוכבת); ברירת מחדל: הצלחה מיד.
    transport: {
      send: (m) => (sent.push(m), options && options.send ? options.send(m) : Promise.resolve(true)),
      retarget: () => {},
      status: () => ({ state: 'online' }),
    },
    now: () => clock,
    timers: noTimers,
    // כמו `scheduleSave`: המצב נלכד ברגע השינוי — מה שלא סומן כשינוי אינו נשמר.
    onChange: () => options && options.onChange && options.onChange(hub),
  });
  return { hub, sent, intervals, tick: (ms) => (clock += ms), now: () => clock };
}

function inbound(t, type, extra) {
  return Object.assign(
    { type, roomHash: '', senderId: 'bbbb', senderName: 'שם', timestampMs: t.now(), sequence: 1, location: null, entries: [] },
    extra
  );
}

test('דיווח מוכנות מגיע לצד השני ושורד העברת מנוע בלי לרענן את הגיל שלו', async () => {
  const t = setup();
  const readiness = { pluginVersion: '7.0.0', appVersion: '0.9.98', network: true,
    syncAllowed: true, backgroundEnabled: true, engine: 'background' };
  t.hub.readiness = readiness;
  await t.hub.setRoom('קוד');
  assert.ok(t.sent.some(m => m.type === 'ready' && m.readiness.pluginVersion === '7.0.0'));
  t.hub.handleInbound(inbound(t, 'ready', { readiness }));
  const before = t.hub.snapshot().peers[0];
  t.tick(1000);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 2 }));
  const next = setup({ now: t.now() });
  await next.hub.setRoom('קוד');
  next.hub.importState(t.hub.exportState());
  const peer = next.hub.snapshot().peers[0];
  assert.equal(peer.readiness.pluginVersion, '7.0.0');
  assert.equal(peer.readinessAt, before.readinessAt);
});

test('מוכנות אינה בולעת מקום או נוכחות מאוחרים בסדר, ואינה חוזרת אחרי פרידה', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const readiness = { pluginVersion: '7.0.0', appVersion: '0.9.99', network: true,
    syncAllowed: true, backgroundEnabled: true, engine: 'background' };
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: { bookId: 'ספר', index: 0 } }));
  t.hub.handleInbound(inbound(t, 'ready', { sequence: 3, readiness }));
  t.hub.handleInbound(inbound(t, 'loc', { sequence: 2, location: { bookId: 'ספר', index: 5 } }));
  assert.equal(t.hub.snapshot().remote.location.index, 5);
  const ready = inbound(t, 'ready', { sequence: 6, readiness });
  t.hub.handleInbound(ready);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 5, location: { bookId: 'ספר', index: 9 } }));
  assert.equal(t.hub.snapshot().remote.location.index, 9);
  const receivedAt = t.hub.snapshot().peers[0].readinessAt;
  t.tick(1000);
  t.hub.handleInbound(ready);
  t.hub.handleInbound(inbound(t, 'ready', { sequence: 4, timestampMs: ready.timestampMs,
    readiness: { ...readiness, pluginVersion: 'old' } }));
  assert.equal(t.hub.snapshot().peers[0].readinessAt, receivedAt);
  assert.equal(t.hub.snapshot().peers[0].readiness.pluginVersion, '7.0.0');
  t.hub.handleInbound(inbound(t, 'bye', { sequence: 7 }));
  t.hub.handleInbound(ready);
  assert.equal(t.hub.snapshot().peers.length, 0);
});

test('פרידה שנשלחה שוב אינה מוציאה את החברותא שוב', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 5 }));
  const bye = inbound(t, 'bye', { sequence: 6 });
  t.hub.handleInbound(bye);
  t.tick(1000);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 7 }));
  t.hub.handleInbound(bye); // replay
  assert.equal(t.hub.snapshot().peers.length, 1);
});

test('פריט שולחן עם חותמת מחוץ לחלון נזרק ואינו מרעיל את השעון', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const future = t.now() + 10 * 365 * 24 * 3600 * 1000;
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('ספר', future, 'bbbb', 0, true)] }));
  assert.equal(t.hub.snapshot().deskCount, 0);
  await t.hub.publishLocalDesk([], {});
  await t.hub.publishLocalDesk([{ b: 'אחר', i: 0 }], {});
  const op = t.sent.filter((m) => m.type === 'desk').pop().entries[0];
  assert.ok(op.stamp < future, 'החותמת שלנו נשארה סבירה');
});

test('המאוחר גובר; בתיקו מכריע מזהה המכשיר', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const s = t.now();
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('ספר', s, 'bbbb', 0, true)] }));
  t.hub.handleInbound(inbound(t, 'desk', { senderId: 'cccc', entries: [P.deskEntry('ספר', s, 'cccc', 0, false)] }));
  assert.equal(t.hub.snapshot().deskCount, 0, 'cccc > bbbb בתיקו');
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('ספר', s - 1, 'zzzz', 0, true)] }));
  assert.equal(t.hub.snapshot().deskCount, 0, 'ישן יותר אינו גובר');
});

test('"לא לסגור" מוציא את הסגירה מהתוכנית, ופתיחה מחדש מחזירה את השאלה', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  await t.hub.publishLocalDesk([], { canClose: true });
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('ספר', t.now(), 'bbbb', 0, true)] }));
  await t.hub.publishLocalDesk([{ b: 'ספר', i: 0 }], { canClose: true });
  t.tick(10);
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('ספר', t.now(), 'bbbb', 0, false)] }));
  assert.equal(t.hub.deskPlan().close.length, 1);
  t.hub.dismissClose('ספר');
  assert.equal(t.hub.deskPlan().close.length, 0);
  t.tick(10);
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('ספר', t.now(), 'bbbb', 0, true)] }));
  t.tick(10);
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('ספר', t.now(), 'bbbb', 0, false)] }));
  assert.equal(t.hub.deskPlan().close.length, 1);
});

test('ספר שאינו בספרייה אינו מוצע שוב, עד שנפתח מחדש', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('חסר', t.now(), 'bbbb', 0, true)] }));
  assert.equal(t.hub.deskPlan().open.length, 1);
  await t.hub.publishLocalDesk([], { failed: ['חסר'] });
  assert.equal(t.hub.deskPlan().open.length, 0);
});

test('הד של ניווט אינו משודר; מקום אחר כן', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const loc = { bookId: 'ברכות', index: 3, ref: null };
  t.hub.handleInbound(inbound(t, 'loc', { location: loc, sequence: 2 }));
  t.hub.markHandedToPlugin(loc);
  assert.equal(await t.hub.publishLocal(loc), false);
  assert.equal(await t.hub.publishLocal({ bookId: 'ברכות', index: 4, ref: null }), true);
  t.hub.setSyncLocation(false);
  assert.equal(await t.hub.publishLocal({ bookId: 'ברכות', index: 5, ref: null }), false, 'מקום הלימוד כבוי');
});

test('המצב עובר בין מנועים, ורק לאותו חדר', async () => {
  const a = setup();
  await a.hub.setRoom('קוד');
  await a.hub.publishLocalDesk([{ b: 'ישן', i: 0 }], {});
  await a.hub.publishLocalDesk([{ b: 'ישן', i: 0 }, { b: 'חדש', i: 1 }], {});
  const saved = JSON.parse(JSON.stringify(a.hub.exportState()));

  const b = setup({ now: a.now() });
  b.hub.roomCode = 'קוד';
  assert.ok(b.hub.importState(saved));
  assert.equal(b.hub.snapshot().deskCount, 1);
  // הדיווח הבא אינו "ראשון": סגירה של ספר משותף משודרת כסגירה.
  await b.hub.publishLocalDesk([{ b: 'ישן', i: 0 }], {});
  const ops = b.sent.filter((m) => m.type === 'desk').flatMap((m) => m.entries);
  assert.deepEqual(ops.map((e) => [e.bookId, e.open]), [['חדש', false]]);

  const c = setup();
  c.hub.roomCode = 'קוד אחר';
  assert.equal(c.hub.importState(saved), false);
});

test('החלפת חדר מנקה את השולחן ונפרדת מהחדר הקודם', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  t.hub.handleInbound(inbound(t, 'desk', { entries: [P.deskEntry('ספר', t.now(), 'bbbb', 0, true)] }));
  await t.hub.setRoom('אחר');
  assert.equal(t.hub.snapshot().deskCount, 0);
  assert.equal(t.hub.snapshot().peers.length, 0);
  const bye = t.sent.find((m) => m.type === 'bye');
  assert.equal(bye.roomHash, P.hashRoomCode('קוד'), 'הפרידה נשלחה לחדר הקודם');
});

// --- רגרסיה: התאוששות למקום העדכני בלי ניווט נוסף -------------------------

test('הודעת מקום שאבדה: הנוכחות הבאה של החברותא מביאה את המקום העדכני', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const L1 = { bookId: 'ברכות', index: 1, ref: null };
  const L2 = { bookId: 'ברכות', index: 9, ref: null };
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: L1 }));
  assert.equal(t.hub.snapshot().remote, null, 'נוכחות ראשונה אינה ניווט');
  // הודעת ה-loc של L2 (רצף 2) אבדה בשרת. החברותא לא זזה שוב — רק
  // שולחת נוכחות (פעימה רגילה, או resync אחרי איפוס השרת).
  t.tick(1000);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 3, location: L2 }));
  const snap = t.hub.snapshot();
  assert.ok(snap.remote, 'המקום שוחזר מהנוכחות');
  assert.equal(snap.remote.location.index, 9);
  assert.ok(t.hub.hasFreshRemoteLocation);
});

test('ההתאוששות מהנוכחות אינה יוצרת הד או לולאת ניווט', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const L1 = { bookId: 'ברכות', index: 1, ref: null };
  const L2 = { bookId: 'ברכות', index: 9, ref: null };
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: L1 }));
  t.tick(1000);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 2, location: L2 }));
  // התוסף מנווט ל-L2; ההד חוזר כדיווח מקום מקומי ואינו משודר.
  t.hub.markHandedToPlugin(L2);
  const sentBefore = t.sent.length;
  assert.equal(await t.hub.publishLocal(L2), false);
  assert.equal(t.sent.length, sentBefore, 'שום הודעה לא יצאה בעקבות ההד');
  // הנוכחות הבאה של החברותא נושאת אותו מקום: אין עדכון חדש.
  const seq = t.hub.remoteSequence;
  t.tick(20000);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 3, location: L2 }));
  assert.equal(t.hub.remoteSequence, seq, 'אין עדכון חוזר');
  assert.equal(t.hub.hasFreshRemoteLocation, false, 'אין מה לנווט שוב');
});

test('נוכחות ישנה של החברותא אינה גוררת אחורה מי שזז זה עתה', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const theirs = { bookId: 'שבת', index: 2, ref: null };
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: theirs }));
  // אנחנו עוברים דף; ההודעה שלנו בדרך אליה.
  assert.equal(await t.hub.publishLocal({ bookId: 'שבת', index: 5, ref: null }), true);
  // הנוכחות שלה, שנשלחה לפני שקיבלה את ההודעה, נושאת מקום אחר.
  t.tick(500);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 2, location: { bookId: 'שבת', index: 3, ref: null } }));
  assert.equal(t.hub.snapshot().remote, null, 'לא נגררים חזרה');
});

test('כשמקום הלימוד כבוי, הנוכחות שלנו אינה נושאת את המקום', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  await t.hub.publishLocal({ bookId: 'שבת', index: 5, ref: null });
  t.hub.setSyncLocation(false);
  await t.hub.publishLocal({ bookId: 'שבת', index: 6, ref: null });
  await t.hub.announce();
  const hi = t.sent.filter((m) => m.type === 'hi').pop();
  assert.equal(hi.location, null);
});

// --- רגרסיה: המחוברים שורדים את החלפת המנוע --------------------------------

test('מנוע שמקבל את המצב רואה את המחוברים מיד, בלי לנווט שוב', async () => {
  const a = setup();
  await a.hub.setRoom('קוד');
  const L = { bookId: 'שבת', index: 4, ref: null };
  a.hub.handleInbound(inbound(a, 'hi', { sequence: 1, location: { bookId: 'שבת', index: 1, ref: null } }));
  a.hub.handleInbound(inbound(a, 'loc', { sequence: 2, location: L }));
  a.hub.markHandedToPlugin(L);
  // מחובר שני שנדם מזמן — אסור שיחזור לחיים.
  a.hub.handleInbound(inbound(a, 'hi', { senderId: 'cccc', senderName: 'ישן', sequence: 1 }));
  a.tick(71000);
  a.hub.handleInbound(inbound(a, 'hi', { sequence: 3, location: L }));
  const saved = JSON.parse(JSON.stringify(a.hub.exportState()));

  const b = setup({ now: a.now() + 2000 });
  b.hub.roomCode = 'קוד';
  b.hub.importState(saved);
  const peers = b.hub.snapshot().peers;
  assert.deepEqual(Array.from(peers, (p) => p.id), ['bbbb'], 'המחובר החי בלבד');
  assert.equal(b.hub.hasFreshRemoteLocation, false, 'אין ניווט חוזר אחרי ההחלפה');
  // והמקום הידוע שלו נשמר: נוכחות באותו מקום אינה "תזוזה".
  const seq = b.hub.remoteSequence;
  b.hub.handleInbound(inbound(b, 'hi', { sequence: 4, location: L }));
  assert.equal(b.hub.remoteSequence, seq);
});

// --- רגרסיה: נוכחות שנחסמה בהגנה אינה מוחקת את בסיס ההשוואה ----------------

test('נוכחות שנחסמה בזמן ההגנה — הנוכחות שאחרי ההגנה עדיין משחזרת את המקום', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const L1 = { bookId: 'ברכות', index: 1, ref: null };
  const L2 = { bookId: 'ברכות', index: 9, ref: null };
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: L1 }));
  // אנחנו זזים — ההגנה מפני גרירה אחורה מתחילה.
  assert.equal(await t.hub.publishLocal({ bookId: 'שבת', index: 3, ref: null }), true);
  // הודעת ה-loc של החברותא (L2) אבדה; הנוכחות שלה מגיעה בזמן ההגנה.
  t.tick(2000);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 3, location: L2 }));
  assert.equal(t.hub.snapshot().remote, null, 'בזמן ההגנה לא נגררים');
  // אף אחד לא זז שוב. הפעימה הבאה שלה, אחרי ההגנה, באותו מקום:
  t.tick(30000);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 4, location: L2 }));
  const snap = t.hub.snapshot();
  assert.ok(snap.remote, 'המקום שוחזר אחרי ההגנה');
  assert.equal(snap.remote.location.index, 9);
  assert.ok(t.hub.hasFreshRemoteLocation);
});

// --- רגרסיה: עדכון מרוחק שטרם נמסר שורד את החלפת המנוע ---------------------

function handover(a, nowOffset) {
  const saved = JSON.parse(JSON.stringify(a.hub.exportState()));
  const b = setup({ now: a.now() + (nowOffset || 1000) });
  b.hub.roomCode = 'קוד';
  b.hub.importState(saved);
  return b;
}

test('עדכון שהתקבל ולא נמסר לתוסף נמסר במנוע החדש', async () => {
  const a = setup();
  await a.hub.setRoom('קוד');
  const L = { bookId: 'עירובין', index: 7, ref: null };
  a.hub.handleInbound(inbound(a, 'loc', { sequence: 1, location: L }));
  assert.ok(a.hub.hasFreshRemoteLocation);
  // המנוע עובר לפני ש-`events` הספיק למסור (markHandedToPlugin לא נקרא).
  const b = handover(a);
  assert.ok(b.hub.hasFreshRemoteLocation, 'העדכון עדיין ממתין למסירה');
  assert.equal(b.hub.snapshot().remote.location.index, 7);
});

test('עדכון שכבר נמסר אינו גורם לניווט חוזר במנוע החדש — וההד שלו עדיין נבלע', async () => {
  const a = setup();
  await a.hub.setRoom('קוד');
  const L = { bookId: 'עירובין', index: 7, ref: null };
  a.hub.handleInbound(inbound(a, 'loc', { sequence: 1, location: L }));
  a.hub.markHandedToPlugin(L);
  const b = handover(a, 500);
  assert.equal(b.hub.hasFreshRemoteLocation, false, 'נמסר כבר — אין ניווט חוזר');
  assert.ok(b.hub.snapshot().remote, 'אבל המקום של החברותא עדיין מוצג');
  // ההד של הניווט מגיע למנוע החדש בתוך חלון ההד — ואינו משודר.
  const before = b.sent.length;
  assert.equal(await b.hub.publishLocal(L), false);
  assert.equal(b.sent.length, before);
});

// --- רגרסיה: ניתוק ארוך מ-peerTimeout אינו מוחק את בסיס ההתאוששות ----------

test('ניתוק ארוך מ-70 שניות ומעבר דף בזמנו — הנוכחות שאחרי החזרה משחזרת את המקום', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const L1 = { bookId: 'סנהדרין', index: 1, ref: null };
  const L2 = { bookId: 'סנהדרין', index: 8, ref: null };
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: L1 }));
  // הקשר נותק יותר מ-70 שניות; החברותא נמחקת מהמחוברים.
  t.tick(RemoteHub.PEER_TIMEOUT_MS + 5000);
  assert.equal(t.hub.snapshot().peers.length, 0, 'פג תוקף המחובר');
  // בזמן הניתוק היא עברה ל-L2, וההודעה אבדה. חוזרים לרשת; אף אחד לא זז שוב.
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 9, location: L2 }));
  const snap = t.hub.snapshot();
  assert.equal(snap.peers.length, 1, 'חזרה');
  assert.ok(snap.remote, 'המקום התאושש');
  assert.equal(snap.remote.location.index, 8);
  assert.ok(t.hub.hasFreshRemoteLocation);
});

test('אחרי ניתוק ארוך: מקום שלא השתנה אינו ניווט, ונוכחות ישנה אינה גוררת אחורה', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const L1 = { bookId: 'סנהדרין', index: 1, ref: null };
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: L1 }));
  t.tick(RemoteHub.PEER_TIMEOUT_MS + 5000);
  t.hub.snapshot();
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 2, location: L1 }));
  assert.equal(t.hub.snapshot().remote, null, 'אותו מקום — אין ניווט');
  // ניתוק נוסף, ובזמנו *אנחנו* זזים; הנוכחות הישנה שלה אינה גוררת אחורה.
  t.tick(RemoteHub.PEER_TIMEOUT_MS + 5000);
  t.hub.snapshot();
  assert.equal(await t.hub.publishLocal({ bookId: 'מכות', index: 3, ref: null }), true);
  t.tick(500);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 3, location: { bookId: 'סנהדרין', index: 2, ref: null } }));
  assert.equal(t.hub.snapshot().remote, null, 'לא נגררים חזרה');
});

test('מי שנפרד (bye) ומצטרף שוב — זו הצטרפות ראשונה, בלי ניווט', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: { bookId: 'סנהדרין', index: 1, ref: null } }));
  t.hub.handleInbound(inbound(t, 'bye', { sequence: 2 }));
  t.tick(1000);
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 3, location: { bookId: 'מכות', index: 4, ref: null } }));
  assert.equal(t.hub.snapshot().remote, null);
});

test('ניתוק ארוך שבמהלכו המנוע עובר — המקום עדיין מתאושש במנוע החדש', async () => {
  const a = setup();
  await a.hub.setRoom('קוד');
  a.hub.handleInbound(inbound(a, 'hi', { sequence: 1, location: { bookId: 'סנהדרין', index: 1, ref: null } }));
  a.tick(RemoteHub.PEER_TIMEOUT_MS + 5000);
  a.hub.snapshot();
  const b = handover(a);
  b.hub.handleInbound(inbound(b, 'hi', { sequence: 9, location: { bookId: 'סנהדרין', index: 8, ref: null } }));
  const snap = b.hub.snapshot();
  assert.ok(snap.remote, 'המקום התאושש');
  assert.equal(snap.remote.location.index, 8);
});

// --- רגרסיה: מה שנשמר הוא מה שסומן כשינוי ---------------------------------
//
// המנוע שומר מצב רק כשה-hub מודיע על שינוי (`onChange` ← `scheduleSave`).
// הבדיקות כאן מעבירות למנוע החדש את המצב **שנלכד בהודעה האחרונה** — לא
// `exportState()` טרי, שהיה מסתיר שינוי שלא דווח.

function saving(now) {
  const box = { saved: null };
  box.t = setup({
    now,
    onChange: (hub) => {
      box.saved = JSON.parse(JSON.stringify(hub.exportState()));
    },
  });
  return box;
}

function handoverSaved(box, nowOffset) {
  const b = setup({ now: box.t.now() + (nowOffset || 0) });
  b.hub.roomCode = box.t.hub.roomCode;
  b.hub.importState(box.saved);
  return b;
}

test('הגנת הנוכחות שורדת החלפת מנוע: מעבר לדף 5, החלפה, נוכחות בדף 3 אחרי 500ms', async () => {
  const box = saving();
  const t = box.t;
  await t.hub.setRoom('קוד');
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: { bookId: 'שבת', index: 2, ref: null } }));
  assert.equal(await t.hub.publishLocal({ bookId: 'שבת', index: 5, ref: null }), true);
  const b = handoverSaved(box, 500);
  b.hub.handleInbound(inbound(b, 'hi', { sequence: 2, location: { bookId: 'שבת', index: 3, ref: null } }));
  assert.equal(b.hub.snapshot().remote, null, 'המנוע החדש אינו נגרר אחורה');
  assert.equal(b.hub.hasFreshRemoteLocation, false);
});

test('חותמת מסירה מחדר קודם אינה חוסמת עדכון בחדר חדש ממחשב ששעונו מפגר בדקה', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const L = { bookId: 'שבת', index: 2, ref: null };
  t.hub.handleInbound(inbound(t, 'loc', { sequence: 1, location: L }));
  t.hub.markHandedToPlugin(L, t.hub.snapshot().remote.updateId);
  await t.hub.setRoom('חדר אחר');
  t.tick(1000);
  t.hub.handleInbound(
    inbound(t, 'loc', { senderId: 'cccc', sequence: 1, timestampMs: t.now() - 60000, location: { bookId: 'ביצה', index: 4, ref: null } })
  );
  assert.ok(t.hub.hasFreshRemoteLocation, 'העדכון בחדר החדש ממתין למסירה');
  assert.equal(t.hub.snapshot().remote.location.index, 4);
});

test('עדכונים נפרדים באותה חותמת זמן — כל אחד נמסר', async () => {
  const t = setup();
  await t.hub.setRoom('קוד');
  const T = t.now();
  const A = { bookId: 'שבת', index: 2, ref: null };
  t.hub.handleInbound(inbound(t, 'loc', { sequence: 1, timestampMs: T, location: A }));
  t.hub.markHandedToPlugin(A, t.hub.snapshot().remote.updateId);
  // מחשב אחר, אותה אלפית שנייה.
  t.hub.handleInbound(inbound(t, 'loc', { senderId: 'cccc', sequence: 1, timestampMs: T, location: { bookId: 'ביצה', index: 4, ref: null } }));
  assert.ok(t.hub.hasFreshRemoteLocation, 'עדכון ממחשב אחר באותה חותמת');
  t.hub.markHandedToPlugin({ bookId: 'ביצה', index: 4, ref: null }, t.hub.snapshot().remote.updateId);
  // אותו מחשב, הודעה הבאה, אותה חותמת (שעון ברזולוציה גסה).
  t.hub.handleInbound(inbound(t, 'loc', { senderId: 'cccc', sequence: 2, timestampMs: T, location: { bookId: 'ביצה', index: 6, ref: null } }));
  assert.ok(t.hub.hasFreshRemoteLocation, 'הודעה נוספת מאותו מחשב באותה חותמת');
  assert.equal(t.hub.snapshot().remote.location.index, 6);
});

test('timeout, פרידה, החלפת מנוע והצטרפות מחדש — הצטרפות ראשונה', async () => {
  const box = saving();
  const t = box.t;
  await t.hub.setRoom('קוד');
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1, location: { bookId: 'סנהדרין', index: 1, ref: null } }));
  t.tick(RemoteHub.PEER_TIMEOUT_MS + 5000);
  assert.equal(t.hub.snapshot().peers.length, 0, 'פג תוקף');
  // הפרידה מגיעה כשהמכשיר כבר אינו ברשימה.
  t.hub.handleInbound(inbound(t, 'bye', { sequence: 2 }));
  const b = handoverSaved(box, 1000);
  b.hub.handleInbound(inbound(b, 'hi', { sequence: 3, location: { bookId: 'מכות', index: 4, ref: null } }));
  assert.equal(b.hub.snapshot().remote, null, 'אין ניווט בהצטרפות מחדש');
});

// --- רגרסיה: סימון "בוצעה" ותוצאת הפקודה נשמרים יחד ------------------------

test('כל מצב שנשמר מכיל גם את סימון הפקודה וגם את תוצאתה — או אף אחד מהם', async () => {
  const states = [];
  const t = setup({ onChange: (hub) => states.push(JSON.parse(JSON.stringify(hub.exportState()))) });
  await t.hub.setRoom('קוד');
  await t.hub.publishLocalDesk([{ b: 'ביצה', i: 0 }], { canClose: true }); // דיווח ראשון — פרטי
  states.length = 0;
  t.hub.markCommandDone('remote.cmd.1');
  await t.hub.carryToDesk(['ביצה']);
  assert.ok(states.length > 0, 'השינוי נשמר');
  for (const s of states) {
    const done = s.doneCommands.includes('remote.cmd.1');
    const shared = s.desk.some((e) => e.b === 'ביצה' && e.o !== false);
    assert.equal(done, shared, 'סימון בלי תוצאה (או להפך) במצב שנשמר');
  }
});

// --- רגרסיה: התור היוצא של פקודות ----------------------------------------

test('prepareCarry אינו משדר, וכל מצב שנשמר מכיל את הפעולה גם בשולחן וגם בתור', async () => {
  const states = [];
  const t = setup({ onChange: (hub) => states.push(JSON.parse(JSON.stringify(hub.exportState()))) });
  await t.hub.setRoom('קוד');
  await t.hub.publishLocalDesk([{ b: 'ביצה', i: 0 }], { canClose: true });
  const before = t.sent.filter((m) => m.type === 'desk').length;
  states.length = 0;
  t.hub.markCommandDone('remote.cmd.1');
  assert.equal(t.hub.prepareCarry(['ביצה']), 1);
  assert.equal(t.sent.filter((m) => m.type === 'desk').length, before, 'לא שודר לפני השמירה');
  for (const s of states) {
    const inDesk = s.desk.find((e) => e.b === 'ביצה' && e.o);
    const inOutbox = s.outbox.find((e) => e.b === 'ביצה');
    assert.ok(inDesk && inOutbox && inDesk.s === inOutbox.s, 'הפעולה בשולחן ובתור, באותה חותמת');
  }
  const savedStamp = states[states.length - 1].outbox[0].s;
  t.hub.confirmSaved(states[states.length - 1]); // המצב הזה נכתב — רק עכשיו מותר לשדר
  await t.hub.flushOutbox();
  const desk = t.sent.filter((m) => m.type === 'desk').pop();
  assert.equal(desk.entries[0].stamp, savedStamp, 'שודרה בדיוק הפעולה שנשמרה');
  assert.equal(t.hub.outboxSize, 0);
});

test('תור יוצא משוחזר אינו משדר פעולה שסגירה מאוחרת של החברותא גברה עליה', async () => {
  const a = setup();
  await a.hub.setRoom('קוד');
  await a.hub.publishLocalDesk([{ b: 'ביצה', i: 0 }], { canClose: true });
  a.hub.prepareCarry(['ביצה']);
  const op = a.hub.exportState().outbox[0];
  // החברותא סגרה אחרי הפתיחה שלנו (חותמת מאוחרת), לפני שהמנוע עבר.
  a.tick(10);
  a.hub.handleInbound(inbound(a, 'desk', { entries: [P.deskEntry('ביצה', op.s + 1000, 'bbbb', 0, false)] }));
  const b = handover(a);
  assert.equal(b.hub.outboxSize, 0, 'הפעולה שנדרסה אינה בתור');
  await b.hub.flushOutbox();
  assert.equal(b.sent.filter((m) => m.type === 'desk').length, 0, 'שום פתיחה לא שודרה');
  assert.equal(b.hub.snapshot().deskCount, 0, 'הספר נשאר סגור');
});

// --- רגרסיה: פעולה שממתינה לשמירה אינה יוצאת באף מסלול שידור ---------------
//
// כל מי שמשדר מהשולחן: הצטרפות מכשיר (`_broadcastDesk`), `resync`, הסנכרון
// התקופתי (`_resyncDesk`), דיווח טאבים ו-`flushOutbox`. הפעולה של `prepareCarry`
// נמצאת בשולחן כבר מרגע ההכנה — ואסור שתצא לפני שהמצב שמכיל אותה נכתב.

async function pendingCarry() {
  const t = setup();
  await t.hub.setRoom('קוד');
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1 })); // חברותא מחוברת
  await t.hub.publishLocalDesk([{ b: 'ביצה', i: 0 }, { b: 'סוכה', i: 0 }], { canClose: true }); // דיווח ראשון — פרטי
  await t.hub.publishLocalDesk([{ b: 'ביצה', i: 0 }, { b: 'סוכה', i: 0 }, { b: 'שבת', i: 0 }], { canClose: true }); // "שבת" נפתח — משותף ונשמר
  assert.equal(t.hub.prepareCarry(['ביצה']), 1);
  t.sent.length = 0;
  return t;
}

const sentBooks = (t) => t.sent.filter((m) => m.type === 'desk').flatMap((m) => m.entries.map((e) => e.bookId));

test('פעולה ממתינה לשמירה: הצטרפות מכשיר אינה משדרת אותה', async () => {
  const t = await pendingCarry();
  t.hub.handleInbound(inbound(t, 'hi', { senderId: 'cccc', senderName: 'חדש', sequence: 1 }));
  await new Promise((r) => setImmediate(r));
  assert.ok(sentBooks(t).includes('שבת'), 'השולחן שודר למצטרף');
  assert.ok(!sentBooks(t).includes('ביצה'), 'אבל בלי הפעולה הממתינה');
});

test('פעולה ממתינה לשמירה: resync אינו משדר אותה', async () => {
  const t = await pendingCarry();
  await t.hub.resync();
  assert.ok(sentBooks(t).includes('שבת'));
  assert.ok(!sentBooks(t).includes('ביצה'));
});

test('פעולה ממתינה לשמירה: הסנכרון התקופתי אינו משדר אותה', async () => {
  const t = await pendingCarry();
  await t.hub.start();
  const periodic = t.intervals.find((i) => i.ms === 60000);
  assert.ok(periodic, 'יש סנכרון שולחן תקופתי');
  t.sent.length = 0;
  await periodic.f();
  assert.ok(sentBooks(t).includes('שבת'));
  assert.ok(!sentBooks(t).includes('ביצה'));
});

test('פעולה ממתינה לשמירה: flushOutbox ודיווח טאבים אינם משדרים אותה', async () => {
  const t = await pendingCarry();
  await t.hub.flushOutbox();
  await t.hub.publishLocalDesk([{ b: 'ביצה', i: 0 }, { b: 'סוכה', i: 0 }, { b: 'שבת', i: 0 }, { b: 'יומא', i: 0 }], { canClose: true });
  assert.ok(sentBooks(t).includes('יומא'), 'דיווח הטאבים שודר');
  assert.ok(!sentBooks(t).includes('ביצה'));
  assert.equal(t.hub.outboxSize, 1, 'הפעולה עדיין בתור');
});

test('אחרי שהשמירה הצליחה — הפעולה יוצאת בתוכן ובחותמת שנשמרו, בכל מסלול', async () => {
  const t = await pendingCarry();
  const saved = JSON.parse(JSON.stringify(t.hub.exportState())); // "נכתב לאחסון"
  t.hub.confirmSaved(saved);
  const op = saved.outbox[0];
  await t.hub.flushOutbox();
  const flushed = t.sent.filter((m) => m.type === 'desk').flatMap((m) => m.entries).find((e) => e.bookId === 'ביצה');
  assert.deepEqual([flushed.bookId, flushed.stamp, flushed.by, flushed.open], [op.b, op.s, op.w, op.o]);
  t.sent.length = 0;
  await t.hub.resync();
  const again = t.sent.filter((m) => m.type === 'desk').flatMap((m) => m.entries).find((e) => e.bookId === 'ביצה');
  assert.equal(again.stamp, op.s, 'גם resync — באותה חותמת');
});

test('אישור שמירה ישן אינו משחרר פעולה שנוספה אחריו', async () => {
  const t = await pendingCarry();
  const before = JSON.parse(JSON.stringify(t.hub.exportState()));
  await t.hub.publishLocalDesk([{ b: 'ביצה', i: 0 }, { b: 'סוכה', i: 0 }, { b: 'שבת', i: 0 }], { canClose: true });
  t.hub.prepareCarry(['סוכה']); // אחרי שהמצב "נלכד" לכתיבה
  t.hub.confirmSaved(before);
  t.sent.length = 0;
  await t.hub.resync();
  assert.ok(sentBooks(t).includes('ביצה'), 'מה שנכתב — יוצא');
  assert.ok(!sentBooks(t).includes('סוכה'), 'מה שלא נכתב — לא');
});

// --- רגרסיה: שידור שולחן במנות קשור לתקופת החדר שבה התחיל -------------------

const BOOKS = Array.from({ length: 30 }, (_, i) => 'ספר-' + (i + 1));

/** hub שהמנה הראשונה של השידור הבא מתעכבת אצלו עד `release()`. */
async function heldDesk(source) {
  const box = { holding: false, release: null };
  const t = setup({
    send: (m) => {
      if (!box.holding || m.type !== 'desk') return Promise.resolve(true);
      box.holding = false;
      return new Promise((r) => (box.release = () => r(true)));
    },
  });
  await t.hub.setRoom('א');
  t.hub.handleInbound(inbound(t, 'hi', { sequence: 1 }));
  const tabs = BOOKS.map((b) => ({ b, i: 0 }));
  if (source === 'carry') {
    await t.hub.publishLocalDesk(tabs, { canClose: true }); // דיווח ראשון — פרטי
  } else {
    // סנכרון שולחן מלא: 30 ספרים משותפים כבר בשולחן.
    t.hub.handleInbound(inbound(t, 'desk', { sequence: 2, entries: BOOKS.map((b) => P.deskEntry(b, t.now(), 'bbbb', 0, true)) }));
  }
  t.sent.length = 0;
  box.holding = true;
  box.t = t;
  box.run = source === 'carry' ? t.hub.carryToDesk(BOOKS) : t.hub.resync();
  await until(() => box.release, 2000, 'המנה הראשונה מעוכבת');
  return box;
}

const until = async (predicate, ms, label) => {
  const deadline = Date.now() + ms;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('timeout: ' + label);
    await new Promise((r) => setTimeout(r, 5));
  }
};

const deskMessages = (t) => t.sent.filter((m) => m.type === 'desk');
const booksIn = (messages) => messages.flatMap((m) => m.entries.map((e) => e.bookId)).filter((b) => BOOKS.includes(b));

for (const source of ['carry', 'resync']) {
  test('שידור במנות (' + source + '): ללא החלפת חדר — כל המנות נמסרות', async () => {
    const box = await heldDesk(source);
    box.release();
    await box.run;
    const messages = deskMessages(box.t).filter((m) => booksIn([m]).length > 0);
    assert.ok(messages.length >= 3, 'לפחות שלוש מנות (' + messages.length + ')');
    assert.deepEqual(booksIn(messages).sort(), BOOKS.slice().sort(), 'כל הספרים, פעם אחת');
  });

  test('שידור במנות (' + source + '): א׳→ב׳ באמצע — אין ספרים ישנים בחדר ב׳', async () => {
    const box = await heldDesk(source);
    await box.t.hub.setRoom('ב');
    box.release();
    await box.run;
    const inB = deskMessages(box.t).filter((m) => m.roomHash === P.hashRoomCode('ב'));
    assert.deepEqual(booksIn(inB), [], 'שום ספר מחדר א׳ לא נשלח לחדר ב׳');
    assert.equal(deskMessages(box.t).length, 1, 'רק המנה שכבר יצאה');
  });

  test('שידור במנות (' + source + '): א׳→ב׳→א׳ באמצע — המנות מהתקופה הקודמת אינן ממשיכות', async () => {
    const box = await heldDesk(source);
    await box.t.hub.setRoom('ב');
    await box.t.hub.setRoom('א');
    const before = box.t.sent.length;
    box.release();
    await box.run;
    assert.deepEqual(booksIn(deskMessages({ sent: box.t.sent.slice(before) })), [], 'שום מנה ישנה אחרי החזרה');
  });
}
