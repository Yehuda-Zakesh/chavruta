'use strict';

const Readiness = (function () {
  const MAX_AGE_MS = 70000;
  const SYNC_PERMISSIONS = ['reader.open', 'navigation.write', 'workspace.read', 'workspace.manage',
    'plugin.storage.read', 'plugin.storage.write', 'events.subscribe:reader.current_ref_changed'];

  function fromBoot(payload, mode) {
    const boot = payload || {};
    const permissions = Array.isArray(boot.permissions) ? boot.permissions : [];
    return {
      pluginVersion: boot.plugin && boot.plugin.version || '',
      appVersion: boot.app && boot.app.version || '',
      network: permissions.indexOf(mode === 'remote' ? 'network.access' : 'network.localhost') >= 0 &&
        !(mode === 'remote' && boot.connectivity && boot.connectivity.isOfflineMode),
      syncAllowed: SYNC_PERMISSIONS.every(function (p) { return permissions.indexOf(p) >= 0; }),
      backgroundEnabled: permissions.indexOf('app.run_on_startup') >= 0 &&
        permissions.indexOf('app.background_keep_alive') >= 0,
      engine: boot.app && boot.app.runMode === 'background' ? 'background' : 'foreground',
    };
  }

  // גרסת תיקון (hotfix) של אוצריא היא רכיב רביעי: 0.9.98.2. כמו
  // PluginVersionUtils באוצריא — משווים את כל הרכיבים, ורכיב חסר נחשב 0.
  const MIN_APP_VERSION = '0.9.98.2';

  function versionParts(value) {
    const match = /^(\d+(?:\.\d+){2,3})(?:[+-].*)?$/.exec(value || '');
    return match ? match[1].split('.').map(Number) : null;
  }

  function supportsApp(value) {
    const v = versionParts(value);
    if (!v) return null;
    const min = versionParts(MIN_APP_VERSION);
    for (let i = 0; i < Math.max(v.length, min.length); i++) {
      const a = v[i] || 0;
      const b = min[i] || 0;
      if (a !== b) return a > b;
    }
    return true;
  }

  function checks(info, owner) {
    const appOk = supportsApp(info.appVersion);
    return [
      { label: 'הרשאת חיבור', kind: info.network ? 'ok' : 'error', text: info.network ? 'מאושרת' : 'יש לאשר את הרשאת החיבור בהגדרות התוסף באוצריא' },
      { label: 'הרשאות סנכרון', kind: info.syncAllowed ? 'ok' : 'error', text: info.syncAllowed ? 'מאושרות' : 'חסרות הרשאות קורא, ניווט, שולחנות או אחסון — בדקו בניהול התוספים' },
      { label: 'רקע', kind: owner === 'background' && info.backgroundEnabled ? 'ok' : 'warning', text: owner === 'background'
        ? (info.backgroundEnabled ? 'מנוע הרקע פעיל' : 'מנוע הרקע פעיל; יש לאשר גם המשך ריצה ברקע')
        : owner === 'foreground' ? 'הסנכרון פועל בלשונית; אשרו ריצה בעלייה והמשך ריצה ברקע' : 'טרם זוהה מנוע פעיל' },
      { label: 'גרסת אוצריא', kind: appOk === null ? 'unknown' : appOk ? 'ok' : 'error', text: info.appVersion
        ? info.appVersion + (appOk === false ? ' — נדרשת ' + MIN_APP_VERSION + ' ומעלה' : '') : 'גרסה לא ידועה' },
    ];
  }

  function evaluate(local, state, mode, now) {
    const time = now === undefined ? Date.now() : now;
    const ownerValue = state && state.engine && state.engine.owner;
    const owner = typeof ownerValue === 'string' && ownerValue.indexOf('background') === 0 ? 'background'
      : typeof ownerValue === 'string' && ownerValue.indexOf('foreground') === 0 ? 'foreground' : null;
    const localChecks = checks(local, owner);
    localChecks.push({ label: 'גרסת התוסף', kind: local.pluginVersion ? 'ok' : 'unknown',
      text: local.pluginVersion || 'לא ידועה' });
    const connected = mode === 'remote' ? state && state.relay && state.relay.state === 'online'
      : state && state.lanBound === true && (!Array.isArray(state.links) || state.links.some(function (l) { return l.sending !== false; }));
    localChecks.push({ label: mode === 'remote' ? 'שרת הממסר' : 'המתאם והקישור המקומי',
      kind: connected ? 'ok' : 'warning', text: connected ? 'זמין' : 'טרם אומת חיבור זמין' });
    const sides = [{ title: 'המחשב שלי', checks: localChecks }];
    const peers = state && Array.isArray(state.peers) ? state.peers : [];
    if (!peers.length) sides.push({ title: 'החברותא', checks: [{ label: 'מוכנות', kind: 'unknown', text: 'ממתין לחברותא — המוכנות תיבדק לאחר ההתחברות באותו קוד' }] });
    peers.forEach(function (peer) {
      const info = peer.readiness;
      const fresh = typeof peer.readinessAt === 'number' && time - peer.readinessAt >= 0 && time - peer.readinessAt < MAX_AGE_MS;
      if (!info || !fresh) {
        sides.push({ title: peer.name || 'החברותא', checks: [{ label: 'מוכנות', kind: 'unknown', text: info
          ? 'דיווח המוכנות התיישן — ממתין לעדכון מהחברותא'
          : 'החברותא מחוברת אך טרם דיווחה מוכנות. אם ההמתנה נמשכת, עדכנו את התוסף והמתאם בשני המחשבים' }] });
        return;
      }
      const rows = checks(info, info.engine);
      const same = !!local.pluginVersion && info.pluginVersion === local.pluginVersion;
      rows.push({ label: 'גרסת התוסף', kind: same ? 'ok' : 'warning', text: info.pluginVersion
        ? info.pluginVersion + (same ? ' — זהה לגרסה שלי' : ' — מומלץ לעדכן את שני הצדדים לאותה גרסה') : 'לא ידועה' });
      rows.push({ label: 'חיבור', kind: 'ok', text: 'התקבל דיווח חתום ועדכני מהחברותא' });
      sides.push({ title: peer.name || 'החברותא', checks: rows });
    });
    return sides;
  }

  return { fromBoot: fromBoot, evaluate: evaluate, minAppVersion: MIN_APP_VERSION };
})();
