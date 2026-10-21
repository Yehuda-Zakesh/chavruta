'use strict';

/**
 * ליבת הסנכרון של החיבור המרוחק — פורט של `SyncHub` מהמתאם
 * (`companion/lib/sync_hub.dart`), שרץ בתוך מופע התוסף שמחזיק את המנוע.
 *
 * **ההחלטות כאן זהות להחלטות של המתאם, וזה מכוון:** מי חבר, מה הד, איך
 * מתמזגים פריטי שולחן ומי גובר בהתנגשות. התיעוד המלא של כל החלטה נמצא
 * ב-Dart, ליד הקוד המקורי; כאן מוסבר רק מה **שונה**:
 *
 * - **אין כאן הכרעה מי מריץ את המנוע.** במתאם זו הייתה החזקה עם תפוגה;
 *   כאן היא נעילת Web Locks של הדפדפן, ב-`remote-link.js`.
 * - **התעבורה היא שרת relay ולא UDP**, ולכן במקום מוני האבחון של הסוקט
 *   יש מצב שרת (`relay` ב-[snapshot]).
 * - **המצב שורד החלפת מנוע.** במתאם הוא חי כל זמן שהתהליך חי; כאן המנוע
 *   עובר בין הלשונית לרקע, ולכן [exportState]/[importState] שומרים את
 *   מה שאסור לאבד — השולחן, המצבות והשעון הלוגי.
 */
