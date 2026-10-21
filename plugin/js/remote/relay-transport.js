'use strict';

/**
 * התעבורה של החיבור המרוחק: שרת relay באינטרנט, דרך `network.fetchStream`
 * של אוצריא.
 *
 * זה התחליף ל-`LanTransport` של המתאם, ובאותו תפקיד בדיוק: לשלוח הודעה
 * חתומה לכל מי שבחדר, ולמסור ל-hub כל הודעה תקינה שהגיעה. השרת אינו מבין
 * את ההודעות ואינו מאמת אותן (ראו `relay/src/index.js`) — האימות כאן.
 *
 *   POST {base}/r/<roomHash>/send                     גוף: הודעה אחת
 *   GET  {base}/r/<roomHash>/poll?since=N&wait=25     {"next", "messages"}
 *
 * **מה ש-UDP לא הכיר וכאן חייבים לטפל בו:**
 *
 * - **השרת שוכח.** החדר חי בזיכרון בלבד; כשהוא נפלט המונה שלו חוזר לאפס
 *   (`next < since`), וכשנשלחו יותר הודעות ממה שהוא זוכר — חלק אבד
 *   (`next - since` גדול ממספר ההודעות שחזרו). בשני המקרים יש הודעות
 *   שלא יגיעו לעולם, ולכן [onResync] משדר מחדש את כל המצב.
 * - **תשובה ישנה היא סכנה.** בקשת המתנה פתוחה עד 25 שניות; אם בזמן הזה
 *   הוחלף החדר או המצב, התשובה שלה שייכת לעולם שכבר אינו קיים. כל בקשה
 *   נושאת את [generation] שבו נשלחה, ותשובה מדור קודם נזרקת. גם הבקשה
 *   עצמה מבוטלת מיד (`return()` על הזרם מבטל את ה-HTTP בצד אוצריא).
 * - **"השרת זמין" אינו "החברותא מחוברת".** [status] מדווח רק על השרת;
 *   מי מחובר — זה עניינו של ה-hub, לפי הודעות נוכחות.
 */
