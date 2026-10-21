'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./load');
const { Readiness } = load(['js/readiness.js']);
const local = { pluginVersion: '7.0.0', appVersion: '0.9.99+99900', network: true,
  syncAllowed: true, backgroundEnabled: true, engine: 'foreground' };
const now = 100000;
function state(info, at = now) {
  return { engine: { owner: 'background' }, relay: { state: 'online' },
    peers: [{ name: 'שותף', readiness: info, readinessAt: at }] };
}
test('דיווח עדכני בשני הצדדים מציג מוכנות וגרסאות תואמות', () => {
  const sides = Readiness.evaluate(local, state({ ...local, engine: 'background' }), 'remote', now);
  assert.equal(sides.length, 2);
  assert.ok(sides.every(s => s.checks.every(c => c.kind === 'ok')));
});
test('גרסאות שונות ורקע בלשונית מוצגים כהנחיות, בלי לקבוע שהסנכרון אינו תואם', () => {
  const side = Readiness.evaluate(local, state({ ...local, pluginVersion: '6.0.0' }), 'remote', now)[1];
  assert.equal(side.checks.find(c => c.label === 'רקע').kind, 'warning');
  assert.equal(side.checks.find(c => c.label === 'גרסת התוסף').kind, 'warning');
});
test('דיווח ישן או חסר אינו מוצג כמוכן, ונוכחות לבדה אינה מרעננת אותו', () => {
  for (const s of [state(null), state(local, now - 70001)]) {
    const checks = Readiness.evaluate(local, s, 'remote', now)[1].checks;
    assert.equal(checks.length, 1);
    assert.equal(checks[0].kind, 'unknown');
  }
});
test('חוסר הרשאות וגרסת אוצריא ישנה מזוהים בשני הצדדים', () => {
  const info = { ...local, appVersion: '0.9.96', network: false, syncAllowed: false };
  const checks = Readiness.evaluate(info, state(info), 'remote', now)[1].checks;
  assert.equal(checks.filter(c => c.kind === 'error').length, 3);
});
test('אין חיבור ואין גרסה אינם מפורשים כמוכנות', () => {
  const sides = Readiness.evaluate({ ...local, appVersion: '' }, null, 'remote', now);
  assert.equal(sides[1].checks[0].kind, 'unknown');
  assert.equal(sides[0].checks.find(c => c.label === 'גרסת אוצריא').kind, 'unknown');
  assert.equal(sides[0].checks.find(c => c.label === 'שרת הממסר').kind, 'warning');
});
test('תאימות אוצריא מתחילה בגרסת המינימום שבמניפסט', () => {
  const manifest = require('../plugin/manifest.json');
  assert.equal(manifest.minAppVersion, '0.9.99');
  for (const [version, expected] of [['0.9.98', 'error'], [manifest.minAppVersion, 'ok'],
    ['0.10.0', 'ok'], ['1.0.0', 'ok']]) {
    const info = { ...local, appVersion: version };
    for (const side of Readiness.evaluate(info, state(info), 'remote', now)) {
      assert.equal(side.checks.find(c => c.label === 'גרסת אוצריא').kind, expected);
    }
  }
});

test('הרשאת החיבור מחושבת לפי הדרך שנבחרה ומצב אוצריא', () => {
  const boot = { permissions: ['network.localhost', 'network.access'], connectivity: { isOfflineMode: true } };
  assert.equal(Readiness.fromBoot(boot, 'local').network, true);
  assert.equal(Readiness.fromBoot(boot, 'remote').network, false);
  assert.equal(Readiness.fromBoot(boot, 'remote').backgroundEnabled, false);
});
