'use strict';

/**
 * החיבור המרוחק — **בלי מתאם ובלי EXE**: התוסף עצמו מדבר עם שרת ה-relay.
 *
 * המודול חושף בדיוק את הממשק של `Companion` (ראו `companion.js`), ולכן
 * `SyncEngine` והלשונית עובדים מולו בלי לדעת איזה חיבור נבחר. מה שהמתאם
 * עשה בצד שלו נעשה כאן, בתוך התוסף:
 *
 * ## מי מריץ את המנוע — נעילת Web Locks
 *
 * לתוסף יש שני מופעים (לשונית ורקע), ורק אחד מהם רשאי להחזיק את ה-hub:
 * שניים היו שולחים את אותן הודעות פעמיים עם מונים שונים, ומנווטים פעמיים.
 * במתאם ההכרעה הייתה החזקה עם תפוגה; כאן אין צד שלישי ששני המופעים רואים,
 * ולכן ההכרעה היא **נעילה של הדפדפן** (`navigator.locks`), ולא ערך באחסון:
 *
 * - `storage.get` ואחריו `storage.set` אינם נעילה — שני מופעים קוראים את
 *   אותו ערך ושניהם כותבים "שלי". אוצריא אינה מציעה השוואה-והחלפה.
 * - Web Locks אטומית בצד תהליך הדפדפן. שני ה-WebView של התוסף רצים באותה
 *   סביבת WebView2 ונטענים מ-`file://`, ולכן חולקים את מנהל הנעילות —
 *   אומת ב-Edge 155 (המנוע של WebView2 המותקן): הדרה, מסירה בשחרור,
 *   `steal`, ושחרור אוטומטי כשהדף נסגר. האימות בתוך אוצריא עצמה מוצג
 *   בלשונית (שורת האבחון "מסנכרן כעת" בכרטיס החיבור המרוחק) ומפורט ב-`docs/remote-feasibility.md`.
 * - **הנעילה משתחררת מעצמה כשהמופע מת** — רקע שנסגר, לשונית שנסגרה — ולכן
 *   אין כאן תפוגה לנחש, והמופע הממתין נכנס מיד.
 * - **רקע גובר על לשונית**, כמו במתאם: הרקע חי כל זמן שאוצריא פתוחה ואילו
 *   הלשונית מוקפאת כשעוברים לספר. **הרקע מבקש, ורק אחר כך גונב**: הוא
 *   נכנס לתור, משאיר בקשת מסירה (`remote.handover`) ונוקש; הלשונית רואה
 *   אותה ב-[checkInbox], מסיימת לכתוב את המצב ([flushSave]) ומשחררת — כך
 *   המצב שהרקע קורא הוא המעודכן. רק אם הלשונית אינה משחררת בתוך
 *   [HANDOVER_TIMEOUT_MS] (מוקפאת) הרקע מבטל את הבקשה שבתור ולוקח ב-`steal`,
 *   והלשונית מגלה זאת בדחייה (`AbortError`) ומפסיקה. רקע אינו גונב מרקע חי
 *   (ראו [shouldSteal]) — אחרת שני מופעי רקע היו מעבירים אותה ביניהם בלי סוף.
 *
 * ## המצב עובר עם המנוע — ומחזיק קודם אינו דורס אותו
 *
 * המצב (השולחן, המצבות, השעון הלוגי) נכתב **מיד** בכל שינוי ([scheduleSave]),
 * ולא בהשהיה: מסירה בתוך חלון השהיה הייתה מאבדת את השינוי האחרון.
 *
 * אין באחסון השוואה-והחלפה, ולכן גם בלי גידור: לשונית מוקפאת שאיבדה את
 * הנעילה (ב-`steal`) עלולה להחזיק כתיבה "בדרך" שתנחת אחרי כתיבות המחזיק
 * החדש. הגידור הוא **מפתח לכל תקופה**: מי שמקבל את המנוע קורא את התקופה
 * הגבוהה E, משחזר ממנה, וכותב מיד את המצב למפתח של E+1 — ומשם רק אליו.
 * קוראים תמיד את התקופה הגבוהה, ולכן כתיבה מאוחרת של מחזיק קודם נוחתת
 * במפתח נמוך ופשוט אינה נקראת. ראו [loadLatestState].
 *
 * **קריאה שנכשלה אינה "אין ערך"** ([storageRead]): אוצריא מחזירה
 * `success: false` בשגיאה פנימית או בהגבלת קצב, ומי שהיה מפרש זאת כריק
 * היה יוצא מהחדר (הגדרות "ריקות"), ממציא מזהה מכשיר חדש או מתחיל משולחן
 * ריק. כשל כזה מבטל את הפעולה, והסבב הבא מנסה שוב. רק התצוגה ([describe])
 * סלחנית.
 *
 * ## איך הלשונית מדברת עם המנוע
 *
 * אין ב-SDK ערוץ בין מופעים, ולכן הערוץ הוא אחסון התוסף, **כשלכל מפתח יש
 * כותב יחיד** — כך אין קריאה-ושינוי-וכתיבה על אותו מפתח משני מופעים:
 *
 * | מפתח                 | כותב              | תוכן                                  |
 * |----------------------|-------------------|---------------------------------------|
 * | `remote.config`      | הלשונית           | חדר, שם, העדפות                        |
 * | `remote.cmd.<id>`    | הלשונית (מפתח חדש לכל פקודה) | העברה לשולחן, "לא לסגור"     |
 * | `remote.identity`    | מחזיק הנעילה      | מזהה המכשיר                            |
 * | `remote.state.<E>.<t>` | המחזיק של תקופה E | השולחן, המצבות והשעון הלוגי (המקור)  |
 * | `remote.status`      | מחזיק הנעילה      | המצב לתצוגה                            |
 * | `remote.holder`      | מחזיק הנעילה      | מי מחזיק (רקע או לשונית) — לעצת ה-steal |
 * | `remote.handover`    | הרקע              | בקשת מסירה מהלשונית                    |
 *
 * המנוע קורא את מפתחות הלשונית כל שנייה וחצי, ומיד כשמגיעה "נקישה" ב-
 * `BroadcastChannel`. **הנקישה ריקה מתוכן בכוונה**: הערוץ משותף לכל דף
 * `file://` — כלומר גם לתוספים אחרים — ולכן שום דבר שעובר בו אינו פרטי.
 */
