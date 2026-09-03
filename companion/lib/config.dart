import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// מה קורה כאן כשהחברותא סוגרת ספר.
///
/// סגירה אינה סימטרית לפתיחה: ספר שנפתח אצל החברותא אפשר תמיד לפתוח גם
/// כאן, אבל ספר שהיא סגרה יכול להיות בדיוק זה שאני באמצע. לכן ברירת
/// המחדל היא **לשאול**, ולא לסגור.
enum ClosePolicy {
  /// שואלים בכל פעם: "החברותא סגרה את X — לסגור גם כאן?".
  ask,

  /// סוגרים מיד, בלי לשאול. שני השולחנות זהים תמיד.
  always,

  /// לא סוגרים כלום. הפתיחה מסתנכרנת, הסגירה לא.
  never;

  String get wire => name;

  static ClosePolicy fromWire(Object? value) => switch (value) {
    'always' => ClosePolicy.always,
    'never' => ClosePolicy.never,
    _ => ClosePolicy.ask,
  };
}

/// קונפיגורציה מתמשכת של המתאם.
///
/// נשמרת ב-`%LOCALAPPDATA%\Chavruta\config.json`: זהות המכשיר (נוצרת פעם
/// אחת), שם תצוגה, קוד החברותא שהמשתמש הקליד, והעדפות הסנכרון.
class CompanionConfig {
  CompanionConfig({
    required this.deviceId,
    required this.deviceName,
    this.roomCode,
    this.syncLocation = true,
    this.closePolicy = ClosePolicy.ask,
    Directory? storageDir,
  }) : storageDir = storageDir ?? defaultStorageDir;

  /// מזהה יציב של המכשיר. משמש לזיהוי הד (הודעה שחזרה מאיתנו).
  final String deviceId;

  /// שם לתצוגה ברשימת המחוברים אצל החברותא.
  String deviceName;

  /// קוד החברותא. `null` = לא מזווג, ואז לא משדרים ולא מקבלים כלום.
  String? roomCode;

  /// האם לסנכרן גם את **מקום הלימוד** בתוך הספר, ולא רק את השולחן.
  ///
  /// דלוק כברירת מחדל — זה מה שהחברותא הייתה מאז ומעולם. אפשר לכבות
  /// כששניים לומדים את אותם ספרים בקצב שונה.
  ///
  /// ההגדרה יושבת במתאם ולא בזיכרון התוסף, כי **שני מופעי התוסף**
  /// (לשונית ורקע) צריכים לראות אותה, והמתאם הוא הנקודה היחידה ששניהם
  /// רואים — בדיוק כמו ההכרעה מי מריץ את המנוע.
  bool syncLocation;

  /// מה לעשות כשהחברותא סוגרת ספר. ראו [ClosePolicy].
  ClosePolicy closePolicy;

  /// התיקייה שבה יושב הקונפיג. פרמטר ולא קבוע גלובלי, כדי שבדיקות
  /// יוכלו לרוץ בתיקייה זמנית ולא לדרוך על הקונפיג של המשתמש.
  final Directory storageDir;

  bool get isPaired => (roomCode ?? '').isNotEmpty;

  File get file => File('${storageDir.path}${Platform.pathSeparator}config.json');

  static Directory get defaultStorageDir {
    final base =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory('$base${Platform.pathSeparator}Chavruta');
  }

  /// תווי בקרה בלתי נראים: סימני כיווניות (RTL/LTR), רוחב-אפס, ומקף רך.
  ///
  /// **זה המסלול שהפיל קודים בעברית בשטח.** יישומי RTL — וואטסאפ, Word —
  /// עוטפים טקסט עברי ב-`U+200F` בלי שהוא נראה על המסך, ומשתמש שמדביק
  /// את הקוד מקבל גיבוב חדר אחר לגמרי. וזה כשל שאין לו שום אבחון:
  /// הדחייה קורית ב-`SyncMessage.decode` **לפני** חישוב ה-HMAC, ולכן גם
  /// דיווח פער השעונים אינו נקרא ואף מונה אבחון אינו זז — שני מסכים
  /// שמציגים קוד זהה לחלוטין, ו"ממתין לחברותא" לנצח.
  ///
  /// כל התווים כאן כתובים ב-escape ולא כתווים עצמם, בכוונה: תו כיווניות
  /// במקור אינו נראה בעין, והוא גם **מהפך את סדר התצוגה של השורה** —
  /// כלומר קוד שאי אפשר לבקר.
  static final RegExp _invisible = RegExp(
    '[\u00ad\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]',
  );

