'use strict';

/**
 * פרוטוקול ההודעות של החברותא, ב-JS — לחיבור המרוחק, שרץ בתוסף עצמו.
 *
 * **זה אותו פרוטוקול בדיוק של המתאם** (`companion/lib/protocol.dart`):
 * אותו נרמול לקוד החדר, אותו גיבוב, אותה צורה קנונית ואותה חתימה, בייט
 * לבייט. כל סטייה כאן אינה "תאימות חלקית" אלא שתיקה מוחלטת: הודעה
 * שחתימתה אינה תואמת נזרקת בצד השני בלי שום סימן. לכן המימוש נבדק מול
 * וקטורים שהמימוש של Dart מפיק (`plugin-test/fixtures/protocol-vectors.json`).
 *
 * קוד החדר עצמו **אינו** יוצא מכאן לשום מקום: לשרת נשלחים רק הגיבוב
 * (בנתיב) וההודעות החתומות.
 */
const RemoteProtocol = (function () {
  const PROTOCOL_VERSION = 1;

  /** ראו `freshnessWindow` ב-Dart. */
  const FRESHNESS_WINDOW_MS = 5 * 60 * 1000;

  /** ראו `maxTabsPerMessage` ב-Dart. */
  const MAX_TABS_PER_MESSAGE = 12;

  /** ראו `maxDeskPayloadBytes` ב-Dart. */
  const MAX_DESK_PAYLOAD_BYTES = 1200;

  /** ראו `maxTrackedTabs` ב-Dart. */
  const MAX_TRACKED_TABS = 60;

  /** ראו `maxWireTextBytes` ב-Dart. */
  const MAX_WIRE_TEXT_BYTES = 512;

  const TYPES = { loc: 'loc', hi: 'hi', bye: 'bye', desk: 'desk', ready: 'ready' };

  // הודעת אבחון נפרדת: גרסאות ישנות מתעלמות ממנה וממשיכות לסנכרן כרגיל.
  function readinessFromJson(raw) {
    if (!isPlainObject(raw)) return null;
    if (typeof raw.pluginVersion !== 'string' || raw.pluginVersion.length > 64 ||
        typeof raw.appVersion !== 'string' || raw.appVersion.length > 64 ||
        typeof raw.network !== 'boolean' || typeof raw.syncAllowed !== 'boolean' || typeof raw.backgroundEnabled !== 'boolean' ||
        ['background', 'foreground'].indexOf(raw.engine) < 0) return null;
    return { pluginVersion: raw.pluginVersion, appVersion: raw.appVersion,
      network: raw.network, syncAllowed: raw.syncAllowed, backgroundEnabled: raw.backgroundEnabled, engine: raw.engine };
  }

  const encoder = new TextEncoder();

  function utf8Length(text) {
    return encoder.encode(text).length;
  }

  function wireTextTooLong(value) {
    return value.length > MAX_WIRE_TEXT_BYTES || utf8Length(value) > MAX_WIRE_TEXT_BYTES;
  }

  // --- נרמול קוד החדר -----------------------------------------------------
  //
  // **התווים נבנים מקודים מספריים ולא נכתבים במקור**, מאותה סיבה שבמתאם:
  // תו כיווניות בתוך קובץ המקור אינו נראה בעין והופך את סדר התצוגה של
  // השורה, ועורכים מסוימים ממירים רצף escape לתו עצמו בלי לשאול.

  function ch(code) {
    return String.fromCharCode(code);
  }

  function charClass(ranges) {
    let body = '';
    ranges.forEach(function (range) {
      const from = Array.isArray(range) ? range[0] : range;
      const to = Array.isArray(range) ? range[1] : range;
      body += from === to ? escapeForClass(from) : escapeForClass(from) + '-' + escapeForClass(to);
    });
    return new RegExp('[' + body + ']', 'g');
  }

  function escapeForClass(code) {
    return '\\u' + code.toString(16).padStart(4, '0');
  }

  /** ראו `_invisible` ב-`config.dart`. */
  const INVISIBLE = charClass([
    0x00ad, [0x200b, 0x200f], [0x202a, 0x202e], [0x2060, 0x2064], [0x2066, 0x2069], 0xfeff,
  ]);

  /** ראו `_hebrewMarks` ב-`config.dart`. */
  const HEBREW_MARKS = charClass([
    [0x0591, 0x05bd], 0x05bf, 0x05c1, 0x05c2, 0x05c4, 0x05c5, 0x05c7,
  ]);

  /** ראו `_quotes` ב-`config.dart`. */
  const QUOTES = [
    [0x05f3, "'"], [0x05f4, '"'], [0x2018, "'"], [0x2019, "'"], [0x201c, '"'], [0x201d, '"'],
  ];

  /** ראו `_presentationForms` ב-`config.dart`. הסדר זהה, כי הוא משנה. */
  const PRESENTATION_FORMS = [
    [0xfb1d, [0x05d9]], [0xfb1f, [0x05d9, 0x05d9]],
    [0xfb20, [0x05e2]], [0xfb21, [0x05d0]],
    [0xfb22, [0x05d3]], [0xfb23, [0x05d4]],
    [0xfb24, [0x05db]], [0xfb25, [0x05dc]],
    [0xfb26, [0x05dd]], [0xfb27, [0x05e8]],
    [0xfb28, [0x05ea]], [0xfb29, '+'],
    [0xfb2a, [0x05e9]], [0xfb2b, [0x05e9]],
    [0xfb2c, [0x05e9]], [0xfb2d, [0x05e9]],
    [0xfb2e, [0x05d0]], [0xfb2f, [0x05d0]],
    [0xfb30, [0x05d0]], [0xfb31, [0x05d1]],
    [0xfb32, [0x05d2]], [0xfb33, [0x05d3]],
    [0xfb34, [0x05d4]], [0xfb35, [0x05d5]],
    [0xfb36, [0x05d6]], [0xfb38, [0x05d8]],
    [0xfb39, [0x05d9]], [0xfb3a, [0x05da]],
    [0xfb3b, [0x05db]], [0xfb3c, [0x05dc]],
    [0xfb3e, [0x05de]], [0xfb40, [0x05e0]],
    [0xfb41, [0x05e1]], [0xfb43, [0x05e3]],
    [0xfb44, [0x05e4]], [0xfb46, [0x05e6]],
    [0xfb47, [0x05e7]], [0xfb48, [0x05e8]],
    [0xfb49, [0x05e9]], [0xfb4a, [0x05ea]],
    [0xfb4b, [0x05d5]], [0xfb4c, [0x05d1]],
    [0xfb4d, [0x05db]], [0xfb4e, [0x05e4]],
    [0xfb4f, [0x05d0, 0x05dc]],
  ].map(function (pair) {
    const to = typeof pair[1] === 'string' ? pair[1] : pair[1].map(ch).join('');
    return [ch(pair[0]), to];
  });

  /**
   * התווים ש-`String.trim` של Dart מסיר. זהה ל-`trim` של JS פרט ל-`U+0085`
   * (NEL), ש-Dart מסיר ו-JS לא — וקוד שהודבק עם NEL בקצהו היה מגיע
   * לחדר אחר.
   */
  const DART_TRIM = charClass([
    [0x0009, 0x000d], 0x0020, 0x0085, 0x00a0, 0x1680, [0x2000, 0x200a],
    0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff,
  ]);

  function dartTrim(text) {
    let start = 0;
    let end = text.length;
    const test = function (index) {
      DART_TRIM.lastIndex = 0;
      return DART_TRIM.test(text.charAt(index));
    };
    while (start < end && test(start)) start++;
    while (end > start && test(end - 1)) end--;
    return text.substring(start, end);
  }

  /** ראו `CompanionConfig.normalizeRoomCode`. */
  function normalizeRoomCode(raw) {
    let code = String(raw).replace(INVISIBLE, '');
    PRESENTATION_FORMS.forEach(function (pair) {
      code = code.split(pair[0]).join(pair[1]);
    });
    code = code.replace(HEBREW_MARKS, '');
    QUOTES.forEach(function (pair) {
      code = code.split(ch(pair[0])).join(pair[1]);
    });
    return dartTrim(code).replace(/\s+/g, ' ').toLowerCase();
  }

  /** גיבוב קוד החדר — 16 תווים הקסה. ראו `SyncMessage.hashRoomCode`. */
  function hashRoomCode(normalizedRoomCode) {
    return ChavrutaCrypto.sha256Hex('chavruta-room:' + normalizedRoomCode).substring(0, 16);
  }

  // --- מבני הנתונים --------------------------------------------------------

  function isPlainObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  function isInt(value) {
    return typeof value === 'number' && Number.isInteger(value);
  }

  /** ראו `SyncLocation.fromJson` — כולל ההערה למה אורך אינו נבדק כאן. */
  function locationFromJson(raw) {
    if (!isPlainObject(raw)) return null;
    const bookId = raw.bookId;
    const index = raw.index;
    if (typeof bookId !== 'string' || bookId === '') return null;
    if (!isInt(index) || index < 0) return null;
    const ref = raw.ref;
    return { bookId: bookId, index: index, ref: typeof ref === 'string' && ref !== '' ? ref : null };
  }

  function locationToJson(location) {
    return { bookId: location.bookId, index: location.index, ref: location.ref == null ? null : location.ref };
  }

  function sameSpot(a, b) {
    return !!a && !!b && a.bookId === b.bookId && a.index === b.index;
  }

  /** פריט שולחן. ראו `DeskEntry` ב-Dart. */
  function deskEntry(bookId, stamp, by, index, open) {
    return {
      bookId: bookId,
      index: typeof index === 'number' ? index : 0,
      open: open !== false,
      stamp: stamp,
      by: by,
    };
  }

  /** ראו `DeskEntry.supersededBy`: מאוחר מנצח, ובתיקו מכריע מזהה המכשיר. */
  function supersededBy(current, other) {
    return other.stamp > current.stamp || (other.stamp === current.stamp && compareStrings(other.by, current.by) > 0);
  }

  /**
   * השוואת מחרוזות לפי יחידות UTF-16, כמו `String.compareTo` של Dart.
   * `localeCompare` היה מכריע אחרת בצד אחד מבצד שני.
   */
  function compareStrings(a, b) {
    return a < b ? -1 : a > b ? 1 : 0;
  }

  function deskEntryToJson(entry) {
    return { b: entry.bookId, i: entry.index, o: entry.open, s: entry.stamp, w: entry.by };
  }

  /** ראו `DeskEntry.fromJson`. */
  function deskEntryFromJson(raw) {
    if (!isPlainObject(raw)) return null;
    const bookId = raw.b;
    const stamp = raw.s;
    const by = raw.w;
    if (typeof bookId !== 'string' || bookId === '') return null;
    if (!isInt(stamp) || stamp < 0) return null;
    if (typeof by !== 'string' || by === '') return null;
    const index = raw.i;
    const open = raw.o;
    return deskEntry(bookId, stamp, by, isInt(index) && index >= 0 ? index : 0, typeof open === 'boolean' ? open : true);
  }

  /** ראו `DeskEntry.listFromJson`. */
  function deskListFromJson(raw) {
    if (!Array.isArray(raw)) return [];
    const seen = new Set();
    const entries = [];
    for (let i = 0; i < raw.length; i++) {
      const entry = deskEntryFromJson(raw[i]);
      if (!entry || seen.has(entry.bookId)) continue;
      seen.add(entry.bookId);
      entries.push(entry);
      if (entries.length >= MAX_TRACKED_TABS) break;
    }
    return entries;
  }

  // --- ההודעה --------------------------------------------------------------

  /**
   * הצורה הקנונית שעליה נחתמת החתימה. **סדר המפתחות כאן הוא החוזה** —
   * הוא זהה לסדר ב-`SyncMessage._canonical`, ו-`JSON.stringify` שומר על
   * סדר ההכנסה. `desk` נכנס רק כשיש פריטים, מאותה סיבה שב-Dart.
   */
  function canonical(message) {
    const out = {
      v: PROTOCOL_VERSION,
      t: message.type,
      room: message.roomHash,
      src: message.senderId,
      name: message.senderName,
      ts: message.timestampMs,
      seq: message.sequence,
      loc: message.location ? locationToJson(message.location) : null,
    };
    if (message.entries && message.entries.length > 0) {
      out.desk = message.entries.map(deskEntryToJson);
    }
    if (message.type === TYPES.ready) out.ready = readinessFromJson(message.readiness);
    return out;
  }

  function sign(canonicalMessage, normalizedRoomCode) {
    return ChavrutaCrypto.hmacSha256Hex(
      'chavruta-sig:' + normalizedRoomCode,
      JSON.stringify(canonicalMessage)
    ).substring(0, 32);
  }

  /** מקודד הודעה לטקסט החוט, כולל חתימה. */
  function encode(message, normalizedRoomCode) {
    const body = canonical(message);
    body.sig = sign(body, normalizedRoomCode);
    return JSON.stringify(body);
  }

  function constantTimeEquals(a, b) {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
  }

  /**
   * מפענח ומאמת. מחזיר `null` לכל הודעה שאינה שייכת לחדר, אינה חתומה
   * נכון או אינה טרייה — בדיוק כמו `SyncMessage.decode`, כולל הסדר.
   *
   * [options.onClockSkew] נקרא רק על הודעה **חתומה נכון** שנדחתה על הזמן.
   */
  function decode(text, normalizedRoomCode, options) {
    const opts = options || {};
    let raw;
    try {
      raw = JSON.parse(text);
    } catch (e) {
      return null;
    }
    if (!isPlainObject(raw)) return null;
    if (raw.v !== PROTOCOL_VERSION) return null;
    if (typeof raw.t !== 'string' || !Object.prototype.hasOwnProperty.call(TYPES, raw.t)) return null;

    const roomHash = raw.room;
    const senderId = raw.src;
    const senderName = raw.name;
    const timestampMs = raw.ts;
    const sequence = raw.seq;
    const signature = raw.sig;
    if (
      typeof roomHash !== 'string' ||
      typeof senderId !== 'string' ||
      typeof senderName !== 'string' ||
      !isInt(timestampMs) ||
      !isInt(sequence) ||
      typeof signature !== 'string'
    ) {
      return null;
    }
    if (senderId === '' || sequence < 0) return null;
    if (roomHash !== hashRoomCode(normalizedRoomCode)) return null;

    const message = {
      type: raw.t,
      roomHash: roomHash,
      senderId: senderId,
      senderName: senderName,
      timestampMs: timestampMs,
      sequence: sequence,
      location: locationFromJson(raw.loc),
      entries: deskListFromJson(raw.desk),
      readiness: raw.t === TYPES.ready ? readinessFromJson(raw.ready) : null,
    };

    if (!constantTimeEquals(sign(canonical(message), normalizedRoomCode), signature)) return null;

    const now = typeof opts.now === 'number' ? opts.now : Date.now();
    const age = now - timestampMs;
    if (Math.abs(age) > FRESHNESS_WINDOW_MS) {
      if (typeof opts.onClockSkew === 'function') opts.onClockSkew(age);
      return null;
    }

    if (message.type === TYPES.loc && !message.location) return null;
    if (message.type === TYPES.ready && !message.readiness) return null;
    if (message.type === TYPES.desk && message.entries.length === 0) return null;
    if (message.entries.length > MAX_TABS_PER_MESSAGE) return null;
    return message;
  }

  return {
    PROTOCOL_VERSION: PROTOCOL_VERSION,
    FRESHNESS_WINDOW_MS: FRESHNESS_WINDOW_MS,
    MAX_TABS_PER_MESSAGE: MAX_TABS_PER_MESSAGE,
    MAX_DESK_PAYLOAD_BYTES: MAX_DESK_PAYLOAD_BYTES,
    MAX_TRACKED_TABS: MAX_TRACKED_TABS,
    MAX_WIRE_TEXT_BYTES: MAX_WIRE_TEXT_BYTES,
    TYPES: TYPES,
    readinessFromJson: readinessFromJson,
    utf8Length: utf8Length,
    wireTextTooLong: wireTextTooLong,
    normalizeRoomCode: normalizeRoomCode,
    hashRoomCode: hashRoomCode,
    locationFromJson: locationFromJson,
    locationToJson: locationToJson,
    sameSpot: sameSpot,
    deskEntry: deskEntry,
    deskEntryToJson: deskEntryToJson,
    supersededBy: supersededBy,
    encode: encode,
    decode: decode,
  };
})();

if (typeof module !== 'undefined') module.exports = RemoteProtocol;
