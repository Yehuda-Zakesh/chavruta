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
   * שם שולחן העבודה המשותף.
   *
   * **השם הוא הזהות המשותפת, ולא המזהה.** מזהה שולחן באוצריא נוצר
   * מחותמת זמן ולכן הוא שונה בין שני המחשבים; שני הצדדים יוצרים שולחן
   * באותו שם, וכל אחד מהם מקומי לגמרי.
   */
  const DESK_WORKSPACE_NAME = 'חברותא';

  /**
   * מפתח האחסון שבו נשמרים הספרים שהיו פתוחים לפני המעבר האוטומטי
   * לשולחן המשותף — כדי שהלשונית תציע להעביר אותם. ראו [ensureDesk].
   */
  const CARRY_KEY = 'carryPending';

  /**
   * כל כמה זמן נסרק השולחן.
   *
   * **לאוצריא אין אירוע "נפתח טאב"** — `reader.getCurrentState` היא הדרך
   * היחידה לדעת מה פתוח, ואין מה שמעיר אותנו.
   *
   * הקצב איטי בכוונה: טאב חדש נעשה הטאב הפעיל ולכן מפעיל את
   * `reader.current_ref_changed`, וזה המסלול שבו הדיווח יוצא כמעט מיד.
   * הסקירה כאן היא רשת ביטחון בלבד, והיא רצה במופע הרקע כל זמן שאוצריא
   * פתוחה — קצב מהיר היה קונה כאן מעט מאוד ועולה הרבה.
   */
  const DESK_POLL_MS = 15000;

  /** השהיית הסקירה שנגררת משינוי מקום. ראו [queueDeskScan]. */
  const DESK_SCAN_DEBOUNCE_MS = 800;

  /** גבול זמן לקריאה לאוצריא. ראו [callWithTimeout]. */
  const API_TIMEOUT_MS = 5000;

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

  /**
   * האם אוצריא כאן מכירה את ממשק השולחנות. `null` = טרם נבדק.
   * ראו [probeDeskApi].
   */
  let deskApi = null;

  /** טיימר הסקירה של השולחן, כשהיא פעילה. */
  let deskTimer = null;

  /** טיימר ההשהיה של סקירה שנגררה משינוי מקום. */
  let deskScanTimer = null;

  /** חתימת השולחן שדווח לאחרונה, כדי לא לדווח את אותה תמונה שוב. */
  let lastDeskKey = null;

  /** האם סקירת שולחן רצה כרגע, כדי ששתיים לא ירוצו זו על גבי זו. */
  let scanningDesk = false;

  /**
   * ספרים שלא הצלחנו לפתוח כאן (אינם בספרייה). מדווחים אותם למתאם כדי
   * שלא יציע אותם שוב ושוב, והוא שוכח אותם כשהם נפתחים מחדש בשולחן.
   */
  let failedBooks = {};

  /** מדיניות הסגירה שהמתאם מדווח: `ask`, `always` או `never`. */
  let closePolicy = 'ask';

  /** האם לסנכרן גם את מקום הלימוד, לפי מה שהמתאם מדווח. */
  let syncLocation = true;

  /** שאלת הסגירה האחרונה שהוצגה, כדי לא לחזור עליה בכל סבב. */
  let lastCloseAsk = null;

  /** האם כבר ניסינו להיכנס לשולחן המשותף מעצמנו. ראו [ensureDesk]. */
  let autoEnterDone = false;

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
    // כשמקום הלימוד כבוי הדיווח **בכל זאת יוצא**, וההשתקה נעשית במתאם:
    // הוא זה שמפסיק לשדר לרשת, והלשונית ממשיכה להראות "המקום שלי".
    // שתי נקודות החלטה על אותו דבר היו נסתרות זו את זו.
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
      // טאב חדש נעשה הטאב הפעיל, ולכן האירוע הזה הוא הרמז המיידי
      // שאוצריא נותנת על פתיחתו — הרבה לפני הסקירה התקופתית.
      queueDeskScan();
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
      startDeskScanning();
    } else {
      detachListener();
      stopDeskScanning();
    }
  }

  // --- השולחן המשותף ------------------------------------------------------

  /**
   * קריאה לאוצריא עם גבול זמן.
   *
   * **קריאה שאינה חוזרת היא הכשל הגרוע ביותר כאן**, כי היא תוקעת את
   * לולאת הסנכרון כולה: אין עוד `/events`, ההחזקה על המנוע פגה, והמצב
   * מבחוץ נראה בדיוק כמו "התוסף מת" — בזמן שהלשונית עצמה מגיבה יפה.
   * מתודה שאינה קיימת אמורה להיכשל מיד, אבל אסור להישען על זה.
   */
  function callWithTimeout(method, args) {
    return Promise.race([
      Otzaria.call(method, args || {}),
      new Promise(function (_, reject) {
        setTimeout(function () {
          reject(new Error(method + ' לא ענתה'));
        }, API_TIMEOUT_MS);
      }),
    ]);
  }

  /**
   * בודק פעם אחת אם אוצריא כאן מכירה את ממשק השולחנות.
   *
   * `workspace.list` היא הקריאה הזולה והבטוחה מבין החדשות, והיא נכנסה
   * יחד עם `reader.closeTab` באותו שינוי — ולכן תשובה ממנה מעידה על כל
   * המשפחה. גרסה ישנה זורקת "מתודה לא מוכרת", והתוסף ממשיך לעבוד בלי
   * שולחן משותף במקום להיתקע.
   */
  async function probeDeskApi() {
    if (deskApi !== null) return deskApi;
    try {
      const res = await callWithTimeout('workspace.list');
      deskApi = !!(res && res.success);
    } catch (e) {
      deskApi = false;
    }
    if (!deskApi) {
      notifyUser(
        'גרסת אוצריא הזאת אינה תומכת בשולחן עבודה משותף. ' +
          'מקום הלימוד ימשיך להסתנכרן כרגיל.'
      );
    }
    return deskApi;
  }

  /** רשימת השולחנות, כדי שהלשונית תוכל להציע מאיפה להביא ספרים. */
  async function listWorkspaces() {
    try {
      const res = await callWithTimeout('workspace.list');
      return res && res.success && Array.isArray(res.data) ? res.data : [];
    } catch (e) {
      return [];
    }
  }

  /** מזהה השולחן הפעיל כרגע, או null אם אין. */
  async function activeWorkspaceId() {
    try {
      const res = await callWithTimeout('workspace.getActive');
      return res && res.success && res.data ? res.data.id : null;
    } catch (e) {
      return null;
    }
  }

  /** שם השולחן הפעיל כרגע, או null אם אין. */
  async function activeWorkspaceName() {
    try {
      const res = await callWithTimeout('workspace.getActive');
      return res && res.success && res.data ? res.data.name : null;
    } catch (e) {
      return null;
    }
  }

  /**
   * נכנס לשולחן המשותף מעצמו, פעם אחת בכל ריצה.
   *
   * **מי שמזווג לחברותא אמור להיות בשולחן המשותף.** בלי זה הסנכרון
   * שותק עד שהמשתמש ילחץ משהו — וזה בדיוק המצב שבו "הכול מחובר" אבל
   * שום דבר לא קורה, שהוא הגרוע מכולם.
   *
   * הספרים שהיו פתוחים לפני המעבר נשמרים, כדי שהלשונית תוכל לשאול מה
   * מהם להעביר בפעם הבאה שהיא נפתחת. המעבר עצמו אינו סוגר אותם — הם
   * נשארים בשולחן שממנו באנו.
   */
  async function ensureDesk() {
    if (autoEnterDone) return;
    autoEnterDone = true;
    if (!(await probeDeskApi())) return;
    if (await inDeskWorkspace()) return;

    let carry = [];
    try {
      carry = await readDesk();
    } catch (e) {
      carry = [];
    }

    if (!(await enterDeskWorkspace())) return;

    // **אומרים מה קרה.** מעבר שולחן הוא שינוי גדול על המסך, ומשתמש
    // שנזרק לשולחן ריק בלי מילה אינו מבין אם משהו התקלקל.
    try {
      const call = Otzaria.call('ui.showSuccess', {
        message:
          'עברת לשולחן העבודה "חברותא" — כאן הספרים משותפים. ' +
          'הספרים שהיו פתוחים נשארו בשולחן הקודם.',
      });
      if (call && typeof call.catch === 'function') call.catch(function () {});
    } catch (e) {
      // ההודעה היא שירות; אין לה השפעה על הסנכרון.
    }

    if (carry.length === 0) return;
    try {
      await Otzaria.call('storage.set', {
        key: CARRY_KEY,
        value: carry.map(function (book) {
          return { b: book.b, i: book.i };
        }),
      });
    } catch (e) {
      // ההצעה היא נוחות; כישלון בשמירה אינו שובר את הסנכרון.
    }
  }

  /**
   * מוודא שאנחנו נמצאים בשולחן החברותא, ויוצר אותו אם אינו קיים.
   *
   * `reuseExisting` לפי **שם** ולא לפי מזהה, ובכוונה: מזהה שולחן נוצר
   * מחותמת זמן ולכן הוא שונה בין שני המחשבים. השם הוא מה שמשותף.
   */
  async function enterDeskWorkspace() {
    if (!(await probeDeskApi())) return false;
    try {
      const res = await callWithTimeout('workspace.create', {
        name: DESK_WORKSPACE_NAME,
        switchTo: true,
        reuseExisting: true,
      });
      if (!res || !res.success || !res.data) return false;
      // המזהה מקומי ואינו מעניין: הזהות המשותפת היא השם.
      await reopenSelf();
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * פותח מחדש את לשונית החברותא אחרי מעבר שולחן.
   *
   * **מעבר שולחן מחליף את כל הטאבים, ולשונית התוסף היא טאב.** בלי זה
   * המשתמש נוחת בשולחן חדש בלי התוסף — בלי הסבר מה קרה, ובלי הדרך
   * היחידה לנהל את החברותא. הוא גם היה מאבד את מנוע הסנכרון עצמו, כי
   * הוא רץ בלשונית כשאין מופע רקע.
   */
  async function reopenSelf() {
    try {
      await callWithTimeout('plugin.openSelf', { param: { enteredDesk: true } });
    } catch (e) {
      // אין הרשאת ניווט, או גרסה ישנה. המשתמש יפתח את הלשונית בעצמו.
    }
  }

  /**
   * הספרים הפתוחים כאן, עם המקום שלהם ברשימה של אוצריא.
   *
   * רק טאבי ספר: טאב חיפוש או טאב של תוסף אחר מופיע גם הוא ב-openTabs,
   * אבל reader.openBook אינה יודעת לשחזר אותו בצד השני. אוצריא מסמנת
   * אותם ב-type ריק.
   *
   * ה-slot הוא המיקום ברשימה **שאוצריא מחזירה**, וזה בדיוק האינדקס
   * ש-reader.closeTab מצפה לו. הוא מקומי למחשב הזה ואינו נשלח לרשת.
   */
  async function readDesk() {
    const res = await callWithTimeout('reader.getCurrentState');
    const list = res && res.success && res.data ? res.data.openTabs : null;
    if (!Array.isArray(list)) return [];
    const books = [];
    for (let i = 0; i < list.length; i++) {
      const tab = list[i];
      if (!tab || tab.type === null || typeof tab.bookId !== 'string') continue;
      if (tab.bookId === '') continue;
      books.push({
        b: tab.bookId,
        i: typeof tab.index === 'number' && tab.index > 0 ? tab.index : 0,
        slot: i,
      });
    }
    return books;
  }

  /**
   * האם מותר לדווח על השולחן עכשיו.
   *
   * **רק כשהשולחן הפעיל הוא שולחן החברותא.** בלי התנאי הזה, מעבר לשולחן
   * עבודה אחר היה נראה למתאם כאילו כל הספרים המשותפים נסגרו — והוא היה
   * סוגר אותם אצל החברותא.
   */
  async function inDeskWorkspace() {
    // **הבדיקה חייבת לרוץ כאן ולא להישען על מי שרץ קודם.** הלשונית
    // נטענת מחדש בכל מעבר שולחן ובכל רענון, והמצב `deskApi` מתאפס איתה;
    // בלי הבדיקה הזאת התשובה הייתה "לא בשולחן המשותף" גם כשאנחנו בתוכו,
    // רק משום שאיש עוד לא בדק אם הממשק קיים.
    if (deskApi === null) await probeDeskApi();
    if (deskApi !== true) return false;
    return (await activeWorkspaceName()) === DESK_WORKSPACE_NAME;
  }

  /**
   * סורק את השולחן ומדווח עליו, אם השתנה.
   *
   * הדיווח הוא תמונת מצב מלאה; מה נפתח, מה נסגר ומה כבר ידוע לחברותא
   * מחושב במתאם. החתימה כאן חוסכת רק את הפנייה עצמה כשלא השתנה כלום.
   */
  async function scanDesk(force) {
    if (!owner || scanningDesk) return;
    if (!(await inDeskWorkspace())) return;
    scanningDesk = true;
    try {
      const books = await readDesk();
      const key = books
        .map(function (t) {
          return t.b;
        })
        .join(' ');
      if (!force && key === lastDeskKey) return;
      await Companion.publishDesk({
        tabs: books.map(function (t) {
          return { b: t.b, i: t.i };
        }),
        canClose: deskApi === true,
        failed: Object.keys(failedBooks),
      });
      lastDeskKey = key;
    } catch (e) {
      // המתאם אינו זמין, או שאוצריא לא ענתה. הסריקה הבאה תדווח ממילא.
    } finally {
      scanningDesk = false;
    }
  }

  /**
   * מבקש סקירה בעקבות שינוי מקום, בהשהיה.
   *
   * reader.current_ref_changed נורה **בכל גלילה**, ו-getCurrentState
   * אינה קריאה זולה — היא פותרת מיקום עבור כל טאב פתוח. בלי ההשהיה
   * גלילה רגילה בספר הייתה מייצרת סריקה על כל שורה.
   */
  function queueDeskScan() {
    if (!owner) return;
    if (deskScanTimer) clearTimeout(deskScanTimer);
    deskScanTimer = setTimeout(function () {
      deskScanTimer = null;
      scanDesk(false);
    }, DESK_SCAN_DEBOUNCE_MS);
  }

  function startDeskScanning() {
    if (deskTimer) return;
    deskTimer = setInterval(function () {
      scanDesk(false);
    }, DESK_POLL_MS);
    scanDesk(true);
  }

  function stopDeskScanning() {
    if (deskScanTimer) {
      clearTimeout(deskScanTimer);
      deskScanTimer = null;
    }
    if (!deskTimer) return;
    clearInterval(deskTimer);
    deskTimer = null;
    lastDeskKey = null;
  }

  /**
   * מבצע את תוכנית השולחן: פותח מה שהחברותא פתחה, וסוגר מה שהיא סגרה.
   *
   * **וחוזר למקום שבו היינו.** reader.openBook פותחת *ומקדמת*, ובלי
   * החזרה הזאת ספר שהחברותא פתחה היה חוטף את המסך באמצע לימוד. סנכרון
   * המקום הוא ערוץ נפרד, והוא זה שיזיז אותנו כשהיא באמת עוברת דף.
   */
  async function applyDeskPlan(plan) {
    const toOpen = (plan && plan.open) || [];
    const toClose = (plan && plan.close) || [];
    if (toOpen.length === 0 && toClose.length === 0) return;
    if (!(await inDeskWorkspace())) return;

    const before = await currentLocation();
    let changed = false;

    for (let i = 0; i < toOpen.length; i++) {
      const entry = toOpen[i];
      if (!entry || typeof entry.b !== 'string' || entry.b === '') continue;
      let opened = false;
      try {
        const res = await Otzaria.call('reader.openBook', {
          bookId: entry.b,
          index: typeof entry.i === 'number' ? entry.i : 0,
        });
        opened = !!(res && res.success && res.data !== false);
      } catch (e) {
        opened = false;
      }
      if (opened) {
        changed = true;
        delete failedBooks[entry.b];
      } else {
        // הספר אינו בספרייה כאן. מדווחים למתאם שלא יציע אותו שוב,
        // ואומרים למשתמש פעם אחת — זה נראה בדיוק כמו סנכרון שנתקע.
        failedBooks[entry.b] = true;
        if (entry.b !== missingBook) {
          missingBook = entry.b;
          notifyUser(
            'החברותא פתחה את "' + entry.b +
              '", והוא אינו בספרייה שלך — הוא לא נפתח כאן.'
          );
        }
      }
    }

    if (toClose.length > 0) {
      const closed = await closeBooks(toClose);
      changed = closed || changed;
    }

    if (changed && before) {
      try {
        await Otzaria.call('reader.openBook', {
          bookId: before.bookId,
          index: before.index,
          navigateToPositionIfReused: true,
        });
      } catch (e) {
        // לא הצלחנו לחזור. סנכרון המקום יחזיר אותנו בעדכון הבא.
      }
    }

    // מדווחים מיד, כדי שהמתאם יידע שהתוכנית בוצעה ולא יציע אותה שוב.
    if (changed) await scanDesk(true);
  }

  /**
   * סוגר ספרים שהחברותא סגרה, לפי מדיניות הסגירה.
   *
   * **הסגירה אינה סימטרית לפתיחה**: ספר שנפתח אצל החברותא אפשר תמיד
   * לפתוח גם כאן, אבל ספר שהיא סגרה יכול להיות בדיוק זה שאני באמצע.
   * לכן ברירת המחדל היא לשאול, והשאלה מוצגת כהודעה שאפשר ללחוץ עליה
   * ולא כחלון שקוטע את הלימוד.
   */
  async function closeBooks(entries) {
    const names = [];
    for (let i = 0; i < entries.length; i++) {
      if (entries[i] && typeof entries[i].b === 'string') {
        names.push(entries[i].b);
      }
    }
    if (names.length === 0) return false;

    if (closePolicy !== 'always') {
      askToClose(names);
      return false;
    }
    return await closeByName(names);
  }

  /**
   * סוגר ספרים לפי שם.
   *
   * reader.closeTab מקבלת **אינדקס ברשימה ש-getCurrentState החזירה**,
   * ולכן קוראים את הרשימה מחדש וסוגרים מהסוף להתחלה: סגירת טאב מזיזה את
   * כל מי שאחריו, וסגירה מלפנים הייתה סוגרת את הטאב הלא נכון.
   */
  async function closeByName(names) {
    const books = await readDesk();
    const wanted = {};
    for (let i = 0; i < names.length; i++) wanted[names[i]] = true;

    const slots = [];
    for (let i = 0; i < books.length; i++) {
      if (wanted[books[i].b]) slots.push(books[i].slot);
    }
    slots.sort(function (a, b) {
      return b - a;
    });

    if (slots.length === 0) {
      // הספר שהחברותא סגרה אינו ברשימת הטאבים הפתוחים כאן. בדרך כלל
      // פירושו ששם הספר כאן שונה מזה שאצלה, וזה בדיוק המקרה שאסור
      // שייעלם בשקט — הוא נראה כמו "לחצתי לסגור ולא קרה כלום".
      notifyUser(
        'לא מצאתי כאן טאב פתוח בשם "' + names.join('", "') +
          '", ולכן אין מה לסגור.'
      );
      return false;
    }

    let closed = 0;
    let lastError = null;
    for (let i = 0; i < slots.length; i++) {
      try {
        const res = await callWithTimeout('reader.closeTab', { index: slots[i] });
        if (res && res.success && res.data !== false) closed++;
        else lastError = 'אוצריא לא סגרה את הטאב';
      } catch (e) {
        lastError = e && e.message ? e.message : 'קריאת הסגירה נכשלה';
        // גרסה שאינה מכירה סגירה. מפסיקים לבקש אותה, אחרת המתאם ימשיך
        // להציע את אותה סגירה בכל סבב.
        deskApi = false;
        break;
      }
    }

    if (closed > 0) {
      lastDeskKey = null;
      await scanDesk(true);
    } else if (lastError) {
      notifyUser('הסגירה נכשלה: ' + lastError);
    }
    return closed > 0;
  }

  /**
   * מציג את שאלת הסגירה כהודעה שאפשר ללחוץ עליה.
   *
   * המנוע רץ בדרך כלל במופע הרקע, שאין לו מסך; ההודעה היא הדרך שלו
   * לדבר. לחיצה עליה פותחת את לשונית החברותא, ושם יש כפתורים.
   */
  function askToClose(names) {
    const key = names.slice().sort().join('|');
    if (key === lastCloseAsk) return;
    lastCloseAsk = key;
    const title =
      names.length === 1
        ? 'החברותא סגרה את "' + names[0] + '"'
        : 'החברותא סגרה ' + names.length + ' ספרים';
    try {
      const call = Otzaria.call('ui.showMessage', {
        message: title + ' — לחצו כאן כדי להחליט אם לסגור גם כאן.',
        tapPayload: { deskCloses: names },
      });
      if (call && typeof call.catch === 'function') call.catch(function () {});
    } catch (e) {
      // ההודעה היא שירות למשתמש, לא חלק מהסנכרון.
    }
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
        // המתג נקרא מהמתאם ולא מזיכרון התוסף, כי מופע הרקע — שהוא בדרך
        // כלל המסנכרן — אינו רואה את מה שהמשתמש לחץ בלשונית.
        // ההעדפות נקראות מהמתאם ולא מזיכרון התוסף, כי מופע הרקע — שהוא
        // בדרך כלל המסנכרן — אינו רואה את מה שהמשתמש לחץ בלשונית.
        syncLocation = state.syncLocation !== false;
        if (typeof state.closePolicy === 'string') {
          closePolicy = state.closePolicy;
        }
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

        // מזווגים אך לא בשולחן המשותף — נכנסים אליו. בלי זה הסנכרון
        // שותק אחרי כל הפעלה מחדש, כי זרימת ההתחברות רצה רק פעם אחת.
        if (state.paired === true) {
          await ensureDesk();
          if (!current(token)) return;
        }

        // השולחן לפני המקום, ובכוונה: פתיחת ספר מקדמת אותו, ואילו הסדר
        // היה הפוך היינו מנווטים למקום הנכון ומיד נזרקים ממנו.
        if (state.desk) await applyDeskPlan(state.desk);
        if (!current(token)) return;

        if (syncLocation && state.hasUpdate && state.remote) {
          await applyRemote(state.remote);
        }
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

    /** האם אוצריא כאן מכירה את ממשק השולחנות. `null` = טרם נבדק. */
    get deskSupported() {
      return deskApi;
    },

    /**
     * נכנס לשולחן החברותא (ויוצר אותו אם צריך).
     *
     * הלשונית קוראת לזה ברגע ההתחברות, לפני שהיא שואלת מה להעביר.
     */
    enterDesk: enterDeskWorkspace,

    /** הספרים הפתוחים בשולחן הפעיל כרגע. הלשונית שואלת מה מהם להעביר. */
    readDesk: readDesk,

    /** רשימת השולחנות, להצעת "מאיפה להביא ספרים". */
    listWorkspaces: listWorkspaces,


    /**
     * האם אנחנו נמצאים כרגע בשולחן המשותף.
     *
     * הלשונית שואלת כדי לדעת אם להציע לחזור אליו: מי שכבר היה מזווג
     * מקודם לא עבר בזרימת ההתחברות, ולכן אינו בשולחן — והסנכרון היה
     * שותק בלי לומר למה.
     */
    inDesk: inDeskWorkspace,

    /** סוגר כאן ספרים לפי שם — התשובה "כן" של המשתמש על שאלת סגירה. */
    closeBooksByName: closeByName,

    /** מדווח את השולחן מיד, בלי להמתין לסקירה הבאה. */
    rescanDesk: function () {
      lastDeskKey = null;
      return scanDesk(true);
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
      lastDeskKey = null;
      lastCloseAsk = null;
      failedBooks = {};
      autoEnterDone = false;
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
      stopDeskScanning();
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
