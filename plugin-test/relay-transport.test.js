'use strict';

// התעבורה מול שרת מדומה, כדי לבדוק במדויק את מה שקשה לייצר מול שרת
// אמיתי: שרת שהתאפס, שרת ששכח הודעות, תשובה שמגיעה אחרי החלפת חדר,
// ושרת שנעלם וחוזר.

const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./load');
const { fetchStream, until } = require('./fakes');

const ctx = load(['js/remote/sha256.js', 'js/remote/protocol.js', 'js/remote/relay-transport.js']);
const { RelayTransport, RemoteProtocol } = ctx;
const CODE = 'קוד בדיקה';
const ROOM = RemoteProtocol.hashRoomCode(CODE);

/** שרת relay בזיכרון, באותה התנהגות של relay/src/room.js. */
function fakeServer() {
  const s = {
    seq: 0,
    log: [],
    keep: 100,
    waiters: [],
    down: false,
    polls: [],
    /** מדמה פליטה של החדר: הכל נשכח והמונה מתחיל מאפס. */
    reset() {
      s.seq = 0;
      s.log = [];
    },
    post(body) {
      s.seq++;
      s.log.push({ n: s.seq, body });
      if (s.log.length > s.keep) s.log.splice(0, s.log.length - s.keep);
      s.waiters.splice(0).forEach((w) => w());
    },
    async fetch(url, init) {
      if (s.down) throw new Error('connect ECONNREFUSED');
      const u = new URL(url);
      if (u.pathname.endsWith('/send')) {
        s.post(init.body);
        return new Response(JSON.stringify({ next: s.seq }));
      }
      s.polls.push(u.pathname);
      const raw = Number(u.searchParams.get('since'));
      const since = raw >= 0 ? raw : s.seq;
      const wait = Number(u.searchParams.get('wait'));
      const collect = () => s.log.filter((m) => m.n > since).map((m) => m.body);
      let found = collect();
      if (found.length === 0 && wait > 0) {
        await new Promise((resolve) => {
          const t = setTimeout(resolve, 300);
          s.waiters.push(() => {
            clearTimeout(t);
            resolve();
          });
          if (init.signal) init.signal.addEventListener('abort', resolve);
        });
        found = collect();
      }
      return new Response(JSON.stringify({ next: s.seq, messages: found }));
    },
  };
  return s;
}

function message(senderId, seq, location) {
  return {
    type: location ? 'loc' : 'hi',
    roomHash: ROOM,
    senderId,
    senderName: senderId,
    timestampMs: Date.now(),
    sequence: seq,
    location: location || null,
    entries: [],
  };
}

function transport(server, extra) {
  const got = [];
  let resyncs = 0;
  const t = new RelayTransport(
    Object.assign(
      {
        baseUrl: 'http://relay.test',
        fetchStream: (params) => fetchStream((url, init) => server.fetch(url, init), params),
        roomCode: () => CODE,
        selfId: () => 'me',
        onMessage: (m) => got.push(m),
        onResync: () => {
          resyncs++;
        },
      },
      extra || {}
    )
  );
  t.got = got;
  t.resyncs = () => resyncs;
  return t;
}

test('הודעה תקינה נמסרת; הודעה זרה נספרת כדחייה', async () => {
  const server = fakeServer();
  const t = transport(server);
  t.start();
  t.retarget(ROOM);
  await until(() => t.status().state === 'online');
  server.post(RemoteProtocol.encode(message('other', 1, { bookId: 'ברכות', index: 2, ref: null }), CODE));
  server.post(RemoteProtocol.encode(message('other', 2), 'קוד אחר'));
  await until(() => t.got.length === 1 && t.status().rejected === 1);
  assert.equal(t.got[0].location.bookId, 'ברכות');
  t.stop();
});

