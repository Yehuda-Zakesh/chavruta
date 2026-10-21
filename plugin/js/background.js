'use strict';

/**
 * נקודת הכניסה של מופע הרקע.
 *
 * מופע הרקע הוא זה שמריץ את הסנכרון בפועל: הוא חי כל זמן שאוצריא פתוחה
 * (בזכות `startup.keepAlive` והרשאת `app.background_keep_alive`), ולכן
 * מקום הלימוד מסתנכרן גם כשהמשתמש קורא בספר ולא נמצא בלשונית התוסף.
 *
 * בחיבור המרוחק גם בקשת ההמתנה הפתוחה מול השרת מחזיקה אותו חי: אוצריא
 * אינה מכבה מופע רקע שיש לו קריאה פתוחה.
 */
Otzaria.on('plugin.boot', async function (payload) {
  // הדף הזה נטען רק כמופע רקע, אבל בדיקת runMode היא רשת ביטחון: מנוע
  // שירוץ גם ברקע וגם בלשונית ינווט פעמיים על כל עדכון מהחברותא.
  if (!payload || !payload.app || payload.app.runMode !== 'background') return;
  RemoteLink.setPermissions(payload.permissions);
  await Link.load();
  function configureReadiness() {
    const info = Readiness.fromBoot(payload, Link.mode);
    RemoteLink.setReadiness(info);
    Companion.setReadiness(info);
  }
  configureReadiness();
  // `'background'` הוא המזהה שמועדף על לשונית — במתאם וגם בנעילה של
  // החיבור המרוחק: המופע הזה חי כל זמן שאוצריא פתוחה, ואילו הלשונית
  // מוקפאת ברגע שהמשתמש עובר לספר.
  SyncEngine.start('background');
  // החלפת דרך החיבור נעשית בלשונית; המופע הזה מגלה אותה ומתחיל מחדש.
  Link.watch(function () {
    configureReadiness();
    SyncEngine.start('background');
  });
});
