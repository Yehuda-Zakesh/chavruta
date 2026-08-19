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

  const el = {
    deviceLabel: document.getElementById('deviceLabel'),
    statusDot: document.getElementById('statusDot'),
    statusText: document.getElementById('statusText'),
    banners: document.getElementById('banners'),
    roomInput: document.getElementById('roomInput'),
    joinButton: document.getElementById('joinButton'),
    leaveButton: document.getElementById('leaveButton'),
    peerList: document.getElementById('peerList'),
    peerEmpty: document.getElementById('peerEmpty'),
    localSpot: document.getElementById('localSpot'),
    remoteSpot: document.getElementById('remoteSpot'),
    nameInput: document.getElementById('nameInput'),
    nameButton: document.getElementById('nameButton'),
  };

  let refreshTimer = null;
  let nameDirty = false;
  let ownsEngine = false;

  // --- תצוגה ---------------------------------------------------------------

  function setStatus(kind, text) {
    el.statusDot.className = 'status-dot' + (kind ? ' ' + kind : '');
    el.statusText.textContent = text;
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

  function renderPeers(peers) {
    const list = Array.isArray(peers) ? peers : [];
    el.peerList.textContent = '';
    el.peerEmpty.classList.toggle('hidden', list.length > 0);

    list.forEach(function (peer) {
      const item = document.createElement('li');
      item.className = 'peer';

      const name = document.createElement('span');
      name.className = 'peer-name';
      name.textContent = peer.name || 'מכשיר ללא שם';

      const seen = document.createElement('span');
      seen.className = 'peer-seen';
      seen.textContent = describeSeen(peer.lastSeenMs);

      item.appendChild(name);
      item.appendChild(seen);
      el.peerList.appendChild(item);
    });
  }

  function renderState(state) {
    el.deviceLabel.textContent = state.deviceName || '';
    if (!nameDirty && document.activeElement !== el.nameInput) {
      el.nameInput.value = state.deviceName || '';
    }

    const paired = state.paired === true;
    el.joinButton.textContent = paired ? 'עדכון קוד' : 'התחברות';
    el.leaveButton.classList.toggle('hidden', !paired);

    if (!paired) {
      setStatus('', 'לא מחובר לחברותא');
    } else if (Array.isArray(state.peers) && state.peers.length > 0) {
      setStatus('on', 'מסונכרן · ' + state.peers.length + ' מחוברים');
    } else {
      setStatus('on', 'ממתין לחברותא');
    }

    renderPeers(state.peers);
    el.localSpot.textContent = describeSpot(state.localLocation);
    el.remoteSpot.textContent = state.remote
      ? describeSpot(state.remote.location) +
        (state.remote.fromName ? ' (' + state.remote.fromName + ')' : '')
      : '—';

    if (state.lanBound === false) {
      banner(
        'lan',
        'error',
        'המתאם אינו מאזין לרשת',
        'פורט 45870 תפוס או חסום על ידי חומת האש. סנכרון לא יעבוד עד שהפורט ' +
          'יתפנה — בדקו שאין מתאם חברותא נוסף שרץ על המחשב.'
      );
    } else {
      clearBanner('lan');
    }
  }

  async function refresh() {
    try {
      const state = await Companion.hello();
      clearBanner('companion');
      renderState(state);
    } catch (e) {
      setStatus('off', 'המתאם אינו פועל');
      banner(
        'companion',
        'error',
        'לא נמצא מתאם חברותא על המחשב הזה',
        'הסנכרון עובד דרך תוכנה קטנה שרצה בצד אוצריא. התקינו את ' +
          '<code>מתאם חברותא</code> והפעילו אותו — הוא עולה עם המחשב ופועל ' +
          'ברקע. אחרי ההתקנה הלשונית הזאת תזהה אותו לבד.'
      );
    }
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
      await Companion.setRoom(code);
      await Otzaria.call('storage.set', { key: ROOM_KEY, value: code });
      Otzaria.call('ui.showSuccess', { message: 'מחובר לחברותא' });
      await refresh();
    } catch (e) {
      notifyError('החיבור לחברותא נכשל: ' + e.message);
    } finally {
      el.joinButton.disabled = false;
    }
  }

  async function leave() {
    el.leaveButton.disabled = true;
    try {
      await Companion.setRoom('');
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

  el.joinButton.addEventListener('click', join);
  el.leaveButton.addEventListener('click', leave);
  el.nameButton.addEventListener('click', saveName);
  el.nameInput.addEventListener('input', function () {
    nameDirty = true;
  });
  el.roomInput.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') join();
  });

  // --- מחזור חיים ----------------------------------------------------------

  Otzaria.on('plugin.boot', async function (payload) {
    applyTheme(payload.theme);

    const permissions = (payload && payload.permissions) || [];
    const canRunInBackground = permissions.indexOf('app.run_on_startup') >= 0;
    const canStayAlive = permissions.indexOf('app.background_keep_alive') >= 0;

    // חלוקת התפקידים: הרקע מסנכרן כשהוא רשאי לרוץ, ואחרת הלשונית.
    ownsEngine = !canRunInBackground;
    if (ownsEngine) {
      banner(
        'role',
        '',
        'הסנכרון פועל רק כשהלשונית הזאת פתוחה',
        'כדי שהסנכרון יעבוד גם בזמן קריאה בספר, אשרו לתוסף את ההרשאות ' +
          '"ריצה בעליית אוצריא" ו"המשך ריצה ברקע" בהגדרות התוספים.'
      );
      SyncEngine.start();
    } else if (!canStayAlive) {
      banner(
        'role',
        '',
        'הסנכרון עשוי להיעצר אחרי כמה דקות',
        'ההרשאה "המשך ריצה ברקע" אינה מאושרת, ולכן אוצריא מכבה את מנוע ' +
          'הסנכרון אחרי כשלוש דקות של חוסר פעילות. אשרו אותה בהגדרות התוספים.'
      );
    }

    try {
      const stored = await Otzaria.call('storage.get', { key: ROOM_KEY });
      if (stored && stored.success && typeof stored.data === 'string') {
        el.roomInput.value = stored.data;
      }
    } catch (e) {
      // אין קוד שמור — השדה נשאר ריק.
    }

    startRefreshing();
  });

  Otzaria.on('theme.changed', applyTheme);

  // ה-WebView מושהה כשהמשתמש עובר ללשונית אחרת; אין טעם לתחקר את המתאם
  // בזמן הזה. מנוע הסנכרון, אם הוא בבעלות הלשונית, ממשיך לרוץ.
  Otzaria.on('plugin.suspended', stopRefreshing);
  Otzaria.on('plugin.resumed', startRefreshing);
})();
