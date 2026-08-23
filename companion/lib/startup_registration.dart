import 'dart:io';

/// המפתח שבו Windows שומר תוכנות שעולות עם המשתמש.
///
/// HKCU ולא HKLM: הרישום הוא למשתמש הנוכחי, ולכן אינו דורש הרשאות מנהל —
/// בדיוק כמו ההתקנה עצמה.
const String startupRunKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

/// שם הערך. זהה לזה שהמתקין כותב, בכוונה: שני מקומות שכותבים את אותה
/// כוונה לשני שמות שונים היו נותנים שתי עליות אוטומטיות במקום אחת.
const String startupValueName = 'ChavrutaCompanion';

const String companionExeName = 'ChavrutaCompanion.exe';
const String launcherExeName = 'ChavrutaLauncher.exe';

/// מריץ את `reg.exe` ומחזיר את התוצאה. מוחלף בבדיקות.
typedef RegRunner = Future<ProcessResult> Function(List<String> arguments);

/// מצב "עלייה עם המחשב", כפי שהתוסף מציג אותו.
///
/// [supported] הוא `false` כשאין מה להציע למשתמש — לא Windows, או שאנחנו
/// רצים מתוך `dart run` ולא מ-exe מותקן. במקרה כזה [reason] מסביר למה,
/// והתוסף מסתיר את המתג במקום להציג מתג שבירה.
class StartupState {
  const StartupState({
    required this.supported,
    required this.enabled,
    this.reason,
    this.command,
  });

  final bool supported;
  final bool enabled;
  final String? reason;

  /// שורת הפקודה שרשומה (או שתירשם) — לאבחון, לא לתצוגה.
  final String? command;

  Map<String, Object?> toJson() => {
    'supported': supported,
    'enabled': enabled,
    if (reason != null) 'reason': reason,
    if (command != null) 'command': command,
  };
}

/// קורא ומשנה את רישום העלייה עם המחשב.
///
/// למה `reg.exe` ולא FFI ל-advapi32: הקריאות היחידות שצריך הן קיום, כתיבה
/// ומחיקה של ערך אחד, ו-`reg.exe` נותן את שלושתן בלי להוסיף תלות
/// (`package:ffi`) ובלי לנהל מצביעים ומחרוזות UTF-16 בשביל שדה בודד.
/// הזיהוי נעשה לפי קוד היציאה ולא לפי הפלט, ולכן אינו תלוי בשפת המערכת.
///
/// אין כאן חלון: התהליך שנפתח יורש את הקונסולה של המתאם, שממילא חסרת
/// חלון כשהמתאם הופעל דרך המשגר.
class StartupRegistration {
  StartupRegistration({
    RegRunner? runReg,
    String? executable,
    bool? isWindows,
  }) : _runReg = runReg ?? _defaultRunner,
       _executable = executable ?? Platform.resolvedExecutable,
       _isWindows = isWindows ?? Platform.isWindows;

  final RegRunner _runReg;
  final String _executable;
  final bool _isWindows;

  static Future<ProcessResult> _defaultRunner(List<String> arguments) =>
      Process.run('reg.exe', arguments, runInShell: false);

  /// המצב עכשיו. קורא את הרישום בכל פעם ולא שומר במטמון: המתקין עשוי
  /// לשנות את אותו ערך תחת המתאם הרץ, ומצב שקרי במתג גרוע ממאמץ קטן.
  Future<StartupState> read() async {
    final blocked = await _blockedReason();
    if (blocked != null) {
      return StartupState(supported: false, enabled: false, reason: blocked);
    }

    try {
      final result = await _runReg([
        'query',
        startupRunKey,
        '/v',
        startupValueName,
      ]);
      // קוד יציאה 1 = הערך אינו קיים, כלומר אינו עולה עם המחשב. זו אינה
      // שגיאה, ולכן אין כאן הבדל בין 1 לכל קוד אחר שאינו 0.
      return StartupState(
        supported: true,
        enabled: result.exitCode == 0,
        command: await _startupCommand(),
      );
    } catch (e) {
      return StartupState(
        supported: false,
        enabled: false,
        reason: 'reg.exe לא נגיש: $e',
      );
    }
  }

  /// מדליק או מכבה, ומחזיר את המצב **כפי שנקרא מחדש** אחרי השינוי — כך
  /// כשלון שקט (הרשאות, מדיניות ארגונית) מדווח כמו שהוא ולא כהצלחה.
  Future<StartupState> setEnabled(bool value) async {
    final blocked = await _blockedReason();
    if (blocked != null) {
      return StartupState(supported: false, enabled: false, reason: blocked);
    }

    try {
      if (value) {
        await _runReg([
          'add',
          startupRunKey,
          '/v',
          startupValueName,
          '/t',
          'REG_SZ',
          '/d',
          await _startupCommand(),
          '/f',
        ]);
      } else {
        // /f כדי שלא יישאל, וקוד יציאה 1 (הערך לא היה קיים) הוא בדיוק
        // המצב המבוקש ולכן אינו כשלון.
        await _runReg(['delete', startupRunKey, '/v', startupValueName, '/f']);
      }
    } catch (e) {
      return StartupState(
        supported: false,
        enabled: false,
        reason: 'reg.exe נכשל: $e',
      );
    }

    final state = await read();
    if (state.supported && state.enabled != value) {
      return StartupState(
        supported: true,
        enabled: state.enabled,
        command: state.command,
        reason: 'Windows לא קיבל את השינוי',
      );
    }
    return state;
  }

  /// `null` = אפשר לגעת ברישום. אחרת הסבר למה לא.
  Future<String?> _blockedReason() async {
    if (!_isWindows) return 'רישום עלייה עם המחשב קיים ב-Windows בלבד';
    if (_baseName(_executable).toLowerCase() !=
        companionExeName.toLowerCase()) {
      // `dart run` — resolvedExecutable הוא ה-VM של Dart. רישום שלו לעלייה
      // עם המחשב הוא באג ולא תכונה.
      return 'המתאם רץ מתוך פיתוח ולא מ-exe מותקן';
    }
    return null;
  }

  /// מה נרשם בפועל. המשגר מועדף — הוא הדבר שמונע את חלון הקונסולה. אם
  /// אינו לצד ה-exe (התקנה שקדמה לו), נרשם המתאם עצמו עם `--hidden`,
  /// שינסה להסתיר את החלון בעצמו.
  Future<String> _startupCommand() async {
    final launcher = '${_dirName(_executable)}$launcherExeName';
    if (await File(launcher).exists()) return '"$launcher" --quiet';
    return '"$_executable" --hidden';
  }
}

String _baseName(String path) {
  final index = path.lastIndexOf(RegExp(r'[\\/]'));
  return index < 0 ? path : path.substring(index + 1);
}

/// התיקייה של [path], כולל המפריד בסוף.
String _dirName(String path) {
  final index = path.lastIndexOf(RegExp(r'[\\/]'));
  return index < 0 ? '' : path.substring(0, index + 1);
}
