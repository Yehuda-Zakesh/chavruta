'use strict';

/**
 * לשונית התוסף: זיווג, מצב ורשימת המחוברים.
 *
 * הלשונית אינה מריצה את מנוע הסנכרון כשמופע הרקע מריץ אותו — היא רק
 * מציגה את מצב המתאם ושולחת לו פקודות. כשההרשאה לריצת רקע לא ניתנה,
 * הלשונית היא שמריצה את המנוע, וכתוב כאן במפורש שהסנכרון תלוי בה.
 */
(function () {
  /** קצב רענון התצוגה כל זמן שהלשונית מוצגת. */
  const REFRESH_MS = 3000;

  /** הקוד שהמשתמש הקליד, כדי למלא את השדה בפתיחה הבאה. */
  const ROOM_KEY = 'roomCode';

  /**
   * הצעת ההעברה שממתינה לשאלה — אותו מפתח שהמנוע כותב אליו.
   *
   * **המעבר לשולחן המשותף הורג את הדף הזה.** `plugin.openSelf` פותח
   * לשונית חדשה בשולחן החדש, ולכן רשימה שנשמרה רק בזיכרון נעלמת לפני
   * שהמשתמש הספיק לראות אותה. הרשימה נשמרת כאן לפני המעבר, והלשונית
   * החדשה קוראת אותה ב-[loadPendingCarry].
   */
  const CARRY_KEY = 'carryPending';

  const el = {
    topbar: document.getElementById('topbar'),
    appContent: document.getElementById('appContent'),
    deviceLabel: document.getElementById('deviceLabel'),
    statusPill: document.getElementById('statusPill'),
    statusDot: document.getElementById('statusDot'),
    statusText: document.getElementById('statusText'),
    banners: document.getElementById('banners'),
    heroViz: document.getElementById('heroViz'),
    heroTitle: document.getElementById('heroTitle'),
    heroSub: document.getElementById('heroSub'),
    roomChip: document.getElementById('roomChip'),
    roomInput: document.getElementById('roomInput'),
    joinButton: document.getElementById('joinButton'),
    leaveButton: document.getElementById('leaveButton'),
    peerList: document.getElementById('peerList'),
    peerCount: document.getElementById('peerCount'),
    peerEmpty: document.getElementById('peerEmpty'),
    localSpot: document.getElementById('localSpot'),
    remoteSpot: document.getElementById('remoteSpot'),
    nameInput: document.getElementById('nameInput'),
    nameButton: document.getElementById('nameButton'),
    deskCount: document.getElementById('deskCount'),
    enterDesk: document.getElementById('enterDesk'),
    locationToggle: document.getElementById('locationToggle'),
    locationText: document.getElementById('locationText'),
    closePolicy: document.getElementById('closePolicy'),
    carryCard: document.getElementById('carryCard'),
    carryList: document.getElementById('carryList'),
    carryAll: document.getElementById('carryAll'),
    carrySome: document.getElementById('carrySome'),
    carrySkip: document.getElementById('carrySkip'),
    closeCard: document.getElementById('closeCard'),
    closeList: document.getElementById('closeList'),
    closeYes: document.getElementById('closeYes'),
    closeNo: document.getElementById('closeNo'),
    companionCard: document.getElementById('companionCard'),
    startupToggle: document.getElementById('startupToggle'),
    startupText: document.getElementById('startupText'),
  };

  let refreshTimer = null;
  let nameDirty = false;

  /** מזהה המופע הזה מול המתאם. ראו את התיעוד בראש `sync-engine.js`. */
  const instanceId =
    'foreground:' + Math.random().toString(36).slice(2, 10);

  /** האם מצב "עולה עם המחשב" נקרא מהמתאם מאז שהוא נמצא. */
  let startupLoaded = false;

  /** האם שינוי העדפה בעיצומו — אז הרענון אינו דורס את הפקד. */
  let settingsBusy = false;

  /** הספרים שמוצעים להעברה לשולחן המשותף. ראו [offerCarry]. */
  let carryOptions = [];

  /** ספרים שהחברותא סגרה וממתינים לתשובה שלך. ראו [renderCloseAsk]. */
  let pendingCloses = [];

  /** הקוד שהזיווג הנוכחי נעשה בו — למען ה-chip שבכרטיס הראשי. המתאם מדווח
   *  אם יש זיווג, אך לא את הקוד עצמו, ולכן הוא נזכר כאן. */
  let activeRoom = '';

  /** הפורט שאליו הקוד השמור כבר נאמר; 0 = עוד לא נאמר לאף מתאם. */
  let roomAssertedPort = 0;

  /** מתי התחילה ההמתנה הנוכחית לחברותא; 0 = לא ממתינים. */
  let waitingSince = 0;

  /** אחרי כמה זמן של המתנה ריקה מוצג רמז מה לבדוק. שתי פעימות נוכחות
   *  של המתאם (20 שניות כל אחת) — אחריהן כבר לא סביר שזה עניין של תזמון. */
  const WAITING_HINT_MS = 45000;

  function trackWaiting(waiting) {
    if (!waiting) waitingSince = 0;
    else if (waitingSince === 0) waitingSince = Date.now();
  }

  function waitingTooLong() {
    return waitingSince !== 0 && Date.now() - waitingSince > WAITING_HINT_MS;
  }

  // --- תצוגה ---------------------------------------------------------------

  function setStatus(kind, text) {
    el.statusDot.className = 'status-dot' + (kind ? ' ' + kind : '');
    el.statusPill.className = 'status' + (kind ? ' ' + kind : '');
    el.statusText.textContent = text;
  }

  /**
   * הכרטיס הראשי: ויזואליזציית החיבור, כותרת ומשפט הסבר.
   * `state` הוא idle / waiting / linked / error, וה-CSS מצייר לפיו את הפס
   * שבין שני המחשבים.
   */
  function setHero(state, title, sub) {
    el.heroViz.className = 'hero-viz state-' + state;
    el.heroTitle.textContent = title;
    el.heroSub.textContent = sub;
  }

  function setRoomChip(code) {
    const show = typeof code === 'string' && code !== '';
    el.roomChip.classList.toggle('hidden', !show);
    if (show) {
      el.roomChip.textContent = code;
      el.roomChip.title = code;
    }
  }

  function banner(id, kind, title, html) {
    let node = document.getElementById(id);
    if (!node) {
      node = document.createElement('div');
      node.id = id;
      node.className = 'banner fade-in' + (kind ? ' ' + kind : '');
      el.banners.appendChild(node);
    }
    node.innerHTML = '<div class="banner-title">' + title + '</div>' + html;
  }

  function clearBanner(id) {
    const node = document.getElementById(id);
    if (node) node.remove();
  }

  /** טקסט שמגיע מהמתאם (הודעת שגיאה של המערכת) נכנס לבאנר כטקסט בלבד. */
  function escapeHtml(text) {
    return String(text).replace(/[&<>"']/g, function (ch) {
      return {
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;',
      }[ch];
    });
  }

  function describeSpot(location) {
    if (!location || typeof location.bookId !== 'string') return '—';
    if (location.ref) return location.ref;
    return location.bookId + ' · קטע ' + location.index;
  }

  function describeSeen(lastSeenMs) {
    const seconds = Math.max(0, Math.round((Date.now() - lastSeenMs) / 1000));
    if (seconds < 30) return 'עכשיו';
    if (seconds < 90) return 'לפני דקה';
    return 'לפני ' + Math.round(seconds / 60) + ' דקות';
  }

  /** האות הראשונה בשם, לעיגול האווטאר. */
  function initialOf(name) {
    const trimmed = (name || '').trim();
    return trimmed === '' ? '?' : trimmed.charAt(0);
  }

  function renderPeers(peers, remote) {
    const list = Array.isArray(peers) ? peers : [];
    el.peerList.textContent = '';
    el.peerEmpty.classList.toggle('hidden', list.length > 0);
    el.peerCount.classList.toggle('hidden', list.length === 0);
    el.peerCount.textContent = String(list.length);

    list.forEach(function (peer) {
      const item = document.createElement('li');
      item.className = 'peer';

      const avatar = document.createElement('span');
      avatar.className = 'peer-avatar';
      avatar.setAttribute('aria-hidden', 'true');
      avatar.textContent = initialOf(peer.name);

      const main = document.createElement('span');
      main.className = 'peer-main';

      const name = document.createElement('span');
      name.className = 'peer-name';
      name.textContent = peer.name || 'מכשיר ללא שם';
      main.appendChild(name);

      // המתאם מדווח מקום מרוחק אחד בלבד, עם מזהה השולח. כשהוא שייך
      // למחובר הזה, מקום הלימוד שלו מוצג בשורה שלו. ההשוואה היא לפי
      // המזהה ולא לפי השם: השם משתנה (המשתמש יכול לשנות אותו בכל רגע,
      // והרשימה מציגה תמיד את החדש), ושני מכשירים יכולים לשאת אותו שם.
      if (remote && remote.fromId && remote.fromId === peer.id) {
        const spot = document.createElement('span');
        spot.className = 'peer-spot';
        spot.textContent = describeSpot(remote.location);
        main.appendChild(spot);
      }

      const seen = document.createElement('span');
      seen.className = 'peer-seen';
      seen.textContent = describeSeen(peer.lastSeenMs);

      item.appendChild(avatar);
      item.appendChild(main);
      item.appendChild(seen);
      el.peerList.appendChild(item);
    });
  }

  /**
   * למה אין אף אחד ברשימה — לפי מה שהמתאם באמת קלט מהרשת.
   *
   * שלושת המצבים האלה נראים מבחוץ זהים לגמרי ("ממתין לחברותא"), והפתרון
   * לכל אחד מהם אחר לגמרי. ההפרדה ביניהם נשענת על כך שהשידור שלנו חוזר
   * אלינו — broadcast נקלט גם אצל השולח — ולכן קליטה באפס אינה "אין אף
   * אחד ברשת" אלא סוקט חסום.
   *
   * מתאם ישן שאינו מדווח את המונים מקבל את הנוסח הכללי שהיה כאן קודם.
   */
  function diagnoseEmptyWait(state) {
    const received = state.datagramsReceived;
    if (typeof received !== 'number') {
      return 'עדיין אין אף אחד. בדקו שחיבור הבלוטות\' בין שני המחשבים פעיל, ' +
        'שהקוד זהה בדיוק, ושמתאם החברותא רץ גם בצד השני.';
    }
    if (received === 0) {
      return 'המתאם אינו שומע כלום — גם לא את השידור של עצמו. ' +
        'זו כמעט תמיד חומת האש של Windows חוסמת את הפורט 45870.';
    }
    if (state.datagramsFromOthers === 0) {
      return 'השידור שלכם יוצא וחוזר, אך שום הודעה ממחשב אחר לא הגיעה. ' +
        'כלומר חיבור הבלוטות\' אינו פעיל כרגע, או שהמתאם בצד השני אינו רץ.';
    }
    if (state.datagramsRejected > 0) {
      return 'הודעות ממחשב אחר כן מגיעות (' + describeSource(state) + '), אך כולן ' +
        'נדחות — כמעט בוודאות הקוד אינו זהה בדיוק בשני הצדדים.';
    }
    return 'הודעות ממחשב אחר מגיעות (' + describeSource(state) + '), אבל לא מחברותא ' +
      'שלכם. ודאו שהקוד זהה בדיוק בשני הצדדים.';
  }

  /** תיאור מקור ההודעות המרוחקות, לשילוב במשפט. */
  function describeSource(state) {
    return typeof state.lastRemoteSource === 'string' && state.lastRemoteSource !== ''
      ? 'מ-' + state.lastRemoteSource
      : 'ממחשב אחר';
  }

  /**
   * תיאור הקישורים שהמתאם משדר דרכם. השוואה בין שני מחשבים חושפת מיד אם
   * הם באמת על אותו קישור, וזה הדבר הראשון שצריך לבדוק.
   *
   * כרטיס ש-`sending` שלו שקר נמנה אך מעולם לא יצא ממנו שידור — זה מצבם
   * של כרטיסי Wi-Fi Direct ו-Bluetooth PAN שאין בצדם אף אחד. הוא מסומן
   * במפורש, כי בלי זה השורה מציגה שלושה כרטיסים מתים כאילו הם קישור.
   */
  function describeLinks(links) {
    if (!Array.isArray(links) || links.length === 0) return 'אין כרטיס פעיל';
    return links
      .map(function (link) {
        const label = link.local + ' → ' + link.broadcast;
        return link.sending === false ? label + ' (אינו משדר)' : label;
      })
      .join(', ');
  }

  /** כתובת 169.254 היא הקישור הישיר בין שני המחשבים — בלוטות', Wi-Fi
   *  Direct או כבל. זה הקישור שהחברותא אמורה להיות בצדו. */
  function hasDirectLink(links) {
    return (
      Array.isArray(links) &&
      links.some(function (link) {
        return (
          link.sending !== false &&
          typeof link.local === 'string' &&
          link.local.indexOf('169.254.') === 0
        );
      })
    );
  }

  /**
   * מציג את מצב השולחן המשותף ואת ההעדפות, כפי שהמתאם מדווח אותם.
   *
   * המקור הוא תמיד המתאם ולא זיכרון הלשונית: ההעדפות נשמרות אצלו כדי
   * ששני מופעי התוסף יראו אותן, והלשונית רק משקפת. לכן היא גם אינה
   * דורסת פקד שהמשתמש בדיוק משנה.
   */
  /**
   * מציג את הכפתור "פתיחת השולחן המשותף" כשצריך.
   *
   * מי שכבר היה מזווג מקודם לא עבר בזרימת ההתחברות, ולכן הוא אינו בשולחן
   * המשותף — והסנכרון שותק. בלי הכפתור הזה אין שום דרך לחזור אליו חוץ
   * מיציאה והתחברות מחדש. הוא גם הדרך היומיומית לחזור אחרי שעבדתם
   * בשולחן אחר.
   */
  async function refreshDeskEntry(paired) {
    if (!paired) {
      if (el.enterDesk) el.enterDesk.classList.add('hidden');
      clearBanner('desk');
      return;
    }
    let inside = false;
    try {
      inside = await SyncEngine.inDesk();
    } catch (e) {
      inside = false;
    }
    if (el.enterDesk) el.enterDesk.classList.toggle('hidden', inside);

    // **המשתמש חייב לדעת באיזה שולחן הוא נמצא.** מעבר שולחן מחליף את
    // כל הטאבים, ובלי השורה הזאת "למה הספרים שלי נעלמו" הוא שאלה
    // סבירה לגמרי.
    if (inside) {
      banner(
        'desk',
        '',
        'אתם בשולחן העבודה "חברותא"',
        'כל ספר שנפתח כאן נפתח גם אצל החברותא. הספרים שבשולחנות ' +
          'האחרים שלכם נשארו שם, פרטיים לגמרי.<br />' +
          'כדי להביא ספר משולחן אחר: עברו אליו, פתחו שם את לשונית ' +
          'חברותא, ולחצו "מעבר לשולחן המשותף" — הספרים שפתוחים שם ' +
          'יוצעו להעברה.'
      );
    } else if (SyncEngine.deskSupported === false) {
      // מצב שונה לגמרי מ"אינך בשולחן": כאן אין בכלל מה לעשות, ואסור
      // לשלוח את המשתמש לחפש שולחן שאוצריא שלו אינה יודעת לפתוח.
      banner(
        'desk',
        '',
        'גרסת אוצריא הזאת אינה תומכת בשולחן משותף',
        'מקום הלימוד מסתנכרן כרגיל. שדרוג של אוצריא יפעיל גם את ' +
          'סנכרון הספרים.'
      );
    } else {
      banner(
        'desk',
        '',
        'אתם לא בשולחן המשותף',
        'הסנכרון של הספרים פועל רק בשולחן העבודה "חברותא". ' +
          'מקום הלימוד ממשיך להסתנכרן כרגיל.'
      );
    }
  }

  /** נכנס לשולחן המשותף ומציע להעביר אליו את מה שפתוח עכשיו. */
  async function enterDesk() {
    el.enterDesk.disabled = true;
    try {
      const before = await readCarryOptions();
      // נשמר **לפני** המעבר: המעבר פותח את הלשונית מחדש, וכל מה שלא
      // נכתב לאחסון עד כאן לא ישרוד כדי להישאל.
      await rememberPendingCarry(before);
      if (!(await SyncEngine.enterDesk())) {
        forgetPendingCarry();
        notifyError('לא הצלחתי לפתוח את השולחן המשותף.');
        return;
      }
      offerCarry(before);
      await refresh();
    } finally {
      el.enterDesk.disabled = false;
    }
  }

  function renderDesk(state) {
    refreshDeskEntry(state && state.paired === true);
    const shared = state && typeof state.deskCount === 'number'
      ? state.deskCount
      : 0;
    el.deskCount.textContent = shared === 0
      ? 'ריק — ספר שייפתח כאן ייפתח גם אצל החברותא'
      : shared === 1
        ? 'ספר אחד משותף'
        : shared + ' ספרים משותפים';

    if (!settingsBusy) {
      el.locationToggle.checked = !(state && state.syncLocation === false);
      el.locationText.textContent = el.locationToggle.checked
        ? 'דלוק — כשאחד עובר דף, השני עובר איתו'
        : 'כבוי — כל אחד גולל בקצב שלו';
      if (state && typeof state.closePolicy === 'string') {
        el.closePolicy.value = state.closePolicy;
      }
    }
  }

  function renderState(state) {
    el.deviceLabel.textContent = state.deviceName || '';
    renderDesk(state);
    if (!nameDirty && document.activeElement !== el.nameInput) {
      el.nameInput.value = state.deviceName || '';
    }

    const paired = state.paired === true;
    const peers = Array.isArray(state.peers) ? state.peers : [];
    el.joinButton.textContent = paired ? 'עדכון קוד' : 'התחברות';
    el.leaveButton.classList.toggle('hidden', !paired);
    setRoomChip(paired ? activeRoom : '');
    trackWaiting(paired && peers.length === 0);

    if (!paired) {
      setStatus('', 'לא מחובר לחברותא');
      setHero(
        'idle',
        'לא מחובר לחברותא',
        'הקלידו קוד — אותו קוד בדיוק אצל שני הצדדים — ולחצו התחברות.'
      );
    } else if (peers.length > 0) {
      setStatus('on', 'מסונכרן · ' + peers.length + ' מחוברים');
      setHero(
        'linked',
        peers.length === 1 ? 'מסונכרן עם החברותא' : 'מסונכרן · ' + peers.length + ' מחוברים',
        'כשאחד מכם עובר דף, השני עובר איתו.'
      );
    } else {
      setStatus('on', 'ממתין לחברותא');
      setHero(
        'waiting',
        'ממתין לחברותא',
        waitingTooLong()
          ? diagnoseEmptyWait(state)
          : 'אתם מחוברים לקוד. ברגע שהצד השני יקליד אצלו את אותו קוד, מקום הלימוד יסתנכרן.'
      );
    }

    renderPeers(peers, state.remote);
    el.localSpot.textContent = describeSpot(state.localLocation);
    el.remoteSpot.textContent = state.remote
      ? describeSpot(state.remote.location) +
        (state.remote.fromName ? ' (' + state.remote.fromName + ')' : '')
      : '—';

    if (state.lanBound === false) {
      banner(
        'lan',
        'error',
        'המתאם אינו מאזין לקישור',
        (state.lanError ? 'הסיבה שדווחה: ' + escapeHtml(state.lanError) + '. ' : '') +
          'המתאם מנסה להתחבר מחדש כל כמה שניות, ולכן ניתוק רגעי מסתדר מעצמו. ' +
          'אם זה נמשך — בדקו שחיבור הבלוטות\' בין המחשבים פעיל, ושאין מתאם ' +
          'חברותא נוסף שרץ.'
      );
    } else {
      clearBanner('lan');
    }

    // **אף מופע של התוסף אינו מסנכרן.** זה היה עד עכשיו בלתי נראה לגמרי:
    // המתאם רץ, המחוברים מוצגים, והמסך אומר "מסונכרן" — אבל אף אחד לא
    // מדווח מיקום ואף אחד לא ממתין לעדכון, ולכן שום דף אינו נפתח.
    const engine = state.engine;
    if (paired && engine && engine.owner === null) {
      banner(
        'engine',
        'error',
        'הסנכרון אינו פועל כרגע',
        'המתאם מחובר לחברותא, אבל אף מופע של התוסף אינו מסנכרן — כלומר ' +
          'מקום הלימוד אינו נשלח ואינו נקלט. פתיחה מחדש של לשונית החברותא ' +
          'מחזירה את הסנכרון; אם זה חוזר, דווחו על כך.'
      );
    } else {
      clearBanner('engine');
    }

    // הקישורים מוצגים רק בשעת אבחון — מזווגים, אין אף אחד, וההמתנה כבר
    // אינה עניין של תזמון. השוואת השורה הזאת בין שני המחשבים היא הבדיקה
    // המהירה ביותר ל"האם הם בכלל על אותה רשת", ובלעדיה צריך לפתוח קובץ
    // יומן בשני המחשבים כדי לענות על השאלה הבסיסית הזאת.
    if (paired && peers.length === 0 && waitingTooLong()) {
      banner(
        'links',
        '',
        'דרך מה המחשב הזה משדר',
        '<code>' + escapeHtml(describeLinks(state.links)) + '</code><br>' +
          (hasDirectLink(state.links)
            ? 'יש כאן קישור ישיר פעיל (<code>169.254</code>) — זה הבלוטות\'. ' +
              'השוו את השורה לזו שבמחשב השני; אם גם שם יש שורת <code>169.254</code> ' +
              'משדרת, הקישור קיים והבעיה בקוד החברותא או במתאם שבצד השני.'
            : 'אין כאן קישור ישיר פעיל. חיבור בלוטות\' בין שני מחשבים נותן ' +
              'כתובת <code>169.254</code> שמשדרת, ובלעדיה אין דרך להגיע לחברותא. ' +
              'ב-Windows החיבור אינו קם מעצמו: לחצו ימני על סמל הבלוטות\' ← ' +
              '<b>הצטרפות לרשת אישית</b>, ובחרו את המחשב השני ← <b>התחבר באמצעות ' +
              'נקודת גישה</b>.')
      );
    } else {
      clearBanner('links');
    }

    // רמז חומת האש מוצג רק כשהוא רלוונטי: מזווגים, ובכל זאת אין אף אחד
    // ברשימה. הודעות החברותא הן תעבורה נכנסת שלא ביקשנו, ו-Windows חוסם
    // אותה כברירת מחדל — כולל כשההיתר ניתן ל"רשתות פרטיות" בלבד והרשת
    // הנוכחית מסומנת ציבורית.
    if (paired && peers.length === 0 && state.firewallRule === false) {
      banner(
        'firewall',
        '',
        'ייתכן שחומת האש של Windows חוסמת',
        'לא נמצא היתר נכנס למתאם החברותא. הריצו את המתקין שוב וסמנו את ' +
          'הוספת חוק חומת האש, או אשרו ידנית ל-<code>ChavrutaCompanion.exe</code> ' +
          'תעבורה נכנסת ב-UDP 45870. חשוב לאשר גם ל<b>רשתות ציבוריות</b>: ' +
          'חיבור בלוטות\' בין שני מחשבים מסומן ב-Windows כרשת ציבורית.'
      );
    } else {
      clearBanner('firewall');
    }

    // הודעות החברותא מגיעות ונדחות בגלל השעה. בלי הבאנר הזה זה נראה
    // בדיוק כמו "אין אף אחד ברשת", ואין שום דרך לנחש את הסיבה.
    if (typeof state.clockSkewMinutes === 'number') {
      banner(
        'clock',
        'error',
        'השעונים של שני המחשבים אינם מסונכרנים',
        'החברותא נמצאה, אך ההודעות שלה נדחות: הפרש של כ-' +
          Math.abs(state.clockSkewMinutes) +
          ' דקות בין השעונים. תקנו את השעה במחשב שסוטה ' +
          '(הגדרות ← שעה ושפה ← סנכרן כעת), והסנכרון יחזור מיד.'
      );
    } else {
      clearBanner('clock');
    }
  }

  /**
   * מה להציג כשאין תשובה מהמתאם.
   *
   * כל המקרים נראים למשתמש אותו דבר — לשונית ריקה — אבל הפתרון שונה
   * לגמרי בכל אחד, ולכן ההסבר נגזר מסוג הכשל ש-`Companion` מדווח ולא
   * מניח שהמתאם אינו פועל. הודעה שגויה כאן שולחת את המשתמש להתקין
   * מחדש תוכנה שרצה כבר, במקום להדליק מתג באוצריא.
   */
  const FAILURES = {
    permission: {
      status: 'אין הרשאת רשת',
      title: 'הרשאת הרשת של התוסף כבויה',
      sub: 'התוסף מדבר עם המתאם דרך כתובת מקומית במחשב, וההרשאה לכך חסומה.',
      bannerTitle: 'צריך להדליק לתוסף "גישה לרשת"',
      html:
        'הסנכרון עובר דרך תוכנה קטנה שרצה על המחשב הזה, ולכן התוסף צריך ' +
        'את הרשאת <code>גישה לשירותים מקומיים</code>. הדליקו אותה ב' +
        '<b>הגדרות › כלים › ניהול תוספים</b>, בשורת החברותא — המתג ' +
        '<code>גישה לרשת</code>. ההרשאה הזאת אינה נותנת לתוסף גישה לאינטרנט.',
    },
    unsupported: {
      status: 'גרסת אוצריא ישנה',
      title: 'אוצריא כאן ישנה מדי',
      sub: 'הלשונית משתמשת בממשק רשת שנוסף באוצריא 0.9.97.',
      bannerTitle: 'צריך לעדכן את אוצריא',
      html:
        'התוסף מדבר עם המתאם דרך <code>network.fetchStream</code>, שקיים ' +
        'מאוצריא <b>0.9.97</b> ומעלה. עדכנו את אוצריא, והלשונית תתחבר לבד.',
    },
    allowlist: {
      status: 'הכתובת חסומה',
      title: 'אוצריא חסמה את הפנייה למתאם',
      sub: 'הכתובת המקומית של המתאם אינה ברשימת ההיתר של התוסף.',
      bannerTitle: 'הכתובת אינה ברשימת ההיתר',
      html:
        'זו תקלה בתוסף עצמו ולא במחשב שלכם — <code>127.0.0.1</code> אמור ' +
        'להיות מוצהר ב-<code>network.allowlist</code> של התוסף. דווחו על כך, ' +
        'ובינתיים נסו להתקין מחדש את גרסת התוסף האחרונה.',
    },
    http: {
      status: 'המתאם עונה בשגיאה',
      title: 'המתאם פועל, אך אינו עונה כשורה',
      sub: 'התוכנה שעל המחשב הזה נמצאה, אבל היא מחזירה שגיאה במקום תשובה.',
      bannerTitle: 'המתאם החזיר שגיאה',
      html:
        'זו אינה תקלת התקנה — המתאם רץ ועונה, אך משהו אצלו נכשל. ' +
        'היומן שלו ב-<code>%LOCALAPPDATA%\\Chavruta\\companion.log</code> ' +
        'אומר מה. אם זה חוזר, סגרו אותו והפעילו מחדש מתפריט התחל ' +
        '("הפעלת מתאם חברותא"), ודווחו על כך.',
    },
    notFound: {
      status: 'המתאם אינו פועל',
      title: 'המתאם אינו פועל',
      sub: 'הסנכרון עובד דרך תוכנה קטנה שרצה בצד אוצריא, והיא אינה פועלת כרגע.',
      bannerTitle: 'לא נמצא מתאם חברותא על המחשב הזה',
      html:
        'הסנכרון עובד דרך תוכנה קטנה שרצה בצד אוצריא. התקינו את ' +
        '<code>מתאם חברותא</code> והפעילו אותו — הוא עולה עם המחשב ופועל ' +
        'ברקע. אחרי ההתקנה הלשונית הזאת תזהה אותו לבד.<br>' +
        'אם התקנתם והפעלתם, המתאם רץ בלי חלון — היומן שלו ב' +
        '<code>%LOCALAPPDATA%\\Chavruta\\companion.log</code> אומר אם הוא עלה ' +
        'ועל איזה פורט.',
    },
  };

  function showFailure(kind) {
    const info = FAILURES[kind] || FAILURES.notFound;
    setStatus('off', info.status);
    setHero('error', info.title, info.sub);
    setRoomChip('');
    // בלי מתאם אין מחוברים ואין מקום מרוחק — הכרטיסים נשארים במצב ריק
    // מפורש ולא מציגים נתונים מלפני שהמתאם נפל.
    renderPeers([], null);
    el.localSpot.textContent = '—';
    el.remoteSpot.textContent = '—';
    // מצב ה-LAN הוא דיווח של המתאם; בלי תשובה ממנו אין מה לטעון עליו.
    clearBanner('lan');
    banner('companion', 'error', info.bannerTitle, info.html);
    // בלי מתאם אין מי שיקרא את הרישום, ולכן גם אין מה להציג עליו.
    startupLoaded = false;
    el.companionCard.classList.add('hidden');
    // המתאם שאליו נאמר הקוד אינו כאן יותר. מי שיימצא במקומו — גם אם
    // הוא על אותו פורט — הוא תהליך אחר, שייתכן שמזווג לקוד אחר לגמרי.
    roomAssertedPort = 0;
  }

  /**
   * מצב "עולה עם המחשב", כפי שהמתאם מדווח אותו.
   *
   * `supported: false` = אין מה להציע במחשב הזה (המתאם רץ מתוך פיתוח, או
   * לא ב-Windows), ואז הכרטיס נשאר מוסתר — מתג שאינו יכול לעבוד גרוע
   * ממתג שאינו מוצג.
   */
  function renderStartup(state) {
    const supported = !!(state && state.supported);
    el.companionCard.classList.toggle('hidden', !supported);
    if (!supported) return;

    el.startupToggle.checked = !!state.enabled;
    el.startupText.textContent = state.enabled
      ? 'עולה עם הכניסה למחשב, ורץ ברקע בלי חלון'
      : 'כבוי — צריך להפעיל את המתאם בעצמכם בכל הדלקה';
  }

  async function loadStartup() {
    try {
      renderStartup(await Companion.startup());
      startupLoaded = true;
    } catch (e) {
      // גרסת מתאם שאינה מכירה את /startup, או כשל רשת. אין כאן מה
      // להודיע למשתמש — פשוט אין מתג.
      startupLoaded = false;
      el.companionCard.classList.add('hidden');
    }
  }

  /**
   * מוודא שהמתאם שנמצא מזווג לקוד שהלשונית מציגה.
   *
   * `/hello` מדווח **אם** יש זיווג אך לא לאיזה קוד — הקוד עצמו אינו יוצא
   * מהמתאם בכוונה. לכן הלשונית מציגה את הקוד שבזיכרון שלה ומניחה שהוא
   * הקוד שבמתאם, וההנחה נשברת בכל מתאם שנשאר מזווג לקוד אחר: מופע ישן
   * שנשאר תלוי על פורט אחר בטווח, או מתאם שהופעל עם `--room` משורת
   * הפקודה. אז הסנכרון רץ בחדר אחד והמסך מראה חדר אחר — שקר שאין שום
   * דרך לראות אותו מהלשונית.
   *
   * `setRoom` בצד המתאם יוצא מיד כשהקוד זהה, ולכן במצב הרגיל זו פעולת
   * אפס — פעם אחת לכל מתאם שנמצא. מחזיר האם הקוד באמת נאמר.
   *
   * נאמר רק למתאם שמדווח על עצמו כמזווג: מתאם שאינו מזווג אינו מציג שום
   * קוד ואין מה לתקן אצלו, וזיווג אוטומטי שלו היה מחזיר לחברותא מישהו
   * שיצא ממנה בכוונה.
   */
  async function assertRoom(state) {
    if (state.paired !== true || activeRoom === '') return false;
    const port = Companion.port;
    if (port === null || port === roomAssertedPort) return false;
    try {
      await Companion.setRoom(activeRoom);
      roomAssertedPort = port;
      return true;
    } catch (e) {
      // המתאם נעלם בין שתי הבקשות. הרענון הבא מחפש אותו מחדש וינסה שוב.
      return false;
    }
  }

  /** רענון שכבר רץ, אם יש. ראו [refresh]. */
  let refreshing = null;

  /**
   * קורא את מצב המתאם ומצייר אותו.
   *
   * רענון אחד בכל רגע: הקצב הוא 3 שניות וגבול הזמן של בקשה הוא 4, ולכן
   * מתאם אטי לרגע היה מייצר בקשות חופפות שמציירות מצבים ישנים על חדשים.
   * מי שקורא בזמן שרענון רץ מקבל את אותו הרענון.
   */
  function refresh() {
    if (refreshing) return refreshing;
    refreshing = (async function () {
      try {
        let state = await Companion.hello();
        clearBanner('companion');
        // אמירת הקוד מנקה את מצב החדר במתאם כשהוא היה בחדר אחר, ולכן
        // המצב נקרא מחדש ולא מוצג זה שנקרא לפניה.
        if (await assertRoom(state)) state = await Companion.hello();
        renderState(state);
        // פעם אחת לכל חיבור למתאם: הרישום אינו משתנה מעצמו, ואין טעם
        // לתחקר אותו בכל רענון.
        if (!startupLoaded) await loadStartup();
      } catch (e) {
        showFailure(e && e.kind);
      } finally {
        refreshing = null;
      }
    })();
    return refreshing;
  }

  function startRefreshing() {
    if (refreshTimer) return;
    refresh();
    refreshTimer = setInterval(refresh, REFRESH_MS);
  }

  function stopRefreshing() {
    if (!refreshTimer) return;
    clearInterval(refreshTimer);
    refreshTimer = null;
  }

  // --- פעולות --------------------------------------------------------------

  function notifyError(message) {
    Otzaria.call('ui.showError', { message: message });
  }

  async function join() {
    const code = el.roomInput.value.trim();
    if (code === '') {
      notifyError('הקלידו קוד חברותא — אותו קוד בדיוק אצל שני הצדדים.');
      return;
    }
    el.joinButton.disabled = true;
    try {
      // **הספרים הפתוחים נקראים לפני המעבר לשולחן החברותא.** אחרי
      // המעבר הם כבר אינם פתוחים — הם נשמרו בשולחן הקודם — וזו הרשימה
      // שהמשתמש בוחר ממנה מה להעביר.
      const before = await readCarryOptions();

      await Companion.setRoom(code);
      await Otzaria.call('storage.set', { key: ROOM_KEY, value: code });
      activeRoom = code;
      // הקוד נאמר לו כרגע במפורש; אין צורך שהרענון יאמר אותו שוב.
      roomAssertedPort = Companion.port;

      await rememberPendingCarry(before);
      const entered = await SyncEngine.enterDesk();
      if (entered) {
        Otzaria.call('ui.showSuccess', {
          message: 'מחובר לחברותא — נפתח שולחן עבודה משותף',
        });
        offerCarry(before);
      } else {
        forgetPendingCarry();
        Otzaria.call('ui.showSuccess', { message: 'מחובר לחברותא' });
      }
      await refresh();
    } catch (e) {
      notifyError('החיבור לחברותא נכשל: ' + e.message);
    } finally {
      el.joinButton.disabled = false;
    }
  }

  /**
   * הספרים הפתוחים כאן עכשיו — המועמדים להעברה לשולחן המשותף.
   *
   * נקרא **לפני** המעבר לשולחן החברותא, כי המעבר מחליף את הטאבים.
   */
  async function readCarryOptions() {
    try {
      const books = await SyncEngine.readDesk();
      return books.map(function (book) {
        return { b: book.b, i: book.i };
      });
    } catch (e) {
      return [];
    }
  }

  /**
   * מציג את השאלה "מה להעביר לשולחן המשותף?".
   *
   * השולחן המשותף מתחיל **ריק**, ובכוונה: מה שפתוח אצלך עכשיו הוא שלך,
   * ורק מה שתבחר להעביר נעשה משותף ומסתנכרן.
   */
  function offerCarry(books) {
    carryOptions = Array.isArray(books) ? books : [];
    renderCarry();
  }

  function renderCarry() {
    const has = carryOptions.length > 0;
    el.carryCard.classList.toggle('hidden', !has);
    if (!has) return;

    el.carryList.innerHTML = '';
    carryOptions.forEach(function (book, position) {
      const item = document.createElement('li');
      item.className = 'carry-item';

      const label = document.createElement('label');
      label.className = 'carry-label';

      const box = document.createElement('input');
      box.type = 'checkbox';
      box.checked = true;
      box.dataset.position = String(position);

      const name = document.createElement('span');
      name.textContent = book.b;

      label.appendChild(box);
      label.appendChild(name);
      item.appendChild(label);
      el.carryList.appendChild(item);
    });
  }

  /** מעביר לשולחן המשותף את מה שסומן, פשוט בכך שהוא נפתח שם. */
  async function carrySelected(all) {
    const boxes = el.carryList.querySelectorAll('input[type="checkbox"]');
    const chosen = [];
    boxes.forEach(function (box) {
      if (!all && !box.checked) return;
      const book = carryOptions[Number(box.dataset.position)];
      if (book) chosen.push(book);
    });

    el.carryAll.disabled = true;
    el.carrySome.disabled = true;
    try {
      for (let i = 0; i < chosen.length; i++) {
        try {
          await Otzaria.call('reader.openBook', {
            bookId: chosen[i].b,
            index: chosen[i].i,
          });
        } catch (e) {
          // ספר שלא נפתח — נדלג עליו ונמשיך לשאר.
        }
      }
      // הסריקה הבאה תראה אותם ותשתף; זירוז כדי שזה ירגיש מיידי.
      await SyncEngine.rescanDesk();
      carryOptions = [];
      renderCarry();
      forgetPendingCarry();
      if (chosen.length > 0) {
        Otzaria.call('ui.showSuccess', {
          message: chosen.length === 1
            ? 'הספר הועבר לשולחן המשותף'
            : chosen.length + ' ספרים הועברו לשולחן המשותף',
        });
      }
      await refresh();
    } finally {
      el.carryAll.disabled = false;
      el.carrySome.disabled = false;
    }
  }

  /** מוותר על ההעברה. הספרים נשארים בשולחן הקודם, פרטיים לגמרי. */
  function skipCarry() {
    carryOptions = [];
    renderCarry();
    forgetPendingCarry();
  }

  /**
   * קורא הצעת העברה שהמנוע השאיר אחריו.
   *
   * המעבר האוטומטי לשולחן המשותף קורה גם כשהלשונית סגורה (מופע הרקע הוא
   * שמסנכרן), ואז אין את מי לשאול. המנוע שומר את מה שהיה פתוח, והלשונית
   * שואלת בפעם הבאה שהיא נפתחת.
   */
  async function loadPendingCarry() {
    if (carryOptions.length > 0) return;
    try {
      const res = await Otzaria.call('storage.get', { key: CARRY_KEY });
      const books = res && res.success ? res.data : null;
      if (Array.isArray(books) && books.length > 0) offerCarry(books);
    } catch (e) {
      // אין הצעה שמורה.
    }
  }

  /**
   * שומר את הצעת ההעברה כדי שתשרוד את המעבר לשולחן המשותף.
   *
   * כישלון בשמירה אינו עוצר את המעבר — במקרה הנדיר שבו הלשונית כן
   * שורדת אותו, [offerCarry] עדיין תציג את הכרטיס מהזיכרון.
   */
  async function rememberPendingCarry(books) {
    if (!Array.isArray(books) || books.length === 0) return;
    try {
      await Otzaria.call('storage.set', { key: CARRY_KEY, value: books });
    } catch (e) {
      // ההצעה היא נוחות; אין לה השפעה על הסנכרון עצמו.
    }
  }

  function forgetPendingCarry() {
    try {
      const call = Otzaria.call('storage.remove', { key: CARRY_KEY });
      if (call && typeof call.catch === 'function') call.catch(function () {});
    } catch (e) {
      // לא נורא; ההצעה תוצג שוב ואפשר יהיה לוותר עליה שוב.
    }
  }

  async function leave() {
    el.leaveButton.disabled = true;
    try {
      await Companion.setRoom('');
      activeRoom = '';
      roomAssertedPort = 0;
      Otzaria.call('ui.showMessage', { message: 'יצאת מהחברותא' });
      await refresh();
    } catch (e) {
      notifyError('היציאה מהחברותא נכשלה: ' + e.message);
    } finally {
      el.leaveButton.disabled = false;
    }
  }

  async function saveName() {
    const name = el.nameInput.value.trim();
    if (name === '') {
      notifyError('שם המכשיר אינו יכול להיות ריק.');
      return;
    }
    el.nameButton.disabled = true;
    try {
      await Companion.setName(name);
      nameDirty = false;
      Otzaria.call('ui.showSuccess', { message: 'השם עודכן' });
      await refresh();
    } catch (e) {
      notifyError('שמירת השם נכשלה: ' + e.message);
    } finally {
      el.nameButton.disabled = false;
    }
  }

  /**
   * הדלקה או כיבוי של עלייה עם המחשב.
   *
   * את הרישום עצמו עושה המתאם — ל-WebView של תוסף אין דרך לגעת ברישום
   * של Windows, וגם לא צריך. התשובה היא המצב **בפועל** אחרי השינוי,
   * ולכן כשל שקט (מדיניות ארגונית, כלי אבטחה) מוצג כמו שהוא במקום
   * להשאיר מתג שנראה דלוק ולא עושה כלום.
   */
  async function toggleStartup() {
    const wanted = el.startupToggle.checked;
    el.startupToggle.disabled = true;
    el.startupText.textContent = 'מעדכן…';
    try {
      const state = await Companion.setStartup(wanted);
      renderStartup(state);
      if (state && state.supported && state.enabled === wanted) {
        Otzaria.call('ui.showSuccess', {
          message: wanted
            ? 'המתאם יעלה עם המחשב'
            : 'המתאם לא יעלה עם המחשב',
        });
      } else {
        // הסיבה שהמתאם מחזיר היא כבר משפט שלם. שרשור שלה אחרי משפט
        // כללי הציג את אותה הודעה פעמיים.
        notifyError(
          (state && state.reason) || 'Windows לא קיבל את השינוי.'
        );
      }
    } catch (e) {
      notifyError('שינוי העלייה עם המחשב נכשל: ' + e.message);
      await loadStartup();
    } finally {
      el.startupToggle.disabled = false;
    }
  }

  /**
   * שומר העדפה במתאם. פעולה אחת, ונשמרת: הוא זוכר אותה בין הפעלות
   * ומספר עליה לשני מופעי התוסף.
   */
  async function saveSettings(settings, message) {
    settingsBusy = true;
    el.locationToggle.disabled = true;
    el.closePolicy.disabled = true;
    try {
      const state = await Companion.setSettings(settings);
      settingsBusy = false;
      renderDesk(state);
      if (message) Otzaria.call('ui.showSuccess', { message: message });
    } catch (e) {
      settingsBusy = false;
      notifyError('שמירת ההעדפה נכשלה: ' + e.message);
      await refresh();
    } finally {
      el.locationToggle.disabled = false;
      el.closePolicy.disabled = false;
    }
  }

  function toggleLocationSync() {
    const wanted = el.locationToggle.checked;
    return saveSettings(
      { syncLocation: wanted },
      wanted
        ? 'מעכשיו כשאחד מכם עובר דף, השני עובר איתו'
        : 'סנכרון מקום הלימוד כובה — השולחן ממשיך להסתנכרן'
    );
  }

  function changeClosePolicy() {
    const value = el.closePolicy.value;
    const messages = {
      ask: 'נשאל אותך בכל פעם שהחברותא סוגרת ספר',
      always: 'ספר שהחברותא סוגרת ייסגר גם כאן',
      never: 'סגירות של החברותא לא ישפיעו עליך',
    };
    return saveSettings({ closePolicy: value }, messages[value]);
  }

  /**
   * שאלת הסגירה: "החברותא סגרה את X — לסגור גם כאן?".
   *
   * המנוע מציג הודעה שאפשר ללחוץ עליה, והלחיצה מגיעה לכאן ופותחת את
   * הכרטיס הזה. כך אין חלון שקוטע את הלימוד.
   */
  function renderCloseAsk() {
    const has = pendingCloses.length > 0;
    el.closeCard.classList.toggle('hidden', !has);
    if (!has) return;
    el.closeList.textContent = pendingCloses.join(', ');
  }

  async function answerClose(shouldClose) {
    const names = pendingCloses.slice();
    if (names.length === 0) return;
    el.closeYes.disabled = true;
    el.closeNo.disabled = true;
    try {
      if (shouldClose) {
        const closed = await SyncEngine.closeBooksByName(names);
        if (!closed) {
          // הכרטיס נשאר פתוח: התשובה לא בוצעה, ואסור שהיא תיראה כאילו כן.
          notifyError('לא הצלחתי לסגור. הפרטים בהודעה שקפצה.');
          return;
        }
        Otzaria.call('ui.showSuccess', {
          message: names.length === 1
            ? 'הספר נסגר גם כאן'
            : names.length + ' ספרים נסגרו גם כאן',
        });
      } else {
        // "לא" נאמר למתאם, אחרת השאלה הייתה חוזרת בכל סבב.
        for (let i = 0; i < names.length; i++) {
          try {
            await Companion.dismissClose(names[i]);
          } catch (e) {
            // כשל בודד אינו מפיל את השאר.
          }
        }
      }
      pendingCloses = [];
      renderCloseAsk();
      await refresh();
    } finally {
      el.closeYes.disabled = false;
      el.closeNo.disabled = false;
    }
  }


  /**
   * מחבר מאזין רק אם האלמנט קיים.
   *
   * במצב פיתוח אוצריא מרעננת את ה-WebView בכל שמירה, וקובץ JS יכול
   * להיטען לצד HTML ישן. אלמנט חסר היה מפיל את כל הקובץ — כלומר גם את
   * מנוע הסנכרון — ומשאיר לשונית ריקה בלי שום רמז למה.
   */
  function on(node, event, handler, options) {
    if (node) node.addEventListener(event, handler, options);
  }

  on(el.joinButton, 'click', join);
  on(el.enterDesk, 'click', enterDesk);
  on(el.locationToggle, 'change', toggleLocationSync);
  on(el.closePolicy, 'change', changeClosePolicy);
  on(el.carryAll, 'click', function () {
    carrySelected(true);
  });
  on(el.carrySome, 'click', function () {
    carrySelected(false);
  });
  on(el.carrySkip, 'click', skipCarry);
  on(el.closeYes, 'click', function () {
    answerClose(true);
  });
  on(el.closeNo, 'click', function () {
    answerClose(false);
  });
  on(el.leaveButton, 'click', leave);
  on(el.nameButton, 'click', saveName);
  on(el.nameInput, 'input', function () {
    nameDirty = true;
  });
  on(el.startupToggle, 'change', toggleStartup);
  on(el.roomInput, 'keydown', function (event) {
    if (event.key === 'Enter') join();
  });

  // פס הכותרת מקבל צללית ברגע שהתוכן נגלל מתחתיו, כמו הסרגל של אוצריא.
  on(el.appContent, 
    'scroll',
    function () {
      if (el.topbar) {
        el.topbar.classList.toggle('scrolled', el.appContent.scrollTop > 2);
      }
    },
    { passive: true }
  );

  // --- מחזור חיים ----------------------------------------------------------

  Otzaria.on('plugin.boot', async function (payload) {
    applyTheme(payload.theme);

    const permissions = (payload && payload.permissions) || [];
    const canRunInBackground = permissions.indexOf('app.run_on_startup') >= 0;

    // **הלשונית מפעילה את המנוע תמיד**, וההכרעה מי מסנכרן בפועל היא של
    // המתאם (ראו את התיעוד בראש `sync-engine.js`). קודם היא נגזרה כאן
    // מרשימת ההרשאות, והתוצאה הייתה שהלשונית ויתרה על המנוע לטובת מופע
    // רקע שלא בהכרח היה חי — ואז שום דבר לא סונכרן, בלי סימן.
    SyncEngine.start(instanceId);

    if (!canRunInBackground) {
      banner(
        'role',
        '',
        'הסנכרון פועל רק כשהלשונית הזאת פתוחה',
        'כדי שהסנכרון יעבוד גם בזמן קריאה בספר, אשרו לתוסף את ההרשאות ' +
          '"ריצה בעליית אוצריא" ו"המשך ריצה ברקע" בהגדרות התוספים.'
      );
    }

    try {
      const stored = await Otzaria.call('storage.get', { key: ROOM_KEY });
      if (stored && stored.success && typeof stored.data === 'string') {
        el.roomInput.value = stored.data;
        activeRoom = stored.data;
      }
    } catch (e) {
      // אין קוד שמור — השדה נשאר ריק.
    }

    loadPendingCarry();
    startRefreshing();
  });

  Otzaria.on('theme.changed', applyTheme);

  /**
   * לחיצה על ההודעה "החברותא סגרה ספרים" — ראו `askToClose` במנוע.
   *
   * ההודעה נשלחת ממופע הרקע, והלחיצה מגיעה לשני המופעים; הלשונית היא
   * זו שיש לה מסך, ולכן היא זו שמציגה את השאלה.
   */
  Otzaria.on('ui.messageClicked', function (payload) {
    const names = payload && payload.payload && payload.payload.deskCloses;
    if (!Array.isArray(names) || names.length === 0) return;
    pendingCloses = names.slice();
    renderCloseAsk();
    Otzaria.call('plugin.openSelf', {});
  });

  // פתיחת הלשונית מתוך ההודעה מגיעה גם כאן; הכרטיס כבר מוצג.
  Otzaria.on('plugin.page_opened', function () {
    renderCloseAsk();
    renderCarry();
  });

  // ה-WebView מושהה כשהמשתמש עובר ללשונית אחרת; אין טעם לתחקר את המתאם
  // בזמן הזה. מנוע הסנכרון, אם הוא בבעלות הלשונית, ממשיך לרוץ.
  Otzaria.on('plugin.suspended', stopRefreshing);
  Otzaria.on('plugin.resumed', startRefreshing);
})();
