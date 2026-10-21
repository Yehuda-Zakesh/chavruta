'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { load } = require('./load');

const vectors = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'fixtures', 'protocol-vectors.json'), 'utf8')
);
const ctx = load(['js/remote/sha256.js', 'js/remote/protocol.js']);
const { ChavrutaCrypto, RemoteProtocol } = ctx;

test('דיווח מוכנות חתום: שינוי גרסה או הרשאות פוסל אותו', () => {
  const readiness = { pluginVersion: '7.0.0', appVersion: '0.9.98', network: true,
    syncAllowed: true, backgroundEnabled: true, engine: 'background' };
  const message = { type: 'ready', roomHash: RemoteProtocol.hashRoomCode('קוד'), senderId: 'abcd',
    senderName: 'מחשב', timestampMs: Date.now(), sequence: 1, readiness };
  const wire = RemoteProtocol.encode(message, 'קוד');
  assert.deepEqual(JSON.parse(JSON.stringify(RemoteProtocol.decode(wire, 'קוד').readiness)), readiness);
  assert.equal(RemoteProtocol.decode(wire.replace('7.0.0', '9.0.0'), 'קוד'), null);
  assert.equal(RemoteProtocol.decode(wire.replace('"network":true', '"network":false'), 'קוד'), null);
});

test('SHA-256 ו-HMAC תואמים את node:crypto', () => {
  const samples = ['', 'abc', 'דף יומי', 'x'.repeat(55), 'y'.repeat(56), 'z'.repeat(64), 'w'.repeat(200)];
  for (const s of samples) {
    assert.equal(ChavrutaCrypto.sha256Hex(s), crypto.createHash('sha256').update(s, 'utf8').digest('hex'));
    for (const key of ['k', 'chavruta-sig:דף יומי', 'q'.repeat(100)]) {
      assert.equal(
        ChavrutaCrypto.hmacSha256Hex(key, s),
        crypto.createHmac('sha256', key).update(s, 'utf8').digest('hex')
      );
    }
  }
});

test('נרמול קוד החדר וגיבובו זהים למתאם', () => {
  for (const v of vectors.normalize) {
    assert.equal(RemoteProtocol.normalizeRoomCode(v.raw), v.normalized, JSON.stringify(v.raw));
    assert.equal(RemoteProtocol.hashRoomCode(v.normalized), v.roomHash);
  }
});

test('הודעה שהמתאם קידד מתפענחת, ומקודדת חזרה לאותם בייטים בדיוק', () => {
  for (const wire of vectors.messages) {
    const raw = JSON.parse(wire);
    const message = RemoteProtocol.decode(wire, vectors.code, { now: raw.ts });
    assert.ok(message, wire);
    assert.equal(RemoteProtocol.encode(message, vectors.code), wire);
  }
});

test('חתימה שגויה, חדר אחר או קוד אחר נדחים', () => {
  const wire = vectors.messages[0];
  const raw = JSON.parse(wire);
  const now = raw.ts;
  assert.equal(RemoteProtocol.decode(wire, 'קוד אחר', { now }), null);
  const tampered = JSON.stringify(Object.assign({}, raw, { seq: raw.seq + 1 }));
  assert.equal(RemoteProtocol.decode(tampered, vectors.code, { now }), null);
});

test('הודעה ישנה מחלון הטריות נדחית ומדווחת כפער שעונים', () => {
  const wire = vectors.messages[0];
  const raw = JSON.parse(wire);
  let skew = null;
  const out = RemoteProtocol.decode(wire, vectors.code, {
    now: raw.ts + 6 * 60 * 1000,
    onClockSkew: (ms) => (skew = ms),
  });
  assert.equal(out, null);
  assert.equal(skew, 6 * 60 * 1000);
});

test('ריפוד מערך השולחן בפריטים פסולים אינו שובר הודעה תקינה', () => {
  const wire = vectors.messages.find(wire => JSON.parse(wire).t === 'desk');
  const raw = JSON.parse(wire);
  raw.desk = raw.desk.concat([{ b: '' }, 5, null]);
  assert.ok(RemoteProtocol.decode(JSON.stringify(raw), vectors.code, { now: raw.ts }));
});
