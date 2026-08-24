import 'dart:io';

/// בדיקה האם קיים ב-Windows חוק חומת אש שמתיר תעבורה נכנסת אל המתאם.
///
/// למה זה כאן בכלל: ההודעות של החברותא מגיעות ב-UDP broadcast, כלומר
/// **תעבורה נכנסת שלא ביקשנו**. Windows חוסם אותה כברירת מחדל, וההיתר
/// שהוא יוצר הוא לפי **נתיב ה-exe ולפי פרופיל הרשת**. משמע שני מצבים
/// שקורים בשטח, ובשניהם המתאם רץ ונראה תקין אך אינו שומע כלום:
///
/// - בחלון האישור של Windows מסומן כברירת מחדל "רשתות פרטיות" בלבד.
///   רשת אלחוטית של בית או נקודה חמה מסומנות לא פעם כ"ציבורית", ואז
///   ההיתר פשוט אינו חל.
/// - החוק נקשר לנתיב הישן. התקנה למיקום אחר, או הרצה מתיקייה אחרת,
///   מגיעה בלי היתר.
///
/// התוצאה כאן היא **רמז ולא פסק דין**: `true` אם נמצא חוק שמזכיר את
/// הנתיב שלנו, `false` אם לא נמצא, ו-`null` אם לא הצלחנו לבדוק (מערכת
/// שאינה Windows, netsh שנכשל). התוסף מציג אותו רק כשהמשתמש מזווג ובכל
/// זאת אינו רואה אף אחד — כלומר בדיוק כשהשאלה "למה?" נשאלת.
Future<bool?> hasInboundFirewallRule({String? executablePath}) async {
  if (!Platform.isWindows) return null;
  final path = (executablePath ?? Platform.resolvedExecutable).toLowerCase();
  if (path.isEmpty) return null;
  try {
    final result = await Process.run('netsh', [
      'advfirewall',
      'firewall',
      'show',
      'rule',
      'name=all',
      'dir=in',
      'verbose',
    ], stdoutEncoding: systemEncoding);
    if (result.exitCode != 0) return null;
    final output = '${result.stdout}'.toLowerCase();
    if (output.isEmpty) return null;
    // הפלט של netsh מתורגם לשפת המערכת, ולכן אין להישען על שמות
    // השדות — הנתיב עצמו מופיע כמות שהוא בכל שפה.
    return output.contains(path);
  } catch (_) {
    // netsh חסום או חסר. אין לנו מה לומר, וזה עדיף על אזהרת שווא.
    return null;
  }
}
