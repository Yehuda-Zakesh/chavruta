import 'dart:convert';
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
///
/// שגיאת שווא כאן יקרה בהרבה משתיקה: היא מאשימה את חומת האש דווקא
/// כשההיתר קיים, ושולחת את המשתמש לחפש במקום הלא נכון. לכן כל הספק
/// שבפענוח הפלט נופל לצד `true` — ראו [netshOutputMentionsPath].
Future<bool?> hasInboundFirewallRule({String? executablePath}) async {
  if (!Platform.isWindows) return null;
  final path = executablePath ?? Platform.resolvedExecutable;
  if (path.isEmpty) return null;
  try {
    // netsh הוא יישום קונסולה, והקודפייג' שבו הוא פולט הוא זה של
    // הקונסולה שירש — לא הקודפייג' של המערכת. המתאם רץ מהמשגר בלי
    // קונסולה כלל, ולכן אין קודפייג' לנחש. `chcp 65001` בקונסולה שאנו
    // עצמנו פותחים הופך את השאלה לוודאות: הפלט יוצא UTF-8.
    final result = await Process.run(
      'cmd',
      [
        '/c',
        'chcp 65001 >nul & '
            'netsh advfirewall firewall show rule name=all dir=in verbose',
      ],
      stdoutEncoding: null, // בייטים גולמיים; הפענוח נעשה למטה
    );
    if (result.exitCode != 0) return null;
    final bytes = (result.stdout as List<int>);
    if (bytes.isEmpty) return null;
    return netshOutputMentionsPath(bytes, path);
  } catch (_) {
    // netsh חסום או חסר. אין לנו מה לומר, וזה עדיף על אזהרת שווא.
    return null;
  }
}

final _nonAscii = RegExp(r'[^\x00-\x7f]+');

/// האם הפלט הגולמי של netsh מזכיר את [path]. חשוף לצורך בדיקות.
///
/// שם המשתמש בחלונות עברית הוא עברי, ולכן הנתיב אינו אסקי — וכל טעות
/// בקודפייג' הופכת אותו ל-`c:\users\׳–׳׳‘...` ומפילה השוואת מלל פשוטה.
/// זה בדיוק מה שקרה בשטח: ההיתר היה קיים, והמתאם הכריז שאינו קיים.
///
/// לכן שלוש שכבות, מהמדויקת למקלה:
/// 1. UTF-8 — מה ש-`chcp 65001` אמור לתת.
/// 2. קודפייג' המערכת — אם netsh התעלם מ-chcp.
/// 3. עוגני האסקי בלבד. בייטים עבריים נפגעים בכל פענוח, אבל האסקי
///    סביבם לעולם לא. די בכך כדי לזהות את הנתיב, וזו הרשת שתופסת גם
///    קודפייג' שלא חזינו.
bool netshOutputMentionsPath(List<int> bytes, String path) {
  final target = path.toLowerCase();
  final asUtf8 = utf8.decode(bytes, allowMalformed: true);

  String? asSystem;
  try {
    asSystem = systemEncoding.decode(bytes);
  } catch (_) {
    asSystem = null; // בייטים שאינם חוקיים בקודפייג' הזה — ממשיכים
  }

  // שלוש השכבות נבדקות בסדר, והראשונה שמצאה את הנתיב היא הקובעת. חשוב
  // שההכרעה תיפול בשכבה אחת ולא תצטבר: שכבה שמצאה חוק חוסם אינה יכולה
  // "להתבטל" בשכבה הבאה שמצאה חוק מתיר, כי שתיהן קוראות את אותו פלט.
  for (final verdict in [
    _verdictFor(asUtf8, target),
    if (asSystem != null) _verdictFor(asSystem, target),
    _verdictFor(asUtf8, target, anchorsOnly: true),
  ]) {
    if (verdict != _RuleVerdict.noMatch) return verdict == _RuleVerdict.allowed;
  }
  return false;
}

enum _RuleVerdict { noMatch, allowed, blocked }

