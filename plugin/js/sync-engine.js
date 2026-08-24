'use strict';

/**
 * מנוע הסנכרון: מחבר בין מקום הקריאה באוצריא לבין המתאם.
 *
 * שני כיוונים, שניהם דרך המתאם:
 * - יוצא: כל שינוי מקום קריאה מדווח ל-`/publish`.
 * - נכנס: המתנה ארוכה על `/events`, וכל עדכון מהחברותא הופך לניווט.
 *
 * **מופע אחד בלבד מריץ את המנוע** — מופע הרקע כשההרשאה לריצת רקע ניתנה,
 * ואחרת לשונית התוסף. שני מופעים שירוצו יחד היו מנווטים פעמיים ומדווחים
 * פעמיים על אותו מקום.
 */
const SyncEngine = (function () {
  /** גלילה מהירה מייצרת שינויי מקום רבים; מדווחים רק על מה שנשאר. */
  const PUBLISH_DEBOUNCE_MS = 700;

  const RETRY_MIN_MS = 3000;
  const RETRY_MAX_MS = 30000;

  let running = false;
  let since = -1;
  let retryDelay = RETRY_MIN_MS;
  let publishTimer = null;
  let lastSentKey = null;
  let listener = null;
  let status = { connected: false, error: null, state: null };
  let onStatusChange = function () {};

  /**
   * מזהה הלולאה הפעילה. `stop()` ואחריו `start()` משאירים את הלולאה
   * הישנה תלויה בתוך `await` ארוך, והיא הייתה מתעוררת לתוך `running`
   * שכבר חזר להיות אמת — שתי לולאות שמנווטות פעמיים על כל עדכון.
   */
  let loopToken = 0;

  /** האם הבקשה האחרונה למתאם הצליחה. מעבר משקר לאמת = מתאם שקם. */
  let connected = false;

  /** הספר האחרון שדווח כחסר, כדי לא להציף את המשתמש באותה הודעה. */
  let missingBook = null;

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  function keyOf(location) {
    return location.bookId + '#' + location.index;
  }

  /** ממיר מצב קורא של אוצריא למיקום שהפרוטוקול מכיר, או `null`. */
  function toLocation(readerState) {
    if (!readerState) return null;
    const bookId = readerState.currentBookId || readerState.currentBook;
    const index = readerState.currentIndex;
    if (typeof bookId !== 'string' || bookId === '') return null;
    if (typeof index !== 'number' || index < 0) return null;
    return {
      bookId: bookId,
      index: index,
      ref: typeof readerState.currentRef === 'string' ? readerState.currentRef : null,
    };
  }

  async function currentLocation() {
    const res = await Otzaria.call('reader.getCurrentRef');
    return res && res.success ? toLocation(res.data) : null;
  }

  function setStatus(next) {
    status = next;
    try {
      onStatusChange(status);
    } catch (e) {
      // מאזין המצב הוא של ה-UI; תקלה בו לא תפיל את הסנכרון.
    }
  }

  /**
   * הודעה למשתמש דרך אוצריא.
   *
   * המנוע רץ בדרך כלל במופע הרקע, שאין לו מסך משלו — ולכן הודעה שנכתבת
   * ל-`status` בלבד אינה מגיעה לאיש. `ui.showError` היא הדרך היחידה
   * לומר משהו מהרקע, והיא נתמכת שם במפורש.
   */
  function notifyUser(message) {
    try {
      const call = Otzaria.call('ui.showError', { message: message });
      if (call && typeof call.catch === 'function') call.catch(function () {});
    } catch (e) {
      // ההודעה היא שירות למשתמש, לא חלק מהסנכרון.
    }
  }

  async function publish(location) {
    if (!location) return;
    const key = keyOf(location);
    if (key === lastSentKey) return;
    try {
      await Companion.publish(location);
      lastSentKey = key;
    } catch (e) {
      // המתאם אינו זמין כרגע. אין טעם לתור המתנה: המקום הנוכחי יידווח
      // שוב בשינוי הבא, וגם `/events` תגלה שהמתאם חזר.
      setStatus({ connected: false, error: e.message, state: null });
    }
  }

  /**
   * מדווח את המקום הנוכחי מחדש, גם אם הוא כבר דווח.
   *
   * נדרש בכל פעם שהמתאם עולה: מתאם שהופעל מחדש (שדרוג, הפעלה מחדש של
   * המחשב) מתחיל בלי מיקום מקומי כלל, ובלי הדיווח הזה הוא היה נשאר כך
   * עד שהמשתמש יעבור דף — כלומר "המקום שלי" ריק, והחברותא אינה יודעת
   * איפה אנחנו.
   */
  async function republishCurrent() {
    lastSentKey = null;
    try {
      const here = await currentLocation();
      if (here) await publish(here);
    } catch (e) {
      // אין ספר פתוח, או שאוצריא לא ענתה. השינוי הבא ידווח ממילא.
    }
  }

  function queuePublish(readerState) {
    const location = toLocation(readerState);
    if (!location) return;
    if (publishTimer) clearTimeout(publishTimer);
    publishTimer = setTimeout(function () {
      publishTimer = null;
      publish(location);
    }, PUBLISH_DEBOUNCE_MS);
  }

  /** מבצע ניווט בעקבות עדכון שהגיע מהחברותא. */
  async function applyRemote(remote) {
    const location = remote && remote.location;
    if (!location || typeof location.bookId !== 'string') return;

    const here = await currentLocation();
    if (here && here.bookId === location.bookId && here.index === location.index) {
      return;
    }

    // ההד שיחזור מהניווט הזה **כן** מדווח למתאם, ובכוונה: המתאם מזהה
    // אותו בעצמו (חלון ההד שב-`markHandedToPlugin`) ואינו משדר אותו
    // בחזרה לחברותא, אבל כן לומד מתוכו איפה אנחנו נמצאים עכשיו. חסימה
    // כאן הייתה משאירה את "המקום שלי" תקוע על המקום הקודם, ואת הנוכחות
    // משדרת מיקום ישן.
    const res = await Otzaria.call('reader.openBook', {
      bookId: location.bookId,
      index: location.index,
      navigateToPositionIfReused: true,
    });
    if (res && res.success && res.data !== false) {
      missingBook = null;
      return;
    }

    // הספר אינו קיים בספרייה של המחשב הזה — מצב רגיל בין ספריות שונות,
    // אבל מבחוץ הוא נראה בדיוק כמו סנכרון שהפסיק לעבוד. לכן אומרים.
    const message = 'החברותא נמצאת בספר "' + location.bookId +
      '", והוא אינו בספרייה שלך — הסנכרון ימשיך בספר הבא.';
    if (location.bookId !== missingBook) {
      missingBook = location.bookId;
      notifyUser(message);
    }
    setStatus({ connected: true, error: message, state: status.state });
  }

  /** האם הלולאה הזאת עדיין הפעילה. ראו [loopToken]. */
  function current(token) {
    return running && token === loopToken;
  }

  async function loop(token) {
    while (current(token)) {
      try {
        const state = await Companion.events(since);
        if (!current(token)) return;
        retryDelay = RETRY_MIN_MS;
        if (typeof state.remoteSequence === 'number') since = state.remoteSequence;
        setStatus({ connected: true, error: null, state: state });

        // מתאם שרק עכשיו נמצא — בעלייה, או אחרי שקם מחדש — אינו יודע
        // איפה אנחנו. מדווחים לפני הטיפול בעדכון, כדי שהמצב שלו יהיה
        // שלם גם אם הניווט שאחריו ייכשל.
        if (!connected) {
          connected = true;
          await republishCurrent();
          if (!current(token)) return;
        }

        if (state.hasUpdate && state.remote) await applyRemote(state.remote);
      } catch (e) {
        connected = false;
        if (!current(token)) return;
        setStatus({ connected: false, error: e.message, state: null });
        await sleep(retryDelay);
        retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
      }
    }
  }

  return {
    get status() {
      return status;
    },

    get running() {
      return running;
    },

    /** מאזין למצב, לצורך תצוגה. */
    onStatus: function (callback) {
      onStatusChange = callback || function () {};
    },

    start: function () {
      if (running) return;
      running = true;
      since = -1;
      // המצב מאופס גם אם המנוע כבר רץ פעם: מתאם אחר, או אותו מתאם
      // אחרי הפעלה מחדש, אינו יודע דבר על מה שדיווחנו בעבר.
      connected = false;
      lastSentKey = null;
      missingBook = null;

      listener = function (payload) {
        queuePublish(payload);
      };
      Otzaria.on('reader.current_ref_changed', listener);

      // הדיווח הראשוני אינו כאן אלא בלולאה, ברגע שהמתאם עונה: בעלייה
      // הוא לא תמיד כבר רץ, ודיווח שנכשל כאן לא היה חוזר לעולם.
      loopToken++;
      loop(loopToken);
    },

    stop: function () {
      running = false;
      connected = false;
      if (listener) {
        Otzaria.off('reader.current_ref_changed', listener);
        listener = null;
      }
      if (publishTimer) {
        clearTimeout(publishTimer);
        publishTimer = null;
      }
    },
  };
})();
