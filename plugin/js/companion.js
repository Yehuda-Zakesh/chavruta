'use strict';

/**
 * הערוץ אל מתאם החברותא שרץ על המחשב הזה.
 *
 * המתאם מאזין ב-loopback בלבד, על הפורט הראשון הפנוי בטווח מוסכם. התוסף
 * אינו מקבל את הפורט בשום דרך חיצונית — הוא סורק את הטווח ומזהה את המתאם
 * לפי תשובת `/hello`. כך אין קונפיגורציה שצריך לתחזק בשני הצדדים.
 */
const Companion = (function () {
  /** הטווח שהמתאם מנסה, באותו סדר שבו הוא מנסה אותו. */
  const PORTS = [45871, 45872, 45873, 45874, 45875];

  /** הפורט שנמצא בפעם הקודמת — מנוסה ראשון בעלייה הבאה. */
  const PORT_KEY = 'companionPort';

  /** זמן המתנה לבקשה רגילה. המתאם הוא מקומי, ולכן זה נדיב מאוד. */
  const REQUEST_TIMEOUT_MS = 4000;

  /** בקשת `/events` נשארת פתוחה עד 25 שניות בצד המתאם. */
  const EVENTS_TIMEOUT_MS = 35000;

  let port = null;

  /**
   * הנקודה היחידה בתוסף שמדברת HTTP.
   *
   * `network.fetchStream` רץ בצד אוצריא (Flutter) ולכן אינו כפוף ל-CORS,
   * בשונה מ-`fetch()` רגיל מתוך ה-WebView. תשובות המתאם קטנות, ולכן אנחנו
   * אוספים את המקטעים למחרוזת אחת ומפענחים JSON בסוף.
   */
  async function request(path, options) {
    const opts = options || {};
    const params = {
      url: 'http://127.0.0.1:' + (opts.port || port) + path,
      method: opts.method || 'GET',
      timeoutMs: opts.timeoutMs || REQUEST_TIMEOUT_MS,
    };
    if (opts.body !== undefined) {
      params.headers = { 'Content-Type': 'application/json;charset=UTF-8' };
      params.body = JSON.stringify(opts.body);
    }

    let body = '';
    try {
      const chunks = Otzaria.call('network.fetchStream', params);
      for await (const chunk of chunks) {
        if (chunk.type === 'response') {
          // יציאה מהלופ מבטלת את הבקשה בצד אוצריא, ולכן אין כאן דליפה.
          if (!chunk.ok) throw new Error('המתאם החזיר שגיאה ' + chunk.status);
          continue;
        }
        if (typeof chunk.body === 'string') body += chunk.body;
      }
    } catch (e) {
      throw e instanceof Error ? e : new Error('קריאת הרשת נכשלה');
    }

    try {
      return JSON.parse(body);
    } catch (e) {
      throw new Error('תשובה לא קריאה מהמתאם');
    }
  }

  async function readStoredPort() {
    try {
      const res = await Otzaria.call('storage.get', { key: PORT_KEY });
      const value = res && res.success ? res.data : null;
      return typeof value === 'number' && PORTS.indexOf(value) >= 0 ? value : null;
    } catch (e) {
      return null;
    }
  }

  async function writeStoredPort(value) {
    try {
      await Otzaria.call('storage.set', { key: PORT_KEY, value: value });
    } catch (e) {
      // זיכרון הפורט הוא קיצור דרך בלבד; כשלון בשמירה אינו מעניין.
    }
  }

  /**
   * מחפש את המתאם בטווח הפורטים. מחזיר את תשובת `/hello` שלו, או `null`
   * אם אין מתאם על המחשב הזה.
   */
  async function discover() {
    const stored = await readStoredPort();
    const order = stored
      ? [stored].concat(
          PORTS.filter(function (p) {
            return p !== stored;
          })
        )
      : PORTS.slice();

    for (let i = 0; i < order.length; i++) {
      const candidate = order[i];
      try {
        const hello = await request('/hello', { port: candidate, timeoutMs: 1500 });
        if (hello && hello.app === 'chavruta-companion') {
          port = candidate;
          if (candidate !== stored) await writeStoredPort(candidate);
          return hello;
        }
      } catch (e) {
        // פורט שאין מאחוריו מתאם — ממשיכים לבא בטווח.
      }
    }
    port = null;
    return null;
  }

  /** מריץ בקשה, ואם המתאם עוד לא נמצא — מחפש אותו קודם. */
  async function withCompanion(run) {
    if (port === null && !(await discover())) {
      throw new Error('לא נמצא מתאם חברותא על המחשב הזה');
    }
    try {
      return await run();
    } catch (e) {
      // המתאם נסגר או התחלף פורט — הבקשה הבאה תחפש אותו מחדש.
      port = null;
      throw e;
    }
  }

  return {
    /** הפורט שבו נמצא המתאם, או `null` אם טרם נמצא. */
    get port() {
      return port;
    },

    /** שוכח את הפורט הידוע, כדי לאלץ חיפוש מחדש. */
    forget: function () {
      port = null;
    },

    discover: discover,

    /** מצב המתאם עכשיו: זיווג, מחוברים, מיקום מרוחק אחרון. */
    hello: function () {
      return withCompanion(function () {
        return request('/hello');
      });
    },

    /**
     * המתנה ארוכה לעדכון מהחברותא. חוזרת מיד אם יש עדכון חדש מ-[since],
     * ואחרת נשארת פתוחה עד שמשהו קורה או עד שיפוג הזמן בצד המתאם.
     */
    events: function (since) {
      return withCompanion(function () {
        return request('/events?since=' + encodeURIComponent(since), {
          timeoutMs: EVENTS_TIMEOUT_MS,
        });
      });
    },

    /** דיווח על מקום הלימוד המקומי. */
    publish: function (location) {
      return withCompanion(function () {
        return request('/publish', { method: 'POST', body: location });
      });
    },

    /** כניסה לחברותא, או יציאה ממנה כאשר [code] ריק. */
    setRoom: function (code) {
      return withCompanion(function () {
        return request('/room', { method: 'POST', body: { code: code || null } });
      });
    },

    /** שינוי שם המכשיר כפי שהוא מוצג לחברותא. */
    setName: function (name) {
      return withCompanion(function () {
        return request('/name', { method: 'POST', body: { name: name } });
      });
    },
  };
})();