  /// ניקוד, דגשים וטעמי המקרא — נמחקים, כדי ש-`דַף יומי` ו-`דף יומי`
  /// יהיו אותו חדר.
  ///
  /// הטווח מדלג בכוונה על תווים **נראים** שבתוכו: מקף עברי (`U+05BE`),
  /// פסק (`U+05C0`), סוף פסוק (`U+05C3`) ונון הפוכה (`U+05C6`). אלה
  /// חלק מהקוד ככל תו אחר.
  static final RegExp _hebrewMarks = RegExp(
    '[\u0591-\u05bd\u05bf\u05c1\u05c2\u05c4\u05c5\u05c7]',
  );

  /// גרש וגרשיים עבריים, ומרכאות מסולסלות, אל המקבילות הלטיניות.
  /// `רש״י` ו-`רש"י` נראים זהים על המסך וחייבים להגיע לאותו חדר.
  static const Map<String, String> _quotes = {
    '\u05f3': "'",
    '\u05f4': '"',
    '\u2018': "'",
    '\u2019': "'",
    '\u201c': '"',
    '\u201d': '"',
  };

  /// צורות תצוגה עבריות (Alphabetic Presentation Forms) אל האות
  /// הבסיסית. `\u05e9\u05c1` כשתי נקודות קוד ו-`\ufb2a` כאחת הן אותה
  /// מלה בדיוק על המסך, ובלי המיפוי הזה הן שני חדרים.
  static const Map<String, String> _presentationForms = {
    '\ufb1d': '\u05d9', '\ufb1f': '\u05d9\u05d9',
    '\ufb20': '\u05e2', '\ufb21': '\u05d0',
    '\ufb22': '\u05d3', '\ufb23': '\u05d4',
    '\ufb24': '\u05db', '\ufb25': '\u05dc',
    '\ufb26': '\u05dd', '\ufb27': '\u05e8',
    '\ufb28': '\u05ea', '\ufb29': '+',
    '\ufb2a': '\u05e9', '\ufb2b': '\u05e9',
    '\ufb2c': '\u05e9', '\ufb2d': '\u05e9',
    '\ufb2e': '\u05d0', '\ufb2f': '\u05d0',
    '\ufb30': '\u05d0', '\ufb31': '\u05d1',
    '\ufb32': '\u05d2', '\ufb33': '\u05d3',
    '\ufb34': '\u05d4', '\ufb35': '\u05d5',
    '\ufb36': '\u05d6', '\ufb38': '\u05d8',
    '\ufb39': '\u05d9', '\ufb3a': '\u05da',
    '\ufb3b': '\u05db', '\ufb3c': '\u05dc',
    '\ufb3e': '\u05de', '\ufb40': '\u05e0',
    '\ufb41': '\u05e1', '\ufb43': '\u05e3',
    '\ufb44': '\u05e4', '\ufb46': '\u05e6',
    '\ufb47': '\u05e7', '\ufb48': '\u05e8',
    '\ufb49': '\u05e9', '\ufb4a': '\u05ea',
    '\ufb4b': '\u05d5', '\ufb4c': '\u05d1',
    '\ufb4d': '\u05db', '\ufb4e': '\u05e4',
    '\ufb4f': '\u05d0\u05dc',
  };

