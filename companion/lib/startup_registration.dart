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
      if (result.exitCode != 0) {
        return StartupState(
          supported: true,
          enabled: false,
          command: await _startupCommand(),
        );
      }

      // קיום הערך אינו מספיק: השאלה היא אם **המתאם הזה** עולה עם המחשב.
      // התקנה קודמת במיקום אחר משאירה ערך באותו שם שמצביע לקובץ שכבר
      // אינו קיים, ואז המתג היה מראה "דלוק" בזמן ששום דבר אינו עולה.
      final registered = _registeredCommand('${result.stdout}');
      if (registered != null && !_pointsToThisInstall(registered)) {
        return StartupState(
          supported: true,
          enabled: false,
          command: registered,
          reason: 'רשומה לעלייה תוכנית אחרת בשם הזה',
        );
      }
      return StartupState(
        supported: true,
        enabled: true,
        command: registered ?? await _startupCommand(),
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
        final wanted = await _startupCommand();
        final result = await _runReg([
          'add',
          startupRunKey,
          '/v',
          startupValueName,
          '/t',
          'REG_SZ',
          '/d',
          wanted,
          '/f',
        ]);
        // **כתיבה שנכשלה אינה נמדדת לפי מה שיש ברישום.** רשומה בשם הזה
        // מהתקנה קודמת נשארת שם, ו-[read] רואה אותה ואומר "עולה עם
        // המחשב" — כלומר המשתמש מקבל אישור על פעולה שלא קרתה, ואחרי
        // הפעלה מחדש עולה (במקרה הטוב) המתאם הישן. קוד היציאה הוא
        // הראיה היחידה כאן, והוא אינו תלוי בשפת המערכת.
        if (result.exitCode != 0) {
          return await _addFailed(wanted, result.exitCode);
        }
      } else {
        // /f כדי שלא יישאל, וקוד יציאה 1 (הערך לא היה קיים) הוא בדיוק
        // המצב המבוקש ולכן אינו כשלון. מחיקה שנכשלה באמת נתפסת למטה,
        // בהשוואת המצב שנקרא מחדש למצב שהתבקש.
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
        // סיבה מפורשת שהקריאה מצאה עדיפה על הכללית: היא אומרת *מה* קרה
        // ולא רק שמשהו לא נתפס.
        reason: state.reason ?? 'Windows לא קיבל את השינוי',
      );
    }
    return state;
  }

  /// המצב אחרי `reg add` שנכשל.
  ///
  /// יש מקרה אחד שבו כישלון אינו כישלון: הערך שרצינו לכתוב כבר רשום
  /// בדיוק ככה (המתקין כתב אותו), ולכן אין מה לתקן. בכל שאר המקרים
  /// התשובה היא כבוי עם סיבה, גם אם ברישום יושבת רשומה אחרת בשם הזה.
  Future<StartupState> _addFailed(String wanted, int exitCode) async {
    final state = await read();
    if (state.enabled && state.command == wanted) return state;
    return StartupState(
      supported: true,
      enabled: false,
      command: state.command,
      reason: 'Windows לא קיבל את הרישום (reg.exe החזיר $exitCode)',
    );
  }

  /// שולף את נתוני הערך מפלט `reg query`, או `null` אם לא נמצא.
  ///
  /// הפלט של `reg.exe` הוא `<שם>    <טיפוס>    <נתונים>` בשורה אחת.
  /// שם הטיפוס (`REG_SZ`) אינו מתורגם בשום שפת מערכת, ולכן הוא העוגן —
  /// וכך הפענוח נשאר נכון גם בחלונות בעברית.
  static String? _registeredCommand(String output) {
    for (final line in output.split('\n')) {
      const type = 'REG_SZ';
      final index = line.indexOf(type);
      if (index < 0) continue;
      if (!line.substring(0, index).contains(startupValueName)) continue;
      final data = line.substring(index + type.length).trim();
      return data.isEmpty ? null : data;
    }
    return null;
  }

  /// האם שורת הפקודה הרשומה מפעילה את ההתקנה הזאת.
  ///
  /// **הפלט של `reg.exe` מגיע בקידוד הקונסולה**, ותווים שאינם ASCII
  /// חוזרים ממנו משובשים ובלתי ניתנים לשחזור: בחלונות בעברית הנתיב
  /// `C:\Users\זאב לונטל\...` נקרא `C:\Users\†€ …ˆ\...`. לכן השוואת
  /// הנתיב היא **ראיה חיובית בלבד** — כשהיא מתאימה זו בוודאות ההתקנה
  /// שלנו, וכשלא, אי אפשר להסיק ממנה דבר.
  ///
  /// ההכרעה במקרה כזה נופלת על שם הקובץ, שהוא תמיד ASCII ולכן תמיד
  /// קריא. כך "רשומה תוכנית אחרת" נאמר רק כשבאמת רשום משהו שאינו שלנו,
  /// ולא על כל מי ששם המשתמש שלו אינו באנגלית — שהוא, בקהל של התוכנה
  /// הזאת, רוב המשתמשים. המחיר: התקנה ישנה שלנו במיקום אחר אינה מזוהה
  /// עוד ככזאת, וזה עדיף בהרבה על מתג שנופל אצל מי שהכול תקין אצלו.
  bool _pointsToThisInstall(String command) {
    final lower = command.toLowerCase();
    if (lower.contains(_dirName(_executable).toLowerCase())) return true;
    return lower.contains(companionExeName.toLowerCase()) ||
        lower.contains(launcherExeName.toLowerCase());
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