test('שרת שהתאפס: קוראים מההתחלה ומשדרים מחדש את המצב', async () => {
  const server = fakeServer();
  const t = transport(server);
  t.start();
  t.retarget(ROOM);
  await until(() => t.status().state === 'online');
  for (let i = 1; i <= 5; i++) server.post(RemoteProtocol.encode(message('other', i), CODE));
  await until(() => t.got.length === 5);
  server.reset();
  // הודעה שנשלחה אחרי האיפוס ממוספרת 1 — מתחת ל-since של הלקוח.
  server.post(RemoteProtocol.encode(message('other', 6, { bookId: 'שבת', index: 1, ref: null }), CODE));
  server.waiters.splice(0).forEach((w) => w());
  await until(() => t.got.some((m) => m.location && m.location.bookId === 'שבת'), 5000, 'הודעה שאחרי האיפוס');
  assert.equal(t.status().serverResets, 1);
  assert.equal(t.resyncs(), 1);
  t.stop();
});

test('שרת ששכח הודעות: הפער מזוהה ומשדרים מחדש', async () => {
  const server = fakeServer();
  server.keep = 3;
  const t = transport(server);
  t.start();
  t.retarget(ROOM);
  await until(() => t.status().state === 'online');
  t.stop(); // בזמן שאיננו מאזינים נשלחות יותר הודעות ממה שהשרת זוכר
  const since = server.seq;
  for (let i = 1; i <= 8; i++) server.post(RemoteProtocol.encode(message('other', i), CODE));
  // חוזרים לאותו מונה, כמו לקוח שהבקשה שלו פשוט התעכבה.
  t._running = true;
  t.generation++;
  t._since = since;
  t._loop(t.generation, ROOM);
  await until(() => t.status().historyGaps === 1, 5000, 'זיהוי פער');
  assert.equal(t.resyncs(), 1);
  assert.equal(t.got.length, 3, 'רק מה שהשרת זכר');
  t.stop();
});

test('תשובה מחדר קודם נזרקת, והבקשה הפתוחה מבוטלת', async () => {
  const server = fakeServer();
  let release;
  const gate = new Promise((r) => (release = r));
  let pendingPolls = 0;
  const slow = Object.assign({}, server, {
    async fetch(url, init) {
      const u = new URL(url);
      if (pendingPolls === 0 && u.pathname.includes('/poll') && Number(u.searchParams.get('wait')) > 0) {
        pendingPolls++;
        await gate; // התשובה מתעכבת עד אחרי ההחלפה
        return new Response(
          JSON.stringify({ next: 99, messages: [RemoteProtocol.encode(message('old', 1, { bookId: 'ישן', index: 1, ref: null }), CODE)] })
        );
      }
      return server.fetch(url, init);
    },
  });
  const t = transport(slow);
  t.start();
  t.retarget(ROOM);
  await until(() => pendingPolls === 1, 3000, 'בקשת המתנה פתוחה');
  const before = t.generation;
  t.retarget(RemoteProtocol.hashRoomCode('חדר חדש'));
  assert.ok(t.generation > before);
  release();
  await new Promise((r) => setTimeout(r, 200));
  assert.ok(!t.got.some((m) => m.location && m.location.bookId === 'ישן'), 'שום הודעה מהחדר הקודם');
  t.stop();
});

test('שרת שנעלם: מצב שגיאת רשת, וחזרה לבד כשהוא חוזר', async () => {
  const server = fakeServer();
  server.down = true;
  const t = transport(server);
  t.start();
  t.retarget(ROOM);
  await until(() => t.status().state === 'error', 3000);
  assert.equal(t.status().errorKind, 'network');
  server.down = false;
  await until(() => t.status().state === 'online', 8000, 'חזרה אחרי ניתוק');
  await until(() => t.resyncs() > 0, 1000, 'הנוכחות והשולחן משודרים מחדש מיד');
  t.stop();
});

test('חסימה של אוצריא מסווגת לפי הטקסט', () => {
  assert.equal(RelayTransport.classify('הכתובת אינה ברשימת ההיתר לגישת רשת של תוספים'), 'allowlist');
  assert.equal(RelayTransport.classify('error.permission_denied: לתוסף אין הרשאת גישה לאינטרנט'), 'permission');
  assert.equal(RelayTransport.classify('Network stream timed out'), 'timeout');
  assert.equal(RelayTransport.classify('SocketException: connection refused'), 'network');
});