  /// מנרמל קוד חברותא כך ששני המשתמשים יגיעו לאותו חדר גם אם הקלידו
  /// אותו בצורה שונה במקצת.
  ///
  /// מה שמנורמל: רווחים מקצה, רווחים כפולים באמצע (כולל רווחי יוניקוד
  /// כמו NBSP), רישיות לטינית, תווי כיווניות בלתי נראים ([_invisible]),
  /// ניקוד ([_hebrewMarks]), גרש וגרשיים ([_quotes]) וצורות תצוגה
  /// ([_presentationForms]). עברית אינה רגישה לרישיות, ואין כאן קיפול
  /// של אותיות סופיות — `מן` ו-`מ ן` אינם אותה מלה.
  ///
  /// **תאימות — שווה לדעת:** [load] מנרמל מחדש את הקוד השמור, ולכן
  /// שדרוג משנה את גיבוב החדר של קוד שכולל אחד מהתווים האלה. לרוב
  /// המכריע של הקודים (עברית מוקלדת, בלי ניקוד ובלי הדבקה) הנרמול
  /// זהה לקודם ולא משתנה דבר; אבל קוד עם ניקוד, שעד עכשיו עבד רק אם
  /// **שני** הצדדים הקלידו בדיוק אותו ניקוד, יעבור חדר — ולכן צריך
  /// לשדרג את שני המחשבים יחד, כמו בכל שדרוג רגיל.
  ///
  /// בכיוון החיובי: קוד שהודבק מוואטסאפ פשוט יתחיל לעבוד.
  static String normalizeRoomCode(String raw) {
    var code = raw.replaceAll(_invisible, '');
    _presentationForms.forEach((from, to) => code = code.replaceAll(from, to));
    code = code.replaceAll(_hebrewMarks, '');
    _quotes.forEach((from, to) => code = code.replaceAll(from, to));
    return code.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  static String _newDeviceId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(8, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<CompanionConfig> load({Directory? storageDir}) async {
    final dir = storageDir ?? defaultStorageDir;
    final file = File('${dir.path}${Platform.pathSeparator}config.json');
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map) {
          final id = json['deviceId'];
          if (id is String && id.isNotEmpty) {
            final rawRoom = json['roomCode'];
            return CompanionConfig(
              deviceId: id,
              deviceName: json['deviceName'] is String &&
                      (json['deviceName'] as String).trim().isNotEmpty
                  ? json['deviceName'] as String
                  : Platform.localHostname,
              roomCode: rawRoom is String && rawRoom.trim().isNotEmpty
                  ? normalizeRoomCode(rawRoom)
                  : null,
              syncLocation: json['syncLocation'] != false,
              closePolicy: ClosePolicy.fromWire(json['closePolicy']),
              storageDir: dir,
            );
          }
        }
      } catch (_) {
        // קונפיג פגום — נבנה חדש במקום להיכשל בעלייה.
      }
    }
    final fresh = CompanionConfig(
      deviceId: _newDeviceId(),
      deviceName: Platform.localHostname,
      storageDir: dir,
    );
    await fresh.save();
    return fresh;
  }

  /// השמירה שרצה עכשיו, אם יש. ראו [save].
  Future<void> _saving = Future<void>.value();

  /// שומר את הקונפיג לדיסק.
  ///
  /// **כתיבה אטומית, ולא ישירות אל `config.json`.** קובץ הקונפיג הוא
  /// היחיד שזוכר את קוד החברותא ואת [deviceId], ו-[load] בונה קונפיג
  /// חדש לגמרי כשהוא אינו נקרא — כלומר הפסקה באמצע כתיבה (נפילת חשמל,
  /// כיבוי, שני handlers שכתבו יחד) אינה "עדכון שאבד" אלא **חדר שנעלם
  /// ומזהה מכשיר חדש**, ובשטח זה נראה בדיוק כמו קישור בלוטות' שהתנתק.
  /// לכן כותבים לקובץ זמני באותה תיקייה ומחליפים בשם — פעולה שמערכת
  /// הקבצים מבצעת כולה או לא מבצעת כלל.
  ///
  /// **וגם: שמירה אחת בכל רגע.** יש כאן `await`, ובלעדי התור שתי בקשות
  /// שהגיעו יחד (שינוי חדר ושינוי שם) היו מחליפות את אותו שם בו-זמנית.
  /// התוכן זהה בשתיהן — כל השדות יושבים באובייקט הזה — ולכן אין כאן
  /// עדכון שנדרס, אך יש כאן שתי פעולות החלפה שמתרוצצות על קובץ אחד.
  Future<void> save() {
    final next = _saving.then((_) => _writeAtomically());
    // התור ממשיך גם אחרי כישלון, אבל **הקורא רואה אותו**: שמירה שנכשלה
    // אינה חוסמת את הבאה בתור, ואינה מדווחת כהצלחה למי שביקש אותה.
    _saving = next.catchError((_) {});
    return next;
  }

  Future<void> _writeAtomically() async {
    await storageDir.create(recursive: true);
    final text = const JsonEncoder.withIndent('  ').convert({
      'deviceId': deviceId,
      'deviceName': deviceName,
      if (isPaired) 'roomCode': roomCode,
      if (!syncLocation) 'syncLocation': false,
      if (closePolicy != ClosePolicy.ask) 'closePolicy': closePolicy.wire,
    });

    final temp = File('${file.path}.tmp');
    await temp.writeAsString(text, flush: true);
    try {
      await temp.rename(file.path);
    } on FileSystemException {
      // ב-Windows החלפה בשם נכשלת כשמישהו אחר מחזיק את היעד פתוח
      // (סורק וירוסים, גיבוי). הקובץ הזמני כבר על הדיסק ושלם, ולכן
      // הנפילה חזרה לכתיבה ישירה מפסידה רק את האטומיות — ולא את הערך.
      await file.writeAsString(text, flush: true);
      try {
        await temp.delete();
      } catch (_) {
        // שארית לא מזיקה; הכתיבה הבאה תדרוס אותה ממילא.
      }
    }
  }
}