/// חוק **חוסם** מזוהה ואינו נספר כהיתר.
///
/// זה אינו מקרה קצה: כשהמשתמש לוחץ "ביטול" בחלון האישור של Windows,
/// Windows יוצר חוקי **Block** לאותו exe. ו-Windows מעריך חסימה לפני
/// היתר, ולכן מי שסירב פעם אחת ואחר כך הריץ את המתקין נשאר חסום — עם
/// חוק היתר וחוק חסימה גם יחד. הבדיקה כאן החזירה במצב הזה "יש היתר",
/// והאזהרה נעלמה דווקא כשחומת האש באמת חוסמת.
///
/// **הספק ממשיך ליפול לצד `true`:** התווית `Action` וערכה עשויים להיות
/// מתורגמים בחלונות בשפה אחרת, ואז אין כאן מה לפרש — בלוק שלא הצלחנו
/// לקרוא את הפעולה שלו נחשב מתיר, בדיוק כמו קודם. רק בלוק שקראנו בו
/// במפורש "Block" נזרק.
_RuleVerdict _verdictFor(
  String text,
  String target, {
  bool anchorsOnly = false,
}) {
  var verdict = _RuleVerdict.noMatch;
  for (final block in _ruleBlocks(text)) {
    final mentions = anchorsOnly
        ? _mentionsAsciiAnchors(block, target)
        : block.toLowerCase().contains(target);
    if (!mentions) continue;
    // **חסימה מכריעה, כמו ב-Windows עצמו.** חומת האש מעריכה חוקי חסימה
    // לפני חוקי היתר, ולכן מי שיש לו את שניהם — מי שסירב פעם אחת בחלון
    // האישור ואחר כך הריץ את המתקין — חסום בפועל, ואין טעם לומר לו
    // שההיתר קיים.
    if (_isBlockingRule(block)) return _RuleVerdict.blocked;
    verdict = _RuleVerdict.allowed;
  }
  return verdict;
}

/// חוקי netsh, מופרדים בשורות ריקות. הפרדה לפי שורה ריקה ולא לפי
/// `Rule Name:` — התווית מתורגמת, שורה ריקה לא.
Iterable<String> _ruleBlocks(String text) {
  final blocks = <String>[];
  final current = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) {
      if (current.isNotEmpty) {
        blocks.add(current.join('\n'));
        current.clear();
      }
      continue;
    }
    current.add(line);
  }
  if (current.isNotEmpty) blocks.add(current.join('\n'));
  return blocks;
}

final _actionLine = RegExp(r'^\s*action\s*:\s*(\S+)', multiLine: true);

bool _isBlockingRule(String block) {
  final match = _actionLine.firstMatch(block.toLowerCase());
  if (match == null) return false; // לא ידוע — ראו [_hasAllowingRuleFor]
  return match.group(1) == 'block';
}

/// חיפוש שברי האסקי של [target] לפי הסדר, בתוך שורה אחת של הפלט.
///
/// שורת `Program:` של החוק הנכון מכילה את כל שברי האסקי של הנתיב לפי
/// סדרם. חוק שנקשר לנתיב אחר — התקנה ישנה, תיקיית הורדות — יחסר את
/// השברים שאחרי שם המשתמש, ולכן לא ייתפס כאן בטעות.
bool _mentionsAsciiAnchors(String text, String target) {
  final fragments = target.split(_nonAscii).where((f) => f.isNotEmpty).toList();
  // שבר אחד פירושו נתיב אסקי לגמרי — שם ההשוואה הישירה כבר הכריעה,
  // וחיפוש חלקי כאן רק היה מקל יתר על המידה.
  if (fragments.length < 2) return false;

  for (final line in const LineSplitter().convert(text)) {
    final lower = line.toLowerCase();
    var from = 0;
    var matched = true;
    for (final fragment in fragments) {
      final at = lower.indexOf(fragment, from);
      if (at < 0) {
        matched = false;
        break;
      }
      from = at + fragment.length;
    }
    if (matched) return true;
  }
  return false;
}
