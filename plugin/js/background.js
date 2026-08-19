'use strict';

/**
 * נקודת הכניסה של מופע הרקע.
 *
 * מופע הרקע הוא זה שמריץ את הסנכרון בפועל: הוא חי כל זמן שאוצריא פתוחה
 * (בזכות `startup.keepAlive` והרשאת `app.background_keep_alive`), ולכן
 * מקום הלימוד מסתנכרן גם כשהמשתמש קורא בספר ולא נמצא בלשונית התוסף.
 */
Otzaria.on('plugin.boot', function (payload) {
  // הדף הזה נטען רק כמופע רקע, אבל בדיקת runMode היא רשת ביטחון: מנוע
  // שירוץ גם ברקע וגם בלשונית ינווט פעמיים על כל עדכון מהחברותא.
  if (!payload || !payload.app || payload.app.runMode !== 'background') return;
  SyncEngine.start();
});
