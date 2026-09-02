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

  /// מנרמל קוד חברותא כך ששני המשתמשים יגיעו לאותו קוד גם אם הקלידו
  /// אותו בצורה שונה במקצת: רווחים מקצה, רווחים כפולים באמצע, ואותיות
  /// לטיניות גדולות/קטנות. עברית אינה רגישה לרישיות ולכן אינה נוגעת.
  static String normalizeRoomCode(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

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

  Future<void> save() async {
    await storageDir.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'deviceId': deviceId,
        'deviceName': deviceName,
        if (isPaired) 'roomCode': roomCode,
        if (!syncLocation) 'syncLocation': false,
        if (closePolicy != ClosePolicy.ask) 'closePolicy': closePolicy.wire,
      }),
    );
  }
}