const RemoteHub = (function () {
  const P = RemoteProtocol;

  /** ראו `echoWindow`. */
  const ECHO_WINDOW_MS = 6000;
  /** ראו `presenceInterval`. */
  const PRESENCE_INTERVAL_MS = 20000;
  /** ראו `peerTimeout`. */
  const PEER_TIMEOUT_MS = 70000;
  /** ראו `deskResyncInterval`. */
  const DESK_RESYNC_INTERVAL_MS = 60000;
  /** ראו `deskTombstoneTtl`. */
  const DESK_TOMBSTONE_TTL_MS = 60 * 60 * 1000;
  /** ראו `maxPeers`. */
  const MAX_PEERS = 12;
  /** סימוני פקודות שבוצעו — חסם לזיכרון; ראו [markCommandDone]. */
  const MAX_DONE_COMMANDS = 200;
  /**
   * כמה זמן אחרי שזזנו בעצמנו ושידרנו את המקום, נוכחות של חברותא שנושאת
   * מקום אחר **אינה** מאומצת. הנוכחות שלה יוצאת פעם בפעימה, ולכן ייתכן
   * שנשלחה לפני שהיא קיבלה את המעבר שלנו — אימוץ שלה היה גורר אותנו
   * אחורה. פעימה אחת ועוד חלון ההד מכסים את ההודעה שהייתה כבר בדרך.
   */
  const PRESENCE_ADOPT_GUARD_MS = PRESENCE_INTERVAL_MS + ECHO_WINDOW_MS;

  const CLOSE_POLICIES = ['ask', 'always', 'never'];

  /**
   * @param {object} options
   *   - `deviceId`: מזהה המכשיר (יציב).
   *   - `transport`: `{ send(message), retarget(roomHash), status() }`.
   *   - `now`: שעון (לבדיקות). ברירת מחדל `Date.now`.
   *   - `timers`: `{ setInterval, clearInterval, setTimeout, clearTimeout }`.
   *   - `log`: יומן אבחון.
   *   - `onChange`: נקרא בכל שינוי מצב, כדי שהמצב יישמר וידווח ללשונית.
   */
  function Hub(options) {
    this.deviceId = options.deviceId;
    this.deviceName = options.deviceName || '';
    this.readiness = options.readiness || null;
    this.roomCode = null;
    this.syncLocation = true;
    this.closePolicy = 'ask';
    this.transport = options.transport;
    this._now = options.now || Date.now;
    this._timers = options.timers || {
      setInterval: setInterval,
      clearInterval: clearInterval,
      setTimeout: setTimeout,
      clearTimeout: clearTimeout,
    };
    this._log = options.log || function () {};
    this._onChange = options.onChange || function () {};

    this._outgoingSequence = 0;
    this._peers = new Map();
    /**
     * המקום האחרון של מחובר שפג תוקפו ([PEER_TIMEOUT_MS]) **בלי להיפרד**:
     * זה ניתוק, לא יציאה. כשהוא חוזר, הנוכחות שלו מושווית למקום הזה, ולכן
     * מקום שעבר אליו בזמן הניתוק (והודעתו אבדה) משוחזר. מי שנפרד (`bye`)
     * נמחק גם מכאן — הצטרפותו הבאה היא הצטרפות ראשונה, בלי ניווט.
     */
    this._knownLocations = new Map();
    this._remoteSequence = 0;
    /**
     * תקופת החדר: עולה בכל [setRoom]. תשובה שנבנתה בתקופה אחת אינה תקפה
     * באחרת — גם כשהחדר חזר להיות אותו חדר (א׳→ב׳→א׳), כי המצב שלו נוקה
     * ונבנה מחדש. ראו `events` ב-`RemoteLink`.
     */
    this._roomEpoch = 0;
    /**
     * אסימון ההצטרפות שהמצב הזה שייך לו (`join` בהגדרות). נשמר עם המצב,
     * ומנוע חדש משחזר מצב רק כשהאסימון שלו הוא של ההגדרות — ההצטרפות
     * הנוכחית. משתנה רק יחד עם ניקוי המצב ([setRoom]), ולכן מצב שנשמר תמיד
     * תואם לאסימון שנשמר איתו.
     */
    this.joinToken = '';
    /**
     * מפתחות הפקודות שבוצעו (ראו `checkInbox` ב-`RemoteLink`). חלק מהמצב
     * השמור: הסימון נכנס *יחד* עם תוצאת הפקודה, ולכן כל מצב ששרד מכיל את
     * שניהם או אף אחד מהם — והמנוע הבא יודע אם לבצע.
     */
    this._doneCommands = [];
    /** פעולות שולחן שנשמרו וטרם שודרו — ראו [prepareCarry]. */
    this._outbox = [];
    /**
     * פעולות מהתור היוצא שהמצב שמכיל אותן **טרם נכתב**. הן כבר בשולחן
     * (ובתור), ולכן כל מסלול שמשדר מהשולחן — הצטרפות מכשיר, `resync`,
     * הסנכרון התקופתי, דיווח טאבים, [flushOutbox] — היה מוציא אותן. הסינון
     * הוא ב-[_sendDesk], שכל שידור שולחן עובר דרכו; השחרור רק ב-[confirmSaved].
     */
    this._pendingSave = [];
    this._remote = null;
    this._localLocation = null;
    this._desk = new Map();
    this._localTabs = new Map();
    this._undeliverable = new Set();
    this._dismissedCloses = new Set();
    this._sawFirstReport = false;
    this._pluginCanClose = false;
    this._lastStamp = 0;
    this._badStampBook = null;
    this._warnedPeerLimit = false;
    this._deliveredDeskPlanKey = null;
    this._lastHandedToPlugin = null;
    this._lastHandedToPluginAtMs = 0;
    this._lastHandedUpdateId = 0;
    this._lastBroadcastMoveMs = null;
    this._lastFromSender = new Map();
    this._waiters = [];
    this._presenceTimer = null;
    this._deskResyncTimer = null;
    this._disposed = false;
  }

  Hub.prototype = {
    get isPaired() {
      return typeof this.roomCode === 'string' && this.roomCode !== '';
    },

    get remoteSequence() {
      return this._remoteSequence;
    },

    get roomEpoch() {
      return this._roomEpoch;
    },

    _changed: function () {
      try {
        this._onChange();
      } catch (e) {
        // מאזין השינוי שומר מצב; תקלה בו אינה מפילה את הסנכרון.
      }
    },

    start: function () {
      const self = this;
      this._presenceTimer = this._timers.setInterval(function () {
        self._announcePresence();
      }, PRESENCE_INTERVAL_MS);
      this._deskResyncTimer = this._timers.setInterval(function () {
        self._resyncDesk();
      }, DESK_RESYNC_INTERVAL_MS);
      // התור היוצא שוחזר ממצב שנשמר — משדרים אותו כפי שהוא (אותן חותמות).
      if (this.isPaired) return this._announcePresence().then(this.flushOutbox.bind(this));
      return Promise.resolve();
    },

    _resyncDesk: function () {
      if (!this.isPaired || this._peers.size === 0 || this._desk.size === 0) return Promise.resolve();
      return this._broadcastDesk();
    },

    /**
     * השרת איבד היסטוריה או התאפס — ראו `RelayTransport`. ההודעות שנשלחו
     * בפער לא יגיעו לעולם, ולכן משדרים מחדש את כל מה שהחברותא צריכה
     * כדי להתיישר: נוכחות (עם המקום שלנו) והשולחן כולו.
     */
    resync: function () {
      if (!this.isPaired) return Promise.resolve();
      const self = this;
      return this._announcePresence().then(function () {
        return self._broadcastDesk();
      });
    },

    /**
     * מחליף את קוד החדר ([normalized] כבר מנורמל, או `null` ליציאה).
     * יוצא מהחדר הקודם בפרידה, מנקה את מצבו, ומכריז נוכחות בחדר החדש.
     * ראו `SyncHub.setRoom`.
     *
     * [options.join] — אסימון ההצטרפות (ראו [joinToken]). **אסימון אחר
     * לאותו חדר הוא הצטרפות חדשה**: פרידה, ניקוי והכרזה, בדיוק כמו החלפת
     * חדר — כך א׳→ב׳→א׳ שהמנוע ראה רק את סופו אינו ממשיך את ההצטרפות שנעזבה.
     */
    setRoom: async function (normalized, options) {
      const next = normalized === '' ? null : normalized;
      const join = options && typeof options.join === 'string' ? options.join : this.joinToken;
      if (next === this.roomCode && join === this.joinToken) return;
      if (next === null && this.roomCode === null) {
        this.joinToken = join;
        this._changed();
        return;
      }
      if (this.isPaired) {
        try {
          await this._send(this._buildMessage(P.TYPES.bye), { farewell: true });
        } catch (e) {
          // פרידה שלא יצאה: החברותא תסיק את היציאה מהשקט.
        }
      }
      this.roomCode = next;
      this.joinToken = join;
      this._roomEpoch++;
      this._lastBroadcastMoveMs = null;
      this._peers.clear();
      this._knownLocations.clear();
      this._lastFromSender.clear();
      this._remote = null;
      this._lastHandedToPlugin = null;
      this._desk.clear();
      this._undeliverable.clear();
      this._dismissedCloses.clear();
      this._outbox = [];
      this._pendingSave = [];
      this._lastStamp = 0;
      this._badStampBook = null;
      this._remoteSequence++;
      // **התעבורה מכוונת מחדש רק אחרי שהמצב נוקה**, כדי שהודעה מהחדר
      // הקודם שעוד בדרך לא תיפול על חדר חדש ונקי. התעבורה עצמה פוסלת את
      // הבקשה הפתוחה ואת כל תשובה ישנה שתחזור ממנה.
      this.transport.retarget(this.isPaired ? P.hashRoomCode(this.roomCode) : null);
      this._wakeWaiters();
      this._changed();
      this._log(next === null ? 'יצאת מהחברותא' : 'הצטרפת לחברותא');
      if (this.isPaired) await this._announcePresence();
    },

    setDeviceName: function (name) {
      const trimmed = String(name || '').trim();
      if (trimmed === '' || trimmed === this.deviceName) return Promise.resolve();
      this.deviceName = trimmed;
      this._changed();
      return this.isPaired ? this._announcePresence() : Promise.resolve();
    },

    setSyncLocation: function (enabled) {
      if (enabled === this.syncLocation) return;
      this.syncLocation = enabled;
      this._wakeWaiters();
      this._changed();
    },

    setClosePolicy: function (policy) {
      const value = CLOSE_POLICIES.indexOf(policy) >= 0 ? policy : 'ask';
      if (value === this.closePolicy) return;
      this.closePolicy = value;
      this._wakeWaiters();
      this._changed();
    },

    /** ראו `SyncHub.publishLocal`. */
    publishLocal: async function (location) {
      this._localLocation = location;
      const handed = this._lastHandedToPlugin;
      const sinceHanded = this._now() - this._lastHandedToPluginAtMs;
      const echo = !!handed && P.sameSpot(location, handed) && sinceHanded < ECHO_WINDOW_MS;
      const broadcast = this.isPaired && this.syncLocation && !echo;
      // **תחילת חלון ההגנה לפני ההודעה על השינוי**: השמירה לוכדת את המצב
      // ברגע ההודעה, ומנוע שיחליף את זה בתוך החלון חייב לדעת שזזנו.
      if (broadcast) this._lastBroadcastMoveMs = this._now();
      this._changed();
      if (!broadcast) return false;
      await this._send(this._buildMessage(P.TYPES.loc, { location: location }));
      return true;
    },

    /**
     * [location] נמסר לתוסף. [updateId] — המזהה של העדכון *שנמסר*, כפי
     * שהופיע בתשובה; בלעדיו, של העדכון הנוכחי. עדכון שהגיע אחרי שהתשובה
     * נבנתה נשאר טרי, ונמסר בסבב הבא.
     *
     * **המזהה מקומי, ולא חותמת הזמן של השולח**: חותמת אינה ייחודית (שני
     * עדכונים באותה אלפית שנייה), ואינה בת השוואה בין מחשבים — מחשב
     * ששעונו מפגר, בחדר חדש, היה נחסם בחותמת שנמסרה בחדר הקודם. המזהה
     * הוא ערך [_remoteSequence] ברגע האימוץ: עולה תמיד, גם בין חדרים וגם
     * בין מנועים (ראו [importState]).
     */
    markHandedToPlugin: function (location, updateId) {
      const handed = typeof updateId === 'number' ? updateId : this._remote ? this._remote.updateId : 0;
      this._lastHandedToPlugin = location;
      this._lastHandedToPluginAtMs = this._now();
      this._lastHandedUpdateId = Math.max(this._lastHandedUpdateId, handed);
      // "נמסר" הוא חלק מהמצב השמור: בלי שמירה כאן, מסירת מנוע הייתה
      // טוענת את הרשומה הקודמת ומנווטת שוב למקום שכבר נמסר.
      this._changed();
    },

    get hasFreshRemoteLocation() {
      return !!this._remote && this.isFreshRemote(this._remote.updateId);
    },

    /** העדכון [updateId] טרם נמסר לתוסף. ראו [markHandedToPlugin]. */
    isFreshRemote: function (updateId) {
      return typeof updateId === 'number' && updateId > this._lastHandedUpdateId;
    },

    doneCommandKeys: function () {
      return this._doneCommands.slice();
    },

    isCommandDone: function (key) {
      return this._doneCommands.indexOf(key) >= 0;
    },

    /**
     * מסמן שהפקודה [key] בוצעה — מיד לפני הביצוע, באותו צעד סינכרוני.
     *
     * **בלי הודעת שינוי, בכוונה**: ההודעה מפעילה שמירה שלוכדת את המצב
     * מיד — עם הסימון ועוד בלי התוצאה. מצב כזה ששרד היה מוחק פקודה שלא
     * בוצעה. הביצוע עצמו (או המתקשר, כשאין לו תוצאה) מודיע על השינוי, והשמירה
     * לוכדת את שניהם יחד.
     */
    markCommandDone: function (key) {
      if (this.isCommandDone(key)) return;
      this._doneCommands.push(key);
      if (this._doneCommands.length > MAX_DONE_COMMANDS) this._doneCommands.shift();
    },

    /** שוכח סימונים של פקודות שכבר אינן באחסון ([present]). */
    forgetCommandsExcept: function (present) {
      const keep = this._doneCommands.filter(function (key) {
        return present.indexOf(key) >= 0;
      });
      if (keep.length === this._doneCommands.length) return;
      this._doneCommands = keep;
      this._changed();
    },

    /** ממשיך את מונה `events` ממנוע קודם, בלי לשחזר את מצבו (הצטרפות אחרת). */
    continueSequence: function (sequence) {
      if (Number.isInteger(sequence) && sequence >= 0) {
        this._remoteSequence = Math.max(this._remoteSequence, sequence) + 1;
      }
    },

    /** ראו `SyncHub.dismissClose`. */
    dismissClose: function (bookId) {
      if (!this._desk.has(bookId)) return;
      this._dismissedCloses.add(bookId);
      this._wakeWaiters();
      this._changed();
    },

    /** ראו `SyncHub._makeDeskRoom` — כולל התנאי שמייצב שני שולחנות מלאים. */
    _makeDeskRoom: function (incomingStamp) {
      if (this._desk.size < P.MAX_TRACKED_TABS) return true;
      const cutoff = this._now() - DESK_TOMBSTONE_TTL_MS;
      for (const [key, entry] of Array.from(this._desk.entries())) {
        if (!entry.open && entry.stamp < cutoff) this._desk.delete(key);
      }
      if (this._desk.size < P.MAX_TRACKED_TABS) return true;
      let oldest = null;
      for (const entry of this._desk.values()) {
        if (entry.open) continue;
        if (this._localTabs.has(entry.bookId)) continue;
        if (!oldest || entry.stamp < oldest.stamp) oldest = entry;
      }
      if (!oldest || oldest.stamp >= incomingStamp) return false;
      this._desk.delete(oldest.bookId);
      return true;
    },

    _nextStamp: function () {
      const wall = this._now();
      this._lastStamp = wall > this._lastStamp ? wall : this._lastStamp + 1;
      return this._lastStamp;
    },

    _observeStamp: function (stamp) {
      if (!this._stampInWindow(stamp)) return;
      if (stamp > this._lastStamp) this._lastStamp = stamp;
    },

    /** ראו `SyncHub._stampInWindow`. */
    _stampInWindow: function (stamp) {
      if (stamp < 0) return false;
      return Math.abs(stamp - this._now()) <= P.FRESHNESS_WINDOW_MS;
    },

    /**
     * התוסף מדווח מה פתוח כאן עכשיו — תמונת מצב מלאה. [tabs] הם
     * `{ b, i }` כפי שהתוסף שולח ל-`/tabs`. ראו `SyncHub.publishLocalDesk`
     * ו-`LocalApi._localEntries`.
     */
    publishLocalDesk: async function (tabs, options) {
      const opts = options || {};
      const localTabs = localEntries(tabs);
      this._pluginCanClose = opts.canClose === true;
      const failed = failedBookIds(opts.failed);
      for (let i = 0; i < failed.length; i++) this._undeliverable.add(failed[i]);
      const reported = new Set(localTabs.map(function (t) { return t.bookId; }));
      for (const key of Array.from(this._undeliverable)) {
        if (reported.has(key)) this._undeliverable.delete(key);
      }

      const previous = new Map(this._localTabs);
      this._localTabs.clear();
      localTabs.slice(0, P.MAX_TRACKED_TABS).forEach(function (tab) {
        this._localTabs.set(tab.bookId, tab);
      }, this);

      const firstReport = !this._sawFirstReport;
      this._sawFirstReport = true;

      const operations = [];
      for (const tab of this._localTabs.values()) {
        const current = this._desk.get(tab.bookId);
        if (current && current.open) continue;
        if (this._dismissedCloses.has(tab.bookId)) continue;
        if (firstReport || previous.has(tab.bookId)) continue;
        operations.push(P.deskEntry(tab.bookId, this._nextStamp(), this.deviceId, tab.index, true));
      }
      for (const key of previous.keys()) {
        if (reported.has(key)) continue;
        const current = this._desk.get(key);
        this._dismissedCloses.delete(key);
        if (!current || !current.open) continue;
        operations.push(P.deskEntry(key, this._nextStamp(), this.deviceId, current.index, false));
      }

      operations.forEach(function (op) {
        this._desk.set(op.bookId, op);
      }, this);
      if (operations.length > 0) {
        this._remoteSequence++;
        this._wakeWaiters();
      }
      this._changed();
      if (!this.isPaired || operations.length === 0) return 0;
      await this._sendDesk(operations);
      return operations.length;
    },

    carryCandidates: function () {
      const out = [];
      for (const tab of this._localTabs.values()) {
        const shared = this._desk.get(tab.bookId);
        if (!(shared && shared.open) && !this._dismissedCloses.has(tab.bookId)) out.push(tab);
      }
      return out;
    },

    /** ראו `SyncHub.carryToDesk`. */
    carryToDesk: async function (bookIds) {
      const operations = this._carryOperations(bookIds);
      if (operations.length > 0 && this.isPaired) await this._sendDesk(operations);
      return operations.length;
    },

    /**
     * כמו [carryToDesk], **בלי לשדר**: הפעולות (זהות, חותמת ותוכן — קבועים
     * מעכשיו) מוחלות על השולחן ונכנסות לתור היוצא, שנשמר עם המצב. השידור
     * רק ב-[flushOutbox], אחרי שהמצב נכתב.
     *
     * כך ביצוע שאבד לפני שנשמר לא השאיר פעולה אצל החברותא, והניסיון החוזר
     * הוא הפעולה הראשונה; וביצוע שנשמר משודר שוב רק *כפי שהוא* — אותה
     * חותמת, שאינה גוברת על סגירה מאוחרת של החברותא. פתיחה חדשה בחותמת
     * חדשה הייתה דורסת אותה.
     */
    prepareCarry: function (bookIds) {
      return this._carryOperations(bookIds, this._outbox).length;
    },

    /**
     * משדר את התור היוצא ומרוקן את מה ששודר. **רק מצב שנשמר**: המתקשר
     * מבטיח שהתור כפי שהוא נכתב לאחסון (ראו `checkInbox` ב-`RemoteLink`).
     */
    flushOutbox: async function () {
      if (!this.isPaired) return;
      const pending = this._pendingSave;
      const batch = this._outbox.filter(function (op) {
        return pending.indexOf(op) < 0;
      });
      if (batch.length === 0) return;
      // שידור שנקטע בהחלפת חדר: התור כבר שייך לתקופה אחרת ואין בו מה לסמן.
      if (!(await this._sendDesk(batch))) return;
      this._outbox = this._outbox.filter(function (op) {
        return batch.indexOf(op) < 0;
      });
      this._changed();
    },

    /**
     * המצב [saved] נכתב לאחסון בהצלחה: הפעולות שבתור שלו — ורק הן, לפי זהות
     * (ספר, חותמת, כותב) — משתחררות לשידור. פעולה שנוספה אחרי שהמצב נלכד
     * לכתיבה נשארת ממתינה עד הכתיבה הבאה.
     */
    confirmSaved: function (saved) {
      const written = saved && Array.isArray(saved.outbox) ? saved.outbox : [];
      if (written.length === 0 || this._pendingSave.length === 0) return;
      this._pendingSave = this._pendingSave.filter(function (op) {
        return !written.some(function (raw) {
          return raw && raw.b === op.bookId && raw.s === op.stamp && raw.w === op.by;
        });
      });
    },

    get outboxSize() {
      return this._outbox.length;
    },

    /** [queue] — התור היוצא, כשהשידור נדחה: נכנס *לפני* הודעת השינוי, כדי
     * שכל מצב שנשמר יכיל את הפעולות גם בשולחן וגם בתור. */
    _carryOperations: function (bookIds, queue) {
      const operations = [];
      (Array.isArray(bookIds) ? bookIds : []).forEach(function (bookId) {
        if (typeof bookId !== 'string') return;
        const tab = this._localTabs.get(bookId);
        if (!tab) return;
        const shared = this._desk.get(bookId);
        if (shared && shared.open) return;
        this._dismissedCloses.delete(bookId);
        operations.push(P.deskEntry(bookId, this._nextStamp(), this.deviceId, tab.index, true));
      }, this);
      if (operations.length === 0) return operations;
      operations.forEach(function (op) {
        this._desk.set(op.bookId, op);
        if (queue) {
          queue.push(op);
          this._pendingSave.push(op);
        }
      }, this);
      this._remoteSequence++;
      this._wakeWaiters();
      this._changed();
      return operations;
    },

    /** ראו `SyncHub.deskPlan`. */
    deskPlan: function () {
      const open = [];
      const close = [];
      for (const entry of this._desk.values()) {
        if (entry.open) {
          if (this._localTabs.has(entry.bookId)) continue;
          if (this._undeliverable.has(entry.bookId)) continue;
          open.push(entry);
        } else {
          if (!this._pluginCanClose || this.closePolicy === 'never') continue;
          if (this._dismissedCloses.has(entry.bookId)) continue;
          if (!this._localTabs.has(entry.bookId)) continue;
          close.push(entry);
        }
      }
      return { open: open, close: close };
    },

    get hasDeskWork() {
      const plan = this.deskPlan();
      if (plan.open.length === 0 && plan.close.length === 0) return false;
      return deskPlanKey(plan) !== this._deliveredDeskPlanKey;
    },

    markDeskPlanDelivered: function (plan) {
      this._deliveredDeskPlanKey =
        plan.open.length === 0 && plan.close.length === 0 ? null : deskPlanKey(plan);
    },

    _broadcastDesk: function () {
      if (!this.isPaired || this._desk.size === 0) return Promise.resolve();
      return this._sendDesk(Array.from(this._desk.values()));
    },

    /** ראו `SyncHub._sendDesk`: מנות לפי מספר פריטים **ולפי בייטים**. */
    _sendDesk: async function (all) {
      // **מחסום השמירה**: פעולה שהמצב שלה טרם נכתב אינה יוצאת — באף מסלול.
      const pending = this._pendingSave;
      const entries = pending.length === 0 ? all : all.filter(function (entry) {
        return pending.indexOf(entry) < 0;
      });
      // **השידור כולו שייך לתקופת החדר שבה התחיל.** בין מנה למנה יש המתנה
      // לתעבורה, ובה החדר יכול להתחלף; המנה הבאה הייתה נבנית עם קוד החדר
      // החדש ([_buildMessage]) ומוסרת לחברותא בחדר אחר ספרים שנבחרו בחדר
      // הקודם. התקופה ולא קוד החדר: גם א׳→ב׳→א׳ פוסל את השידור הישן, כי מצב
      // החדר נוקה ונבנה מחדש. מחזיר אם השידור הושלם.
      const epoch = this._roomEpoch;
      let index = 0;
      while (index < entries.length) {
        if (this._roomEpoch !== epoch || this._disposed) return false;
        const chunk = [];
        let bytes = 200 + P.utf8Length(this.deviceName);
        while (index < entries.length && chunk.length < P.MAX_TABS_PER_MESSAGE) {
          const size = P.utf8Length(JSON.stringify(P.deskEntryToJson(entries[index]))) + 1;
          if (chunk.length > 0 && bytes + size > P.MAX_DESK_PAYLOAD_BYTES) break;
          chunk.push(entries[index]);
          bytes += size;
          index++;
        }
        await this._send(this._buildMessage(P.TYPES.desk, { entries: chunk }));
      }
      return this._roomEpoch === epoch;
    },

    /** ראו `SyncHub._mergeRemoteDesk`. */
    _mergeRemoteDesk: function (entries) {
      let changed = false;
      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        if (P.wireTextTooLong(entry.bookId) || P.wireTextTooLong(entry.by)) continue;
        if (!this._stampInWindow(entry.stamp)) {
          if (this._badStampBook !== entry.bookId) {
            this._badStampBook = entry.bookId;
            this._log(
              'פריט שולחן נזרק: החותמת של "' + entry.bookId +
                '" חורגת מחלון הסבילות. בדקו את השעה בשני המחשבים.'
            );
          }
          continue;
        }
        this._observeStamp(entry.stamp);
        const current = this._desk.get(entry.bookId);
        if (current && !P.supersededBy(current, entry)) continue;
        if (!current && !this._makeDeskRoom(entry.stamp)) continue;
        this._desk.set(entry.bookId, entry);
        if (entry.open) {
          this._undeliverable.delete(entry.bookId);
          this._dismissedCloses.delete(entry.bookId);
        }
        changed = true;
      }
      if (!changed) return;
      this._remoteSequence++;
      this._changed();
    },

    /** הכרזת נוכחות מבחוץ — ראו `onJoined` ב-`RelayTransport`. */
    announce: function () {
      return this._announcePresence();
    },

    /**
     * הנוכחות נושאת את המקום שלנו, כי החברותא משחזרת ממנה מקום שהודעת ה-`loc`
     * שלו אבדה (ראו `handleInbound`). **כשמקום הלימוד כבוי היא אינה נושאת
     * אותו** — אחרת החברותא הייתה מאמצת את המקום שלנו אף שכיבינו את השיתוף.
     */
    _announcePresence: function () {
      if (!this.isPaired) return Promise.resolve();
      const location = this.syncLocation ? this._localLocation : null;
      const self = this;
      return this._send(this._buildMessage(P.TYPES.hi, { location: location })).then(function () {
        if (self.readiness) return self._send(self._buildMessage(P.TYPES.ready, { readiness: self.readiness }));
      });
    },

    /**
     * שליחה שאינה זורקת: אובדן הודעה כאן שקול לאובדן datagram במתאם, והשידור
     * המלא התקופתי מתקן אותו. התעבורה מדווחת את הכשל במצב השרת.
     * [options] עוברות לתעבורה כמות שהן — `{ farewell: true }` לפרידה מכוונת.
     */
    _send: function (message, options) {
      if (this._disposed && message.type !== P.TYPES.bye) return Promise.resolve();
      // **השליחה עצמה סינכרונית**: ההודעה נמסרת לתעבורה כבר בקריאה, כדי
      // שסדר ההודעות יישאר סדר הקריאות. רק התוצאה נבלעת.
      let sending;
      try {
        sending = options ? this.transport.send(message, options) : this.transport.send(message);
      } catch (e) {
        return Promise.resolve();
      }
      return Promise.resolve(sending).catch(function () {});
    },

    _buildMessage: function (type, extra) {
      const more = extra || {};
      return {
        type: type,
        roomHash: P.hashRoomCode(this.roomCode || ''),
        senderId: this.deviceId,
        senderName: this.deviceName,
        timestampMs: this._now(),
        sequence: ++this._outgoingSequence,
        location: more.location || null,
        entries: more.entries || [],
        readiness: more.readiness || null,
      };
    },

    /** ראו `SyncHub._handleInbound` — כולל הסדר: סינון כפילויות לפני `bye`. */
    handleInbound: function (message) {
      if (message.senderId === this.deviceId) return;
      const now = this._now();
      // אבחון אינו מקדם את סף הסנכרון. ready מאוחר עדיין נבדק גם מול
      // הסנכרון, כדי שלא יחזיר חבר שכבר נפרד בהודעת bye חדשה יותר.
      const diagnostic = message.type === P.TYPES.ready;
      const senderKey = JSON.stringify([message.senderId, diagnostic]);
      const last = this._lastFromSender.get(senderKey);
      const previous = [last];
      if (diagnostic) previous.push(this._lastFromSender.get(JSON.stringify([message.senderId, false])));
      for (const last of previous) {
        if (message.type === P.TYPES.desk || !last) continue;
        const duplicate = message.sequence === last.sequence && message.timestampMs === last.timestampMs;
        const recent = now - last.receivedAtMs <= PEER_TIMEOUT_MS;
        const older = message.sequence <= last.sequence && message.timestampMs <= last.timestampMs;
        if (duplicate || (older && recent)) return;
      }
      const advances = !last || message.sequence > last.sequence || message.timestampMs > last.timestampMs;
      this._lastFromSender.set(senderKey, {
        sequence: advances ? message.sequence : last.sequence,
        timestampMs: advances ? message.timestampMs : last.timestampMs,
        receivedAtMs: now,
      });

      if (message.type === P.TYPES.bye) {
        // **השכחה היא שינוי גם כשהמכשיר כבר אינו ברשימה** (פג תוקפו לפני
        // הפרידה): בלי שמירה, מנוע חדש היה טוען את המקום הישן מהמצב השמור,
        // והצטרפות מחדש הייתה מנווטת — במקום להיות הצטרפות ראשונה.
        const forgot = this._knownLocations.delete(message.senderId);
        const left = this._peers.delete(message.senderId);
        if (left) this._wakeWaiters();
        if (left || forgot) this._changed();
        return;
      }

      let peer = this._peers.get(message.senderId);
      if (!peer) {
        if (this._peers.size >= MAX_PEERS) {
          this._prunePeers();
          if (this._peers.size >= MAX_PEERS) {
            if (!this._warnedPeerLimit) {
              this._warnedPeerLimit = true;
              this._log('רשימת המחוברים הגיעה ל-' + MAX_PEERS + '; מתעלם ממכשירים נוספים.');
            }
            return;
          }
        }
        // חוזר מניתוק: בסיס ההשוואה הוא המקום שידענו לפני שפג תוקפו.
        const remembered = this._knownLocations.get(message.senderId) || null;
        this._knownLocations.delete(message.senderId);
        peer = { id: message.senderId, name: message.senderName, lastSeenMs: now, lastLocation: remembered };
        this._peers.set(message.senderId, peer);
        this._log('הצטרף: ' + message.senderName);
        this._broadcastDesk();
        this._announcePresence();
      } else {
        peer.name = message.senderName;
        peer.lastSeenMs = now;
      }
      if (message.type === P.TYPES.ready && message.readiness) {
        peer.readiness = P.readinessFromJson(message.readiness);
        peer.readinessAt = now;
      }

      if (message.type === P.TYPES.desk) {
        this._mergeRemoteDesk(message.entries);
        this._wakeWaiters();
        this._changed();
        return;
      }

      const location = message.location;
      if (message.type === P.TYPES.loc && location) {
        if (!P.sameSpot(location, this._localLocation)) this._adoptRemote(message);
        peer.lastLocation = location;
      } else if (message.type === P.TYPES.hi && location) {
        // **נוכחות משחזרת מקום שהודעת ה-`loc` שלו אבדה** (איפוס השרת, פער
        // בהיסטוריה): `resync` של החברותא, או סתם הפעימה הבאה שלה, נושאים את
        // המקום העדכני שלה. מאמצים אותו רק כשהוא שונה ממה שידענו עליה —
        // כלומר היא זזה ואנחנו פספסנו. נוכחות ראשונה אחרי הצטרפות אינה ניווט
        // (אין "קודם" להשוות אליו), מקום שכבר שלנו אינו עדכון (כך ההד של
        // הניווט לשם אינו חוזר כעדכון), ומי שזז זה עתה בעצמו אינו נגרר
        // אחורה בנוכחות שאולי יצאה לפני שהחברותא קיבלה את המעבר שלו.
        const known = peer.lastLocation;
        const movedRecently =
          this._lastBroadcastMoveMs !== null && now - this._lastBroadcastMoveMs < PRESENCE_ADOPT_GUARD_MS;
        const moved = known && !P.sameSpot(location, known) && !P.sameSpot(location, this._localLocation);
        if (moved && movedRecently) {
          // **נדחה, ולא נבלע: בסיס ההשוואה נשאר כשהיה.** ההגנה אומרת רק
          // "עוד מוקדם לדעת" — אולי הנוכחות יצאה לפני שהחברותא קיבלה את
          // המעבר שלנו. עדכון הבסיס כאן היה הופך את הדחייה לוויתור: הנוכחות
          // הבאה, באותו מקום, כבר נראית "לא זזה", והמקום שהודעת ה-`loc` שלו
          // אבדה לא היה משוחזר לעולם. אם החברותא באמת עברה אלינו, הנוכחות
          // הבאה שלה נושאת את המקום שלנו — וזה מעדכן את הבסיס למטה.
        } else {
          if (moved) this._adoptRemote(message);
          peer.lastLocation = location;
        }
      }
      this._wakeWaiters();
      this._changed();
    },

    /** המקום של [message] הופך למקום המרוחק שהתוסף ינווט אליו. */
    _adoptRemote: function (message) {
      this._remoteSequence++;
      this._remote = {
        location: message.location,
        fromId: message.senderId,
        fromName: message.senderName,
        timestampMs: message.timestampMs,
        updateId: this._remoteSequence,
      };
    },

    _prunePeers: function () {
      const now = this._now();
      const before = this._peers.size;
      for (const [id, peer] of Array.from(this._peers.entries())) {
        if (peer.lastSeenMs < now - PEER_TIMEOUT_MS) {
          this._peers.delete(id);
          this._remember(id, peer.lastLocation);
        }
      }
      if (this._peers.size !== before) {
        this._warnedPeerLimit = false;
        this._wakeWaiters();
      }
      for (const [id, last] of Array.from(this._lastFromSender.entries())) {
        if (last.receivedAtMs < now - P.FRESHNESS_WINDOW_MS) this._lastFromSender.delete(id);
      }
    },

    /** ראו [_knownLocations]. חסום ל-[MAX_PEERS]; הוותיק ביותר יוצא ראשון. */
    _remember: function (id, location) {
      if (!location) return;
      this._knownLocations.delete(id);
      if (this._knownLocations.size >= MAX_PEERS) {
        this._knownLocations.delete(this._knownLocations.keys().next().value);
      }
      this._knownLocations.set(id, location);
    },

    /**
     * ממתין לשינוי במצב או עד שיפוג הזמן. [abort] — הבטחה שסיומה מקצר את
     * ההמתנה (אובדן הנעילה, שינוי הגדרות מהלשונית).
     */
    waitForChange: function (timeoutMs, abort) {
      const self = this;
      return new Promise(function (resolve) {
        let done = false;
        const finish = function () {
          if (done) return;
          done = true;
          self._timers.clearTimeout(timer);
          const at = self._waiters.indexOf(finish);
          if (at >= 0) self._waiters.splice(at, 1);
          resolve();
        };
        const timer = self._timers.setTimeout(finish, timeoutMs);
        self._waiters.push(finish);
        if (abort && typeof abort.then === 'function') abort.then(finish, finish);
      });
    },

    wake: function () {
      this._wakeWaiters();
    },

    _wakeWaiters: function () {
      const pending = this._waiters.slice();
      this._waiters.length = 0;
      pending.forEach(function (finish) {
        finish();
      });
    },

    /** המצב לתצוגה ול-`/events`. אותם שמות שדות כמו `SyncHub.snapshot`. */
    snapshot: function () {
      this._prunePeers();
      const relay = this.transport.status ? this.transport.status() : {};
      let deskCount = 0;
      for (const entry of this._desk.values()) if (entry.open) deskCount++;
      return {
        transport: 'relay',
        deviceId: this.deviceId,
        deviceName: this.deviceName,
        paired: this.isPaired,
        relay: relay,
        clockSkewMinutes: relay.clockSkewMinutes == null ? null : relay.clockSkewMinutes,
        remoteSequence: this._remoteSequence,
        roomEpoch: this._roomEpoch,
        remote: this._remote
          ? {
              location: P.locationToJson(this._remote.location),
              fromId: this._remote.fromId,
              fromName: this._remote.fromName,
              timestampMs: this._remote.timestampMs,
              updateId: this._remote.updateId,
            }
          : null,
        localLocation: this._localLocation ? P.locationToJson(this._localLocation) : null,
        syncLocation: this.syncLocation,
        closePolicy: this.closePolicy,
        deskCount: deskCount,
        localTabCount: this._localTabs.size,
        canClose: this._pluginCanClose,
        carryCandidates: this.carryCandidates().map(P.deskEntryToJson),
        peers: Array.from(this._peers.values()).map(function (p) {
          return { id: p.id, name: p.name, lastSeenMs: p.lastSeenMs,
            readiness: p.readiness || null, readinessAt: p.readinessAt || 0 };
        }),
      };
    },

    /**
     * מה שאסור לאבד כשהמנוע עובר בין הלשונית לרקע. **רק מצב של החדר**:
     * מחוברים ומקום מרוחק נבנים מחדש מהרשת בתוך פעימת נוכחות אחת, ואילו
     * השולחן, המצבות והשעון הלוגי אינם נבנים מחדש לעולם — מנוע שמתחיל
     * מאפס היה מפרש את דיווח הטאבים הראשון כ"אין שינוי", ושוכח סגירות.
     */
    exportState: function () {
      return {
        roomHash: this.isPaired ? P.hashRoomCode(this.roomCode) : null,
        desk: Array.from(this._desk.values()).map(P.deskEntryToJson),
        localTabs: Array.from(this._localTabs.values()).map(function (t) {
          return { b: t.bookId, i: t.index };
        }),
        sawFirstReport: this._sawFirstReport,
        undeliverable: Array.from(this._undeliverable),
        dismissed: Array.from(this._dismissedCloses),
        lastStamp: this._lastStamp,
        localLocation: this._localLocation ? P.locationToJson(this._localLocation) : null,
        canClose: this._pluginCanClose,
        // **גם המחוברים.** החברותא כבר מכירה את המכשיר הזה, ולכן אינה עונה
        // להכרזת הנוכחות של מנוע חדש — היא שומעת רק "עוד הודעה מאותו שולח".
        // מנוע שמתחיל בלי הרשימה היה מראה "ממתין לחברותא" עד פעימת הנוכחות
        // הבאה שלה, עשרים שניות אחרי כל מעבר בין הלשונית לרקע. המקום הידוע
        // של כל אחד נשמר איתו, כדי שההתאוששות מנוכחות (ראו [handleInbound])
        // לא תפרש את הנוכחות הבאה כתזוזה.
        peers: Array.from(this._peers.values()).map(function (p) {
          return {
            id: p.id,
            name: p.name,
            lastSeenMs: p.lastSeenMs,
            readiness: p.readiness || null,
            readinessAt: p.readinessAt || 0,
            lastLocation: p.lastLocation ? P.locationToJson(p.lastLocation) : null,
          };
        }),
        // **מה שהתקבל ומה שנמסר — שני שדות נפרדים, בכוונה.** עדכון שהגיע
        // רגע לפני ההחלפה, לפני ש-`events` הספיק למסור אותו לתוסף, חייב
        // להימסר במנוע החדש; ועדכון שכבר נמסר אסור שיימסר שוב — זה ניווט
        // חוזר שגורר את המשתמש לדף שכבר עזב. ההבחנה ביניהם היא מזהה
        // המסירה האחרונה מול מזהה העדכון ([markHandedToPlugin]).
        received: this._remote
          ? {
              location: P.locationToJson(this._remote.location),
              fromId: this._remote.fromId,
              fromName: this._remote.fromName,
              timestampMs: this._remote.timestampMs,
              updateId: this._remote.updateId,
            }
          : null,
        // מה שנמסר לתוסף, ומתי (בשעון המחשב הזה) — גם בסיס חלון ההד:
        // הד של ניווט שנעשה במנוע הקודם מגיע לא פעם למנוע החדש.
        delivered: {
          updateId: this._lastHandedUpdateId,
          location: this._lastHandedToPlugin ? P.locationToJson(this._lastHandedToPlugin) : null,
          atMs: this._lastHandedToPluginAtMs,
        },
        // תחילת חלון ההגנה מגרירה אחורה (בשעון המחשב הזה, כמו `delivered.atMs`):
        // מנוע שמחליף את זה זמן קצר אחרי שזזנו חייב להמשיך להגן.
        lastMoveMs: this._lastBroadcastMoveMs,
        // מונה `events`, כדי שהמנוע הבא ימשיך ממנו (ראו [importState]).
        sequence: this._remoteSequence,
        // ההצטרפות שהמצב שייך לה, והפקודות שבוצעו בה — ראו [joinToken].
        join: this.joinToken,
        doneCommands: this._doneCommands.slice(),
        outbox: this._outbox.map(P.deskEntryToJson),
        // המקום האחרון של מי שפג תוקפו בלי להיפרד — ראו [_knownLocations].
        known: Array.from(this._knownLocations.entries()).map(function (pair) {
          return { id: pair[0], location: P.locationToJson(pair[1]) };
        }),
      };
    },

    /**
     * משחזר מצב שנשמר — רק אם הוא של החדר הנוכחי.
     *
     * **העדכון המרוחק משוחזר יחד עם רישום המסירה שלו**, ולכן מה שטרם נמסר
     * נמסר במנוע החדש, ומה שכבר נמסר אינו "טרי" שוב (ראו `received` ו-
     * `delivered` ב-[exportState]).
     *
     * **המונה [_remoteSequence] ממשיך מהמנוע הקודם, ומתקדם.** לקוח שהחזיק
     * את המנוע קודם (הלוך וחזור) שומר `since` מאותה תקופה; מונה שמתחיל
     * מאפס היה מתנגש בו, ועדכון ממתין היה נראה "לא חדש". הקידום מבטיח
     * שכל `since` שניתן לפני ההחלפה קטן מהמונה, ולכן הלקוח מקבל תשובה
     * מיד — ו"עדכון" בה רק אם [hasFreshRemoteLocation], כך שמה שכבר נמסר
     * אינו נמסר שוב.
     */
    importState: function (state) {
      if (!state || !this.isPaired) return false;
      if (state.roomHash !== P.hashRoomCode(this.roomCode)) return false;
      const self = this;
      (Array.isArray(state.desk) ? state.desk : []).forEach(function (raw) {
        const entry = raw && typeof raw.b === 'string' && typeof raw.s === 'number' && typeof raw.w === 'string'
          ? P.deskEntry(raw.b, raw.s, raw.w, typeof raw.i === 'number' ? raw.i : 0, raw.o !== false)
          : null;
        if (entry && self._desk.size < P.MAX_TRACKED_TABS) self._desk.set(entry.bookId, entry);
      });
      localEntries(state.localTabs).forEach(function (tab) {
        self._localTabs.set(tab.bookId, tab);
      });
      this._sawFirstReport = state.sawFirstReport === true;
      failedBookIds(state.undeliverable).forEach(function (b) {
        self._undeliverable.add(b);
      });
      failedBookIds(state.dismissed).forEach(function (b) {
        self._dismissedCloses.add(b);
      });
      if (typeof state.lastStamp === 'number' && this._stampInWindow(state.lastStamp)) {
        this._lastStamp = Math.max(this._lastStamp, state.lastStamp);
      }
      const location = P.locationFromJson(state.localLocation);
      if (location) this._localLocation = location;
      this._pluginCanClose = state.canClose === true;
      const received = state.received;
      const receivedAt = P.locationFromJson(received && received.location);
      if (
        receivedAt &&
        typeof received.fromId === 'string' &&
        typeof received.fromName === 'string' &&
        Number.isInteger(received.timestampMs) &&
        Number.isInteger(received.updateId)
      ) {
        this._remote = {
          location: receivedAt,
          fromId: received.fromId,
          fromName: received.fromName,
          timestampMs: received.timestampMs,
          updateId: received.updateId,
        };
      }
      const delivered = state.delivered;
      if (delivered && typeof delivered === 'object') {
        if (Number.isInteger(delivered.updateId)) this._lastHandedUpdateId = delivered.updateId;
        const handed = P.locationFromJson(delivered.location);
        if (handed && Number.isInteger(delivered.atMs)) {
          this._lastHandedToPlugin = handed;
          this._lastHandedToPluginAtMs = delivered.atMs;
        }
      }
      if (Number.isInteger(state.lastMoveMs)) this._lastBroadcastMoveMs = state.lastMoveMs;
      (Array.isArray(state.outbox) ? state.outbox : []).forEach(function (raw) {
        const op = self._desk.get(raw && raw.b);
        // הפעולה עצמה, כפי שבשולחן — רק אם השולחן עדיין מחזיק בדיוק אותה.
        if (op && op.stamp === raw.s && op.by === raw.w) self._outbox.push(op);
      });
      (Array.isArray(state.doneCommands) ? state.doneCommands : []).forEach(function (key) {
        if (typeof key === 'string' && key !== '' && !self.isCommandDone(key)) self._doneCommands.push(key);
      });
      if (this._doneCommands.length > MAX_DONE_COMMANDS) this._doneCommands.splice(0, this._doneCommands.length - MAX_DONE_COMMANDS);
      // המונה לפחות כמו כל מזהה עדכון שנשמר — כך העדכון הבא מקבל מזהה גדול
      // מכל מה שנמסר, וההשוואה ב-[isFreshRemote] נשארת נכונה.
      const sequence = Math.max(
        Number.isInteger(state.sequence) && state.sequence >= 0 ? state.sequence : 0,
        this._remote ? this._remote.updateId : 0,
        this._lastHandedUpdateId
      );
      this._remoteSequence = Math.max(this._remoteSequence, sequence) + 1;
      // מחובר שנדם יותר מ-[PEER_TIMEOUT_MS] אינו חוזר — אותו כלל של
      // [_prunePeers], לפי השעון של המחשב הזה (שבו גם נמדד `lastSeenMs`).
      const now = this._now();
      (Array.isArray(state.peers) ? state.peers : []).forEach(function (raw) {
        if (!raw || typeof raw.id !== 'string' || raw.id === '' || raw.id === self.deviceId) return;
        if (typeof raw.name !== 'string' || P.wireTextTooLong(raw.id) || P.wireTextTooLong(raw.name)) return;
        if (typeof raw.lastSeenMs !== 'number' || now - raw.lastSeenMs > PEER_TIMEOUT_MS) {
          // פג תוקפו בזמן ההחלפה — ניתוק, לא יציאה: המקום שלו נזכר.
          self._remember(raw.id, P.locationFromJson(raw.lastLocation));
          return;
        }
        if (self._peers.size >= MAX_PEERS) return;
        self._peers.set(raw.id, {
          id: raw.id,
          name: raw.name,
          lastSeenMs: raw.lastSeenMs,
          readiness: P.readinessFromJson(raw.readiness),
          readinessAt: typeof raw.readinessAt === 'number' ? raw.readinessAt : 0,
          lastLocation: P.locationFromJson(raw.lastLocation),
        });
      });
      (Array.isArray(state.known) ? state.known : []).forEach(function (raw) {
        if (!raw || typeof raw.id !== 'string' || raw.id === '' || raw.id === self.deviceId) return;
        if (P.wireTextTooLong(raw.id) || self._peers.has(raw.id)) return;
        self._remember(raw.id, P.locationFromJson(raw.location));
      });
      return true;
    },

    dispose: async function () {
      if (this._disposed) return;
      this._disposed = true;
      if (this._presenceTimer) this._timers.clearInterval(this._presenceTimer);
      if (this._deskResyncTimer) this._timers.clearInterval(this._deskResyncTimer);
      this._presenceTimer = null;
      this._deskResyncTimer = null;
      if (this.isPaired) {
        try {
          await this.transport.send(this._buildMessage(P.TYPES.bye), { farewell: true });
        } catch (e) {
          // החברותא תסיק את היציאה מהשקט.
        }
      }
      this._wakeWaiters();
    },
  };

  /** ראו `LocalApi._localEntries`. */
  function localEntries(raw) {
    const seen = new Set();
    const entries = [];
    (Array.isArray(raw) ? raw : []).forEach(function (item) {
      if (!item || typeof item !== 'object') return;
      const bookId = item.b;
      if (typeof bookId !== 'string' || bookId === '' || P.wireTextTooLong(bookId) || seen.has(bookId)) return;
      if (entries.length >= P.MAX_TRACKED_TABS) return;
      seen.add(bookId);
      const index = item.i;
      entries.push({ bookId: bookId, index: Number.isInteger(index) && index >= 0 ? index : 0 });
    });
    return entries;
  }

  /** ראו `LocalApi._failedBookIds`. */
  function failedBookIds(raw) {
    const out = [];
    (Array.isArray(raw) ? raw : []).forEach(function (item) {
      if (typeof item !== 'string' || item === '' || P.wireTextTooLong(item)) return;
      if (out.length >= P.MAX_TRACKED_TABS) return;
      out.push(item);
    });
    return out;
  }

  function deskPlanKey(plan) {
    const open = plan.open.map(function (e) { return e.bookId + '@' + e.index; }).sort();
    const close = plan.close.map(function (e) { return e.bookId; }).sort();
    return open.join(',') + '|' + close.join(',');
  }

  Hub.PRESENCE_INTERVAL_MS = PRESENCE_INTERVAL_MS;
  Hub.PEER_TIMEOUT_MS = PEER_TIMEOUT_MS;
  return Hub;
})();

if (typeof module !== 'undefined') module.exports = RemoteHub;
