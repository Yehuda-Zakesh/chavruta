'use strict';

/**
 * מנוע הסנכרון: מחבר בין מקום הקריאה באוצריא לבין המתאם.
 *
 * שני כיוונים, שניהם דרך המתאם:
 * - יוצא: כל שינוי מקום קריאה מדווח ל-`/publish`.
 * - נכנס: המתנה ארוכה על `/events`, וכל עדכון מהחברותא הופך לניווט.
 *
 * **מופע אחד בלבד מריץ את המנוע**, ושני מופעים יחד היו מנווטים פעמיים
 * ומדווחים פעמיים על אותו מקום. **המתאם הוא שמכריע מי זה**, ולא התוסף:
 * שני המופעים מתחילים לרוץ, כל אחד שולח את המזהה שלו, ומי שאינו המחזיק
 * מקבל `engineMine: false` ומחכה בלי לגעת בכלום.
 *
 * זה בא במקום חלוקה שנגזרה כאן מרשימת ההרשאות, והייתה נחישה: הלשונית
 * ויתרה על המנוע ברגע ש-`app.run_on_startup` אושרה, בלי שום דרך לדעת אם
 * מופע הרקע באמת חי. כשהוא לא היה חי — הרשאת keep-alive שלא אושרה,
 * ואוצריא סוגרת את המופע אחרי כשלוש דקות — הסנכרון נעצר בשקט מוחלט.
 */
const SyncEngine = (function () {
  /** גלילה מהירה מייצרת שינויי מקום רבים; מדווחים רק על מה שנשאר. */
  const PUBLISH_DEBOUNCE_MS = 700;

  const RETRY_MIN_MS = 3000;
  const RETRY_MAX_MS = 30000;

  /**
   * כמה להמתין בין ניסיונות כשמופע אחר מחזיק את המנוע.
   *
   * זו אינה שגיאה אלא המצב הרגיל בלשונית פתוחה, ולכן ההמתנה קבועה ואינה
   * גדלה. היא צריכה להיות קצרה מההחזקה בצד המתאם (45 שניות), כדי שמופע
   * רקע שנסגר יוחלף מהר.
   */
  const NOT_OWNER_RETRY_MS = 10000;

  let running = false;
  let since = -1;
  let retryDelay = RETRY_MIN_MS;
  let publishTimer = null;
  let lastSentKey = null;
  let listener = null;
  let status = { connected: false, error: null, state: null, owner: false };
  let onStatusChange = function () {};

  /** האם המתאם מסר לנו את ההחזקה על המנוע. ראו את התיעוד בראש הקובץ. */
  let owner = false;

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
    // מופע שאינו המחזיק אינו מדווח: שני מופעים שידווחו יגרמו לשידור כפול,
    // ואם הלשונית תדווח בזמן שהרקע מנווט — גם למיקום שאינו הנוכחי.
    if (!owner) return;
    const key = keyOf(location);
    if (key === lastSentKey) return;
    try {
      await Companion.publish(location);
      lastSentKey = key;
    } catch (e) {
      // המתאם אינו זמין כרגע. אין טעם לתור המתנה: המקום הנוכחי יידווח
      // שוב בשינוי הבא, וגם `/events` תגלה שהמתאם חזר.
      setStatus({ connected: false, error: e.message, state: null, owner: owner });
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

  function attachListener() {
    if (listener) return;
    listener = function (payload) {
      queuePublish(payload);
    };
    Otzaria.on('reader.current_ref_changed', listener);
  }

  function detachListener() {
    if (publishTimer) {
      clearTimeout(publishTimer);
      publishTimer = null;
    }
    if (!listener) return;
    Otzaria.off('reader.current_ref_changed', listener);
    listener = null;
  }

  /**
   * מעדכן אם ההחזקה על המנוע בידינו, ומחבר או מנתק את המעקב בהתאם.
   *
   * המאזין מחובר רק כשההחזקה בידינו: מופע שאינו המחזיק אינו צריך לשמוע
   * על שינויי מקום כלל, ומופע שקיבל את ההחזקה חייב לדווח את המקום הנוכחי
   * מיד — אחרת המתאם אינו יודע איפה אנחנו עד מעבר הדף הבא.
   */
  async function setOwner(next) {
    if (next === owner) return;
    owner = next;
    if (owner) {
      attachListener();
      await republishCurrent();
    } else {
      detachListener();
    }
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

        // מתאם מגרסה שאינה מכירה את ההחזקה אינו מחזיר `engineMine`. אז
        // מתייחסים אליו כמי שמסר לנו אותה, כלומר בדיוק ההתנהגות הקודמת.
        const mine = state.engineMine !== false;
        await setOwner(mine);
        if (!current(token)) return;
        setStatus({ connected: true, error: null, state: state, owner: mine });

        if (!mine) {
          // מופע אחר מסנכרן. לא מדווחים, לא מנווטים, ולא מחזיקים בקשה
          // פתוחה — רק חוזרים לבדוק, כדי לקחת את המנוע אם הוא ייסגר.
          await sleep(NOT_OWNER_RETRY_MS);
          continue;
        }

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
        setStatus({ connected: false, error: e.message, state: null, owner: owner });
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

    /** האם ההחזקה על המנוע בידי המופע הזה. */
    get owner() {
      return owner;
    },

    /**
     * מפעיל את המנוע עבור המופע [instanceId] (`'background'` או
     * `'foreground:<מזהה>'`).
     *
     * שני המופעים קוראים לזה, וזה בכוונה: המתאם הוא שמכריע מי מהם
     * מסנכרן בפועל, וכך מופע רקע שנסגר מוחלף מעצמו.
     */
    start: function (instanceId) {
      if (running) return;
      running = true;
      since = -1;
      // המצב מאופס גם אם המנוע כבר רץ פעם: מתאם אחר, או אותו מתאם
      // אחרי הפעלה מחדש, אינו יודע דבר על מה שדיווחנו בעבר.
      connected = false;
      owner = false;
      lastSentKey = null;
      missingBook = null;
      Companion.setInstance(instanceId || '');

      // המאזין מחובר רק כשהמתאם ימסור לנו את ההחזקה (ראו [setOwner]), וגם
      // הדיווח הראשוני נעשה שם: בעלייה המתאם לא תמיד כבר רץ, ודיווח
      // שנכשל כאן לא היה חוזר לעולם.
      loopToken++;
      loop(loopToken);
    },

    stop: function () {
      running = false;
      connected = false;
      detachListener();
      // משחררים את ההחזקה כדי שהמופע האחר ייכנס מיד ולא ימתין עד שהיא
      // תפוג. כשל כאן אינו מעניין — היא פגה לבדה.
      if (owner) {
        owner = false;
        try {
          const call = Companion.releaseEngine();
          if (call && typeof call.catch === 'function') call.catch(function () {});
        } catch (e) {
          // אין מתאם, או שהוא נסגר. ההחזקה תפוג בצד שלו ממילא.
        }
      }
    },
  };
})();
