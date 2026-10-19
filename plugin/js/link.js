'use strict';

/**
 * בחירת דרך החיבור: ישיר (בלוטות' / רשת מקומית, דרך המתאם) או מרוחק
 * (שרת relay, מתוך התוסף עצמו, בלי EXE).
 *
 * `Link.api` הוא תמיד אובייקט עם הממשק של `Companion`, ולכן המנוע
 * והלשונית אינם צריכים לדעת איזה חיבור נבחר.
 *
 * **ברירת המחדל היא החיבור הישיר**: משתמש קיים, שלא בחר דבר, ממשיך בדיוק
 * כמו קודם. הבחירה נשמרת באחסון התוסף, ששני המופעים רואים; המופע השני
 * מגלה אותה בבדיקה תקופתית (ובנקישה בערוץ), ומחליף בעצמו.
 */
const Link = (function () {
  const MODE_KEY = 'connectionMode';
  const POKE_CHANNEL = 'io.github.yehudazakesh.chavruta:mode-poke';
  const WATCH_MS = 2000;

  let mode = 'local';
  let watchTimer = null;
  let channel = null;
  let onChange = null;

  function normalize(value) {
    return value === 'remote' ? 'remote' : 'local';
  }

  /** גבול הזמן לקריאת הבחירה. ראו [readMode]. */
  const READ_TIMEOUT_MS = 3000;

  /**
   * קורא את הבחירה השמורה, **עם גבול זמן**: הקריאה הזאת על מסלול העלייה
   * של שני המופעים, ו-`storage.get` שאינו חוזר (אוצריא עסוקה בעליית
   * הספרייה) היה משאיר את המנוע כבוי לגמרי. בכשל נשארת הבחירה הנוכחית —
   * בעלייה זו ברירת המחדל — והבדיקה התקופתית ב-[watch] מתקנת אחר כך.
   *
   * **מפתח חסר וקריאה שנכשלה אינם אותו דבר.** `Otzaria.call` אינה זורקת
   * על כשל ממשק — היא מחזירה `success: false` (`error.internal`,
   * `error.rate_limited`) — ורק `success: true` עם `data: null` פירושו
   * "המשתמש לא בחר כלום", כלומר החיבור הישיר. תרגום של כשל ל"ישיר" היה
   * מחליף את המצב בבדיקה התקופתית: המנוע המרוחק נעצר, נפרד מהחדר, והמתאם
   * נתבע — בגלל עומס רגעי באחסון. בכשל הבחירה הנוכחית נשארת.
   */
  async function readMode() {
    try {
      const res = await Promise.race([
        Otzaria.call('storage.get', { key: MODE_KEY }),
        new Promise(function (_, reject) {
          setTimeout(function () {
            reject(new Error('timeout'));
          }, READ_TIMEOUT_MS);
        }),
      ]);
      if (!res || res.success !== true) return mode;
      return normalize(res.data);
    } catch (e) {
      return mode;
    }
  }

  /** החלפה שכבר רצה, כדי ששתי בדיקות לא יחליפו זו על גבי זו. */
  let switching = null;

  function check() {
    if (switching) return switching;
    switching = (async function () {
      try {
        const next = await readMode();
        if (next === mode) return;
        const previous = mode;
        // **הסדר כאן הוא העיקר.**
        //
        // ביציאה מהמצב המרוחק — קודם פרידה מהחדר ושחרור הנעילה, ורק אחר כך
        // עצירת המנוע. העצירה משחררת את המנוע *בלי* פרידה (זה מה שנכון
        // במסירה בין לשונית לרקע), ואחריה כבר לא היה ממי להיפרד: החברותא
        // הייתה רואה אותנו "מחוברים" עוד 70 שניות. השחרור גם פוסל נעילה
        // שתתקבל באיחור, כדי שלא תפעיל מנוע במצב שננטש.
        //
        // והעצירה לפני החלפת `mode`: המנוע משחרר את ההחזקה דרך `Link.api`,
        // ואחרי ההחלפה השחרור היה הולך לחיבור החדש — והמתאם היה ממתין 45
        // שניות למנוע שאינו קיים.
        if (previous === 'remote') await RemoteLink.shutdown();
        SyncEngine.stop();
        mode = next;
        if (onChange) await onChange(next, previous);
      } finally {
        switching = null;
      }
    })();
    return switching;
  }

  return {
    get mode() {
      return mode;
    },

    get api() {
      return mode === 'remote' ? RemoteLink : Companion;
    },

    /** קורא את הבחירה השמורה. נקרא פעם אחת בעלייה, לפני הפעלת המנוע. */
    load: async function () {
      mode = await readMode();
      return mode;
    },

    /**
     * מאזין להחלפה (כאן או במופע האחר). המנוע הישן כבר נעצר כשנקרא
     * [callback] עם `(next, previous)`; תפקידו להפעיל אותו מחדש.
     */
    watch: function (callback) {
      onChange = callback;
      if (!watchTimer) watchTimer = setInterval(check, WATCH_MS);
      if (!channel && typeof BroadcastChannel !== 'undefined') {
        try {
          channel = new BroadcastChannel(POKE_CHANNEL);
          channel.onmessage = check;
        } catch (e) {
          channel = null;
        }
      }
    },

    /**
     * שומר בחירה חדשה ומחיל אותה כאן מיד.
     *
     * **שמירה שנכשלה נדחית, ולא ממשיכה.** `Otzaria.call` אינה זורקת על כשל
     * ממשק — היא מחזירה `success: false` — והתעלמות ממנו הייתה ממשיכה
     * ל-[check], שקורא את הערך הישן ולא מחליף דבר, והמסך היה מודיע "עברתם"
     * על בחירה שלא נשמרה. בכשל (או בתשובה חסרה, או בזריקה) המצב נשאר, המופע
     * השני לא ננקש, והמנוע לא נעצר; הדחייה מגיעה ל-`changeMode`, שמציג
     * שגיאה ומחזיר את הבחירה במסך למצב הנוכחי.
     */
    setMode: async function (next) {
      const value = normalize(next);
      const res = await Otzaria.call('storage.set', { key: MODE_KEY, value: value });
      if (!res || res.success !== true) {
        const message = res && res.error && res.error.message;
        throw new Error(message || 'שמירת דרך החיבור נכשלה');
      }
      if (typeof BroadcastChannel !== 'undefined') {
        try {
          const poke = new BroadcastChannel(POKE_CHANNEL);
          poke.postMessage('poke');
          poke.close();
        } catch (e) {
          // המופע השני יגלה בבדיקה התקופתית.
        }
      }
      await check();
    },
  };
})();