const RemoteLink = (function () {
  const PLUGIN_ID = 'io.github.yehudazakesh.chavruta';

  /**
   * כתובת השרת. חייבת להופיע גם במניפסט וגם ברשימת ההיתר של אוצריא —
   * **כולל ה-scheme**: אוצריא משווה את הכתובת כקידומת מלאה, ו-`https://`
   * אינו תואם רשומה של `http://`.
   *
   * `http` ולא `https`, כי זו הכתובת שאושרה ברשימת ההיתר (commit
   * `ad82b14` בענף `dev` של אוצריא). ההודעות חתומות ב-HMAC, ולכן מי שבדרך
   * אינו יכול לזייף או לשנות אותן — אבל הוא **כן** רואה אותן: שמות ספרים,
   * מקום הלימוד ושם המכשיר. כשתאושר גם כתובת `https`, החליפו כאן ובמניפסט.
   */
  const RELAY_URL = 'http://chavruta-relay.chavruta.workers.dev';

  const ENGINE_LOCK = PLUGIN_ID + ':remote-engine';
  const POKE_CHANNEL = PLUGIN_ID + ':remote-poke';

  const KEY_CONFIG = 'remote.config';
  const KEY_IDENTITY = 'remote.identity';
  /** `remote.state.<תקופה>.<אסימון>` — ראו [loadLatestState]. */
  const STATE_PREFIX = 'remote.state.';
  const STATE_KEY_RE = /^remote\.state\.(\d+)\.([0-9a-z]+)$/;
  const KEY_STATUS = 'remote.status';
  const KEY_HOLDER = 'remote.holder';
  const KEY_HANDOVER = 'remote.handover';
  const CMD_PREFIX = 'remote.cmd.';

  /** ראו `longPollTimeout` במתאם. */
  const LONG_POLL_MS = 25000;

  const INBOX_POLL_MS = 1500;
  const STATUS_HEARTBEAT_MS = 10000;
  /** ניסיון חוזר אחרי שמירה שנכשלה (שמירה רגילה יוצאת מיד). */
  const SAVE_RETRY_MS = 1000;
  const STATUS_DEBOUNCE_MS = 400;

  /**
   * כמה זמן הרקע ממתין שהלשונית תמסור את המנוע לפני שהוא גונב. הלשונית
   * רואה את הבקשה בתוך סבב תיבה אחד ([INBOX_POLL_MS]) ומסיימת כתיבה אחת;
   * מעבר לזה היא כנראה מוקפאת.
   */
  const HANDOVER_TIMEOUT_MS = 4000;

  /** רשומת מחזיק ישנה מזה נחשבת מחזיק שמת (רק לעצת ה-steal). */
  const HOLDER_FRESH_MS = 30000;

  /**
   * @param {object} deps — תלויות, כדי שהבדיקות יוכלו להחליף אותן:
   *   `call(method, args)`, `locks`, `BroadcastChannel`, `now`, `timers`,
   *   `randomHex(bytes)`, `relayUrl`.
   */
  function create(deps) {
    const d = deps || {};
    const call = d.call || function (method, args) {
      return Otzaria.call(method, args);
    };
    const now = d.now || Date.now;
    const timers = d.timers || {
      setTimeout: setTimeout,
      clearTimeout: clearTimeout,
      setInterval: setInterval,
      clearInterval: clearInterval,
    };
    const locks =
      'locks' in d ? d.locks : typeof navigator !== 'undefined' && navigator.locks ? navigator.locks : null;
    const Channel =
      'BroadcastChannel' in d
        ? d.BroadcastChannel
        : typeof BroadcastChannel !== 'undefined'
          ? BroadcastChannel
          : null;
    const randomHex = d.randomHex || ChavrutaCrypto.randomHex;
    const relayUrl = d.relayUrl || RELAY_URL;

    let instance = '';
    let permissions = [];

    // --- הנעילה ------------------------------------------------------------

    /** `none` / `pending` / `held`. */
    let lockState = 'none';
    let lockGen = 0;
    let releaseHeld = null;
    /** מתי ההחזקה הנוכחית התחילה — ראו [handOverIfAsked]. */
    let heldSince = 0;

    /** מתממשת כשההחזקה הנוכחית אובדת. ההמתנה הארוכה מתקצרת בה. */
    let lostSignal = null;
    let signalLost = function () {};

    let engine = null;
    let engineStarting = null;

    function kind() {
      return instance.indexOf('background') === 0 ? 'background' : 'foreground';
    }

    function holding() {
      return locks ? lockState === 'held' : fallbackOwner();
    }

    /**
     * רשת ביטחון לגרסה שאין בה Web Locks: הרקע לבדו מריץ את המנוע, והלשונית
     * רק כשאין הרשאה לרקע. זו חלוקה נחושה ולא נעילה — ולכן היא רק נפילה
     * אחורה, ומסומנת במסך (`lockSupported: false`).
     */
    function fallbackOwner() {
      if (instance === '') return false;
      if (kind() === 'background') return true;
      return permissions.indexOf('app.run_on_startup') < 0;
    }

    async function readHolder() {
      const value = await storageGet(KEY_HOLDER);
      return value && typeof value === 'object' ? value : null;
    }

    /** ראו את התיעוד בראש המודול: רקע גונב מלשונית, לא מרקע חי. */
    async function shouldSteal() {
      if (kind() !== 'background') return false;
      const holder = await readHolder();
      if (!holder || holder.kind !== 'background') return true;
      return now() - (holder.at || 0) > HOLDER_FRESH_MS;
    }

    async function ensureLock() {
      if (!locks) {
        if (fallbackOwner() && !engine && !engineStarting) await startEngine();
        return;
      }
      if (lockState !== 'none' || instance === '') return;
      lockState = 'pending';
      const gen = ++lockGen;
      let steal = false;
      let holder = null;
      try {
        steal = await shouldSteal();
        if (steal) holder = await readHolder();
      } catch (e) {
        steal = false;
      }
      if (gen !== lockGen) return;
      lostSignal = new Promise(function (resolve) {
        signalLost = resolve;
      });
      let handoverTimer = null;

      function granted() {
        if (handoverTimer) timers.clearTimeout(handoverTimer);
        handoverTimer = null;
        if (gen !== lockGen) return undefined;
        lockState = 'held';
        heldSince = now();
        const held = new Promise(function (resolve) {
          releaseHeld = resolve;
        });
        // נכשל (למשל קריאה שנכשלה)? הנעילה נשארת, ו-`events` הבא מנסה שוב.
        startEngine().catch(function () {});
        return held;
      }

      function request(options) {
        return locks.request(ENGINE_LOCK, options, granted);
      }

      function settle(promise) {
        promise.then(
          function () {
            lockGone(gen);
          },
          function () {
            // `AbortError`: הרקע לקח את הנעילה. אין כאן תקלה.
            lockGone(gen);
          }
        );
      }

      // רקע שמת (רשומת רקע ישנה) אינו יכול למסור דבר — לוקחים מיד. לשונית
      // מתבקשת למסור, כדי שתסיים לכתוב את המצב לפני שהרקע קורא אותו.
      const graceful =
        steal && !(holder && holder.kind === 'background') && typeof AbortController !== 'undefined';
      if (!graceful) {
        settle(request(steal ? { steal: true } : {}));
        return;
      }
      const controller = new AbortController();
      request({ signal: controller.signal }).then(
        function () {
          lockGone(gen);
        },
        function () {
          if (controller.signal.aborted && gen === lockGen && lockState === 'pending') {
            // הלשונית לא מסרה בזמן (מוקפאת): לוקחים. כתיבה שלה שעוד בדרך
            // תנחת במפתח של תקופה ישנה, ולכן אינה דורסת דבר.
            settle(request({ steal: true }));
            return;
          }
          lockGone(gen);
        }
      );
      handoverTimer = timers.setTimeout(function () {
        handoverTimer = null;
        if (gen === lockGen && lockState === 'pending') controller.abort();
      }, HANDOVER_TIMEOUT_MS);
      try {
        // כותב יחיד: הרקע. `at` מאוחר מרגע הכניסה של המחזיק — ולכן בקשה
        // ישנה שנשארה באחסון אינה מוציאה לשונית שנכנסה אחריה.
        await storageSet(KEY_HANDOVER, { at: now(), instance: instance });
      } catch (e) {
        // בלי הבקשה הלשונית לא תמסור, והטיימר יגנוב.
      }
      poke();
    }

    function lockGone(gen) {
      if (gen !== lockGen) return;
      lockState = 'none';
      releaseHeld = null;
      signalLost();
      // **בלי פרידה**: המנוע עובר למופע אחר של אותו מכשיר, והחברותא אינה
      // אמורה לראות אותנו יוצאים ונכנסים. גם בלי שמירה: מי שלקח את הנעילה
      // כבר כותב, וכתיבה מכאן הייתה שני כותבים לאותו מפתח.
      haltEngine(false);
    }

    function releaseLock() {
      lockGen++;
      const release = releaseHeld;
      releaseHeld = null;
      lockState = 'none';
      signalLost();
      if (release) release();
    }

    // --- אחסון -------------------------------------------------------------

    function storageError(res, fallback) {
      return new Error((res && res.error && res.error.message) || fallback);
    }

    /**
     * קריאה מחמירה: `null` רק כשהמפתח **חסר** (`success: true`). קריאה
     * שנכשלה — `success` שאינו `true`, תשובה חסרה או חריגה — נזרקת, כדי
     * שלא תתפרש כ"אין ערך". ראו את התיעוד בראש המודול.
     */
    async function storageRead(key) {
      const res = await call('storage.get', { key: key });
      if (!res || res.success !== true) throw storageError(res, 'הקריאה נכשלה');
      return res.data === undefined ? null : res.data;
    }

    /** קריאה סלחנית, **לתצוגה בלבד**: כל כשל הוא "אין ערך". */
    async function storageGet(key) {
      try {
        return await storageRead(key);
      } catch (e) {
        return null;
      }
    }

    /** רשימת המפתחות; כשל נזרק (רשימה ריקה הייתה "אין פקודות, אין מצב"). */
    async function storageList() {
      const res = await call('storage.list', {});
      if (!res || res.success !== true || !Array.isArray(res.data)) throw storageError(res, 'הרשימה נכשלה');
      return res.data.filter(function (k) {
        return typeof k === 'string';
      });
    }

    async function storageSet(key, value) {
      const res = await call('storage.set', { key: key, value: value });
      if (!res || res.success !== true) throw storageError(res, 'השמירה נכשלה');
    }

    async function storageRemove(key) {
      const res = await call('storage.remove', { key: key });
      if (!res || res.success !== true) throw storageError(res, 'המחיקה נכשלה');
    }

    /** [lenient] — לתצוגה בלבד; בכל מקום אחר כשל קריאה מבטל את הפעולה. */
    async function readConfig(lenient) {
      const value = lenient ? await storageGet(KEY_CONFIG) : await storageRead(KEY_CONFIG);
      return value && typeof value === 'object' ? value : {};
    }

    // --- המצב השמור, בתקופות ----------------------------------------------

    function stateKey(epoch, token) {
      return STATE_PREFIX + epoch + '.' + token;
    }

    /**
     * המצב העדכני: מפתח התקופה הגבוהה. מחזיר `{ state, maxEpoch, keys }`,
     * כש-[maxEpoch] היא הגבוהה **שנראתה** (גם אם הרשומה בה פגומה) — כדי
     * שהתקופה החדשה תהיה גבוהה מכל מפתח קיים.
     *
     * שתי רשומות באותה תקופה יכולות להיווצר רק מהתביעה (ב-[startEngine]) של
     * מחזיק שאיבד את הנעילה בזמן שהיא הייתה בדרך. תביעה כזו היא המצב שהוא
     * שחזר ולא יותר (`writes: 0`), ולכן במקרה כזה גוברת הרשומה עם יותר
     * כתיבות — היא של המחזיק שהמשיך לעבוד.
     */
    async function loadLatestState() {
      const keys = await storageList();
      const byEpoch = {};
      let maxEpoch = 0;
      keys.forEach(function (key) {
        const m = STATE_KEY_RE.exec(key);
        if (!m) return;
        const epoch = parseInt(m[1], 10);
        if (!isFinite(epoch)) return;
        (byEpoch[epoch] = byEpoch[epoch] || []).push(key);
        if (epoch > maxEpoch) maxEpoch = epoch;
      });
      const epochs = Object.keys(byEpoch)
        .map(Number)
        .sort(function (a, b) {
          return b - a;
        });
      for (let i = 0; i < epochs.length; i++) {
        let best = null;
        const candidates = byEpoch[epochs[i]];
        for (let j = 0; j < candidates.length; j++) {
          const record = await storageRead(candidates[j]);
          if (!record || typeof record !== 'object' || !record.state || typeof record.state !== 'object') continue;
          const writes = typeof record.writes === 'number' ? record.writes : 0;
          if (!best || writes > best.writes) best = { writes: writes, state: record.state };
        }
        if (best) return { state: best.state, maxEpoch: maxEpoch, keys: keys };
      }
      return { state: null, maxEpoch: maxEpoch, keys: keys };
    }

    /** כתיבת המצב למפתח של התקופה של [current] — **ורק אליו**. */
    async function writeState(current) {
      const state = current.hub.exportState();
      const writes = current.stateWrites++;
      await storageSet(current.stateKey, { epoch: current.epoch, writes: writes, state: state });
      // מה שכתוב באחסון עכשיו — ולא מה שבזיכרון. ראו [persisted].
      current.persistedDone = state.doneCommands || [];
      // והפעולות שבתור היוצא של המצב הזה משתחררות לשידור — רק אם הכתיבה
      // הייתה של המחזיק: כתיבה מאוחרת של מי שאיבד את המנוע נוחתת בתקופה
      // שאיש אינו קורא, ומה שבה אינו "נשמר".
      if (stillMine(current.gen)) current.hub.confirmSaved(state);
    }

    /**
     * **הסימון [key] נכתב לאחסון** (בכתיבה המוצלחת האחרונה, או במצב
     * שהמנוע שוחזר ממנו). סימון בזיכרון בלבד אינו הוכחה: אחרי כתיבה שנכשלה
     * הוא קיים כאן, ומחיקת הפקודה על סמכו הייתה מאבדת אותה ואת התוצאה יחד.
     */
    function persisted(current, key) {
      return current.persistedDone.indexOf(key) >= 0;
    }

    /** כותב את המצב ומחכה לכתיבה. אמת רק אם נכתב, והמנוע עדיין כאן ושלנו. */
    async function persistNow(current) {
      if (engine !== current) return false;
      scheduleSave();
      const saved = await flushSave(current);
      return saved && engine === current && stillMine(current.gen);
    }

    function configKey(config) {
      return JSON.stringify([
        config.room || null,
        config.name || '',
        config.syncLocation !== false,
        config.closePolicy || 'ask',
        // הצטרפות חדשה לאותו חדר היא שינוי שהמנוע חייב להחיל ([applyConfig]).
        joinOf(config),
      ]);
    }

    /**
     * אסימון תקופת ההצטרפות שבהגדרות: מתחלף בכל החלפת חדר ([writeConfig]).
     * פקודה שהלשונית שומרת נושאת אותו, ותקפה רק כל עוד הוא האסימון של
     * ההגדרות וגם של מה שהמנוע החיל ([checkInbox]). קוד החדר לבדו אינו
     * מבחין בין שתי הצטרפויות לאותו חדר.
     */
    function joinOf(value) {
      return value && typeof value.join === 'string' ? value.join : '';
    }

    function defaultName(deviceId) {
      return 'מחשב ' + String(deviceId || '').slice(0, 4).toUpperCase();
    }

    // --- המנוע -------------------------------------------------------------

    function startEngine() {
      if (engine) return Promise.resolve(engine);
      if (engineStarting) return engineStarting;
      const gen = lockGen;
      engineStarting = (async function () {
        try {
          // כל הקריאות כאן מחמירות: כשל נזרק, ההפעלה נכשלת ו-`events` הבא
          // מנסה שוב — ולא מזהה חדש, הגדרות ריקות או שולחן ריק.
          let identity = await storageRead(KEY_IDENTITY);
          if (!identity || typeof identity.deviceId !== 'string' || identity.deviceId === '') {
            // נוצר רק כאן, תחת הנעילה, ורק כשהמפתח **חסר** — ולכן שני מופעים
            // אינם ממציאים שני מזהים שונים לאותו מכשיר.
            identity = { deviceId: randomHex(8) };
            await storageSet(KEY_IDENTITY, identity);
          }
          const config = await readConfig();
          const latest = await loadLatestState();
          if (!stillMine(gen)) return null;

          const box = { hub: null };
          const transport = new RelayTransport({
            baseUrl: relayUrl,
            fetchStream: function (params) {
              return call('network.fetchStream', params);
            },
            roomCode: function () {
              return box.hub ? box.hub.roomCode : null;
            },
            selfId: function () {
              return identity.deviceId;
            },
            onMessage: function (message) {
              if (box.hub) box.hub.handleInbound(message);
            },
            onResync: function () {
              return box.hub ? box.hub.resync() : null;
            },
            onJoined: function () {
              return box.hub ? box.hub.announce() : null;
            },
            onStatus: scheduleStatus,
            now: now,
            timers: timers,
          });
          const hub = new RemoteHub({
            deviceId: identity.deviceId,
            deviceName: config.name || defaultName(identity.deviceId),
            transport: transport,
            now: now,
            timers: timers,
            onChange: function () {
              scheduleSave();
              scheduleStatus();
            },
          });
          box.hub = hub;
          hub.syncLocation = config.syncLocation !== false;
          hub.setClosePolicy(config.closePolicy);
          // החדר נקבע ישירות ולא דרך `setRoom`, ובכוונה: זו המשכיות של אותו
          // חדר ממנוע קודם, ולא החלפה — אין למי להיפרד, ואסור לנקות את
          // השולחן שזה עתה שוחזר.
          hub.roomCode = typeof config.room === 'string' && config.room !== '' ? config.room : null;
          // **שחזור רק לאותה הצטרפות.** מצב שנשמר בהצטרפות שנעזבה (א׳→ב׳→א׳
          // בזמן שאיש לא החזיק את המנוע) אינו מוחיה — לא שולחן, לא עדכון
          // ממתין ולא אישורי מסירה. רק המונה ממשיך, כדי ש-`since` של לקוח
          // ותיק לא יתנגש בו.
          hub.joinToken = joinOf(config);
          if (latest.state && joinOf(latest.state) === hub.joinToken) hub.importState(latest.state);
          else if (latest.state) hub.continueSequence(latest.state.sequence);

          const epoch = latest.maxEpoch + 1;
          const current = {
            gen: gen,
            hub: hub,
            transport: transport,
            identity: identity,
            appliedConfig: configKey(config),
            inboxTimer: null,
            heartbeat: null,
            channel: null,
            statusTimer: null,
            inboxBusy: null,
            // ראו [loadLatestState] ו-[scheduleSave].
            epoch: epoch,
            stateKey: stateKey(epoch, randomHex(4)),
            stateWrites: 0,
            // ראו [persisted]: מה ששוחזר מהאחסון כבר כתוב בו.
            persistedDone: hub.doneCommandKeys(),
            saving: null,
            saveDirty: false,
            saveRetry: null,
            // בקשת מסירה ישנה מזה — אין לה תוקף ([handOverIfAsked]). רגע קבלת
            // הנעילה ולא רגע הקמת המנוע: בקשה שהגיעה בזמן שהמנוע עוד עלה
            // תקפה, אחרת הרקע היה ממתין לשווא עד הגניבה.
            acquiredAt: locks ? heldSince : now(),
          };
          // **התביעה, לפני כל דבר אחר**: מעכשיו התקופה הזו היא הגבוהה, וכל
          // כתיבה של מחזיק קודם נוחתת במפתח נמוך ממנה ואינה נקראת.
          await writeState(current);
          if (!stillMine(gen)) return null;
          // מפתחות התקופות הקודמות כבר אינם נקראים. כתיבה מאוחרת שתיצור
          // אחד מהם מחדש תימחק במסירה הבאה.
          latest.keys.forEach(function (key) {
            const m = STATE_KEY_RE.exec(key);
            if (m && parseInt(m[1], 10) < epoch) storageRemove(key).catch(function () {});
          });

          engine = current;
          transport.start();
          transport.retarget(hub.isPaired ? RemoteProtocol.hashRoomCode(hub.roomCode) : null);
          await hub.start();
          if (!stillMine(gen)) {
            haltEngine(false);
            return null;
          }
          await writeHolder();
          engine.inboxTimer = timers.setInterval(checkInbox, INBOX_POLL_MS);
          engine.heartbeat = timers.setInterval(writeStatusNow, STATUS_HEARTBEAT_MS);
          if (Channel) {
            try {
              engine.channel = new Channel(POKE_CHANNEL);
              engine.channel.onmessage = function () {
                checkInbox();
              };
            } catch (e) {
              engine.channel = null;
            }
          }
          await writeStatusNow();
          return engine;
        } finally {
          engineStarting = null;
        }
      })();
      return engineStarting;
    }

    function stillMine(gen) {
      return (locks ? lockState === 'held' && gen === lockGen : fallbackOwner());
    }

    /**
     * עוצר את המנוע. [farewell] — האם להיפרד מהחדר (יציאה מהחיבור המרוחק),
     * או רק לעצור (המנוע עובר למופע אחר של אותו מכשיר).
     */
    function haltEngine(farewell) {
      const current = engine;
      engine = null;
      if (!current) return Promise.resolve();
      timers.clearInterval(current.inboxTimer);
      timers.clearInterval(current.heartbeat);
      // כתיבה שכבר בדרך ממשיכה — היא נוחתת במפתח התקופה של המנוע הזה, ולכן
      // אינה דורסת מחזיק חדש. כתיבות נוספות לא ייצאו ([runSaves] בודקת).
      timers.clearTimeout(current.saveRetry);
      timers.clearTimeout(current.statusTimer);
      if (current.channel) {
        try {
          current.channel.close();
        } catch (e) {
          // כבר סגור.
        }
      }
      const done = farewell ? current.hub.dispose() : Promise.resolve(haltHub(current.hub));
      return done.then(function () {
        current.transport.stop();
      });
    }

    /** עצירת ה-hub בלי פרידה: טיימרים בלבד, ומי שממתין מתעורר. */
    function haltHub(hub) {
      hub._disposed = true;
      if (hub._presenceTimer) timers.clearInterval(hub._presenceTimer);
      if (hub._deskResyncTimer) timers.clearInterval(hub._deskResyncTimer);
      hub._presenceTimer = null;
      hub._deskResyncTimer = null;
      hub.wake();
    }

    /**
     * שמירה **מיידית ומאוחדת**: שינוי מוציא כתיבה מיד; שינוי בזמן שכתיבה
     * בדרך רק מסמן "מלוכלך", וכשהיא נוחתת יוצאת עוד אחת — עם המצב העדכני
     * שבאותו רגע. כך לעולם אין יותר מכתיבה אחת בדרך, ואין חלון שבו שינוי
     * ממתין לטיימר (מסירה בתוכו הייתה מאבדת אותו).
     */
    function scheduleSave() {
      const current = engine;
      if (!current) return;
      current.saveDirty = true;
      kickSave(current);
    }

    function kickSave(current) {
      if (current.saving || !current.saveDirty) return;
      if (current.saveRetry) {
        timers.clearTimeout(current.saveRetry);
        current.saveRetry = null;
      }
      // מנקים אחרי שהיא נגמרת ולא בתוכה: ריצה שמסתיימת בלי `await` הייתה
      // מנקה לפני ההשמה, ו-`saving` היה נשאר תקוע.
      const run = runSaves(current);
      current.saving = run;
      run.then(function () {
        if (current.saving === run) current.saving = null;
      });
    }

    async function runSaves(current) {
      while (current.saveDirty && engine === current && stillMine(current.gen)) {
        current.saveDirty = false;
        try {
          await writeState(current);
        } catch (e) {
          // נשאר מלוכלך, וננסה שוב בעוד רגע (גם [flushSave] תנסה).
          current.saveDirty = true;
          if (!current.saveRetry) {
            current.saveRetry = timers.setTimeout(function () {
              current.saveRetry = null;
              if (engine === current) kickSave(current);
            }, SAVE_RETRY_MS);
          }
          return;
        }
      }
    }

    /**
     * מסיימת את מה שממתין לשמירה: אם יש שינוי שלא נכתב — כותבת אותו, ואם
     * כתיבה בדרך — ממתינה לה. מחזירה `true` אם המצב שבאחסון עדכני.
     */
    async function flushSave(target) {
      const current = target || engine;
      if (!current) return true;
      kickSave(current);
      while (current.saving) await current.saving;
      return !current.saveDirty;
    }

    function scheduleStatus() {
      const current = engine;
      if (!current || current.statusTimer) return;
      current.statusTimer = timers.setTimeout(function () {
        current.statusTimer = null;
        writeStatusNow();
      }, STATUS_DEBOUNCE_MS);
    }

    async function writeHolder() {
      if (!engine || !holding()) return;
      try {
        await storageSet(KEY_HOLDER, { kind: kind(), instance: instance, at: now() });
      } catch (e) {
        // עצה בלבד; ראו [shouldSteal].
      }
    }

    async function writeStatusNow() {
      const current = engine;
      if (!current || !holding()) return;
      const snapshot = current.hub.snapshot();
      try {
        await storageSet(KEY_STATUS, {
          writtenAt: now(),
          owner: kind(),
          roomHash: current.hub.isPaired ? RemoteProtocol.hashRoomCode(current.hub.roomCode) : null,
          snapshot: snapshot,
        });
        await storageSet(KEY_HOLDER, { kind: kind(), instance: instance, at: now() });
      } catch (e) {
        // התצוגה תתעדכן בכתיבה הבאה.
      }
    }

    /**
     * קורא את מה שהלשונית השאירה: הגדרות ופקודות. רץ רק במנוע. ריצה אחת
     * בכל רגע — הנקישה והטיימר יכולים להגיע יחד.
     */
    function checkInbox() {
      const current = engine;
      if (!current) return Promise.resolve();
      if (current.inboxBusy) return current.inboxBusy;
      current.inboxBusy = (async function () {
        try {
          // כל הקריאות כאן מחמירות: קריאה שנכשלה מדלגת על הסבב, ואינה
          // מתפרשת כהגדרות ריקות (= יציאה מהחדר) או כ"אין פקודות".
          if (await handOverIfAsked(current)) return;
          const config = await readConfig();
          if (engine !== current) return;
          const key = configKey(config);
          if (key !== current.appliedConfig) {
            current.appliedConfig = key;
            await applyConfig(current, config);
          }
          if (engine !== current) return;
          const hub = current.hub;
          const roomEpoch = hub.roomEpoch;
          const keys = await storageList();
          const commands = keys.filter(function (k) {
            return k.indexOf(CMD_PREFIX) === 0;
          }).sort();
          hub.forgetCommandsExcept(commands);
          // תור יוצא שנשאר מסבב קודם (שידור שלא הספיק) — רק כשהוא כתוב.
          if (hub.outboxSize > 0 && (await persistNow(current))) await hub.flushOutbox();
          // **ביצוע עמיד, פעם אחת.** סדר הצעדים לכל פקודה:
          //   1. סימון "בוצעה" והביצוע — באותו צעד סינכרוני, ולכן כל מצב
          //      שנשמר מכיל את שניהם או אף אחד מהם;
          //   2. שמירת המצב, והמתנה שתיכתב;
          //   3. שידור פעולות השולחן שנשמרו (התור היוצא);
          //   4. רק אז מחיקת המפתח.
          // מנוע שמקבל את הבעלות בכל נקודה בדרך מוצא אחד משלושה: מפתח בלי
          // סימון במצב — מבצע (הביצוע הקודם לא שרד); מפתח עם סימון — מוחק
          // בלי לבצע; בלי מפתח — המצב כבר כולל את הביצוע. מחיקה *לפני*
          // הביצוע הייתה מאבדת פקודה שהבעלות עברה אחרי מחיקתה.
          //
          // **הודעת השולחן לחברותא יוצאת רק אחרי שהמצב נשמר.** פתיחה שיצאה
          // לפני כן, ממנוע שמת לפני השמירה, הייתה מבוצעת שוב במנוע הבא —
          // בחותמת חדשה ומאוחרת, שגוברת על סגירה שהחברותא עשתה בינתיים
          // ופותחת מחדש ספר שהיא סגרה. כך: ביצוע שלא נשמר לא השאיר דבר
          // אצל החברותא, וביצוע שנשמר משודר שוב רק כפי שנשמר — אותה חותמת,
          // שאינה גוברת על פעולה מאוחרת של החברותא.
          for (let i = 0; i < commands.length; i++) {
            if (engine !== current || !stillMine(current.gen)) return;
            if (hub.isCommandDone(commands[i])) {
              // סומנה — אבל מוחקים רק אם הסימון (ואיתו התוצאה) כבר כתוב.
              if (!(await persistNow(current)) || !persisted(current, commands[i])) return;
              await hub.flushOutbox();
              if (engine !== current || !stillMine(current.gen)) return;
              await storageRemove(commands[i]);
              continue;
            }
            const command = await storageRead(commands[i]);
            // **הפקודה שייכת לתקופת ההצטרפות שבה נשמרה.** ההגדרות נקראות שוב
            // *אחרי* קריאת הפקודה: החדר יכול היה להתחלף בזמן ההמתנה לאחסון.
            const latest = await readConfig();
            if (engine !== current || !stillMine(current.gen)) return;
            const join = joinOf(latest);
            if (joinOf(command) !== join) {
              // מתקופה שנעזבה — נפסלת: לא תשתף ספר ולא תבטל סגירה בחדר אחר,
              // וגם לא באותו חדר אחרי יציאה וחזרה.
              await storageRemove(commands[i]);
              continue;
            }
            // פקודה מתקופה שההגדרות כבר עברו אליה, והמנוע עוד לא: נשארת,
            // והסבב הבא יחיל את ההגדרות ויבצע אותה.
            if (join !== hub.joinToken || hub.roomEpoch !== roomEpoch) return;
            hub.markCommandDone(commands[i]);
            await runCommand(hub, command, true);
            // שמירה שלא נכתבה, או בעלות שאבדה: המפתח נשאר, ושום דבר לא שודר.
            // המנוע הבא יבצע אם הביצוע הזה לא שרד, או ימחק אם שרד.
            if (!(await persistNow(current)) || !persisted(current, commands[i])) return;
            await hub.flushOutbox();
            if (engine !== current || !stillMine(current.gen)) return;
            await storageRemove(commands[i]);
          }
        } catch (e) {
          // הסבב הבא ינסה שוב.
        } finally {
          current.inboxBusy = null;
        }
      })();
      return current.inboxBusy;
    }

    /**
     * לשונית שמחזיקה את המנוע ורואה בקשת מסירה מהרקע: מסיימת לכתוב את המצב
     * ומשחררת, **בלי פרידה** — המכשיר נשאר בחדר, רק המנוע עובר. בקשה
     * שנכתבה לפני שהמנוע נכנס לכאן ישנה (מסירה קודמת) ואין לה תוקף.
     *
     * שמירה שלא הצליחה — לא משחררים, כדי שהרקע לא ישחזר מצב ישן; הסבב הבא
     * ינסה שוב, ואם לא יספיק, הרקע ייקח אחרי [HANDOVER_TIMEOUT_MS] ממילא.
     */
    async function handOverIfAsked(current) {
      if (!locks || kind() !== 'foreground') return false;
      const request = await storageRead(KEY_HANDOVER);
      if (!request || typeof request.at !== 'number' || request.at < current.acquiredAt) return false;
      if (request.instance === instance) return false;
      const clean = await flushSave(current);
      if (!clean || engine !== current || !stillMine(current.gen)) return false;
      releaseLock();
      await haltEngine(false);
      return true;
    }

    async function applyConfig(current, config) {
      const hub = current.hub;
      hub.setSyncLocation(config.syncLocation !== false);
      hub.setClosePolicy(config.closePolicy);
      await hub.setDeviceName(config.name || defaultName(current.identity.deviceId));
      const room = typeof config.room === 'string' && config.room !== '' ? config.room : null;
      // חדר אחר, או אותו חדר בהצטרפות אחרת — שתיהן הצטרפות חדשה ונקייה.
      const join = joinOf(config);
      if (room !== hub.roomCode || join !== hub.joinToken) await hub.setRoom(room, { join: join });
      scheduleStatus();
    }

    /**
     * [deferred] — פקודה מהתור: פתיחה נכנסת לתור היוצא ואינה משודרת עד
     * שהמצב נשמר (ראו `prepareCarry`). בלעדיו (פקודה מהלשונית המחזיקה, בלי
     * תור באחסון) — משודרת מיד, כמו קודם.
     */
    async function runCommand(hub, command, deferred) {
      if (!command || typeof command !== 'object') return;
      if (command.type === 'carry') {
        if (deferred) hub.prepareCarry(command.bookIds);
        else await hub.carryToDesk(command.bookIds);
      }
      else if (command.type === 'dismiss' && typeof command.bookId === 'string') hub.dismissClose(command.bookId);
    }

    /** מעיר את המנוע — אם הוא כאן, ישירות; אחרת בנקישה בערוץ. */
    function poke() {
      if (engine) {
        checkInbox();
        return;
      }
      if (!Channel) return;
      try {
        const channel = new Channel(POKE_CHANNEL);
        channel.postMessage('poke');
        channel.close();
      } catch (e) {
        // המנוע יקרא את האחסון בסבב הבא שלו ממילא.
      }
    }

    // --- המצב לתצוגה --------------------------------------------------------

    async function engineHeldSomewhere() {
      if (!locks || typeof locks.query !== 'function') return null;
      try {
        const state = await locks.query();
        return (state.held || []).some(function (lock) {
          return lock.name === ENGINE_LOCK;
        });
      } catch (e) {
        return null;
      }
    }

    /**
     * המצב כפי שהלשונית מציגה אותו. ההגדרות נקראות מהאחסון ולא מהמנוע,
     * כדי שלחיצה תשתקף במסך מיד ולא רק אחרי שהמנוע קלט אותה.
     */
    async function describe() {
      const config = await readConfig(true);
      const room = typeof config.room === 'string' && config.room !== '' ? config.room : null;
      const roomHash = room ? RemoteProtocol.hashRoomCode(room) : null;
      let snapshot;
      let owner;
      if (engine && holding()) {
        snapshot = engine.hub.snapshot();
        owner = kind();
      } else {
        const status = await storageGet(KEY_STATUS);
        const held = await engineHeldSomewhere();
        const fresh = status && now() - (status.writtenAt || 0) < 3 * STATUS_HEARTBEAT_MS;
        owner = held === false ? null : status && fresh ? status.owner : held ? 'unknown' : null;
        snapshot = status && status.snapshot && status.roomHash === roomHash ? status.snapshot : null;
      }
      const identity = await storageGet(KEY_IDENTITY);
      const deviceId = identity && identity.deviceId;
      const base = snapshot || {
        transport: 'relay',
        relay: { state: room ? 'connecting' : 'idle' },
        peers: [],
        remote: null,
        localLocation: null,
        deskCount: 0,
        carryCandidates: [],
        remoteSequence: 0,
      };
      return Object.assign({}, base, {
        transport: 'relay',
        app: 'chavruta-remote',
        deviceId: deviceId || base.deviceId || null,
        deviceName: config.name || (deviceId ? defaultName(deviceId) : base.deviceName || ''),
        paired: !!room,
        // הקוד עצמו, לתצוגה בלשונית בלבד. הוא נקרא מההגדרות המקומיות
        // ואינו חלק מהמצב שהמנוע כותב — ולכן אינו נשמר בשום מקום נוסף.
        roomLabel: room || '',
        syncLocation: config.syncLocation !== false,
        closePolicy: config.closePolicy || 'ask',
        lockSupported: !!locks,
        engine: { owner: owner === undefined ? null : owner },
      });
    }

    function notOwner(extra) {
      return describe().then(function (state) {
        return Object.assign({ hasUpdate: false, engineMine: false, broadcast: false }, state, extra || {});
      });
    }

    async function writeConfig(patch) {
      // מחמירה: קריאה שנכשלה הייתה כותבת את [patch] לבדו — ומוחקת את החדר.
      const config = await readConfig();
      const next = Object.assign({}, config, patch);
      // הצטרפות לחדר — תקופה חדשה, עם אסימון חדש (ראו [joinOf]). גם חזרה
      // לחדר שכבר היינו בו (א׳→ב׳→א׳) היא תקופה חדשה.
      if (Object.prototype.hasOwnProperty.call(patch, 'room') && (patch.room || null) !== (config.room || null)) {
        next.join = randomHex(8);
      }
      await storageSet(KEY_CONFIG, next);
      poke();
      if (engine) await checkInbox();
      return next;
    }

    // --- הממשק — זהה ל-`Companion` ----------------------------------------

    return {
      RELAY_URL: relayUrl,
      ENGINE_LOCK: ENGINE_LOCK,

      get port() {
        return null;
      },

      forget: function () {},

      discover: function () {
        return Promise.resolve({ app: 'chavruta-remote' });
      },

      setInstance: function (value) {
        const next = typeof value === 'string' ? value : '';
        if (next === instance) return;
        instance = next;
      },

      get instance() {
        return instance;
      },

      /** ההרשאות שהוענקו, מ-`plugin.boot`. משמשות רק את נפילת האחורה. */
      setPermissions: function (list) {
        permissions = Array.isArray(list) ? list.slice() : [];
      },

      get lockSupported() {
        return !!locks;
      },

      get holdsEngine() {
        return !!engine && holding();
      },

      /**
       * המצב שהמנוע כאן מחזיק (לאבחון ולבדיקות), או `null` אם אינו כאן.
       * **עותק עמוק** — בדיוק מה שנשמר באחסון, ושינוי בו אינו נוגע במנוע.
       */
      engineState: function () {
        return engine && holding() ? JSON.parse(JSON.stringify(engine.hub.exportState())) : null;
      },

      hello: function () {
        return describe();
      },

      /**
       * ראו `LocalApi._handleEvents` — אותה התנהגות בדיוק, כולל מה מוחזר
       * למופע שאינו המחזיק ומתי ההמתנה הארוכה מתקצרת.
       */
      events: async function (since) {
        await ensureLock();
        if (!holding()) return notOwner();
        const current = engine || (await startEngine());
        if (!current || !holding()) return notOwner();
        const hub = current.hub;
        const asked = typeof since === 'number' ? since : -1;
        const from = asked > hub.remoteSequence ? -1 : asked;
        // עדכון שטרם נמסר אינו ממתין, גם כשהמונה של הלקוח אינו מראה אותו
        // כחדש: המונה שייך למנוע, ולקוח שחוזר אחרי העברה הלוך וחזור עשוי
        // להחזיק מספר שמתנגש במונה של המנוע הנוכחי.
        if (hub.remoteSequence <= from && !hub.hasDeskWork && !hub.hasFreshRemoteLocation) {
          await hub.waitForChange(LONG_POLL_MS, lostSignal);
          if (!holding() || engine !== current) return notOwner();
        }
        // **תשובה אחת — מתקופת חדר אחת.** `describe` ממתין לאחסון לפני
        // צילום המצב ואחריו, ובכל אחת מההמתנות החדר יכול להתחלף באותו מנוע
        // (המנוע אותו אובייקט, ולכן בדיקת הבעלות אינה תופסת את זה). תוכנית
        // שולחן מהחדר שנעזב עם מצב מהחדש, או עדכון מהחדר הקודם, היו מורים
        // לנווט, לפתוח ולסגור — ואישור המסירה היה מסמן תוכנית זהה בחדר
        // הנוכחי כ"נמסרה". קוד החדר לבדו אינו מספיק (א׳→ב׳→א׳), ולכן
        // התקופה: התוכנית, הצילום והאישור חייבים כולם להיות מאותה תקופה.
        // אחרת — בונים שוב מהמצב הנוכחי; ואם החדר ממשיך להתחלף, משיבים
        // בלי הוראות, ושום דבר אינו מסומן כנמסר.
        let plan = null;
        let snapshot = null;
        for (let attempt = 0; attempt < 3 && !snapshot; attempt++) {
          const epoch = hub.roomEpoch;
          const builtPlan = hub.deskPlan();
          const described = await describe();
          // **בעלות שוב, אחרי ההמתנה ולפני כל אישור.** בזמן ש-`describe`
          // חיכה לאחסון המנוע יכול היה לעבור למופע אחר. תשובה של מנוע שכבר
          // אינו כאן אינה מורה דבר — המנוע החדש ימסור בעצמו — ואישור מסירה
          // כאן היה נרשם במנוע מת, או נשמר ומוחק עדכון שלא נמסר.
          if (!holding() || engine !== current) return notOwner();
          if (described.roomEpoch === epoch && hub.roomEpoch === epoch) {
            plan = builtPlan;
            snapshot = described;
          }
        }
        if (!snapshot) {
          return Object.assign({}, await describe(), {
            hasUpdate: false,
            engineMine: holding() && engine === current,
            desk: { open: [], close: [] },
          });
        }
        // **ההחלטה והאישור — לפי העדכון שבתשובה, ולא לפי העדכון החי.**
        // `describe` ממתין לאחסון אחרי שתמונת המצב נלקחה, ובינתיים יכול
        // להגיע עדכון חדש; רישומו כ"נמסר" היה מוחק אותו בלי שהתוסף ראה.
        const remote = snapshot.remote;
        const location = remote ? RemoteProtocol.locationFromJson(remote.location) : null;
        const hasUpdate = !!location && hub.isFreshRemote(remote.updateId);
        if (hasUpdate) hub.markHandedToPlugin(location, remote.updateId);
        hub.markDeskPlanDelivered(plan);
        return Object.assign(
          {
            hasUpdate: hasUpdate,
            engineMine: true,
            desk: {
              open: plan.open.map(RemoteProtocol.deskEntryToJson),
              close: plan.close.map(RemoteProtocol.deskEntryToJson),
            },
          },
          snapshot
        );
      },

      publish: async function (location) {
        const parsed = RemoteProtocol.locationFromJson(location);
        if (!parsed) throw new Error('bookId and index are required');
        if (RemoteProtocol.wireTextTooLong(parsed.bookId)) {
          throw new Error('bookId must be at most ' + RemoteProtocol.MAX_WIRE_TEXT_BYTES + ' bytes');
        }
        await ensureLock();
        if (!engine || !holding()) return notOwner();
        const ref = parsed.ref && RemoteProtocol.wireTextTooLong(parsed.ref) ? null : parsed.ref;
        const broadcast = await engine.hub.publishLocal({ bookId: parsed.bookId, index: parsed.index, ref: ref });
        return Object.assign({ broadcast: broadcast, engineMine: true }, await describe());
      },

      publishDesk: async function (payload) {
        if (!payload || !Array.isArray(payload.tabs)) throw new Error('tabs must be an array');
        await ensureLock();
        if (!engine || !holding()) return notOwner();
        const broadcast = await engine.hub.publishLocalDesk(payload.tabs, {
          canClose: payload.canClose === true,
          failed: payload.failed || [],
        });
        return Object.assign({ broadcast: broadcast, engineMine: true }, await describe());
      },

      carryToDesk: async function (bookIds) {
        await this._command({ type: 'carry', bookIds: Array.isArray(bookIds) ? bookIds : [] });
        return describe();
      },

      dismissClose: async function (bookId) {
        await this._command({ type: 'dismiss', bookId: bookId });
        return describe();
      },

      _command: async function (command) {
        // הפקודה נקשרת לתקופת ההצטרפות שבה ניתנה — זו שבהגדרות עכשיו.
        const config = await readConfig();
        const stamped = Object.assign({}, command, { join: joinOf(config) });
        const current = engine;
        if (current && holding() && current.hub.joinToken === stamped.join) {
          await runCommand(current.hub, stamped);
          return;
        }
        // מפתח חדש לכל פקודה: כותב יחיד לכל מפתח, וקורא יחיד (המנוע) שמוחק.
        const key = CMD_PREFIX + now().toString(36) + '.' + randomHex(4);
        await storageSet(key, stamped);
        poke();
      },

      /** ראו `LocalApi._handleSettings`: בודקים הכל לפני ששומרים משהו. */
      setSettings: async function (settings) {
        const patch = {};
        if (settings && Object.prototype.hasOwnProperty.call(settings, 'syncLocation')) {
          if (typeof settings.syncLocation !== 'boolean') throw new Error('syncLocation must be a boolean');
          patch.syncLocation = settings.syncLocation;
        }
        if (settings && Object.prototype.hasOwnProperty.call(settings, 'closePolicy')) {
          if (['ask', 'always', 'never'].indexOf(settings.closePolicy) < 0) {
            throw new Error('closePolicy must be one of ask, always, never');
          }
          patch.closePolicy = settings.closePolicy;
        }
        await writeConfig(patch);
        return describe();
      },

      /**
       * מוותר על המנוע — הלשונית נסגרת או שהמצב מוחלף. הנעילה משוחררת
       * והמופע האחר נכנס מיד. **בלי פרידה**, כי המכשיר עצמו נשאר בחדר.
       */
      releaseEngine: function () {
        const current = engine;
        const save = current && holding() ? flushSave(current) : Promise.resolve(true);
        return save.then(function () {
          // משחררים גם אם השמירה נכשלה: המופע יוצא בכל מקרה, וגם הממתין
          // ישחזר את התקופה האחרונה שנכתבה.
          if (locks) releaseLock();
          return haltEngine(false);
        });
      },

      /**
       * יציאה מהחיבור המרוחק (מעבר לחיבור ישיר): פרידה מהחדר, עצירה ושחרור.
       * החדר נשאר שמור, כדי שחזרה למצב המרוחק תחזיר לאותה חברותא.
       */
      shutdown: function () {
        const done = haltEngine(true);
        if (locks) releaseLock();
        return done;
      },

      /**
       * כניסה לחדר, או יציאה ממנו כאשר [code] ריק. **הקוד מנורמל כאן**,
       * בדיוק כמו במתאם, ורק הוא נשמר — לשרת עצמו לא יוצא דבר מלבד הגיבוב.
       */
      setRoom: async function (code) {
        const raw = typeof code === 'string' ? code : '';
        const normalized = raw.trim() === '' ? null : RemoteProtocol.normalizeRoomCode(raw);
        await writeConfig({ room: normalized });
        return describe();
      },

      setName: async function (name) {
        if (typeof name !== 'string') throw new Error('name must be a string');
        if (RemoteProtocol.wireTextTooLong(name)) {
          throw new Error('name must be at most ' + RemoteProtocol.MAX_WIRE_TEXT_BYTES + ' bytes');
        }
        const trimmed = name.trim();
        if (trimmed === '') return describe();
        await writeConfig({ name: trimmed });
        return describe();
      },

      /** אין מתאם במצב הזה, ולכן אין גם "עולה עם המחשב". */
      startup: function () {
        return Promise.resolve({ supported: false, enabled: false });
      },

      setStartup: function () {
        return Promise.resolve({ supported: false, enabled: false });
      },
    };
  }

  const shared = create();
  shared.create = create;
  return shared;
})();

if (typeof module !== 'undefined') module.exports = RemoteLink;