const RelayTransport = (function () {
  /** כמה זמן השרת מחזיק בקשת המתנה. התקרה בשרת היא 25 שניות. */
  const POLL_WAIT_S = 25;

  /** גבול הזמן של בקשת המתנה בצד אוצריא: ההמתנה ועוד מרווח לרשת איטית. */
  const POLL_TIMEOUT_MS = 40000;

  /** גבול הזמן של שליחה. */
  const SEND_TIMEOUT_MS = 10000;

  const BACKOFF_MIN_MS = 1000;
  const BACKOFF_MAX_MS = 30000;

  /**
   * חסימה בצד אוצריא (הרשאה כבויה, כתובת שעוד לא אושרה) לא תשתנה בעוד
   * שנייה. ניסיון חוזר תכוף היה רק מציף את היומן של אוצריא.
   */
  const BLOCKED_RETRY_MS = 60000;

  /** ראו `Companion.classify` — אותו סיווג, כי אוצריא מעבירה טקסט בלבד. */
  function classify(message) {
    const text = String(message || '');
    if (/הרשא|permission/i.test(text)) return 'permission';
    if (/רשימת ההיתר|forbidden|allowlist/i.test(text)) return 'allowlist';
    if (/async iterable|asyncIterator|unknown method|unsupported|לא נתמך/i.test(text)) {
      return 'unsupported';
    }
    if (/timed? ?out|timeout/i.test(text)) return 'timeout';
    return 'network';
  }

  function failure(kind, message) {
    const error = new Error(message);
    error.kind = kind;
    return error;
  }

  /**
   * @param {object} options
   *   - `baseUrl`: כתובת השרת, בלי `/` בסוף.
   *   - `fetchStream(params)`: מחזיר את הזרם של `network.fetchStream`.
   *   - `roomCode()`: קוד החדר המנורמל הנוכחי, לאימות הודעות.
   *   - `selfId()`: מזהה המכשיר, כדי להבדיל הודעה שלנו שחזרה.
   *   - `onMessage(message)`: הודעה תקינה מהחדר (כולל שלנו — ה-hub מסנן).
   *   - `onResync()`: השרת שכח הודעות. ראו את התיעוד של המודול.
   *   - `onJoined()`: הסמן מול החדר נקבע — מכאן כל הודעה מגיעה אלינו.
   *   - `onStatus()`: המצב השתנה.
   */
  function Transport(options) {
    this.baseUrl = options.baseUrl;
    this._fetchStream = options.fetchStream;
    this._roomCode = options.roomCode;
    this._selfId = options.selfId;
    this._onMessage = options.onMessage || function () {};
    this._onResync = options.onResync || function () {};
    this._onJoined = options.onJoined || function () {};
    this._onStatus = options.onStatus || function () {};
    this._now = options.now || Date.now;
    this._timers = options.timers || { setTimeout: setTimeout, clearTimeout: clearTimeout };
    this._log = options.log || function () {};

    this.generation = 0;
    this._running = false;
    this._roomHash = null;
    this._since = -1;
    this._poll = null;
    this._sleep = null;
    this._sendChain = Promise.resolve();
    /** זרמי השליחה שבאוויר (חוץ מפרידה), כדי לבטל אותם כשהדור מתחלף. */
    this._sends = new Set();
    this._status = freshStatus();
  }

  function freshStatus() {
    return {
      state: 'idle',
      errorKind: null,
      error: null,
      lastOkAt: 0,
      serverResets: 0,
      historyGaps: 0,
      received: 0,
      fromOthers: 0,
      rejected: 0,
      clockRejected: 0,
      clockSkewMinutes: null,
    };
  }

  Transport.prototype = {
    status: function () {
      return Object.assign({ room: this._roomHash !== null }, this._status);
    },

    _setStatus: function (patch) {
      Object.assign(this._status, patch);
      try {
        this._onStatus();
      } catch (e) {
        // מאזין המצב הוא של התצוגה בלבד.
      }
    },

    start: function () {
      this._running = true;
      this._restart();
    },

    /** עוצר הכל ופוסל כל תשובה שעוד בדרך. */
    stop: function () {
      this._running = false;
      this.generation++;
      this._cancelPoll();
      this._cancelSends();
      this._setStatus({ state: 'idle' });
    },

    /**
     * מכוון את ההאזנה לחדר אחר ([roomHash], או `null` = אין חדר).
     *
     * **החדר הקודם ננטש מיד**: הבקשה הפתוחה מבוטלת, הדור מתקדם, והמונה
     * מתחיל מחדש — מונה של חדר אחד אינו אומר דבר על חדר אחר.
     */
    retarget: function (roomHash) {
      this._roomHash = roomHash || null;
      this._status = freshStatus();
      this._restart();
    },

    _restart: function () {
      this.generation++;
      this._since = -1;
      this._cancelPoll();
      this._cancelSends();
      if (!this._running || this._roomHash === null) {
        this._setStatus({ state: 'idle' });
        return;
      }
      this._setStatus({ state: 'connecting' });
      this._loop(this.generation, this._roomHash);
    },

    _cancelPoll: function () {
      const poll = this._poll;
      this._poll = null;
      if (poll && typeof poll.return === 'function') {
        try {
          const done = poll.return();
          if (done && typeof done.catch === 'function') done.catch(function () {});
        } catch (e) {
          // הזרם כבר הסתיים.
        }
      }
      const sleep = this._sleep;
      this._sleep = null;
      if (sleep) sleep();
    },

    /** מבטל את השליחות שבאוויר. פרידה מכוונת אינה כאן — ראו [send]. */
    _cancelSends: function () {
      const sends = Array.from(this._sends);
      this._sends.clear();
      sends.forEach(function (stream) {
        if (!stream || typeof stream.return !== 'function') return;
        try {
          const done = stream.return();
          if (done && typeof done.catch === 'function') done.catch(function () {});
        } catch (e) {
          // הזרם כבר הסתיים.
        }
      });
    },

    _current: function (gen) {
      return this._running && gen === this.generation;
    },

    /** המתנה שמתקצרת כשהדור מתחלף. */
    _wait: function (ms) {
      const self = this;
      return new Promise(function (resolve) {
        const timer = self._timers.setTimeout(done, ms);
        function done() {
          self._timers.clearTimeout(timer);
          if (self._sleep === done) self._sleep = null;
          resolve();
        }
        self._sleep = done;
      });
    },

    /**
     * בקשת HTTP אחת דרך אוצריא. מחזיר את הגוף כטקסט.
     *
     * [track] מקבל את הזרם, כדי שאפשר יהיה לבטל אותו מבחוץ.
     */
    _request: async function (params, track) {
      let stream;
      try {
        stream = this._fetchStream(params);
      } catch (e) {
        throw failure(classify(e && e.message), e && e.message ? e.message : 'קריאת הרשת נכשלה');
      }
      if (track) track(stream);
      let body = '';
      let status = 0;
      try {
        const iterator = stream[Symbol.asyncIterator] ? stream[Symbol.asyncIterator]() : stream;
        for (;;) {
          const step = await iterator.next();
          if (step.done) break;
          const chunk = step.value;
          if (chunk && chunk.type === 'response') {
            status = chunk.status;
            if (!chunk.ok) {
              // **מישהו ענה**, ולכן זו אינה "אין רשת". שגיאת HTTP מהשרת
              // (או מסנן תוכן שעונה במקומו) מדווחת כמו שהיא.
              if (typeof iterator.return === 'function') iterator.return();
              throw failure('http', 'השרת החזיר שגיאה ' + chunk.status);
            }
            continue;
          }
          if (chunk && typeof chunk.body === 'string') body += chunk.body;
        }
      } catch (e) {
        if (e && e.kind) throw e;
        const message = e && e.message ? e.message : 'קריאת הרשת נכשלה';
        throw failure(classify(message), message);
      }
      if (status === 0) throw failure('cancelled', 'הבקשה בוטלה');
      return body;
    },

    _url: function (roomHash, action, query) {
      return this.baseUrl + '/r/' + roomHash + '/' + action + (query ? '?' + query : '');
    },

    /**
     * שולח הודעה אחת. השליחות יוצאות **אחת אחרי השנייה**: אוצריא מגבילה
     * תוסף לארבעה זרמי רשת פתוחים, ובקשת ההמתנה כבר תופסת אחד; פרץ של
     * מנות שולחן במקביל היה נדחה ב-`rate_limited`.
     *
     * הנתיב נגזר מהחדר **של ההודעה** ולא מהחדר הנוכחי, כדי שהודעת פרידה
     * מהחדר הקודם תגיע אליו גם אם ההחלפה כבר התחילה.
     */
    /**
     * **שליחה שייכת לדור שבו נכנסה לתור.** עצירה, החלפת חדר או אובדן
     * בעלות (שקורא ל-`stop()`) פוסלים אותה: מה שעוד בתור אינו יוצא כלל
     * ומחזיר `false`, ומה שכבר באוויר מבוטל (`return()` על הזרם). בלי זה
     * מנת שולחן ישנה הייתה יוצאת אחרי שהמופע כבר אינו הבעלים, וההשלמה שלה
     * הייתה מחזירה "מחובר" לתצוגה של מופע עצור.
     *
     * החריג היחיד הוא **פרידה מכוונת** (`{ farewell: true }`): היא נשלחת
     * גם אחרי החלפת חדר או עצירה — זו כל מטרתה — ואינה מבוטלת. אבל גם
     * ההשלמה שלה אינה נוגעת במצב אם הדור כבר התחלף: היא מדווחת על החדר
     * הקודם, לא על הנוכחי.
     */
    send: function (message, options) {
      const self = this;
      const farewell = !!(options && options.farewell);
      const code = this._roomCode();
      if (!code || (!this._running && !farewell)) return Promise.resolve(false);
      const body = RemoteProtocol.encode(message, code);
      const url = this._url(message.roomHash, 'send');
      const gen = this.generation;
      const run = function () {
        if (!farewell && !self._current(gen)) return Promise.resolve(false);
        let stream = null;
        return self
          ._request(
            {
              url: url,
              method: 'POST',
              headers: { 'Content-Type': 'application/json;charset=UTF-8' },
              body: body,
              timeoutMs: SEND_TIMEOUT_MS,
            },
            farewell
              ? null
              : function (s) {
                  stream = s;
                  self._sends.add(s);
                }
          )
          .then(
            function () {
              if (stream) self._sends.delete(stream);
              if (!self._current(gen)) return !!farewell;
              self._setStatus({ state: 'online', errorKind: null, error: null, lastOkAt: self._now() });
              return true;
            },
            function (e) {
              if (stream) self._sends.delete(stream);
              // **כישלון של שליחה מדור שעבר אינו תקלה של החיבור הנוכחי** —
              // לרוב זה בדיוק הביטול שלנו. לא מדווחים ולא דוחים.
              if (!self._current(gen)) return false;
              self._setStatus({ state: 'error', errorKind: e.kind || 'network', error: e.message });
              throw e;
            }
          );
      };
      const next = this._sendChain.then(run, run);
      this._sendChain = next.catch(function () {});
      return next;
    },

    _loop: async function (gen, roomHash) {
      let backoff = BACKOFF_MIN_MS;
      let recovering = false;
      while (this._current(gen)) {
        let body;
        const self = this;
        try {
          // **הפנייה הראשונה לחדר אינה ממתינה.** היא רק לומדת את המונה של
          // השרת, ובהמתנה מלאה המסך היה אומר "מתחבר לשרת" עשרים וחמש
          // שניות בכל הצטרפות — גם כשהשרת זמין לגמרי.
          const wait = this._since === -1 ? 0 : POLL_WAIT_S;
          body = await this._request(
            {
              url: this._url(roomHash, 'poll', 'since=' + this._since + '&wait=' + wait),
              method: 'GET',
              timeoutMs: POLL_TIMEOUT_MS,
            },
            function (stream) {
              if (self._current(gen)) self._poll = stream;
            }
          );
        } catch (e) {
          if (!this._current(gen)) return;
          recovering = true;
          this._poll = null;
          const kind = e.kind || 'network';
          this._setStatus({ state: 'error', errorKind: kind, error: e.message });
          const blocked = kind === 'permission' || kind === 'allowlist' || kind === 'unsupported';
          await this._wait(blocked ? BLOCKED_RETRY_MS : backoff + Math.floor(Math.random() * 500));
          backoff = Math.min(backoff * 2, BACKOFF_MAX_MS);
          continue;
        }
        if (!this._current(gen)) return;
        this._poll = null;

        let reply;
        try {
          reply = JSON.parse(body);
        } catch (e) {
          reply = null;
        }
        if (!reply || typeof reply.next !== 'number' || !Array.isArray(reply.messages)) {
          // ענה מישהו שאינו השרת — בדרך כלל מסנן תוכן שמחזיר דף חסימה
          // ב-200. זה אינו "אין אינטרנט", ולכן מסווג בנפרד.
          this._setStatus({ state: 'error', errorKind: 'invalid', error: 'תשובה לא צפויה מהשרת' });
          recovering = true;
          await this._wait(backoff);
          backoff = Math.min(backoff * 2, BACKOFF_MAX_MS);
          continue;
        }
        backoff = BACKOFF_MIN_MS;
        this._setStatus({ state: 'online', errorKind: null, error: null, lastOkAt: this._now() });

        if (this._since === -1) {
          // ההתחברות הראשונה לחדר: מתחילים מכאן והלאה. היסטוריה ישנה
          // אינה רלוונטית — המצב העדכני מגיע בשידור המלא של הצד השני.
          this._since = reply.next;
          // **ומכריזים נוכחות שוב, עכשיו.** ההכרזה הראשונה יצאה עוד לפני
          // שהיה לנו סמן, וכך גם של החברותא אם נכנסה באותו רגע — כל צד
          // מדלג על הודעת השני, ושניהם "ממתינים לחברותא" עד פעימת הנוכחות
          // הבאה, עשרים שניות. מכאן והלאה כל הודעה כבר מגיעה, ולכן הכרזה
          // שיוצאת אחרי שהסמן נקבע נקלטת אצל כל מי שכבר מאזין — והוא עונה.
          this._safe(this._onJoined);
        } else if (reply.next < this._since) {
          // **המונה של השרת חזר אחורה: החדר נפלט ונבנה מחדש.** כל מה
          // שנשלח לפני כן אבד, ומה שנשלח אחרי — ממוספר מאפס. קוראים
          // מההתחלה, ומשדרים מחדש את המצב שלנו.
          this._since = 0;
          this._setStatus({ serverResets: this._status.serverResets + 1 });
          this._log('השרת התאפס; משדרים מחדש את המצב');
          this._safeResync();
          continue;
        } else {
          if (reply.next - this._since > reply.messages.length) {
            // **השרת זוכר רק את ההודעות האחרונות**, ונשלחו יותר מזה מאז
            // הבקשה הקודמת שלנו. ההודעות שבאמצע לא יגיעו לעולם.
            this._setStatus({ historyGaps: this._status.historyGaps + 1 });
            this._log('אבדו הודעות בשרת; משדרים מחדש את המצב');
            this._safeResync();
          }
          this._since = reply.next;
        }
        this._deliver(reply.messages);
        // חזרה מהרשת מחזירה גם את הנוכחות והספרים מיד. המתנה לפעימה
        // התקופתית משאירה את שני הצדדים עם רשימת מחוברים ריקה אחרי ניתוק.
        if (recovering) {
          recovering = false;
          this._safeResync();
        }
      }
    },

    _safeResync: function () {
      this._safe(this._onResync);
    },

    /** קורא למאזין בלי שתקלה בו (או דחייה שלו) תפיל את הלולאה. */
    _safe: function (callback) {
      try {
        const result = callback();
        if (result && typeof result.catch === 'function') result.catch(function () {});
      } catch (e) {
        // השידור התקופתי יתקן ממילא.
      }
    },

    _deliver: function (bodies) {
      const code = this._roomCode();
      if (!code) return;
      const self = this.selfIdValue();
      for (let i = 0; i < bodies.length; i++) {
        const text = bodies[i];
        if (typeof text !== 'string') continue;
        let fromSelf = false;
        try {
          fromSelf = JSON.parse(text).src === self;
        } catch (e) {
          fromSelf = false;
        }
        const status = this._status;
        status.received++;
        if (!fromSelf) status.fromOthers++;
        let clockRejected = false;
        const message = RemoteProtocol.decode(text, code, {
          now: this._now(),
          onClockSkew: function (ms) {
            clockRejected = true;
            status.clockSkewMinutes = Math.trunc(ms / 60000);
          },
        });
        if (!message) {
          if (!fromSelf) {
            if (clockRejected) status.clockRejected++;
            else status.rejected++;
          }
          continue;
        }
        if (!fromSelf) status.clockSkewMinutes = null;
        try {
          this._onMessage(message);
        } catch (e) {
          this._log('טיפול בהודעה נכשל: ' + (e && e.message));
        }
      }
      this._setStatus({});
    },

    selfIdValue: function () {
      try {
        return this._selfId();
      } catch (e) {
        return null;
      }
    },
  };

  Transport.classify = classify;
  Transport.POLL_WAIT_S = POLL_WAIT_S;
  return Transport;
})();

if (typeof module !== 'undefined') module.exports = RelayTransport;
