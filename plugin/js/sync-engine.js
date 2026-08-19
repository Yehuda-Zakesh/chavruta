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

    // הניווט הזה יוליד אירוע שינוי מקום שיחזור אלינו מיד. מסמנים אותו
    // כ"נשלח" כדי שלא נשדר לחברותא את מה שהיא עצמה ביקשה.
    lastSentKey = keyOf(location);

    const res = await Otzaria.call('reader.openBook', {
      bookId: location.bookId,
      index: location.index,
      navigateToPositionIfReused: true,
    });
    if (!res || !res.success || res.data === false) {
      // הספר אינו קיים בספרייה של המחשב הזה — מצב רגיל בין ספריות שונות.
      lastSentKey = null;
      setStatus({
        connected: true,
        error: 'הספר "' + location.bookId + '" אינו נמצא בספרייה שלך',
        state: status.state,
      });
    }
  }

  async function loop() {
    while (running) {
      try {
        const state = await Companion.events(since);
        retryDelay = RETRY_MIN_MS;
        if (typeof state.remoteSequence === 'number') since = state.remoteSequence;
        setStatus({ connected: true, error: null, state: state });
        if (state.hasUpdate && state.remote) await applyRemote(state.remote);
      } catch (e) {
        if (!running) return;
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

    async start() {
      if (running) return;
      running = true;
      since = -1;

      listener = function (payload) {
        queuePublish(payload);
      };
      Otzaria.on('reader.current_ref_changed', listener);

      // דיווח ראשוני: החברותא צריכה לדעת איפה אנחנו גם בלי שנזוז.
      try {
        const here = await currentLocation();
        if (here) await publish(here);
      } catch (e) {
        // אין ספר פתוח, או שהמתאם עוד לא עלה. הלופ יטפל בזה.
      }

      loop();
    },

    stop: function () {
      running = false;
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