test('שני צדדים שנכנסו יחד רואים זה את זה בלי להמתין לפעימה הבאה', async () => {
  const server = fakeServer();
  const sides = ['a', 'b'].map((id) => {
    const box = {};
    box.t = transport(server, {
      selfId: () => id,
      // כמו ה-hub: הכרזת נוכחות כשהסמן נקבע.
      onJoined: () => box.t.send(message(id, (box.seq = (box.seq || 0) + 1))),
    });
    return box;
  });
  // שני הצדדים מכריזים לפני שלמי מהם יש סמן — ההכרזות האלה מדולגות.
  for (const s of sides) {
    s.t.start();
    s.t.send(message(s.t.selfIdValue(), 100));
  }
  await new Promise((r) => setTimeout(r, 30));
  for (const s of sides) s.t.retarget(ROOM);
  await until(
    () => sides.every((s) => s.t.got.some((m) => m.senderId !== s.t.selfIdValue())),
    3000,
    'כל צד שמע את השני'
  );
  sides.forEach((s) => s.t.stop());
});

// --- רגרסיה: עבודה ישנה אחרי עצירה, החלפת חדר או אובדן בעלות --------------

/** שרת ששליחה אליו נתקעת עד שפותחים את השער. */
function gatedSends(server) {
  const posted = [];
  let release;
  const opened = new Promise((r) => (release = r));
  const gated = Object.assign({}, server, {
    async fetch(url, init) {
      const u = new URL(url);
      if (u.pathname.endsWith('/send')) {
        await opened;
        posted.push({ path: u.pathname, body: JSON.parse(init.body) });
        server.post(init.body);
        return new Response(JSON.stringify({ next: server.seq }));
      }
      return server.fetch(url, init);
    },
  });
  return { gated, posted, release };
}

test('עצירה כשיש שליחה פעילה ושליחה בתור: שום דבר לא יוצא אחריה, והמצב אינו "מחובר"', async () => {
  const server = fakeServer();
  const g = gatedSends(server);
  const t = transport(g.gated);
  t.start();
  t.retarget(ROOM);
  await until(() => t.status().state === 'online');
  const first = t.send(message('me', 1));
  const second = t.send(message('me', 2));
  await new Promise((r) => setTimeout(r, 30)); // הראשונה פעילה, השנייה בתור
  t.stop();
  assert.equal(t.status().state, 'idle');
  g.release();
  const results = await Promise.allSettled([first, second]);
  await new Promise((r) => setTimeout(r, 100));
  assert.ok(!g.posted.some((p) => p.body.seq === 2), 'השליחה שבתור לא יצאה');
  assert.equal(t.status().state, 'idle', 'השלמה ישנה אינה מחזירה "מחובר"');
  assert.notEqual(results[1].status === 'fulfilled' && results[1].value, true);
});

test('החלפת חדר פוסלת שליחה שבתור לחדר הקודם — חוץ מפרידה מכוונת', async () => {
  const server = fakeServer();
  const g = gatedSends(server);
  const t = transport(g.gated);
  const OTHER = RemoteProtocol.hashRoomCode('חדר אחר');
  t.start();
  t.retarget(ROOM);
  await until(() => t.status().state === 'online');
  t.send(message('me', 1)); // פעילה
  t.send(message('me', 2)); // בתור — שייכת לחדר הקודם
  const bye = Object.assign(message('me', 3), { type: 'bye' });
  const farewell = t.send(bye, { farewell: true });
  await new Promise((r) => setTimeout(r, 30));
  t.retarget(OTHER);
  g.release();
  await farewell;
  await new Promise((r) => setTimeout(r, 100));
  assert.ok(!g.posted.some((p) => p.body.seq === 2), 'שליחה רגילה לחדר הקודם בוטלה');
  const sentBye = g.posted.find((p) => p.body.t === 'bye');
  assert.ok(sentBye, 'הפרידה יצאה');
  assert.ok(sentBye.path.includes(ROOM), 'אל החדר הקודם');
  t.stop();
});
