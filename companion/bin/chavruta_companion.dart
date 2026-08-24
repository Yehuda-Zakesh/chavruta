import 'dart:async';
import 'dart:io';

import 'package:chavruta_companion/config.dart';
import 'package:chavruta_companion/console_window.dart';
import 'package:chavruta_companion/firewall_check.dart';
import 'package:chavruta_companion/lan_transport.dart';
import 'package:chavruta_companion/local_api.dart';
import 'package:chavruta_companion/protocol.dart';
import 'package:chavruta_companion/sync_hub.dart';
import 'package:chavruta_companion/version.dart';

/// גודל מקסימלי לקובץ הלוג. מעליו הוא נמחק ומתחיל מחדש — המתאם רץ
/// חודשים ברקע, וקובץ לוג שגדל בלי גבול הוא באג ולא כלי אבחון.
const int maxLogBytes = 256 * 1024;

const String usage = '''
מתאם חברותא $companionVersion — גשר סנכרון מקומי בין מופעי אוצריא.

שימוש:
  chavruta_companion [אפשרויות]

אפשרויות:
  --room <קוד>     קוד חברותא. ריק (--room "") = יציאה מהחברותא.
  --name <שם>      שם המכשיר כפי שיוצג לחברותא.
  --data-dir <נתיב> תיקיית קונפיג ולוג. ברירת מחדל: %LOCALAPPDATA%\\Chavruta
  --quiet          בלי הדפסה למסך (הלוג עדיין נכתב לקובץ).
  --console        השארת חלון הקונסולה גלוי, לצפייה חיה בלוג בפיתוח.
  --hidden         נשאר לתאימות לאחור; שקול ל-`--quiet`. חלון הקונסולה
                   מוסתר כברירת מחדל כך או כך.
  --version        הדפסת גרסה ויציאה.
  --help           הדפסת עזרה זו.

בלי --room המתאם עולה עם הקוד השמור, ואם אין — ממתין שהתוסף יזווג אותו
דרך ה-API המקומי. אין צורך להריץ אותו מחדש כדי לשנות קוד.
''';

/// ארגומנטים מפוענחים. `null` בשדה = המשתמש לא ציין אותו, ולכן הערך
/// השמור בקונפיג נשאר כמו שהוא.
class _Args {
  String? room;
  String? name;
  String? dataDir;
  bool quiet = false;
  bool console = false;
}

/// כתיבה ל-stdout/stderr שלא מתפוצצת אם הקונסולה כבר הוסתרה (או שלא
/// הייתה כזו מעולם). מוגן ליתר ביטחון — בפועל תמיד יש כאן קונסולה
/// אמיתית, רק מוסתרת, כך שהכתיבה מצליחה; זה נועד למקרה שהיא נחסמה
/// בדרך אחרת (כלי אבטחה, למשל).
void _safePrint(IOSink sink, String text) {
  try {
    sink.write(text);
  } catch (_) {}
}

/// מפענח את שורת הפקודה. מחזיר `null` אם צריך לצאת (עזרה/גרסה/שגיאה),
/// לאחר שהדפיס את מה שצריך.
_Args? _parseArgs(List<String> argv) {
  final args = _Args();
  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    String? next() {
      if (i + 1 >= argv.length) {
        _safePrint(stderr, 'חסר ערך אחרי $arg\n');
        return null;
      }
      return argv[++i];
    }

    switch (arg) {
      case '--help':
      case '-h':
        _safePrint(stdout, usage);
        return null;
      case '--version':
      case '-v':
        _safePrint(stdout, '$companionVersion\n');
        return null;
      case '--quiet':
      case '-q':
        args.quiet = true;
      case '--console':
        args.console = true;
      case '--hidden':
        // לתאימות לאחור עם קיצורי דרך/רישום Run ישנים שמעבירים את הדגל
        // הזה במפורש. ההסתרה עצמה כברירת מחדל, לא תלויה בו.
        args.quiet = true;
      case '--room':
        final value = next();
        if (value == null) return null;
        args.room = value;
      case '--name':
        final value = next();
        if (value == null) return null;
        args.name = value;
      case '--data-dir':
        final value = next();
        if (value == null) return null;
        args.dataDir = value;
      default:
        _safePrint(stderr, 'אפשרות לא מוכרת: $arg\n');
        _safePrint(stderr, usage);
        return null;
    }
  }
  return args;
}

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);
  if (args == null) return;
  // בהרצה הרגילה (דרך ChavrutaLauncher.exe) אין כאן חלון מלכתחילה, ולכן
  // זו הרצה ישירה של ה-exe — לחיצה כפולה או קיצור דרך ישן — ואז מנסים
  // להסתיר. ההסתרה אינה מובטחת; ראו את התיעוד ב-console_window.dart.
  // --console הוא היציאה המפורשת למי שרוצה לצפות בלוג בזמן פיתוח.
  if (!args.console) hideConsoleWindow();

  final storageDir = args.dataDir == null
      ? CompanionConfig.defaultStorageDir
      : Directory(args.dataDir!);

  final log = await _Logger.open(storageDir, toStdout: !args.quiet);
  log('מתאם חברותא $companionVersion מתחיל');

  final config = await CompanionConfig.load(storageDir: storageDir);
  if (args.name != null) {
    final trimmed = args.name!.trim();
    if (trimmed.isNotEmpty) config.deviceName = trimmed;
  }
  if (args.room != null) {
    config.roomCode = args.room!.trim().isEmpty
        ? null
        : CompanionConfig.normalizeRoomCode(args.room!);
  }
  if (args.name != null || args.room != null) await config.save();

  final transport = LanTransport(
    roomCodeProvider: () => config.roomCode,
    onLog: log,
  );
  final hub = SyncHub(config: config, transport: transport, onLog: log);
  final api = LocalApi(hub: hub, version: companionVersion, onLog: log);

  // ה-API המקומי הוא הדבר היחיד שבלעדיו המתאם חסר תועלת: בלי ערוץ אל
  // התוסף אין מה לסנכרן. כל הפורטים בטווח תפוסים = כמעט תמיד מתאם אחר
  // שכבר רץ, ולכן זו יציאה שקטה ולא קריסה.
  if (!await api.start()) {
    log(
      'לא נמצא פורט פנוי בטווח $localApiFirstPort-$localApiLastPort — '
      'כנראה שמתאם חברותא אחר כבר רץ. יוצא.',
    );
    await hub.dispose();
    await log.close();
    exit(1);
  }

  await hub.start();
  log(
    config.isPaired
        ? 'מחובר לחברותא בשם "${config.deviceName}"'
        : 'לא מזווג — ממתין לקוד חברותא מהתוסף',
  );

  // בדיקת חומת האש היא הרצת netsh, ולכן היא רצה ברקע ואינה מעכבת את
  // העלייה. התוצאה נשלפת מאוחר יותר דרך /hello, כשהתוסף מציג למה
  // ייתכן שאין חברותא ברשימה.
  unawaited(
    hasInboundFirewallRule().then((allowed) {
      hub.firewallRule = allowed;
      if (allowed == false) {
        log(
          'לא נמצא חוק חומת אש נכנס עבור ${Platform.resolvedExecutable} — '
          'ייתכן ש-Windows חוסם את ההודעות מהחברותא',
        );
      }
    }),
  );

  final done = Completer<void>();
  // דגל ולא `done.isCompleted`: הסגירה היא אסינכרונית, ו-`done` מסומן רק
  // בסופה. שני Ctrl+C צמודים היו שניהם עוברים את הבדיקה, סוגרים פעמיים
  // ומשדרים שתי הודעות פרידה.
  var closing = false;
  Future<void> shutdown(String reason) async {
    if (closing) return;
    closing = true;
    log('נסגר ($reason)');
    await api.dispose();
    await hub.dispose();
    await log.close();
    done.complete();
  }

  final signals = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) => shutdown('Ctrl+C')),
  ];
  if (!Platform.isWindows) {
    // sigterm אינו נתמך ב-Windows; האזנה אליו שם זורקת.
    signals.add(ProcessSignal.sigterm.watch().listen((_) => shutdown('sigterm')));
  }

  await done.future;
  for (final signal in signals) {
    await signal.cancel();
  }
  exit(0);
}

/// לוג לקובץ ולמסך. הקובץ הוא הדבר שמאפשר לאבחן מתאם שרץ ברקע בלי
/// חלון קונסולה, ולכן הכתיבה אליו לא תלויה בדגל `--quiet`.
class _Logger {
  _Logger._(this._file, this._toStdout);

  final IOSink? _file;
  final bool _toStdout;

  static Future<_Logger> open(Directory dir, {required bool toStdout}) async {
    IOSink? sink;
    try {
      await dir.create(recursive: true);
      final path = '${dir.path}${Platform.pathSeparator}companion.log';
      final file = File(path);
      if (await file.exists() && await file.length() > maxLogBytes) {
        await file.delete();
      }
      sink = file.openWrite(mode: FileMode.append);
    } catch (_) {
      // דיסק מלא או תיקייה חסומה — עדיף מתאם שרץ בלי לוג מלא מתאם שנפל.
      sink = null;
    }
    return _Logger._(sink, toStdout);
  }

  void call(String message) {
    final line = '[${DateTime.now().toIso8601String()}] $message';
    if (_toStdout) {
      try {
        stdout.writeln(line);
      } catch (_) {
        // ליתר ביטחון: אם מסיבה כלשהי אין stdout תקין. הלוג לקובץ
        // ממשיך כרגיל.
      }
    }
    try {
      _file?.writeln(line);
    } catch (_) {
      // כתיבה לקובץ נכשלה באמצע הריצה — אין מה לעשות עם זה.
    }
  }

  Future<void> close() async {
    try {
      await _file?.flush();
      await _file?.close();
    } catch (_) {
      // כבר סגור.
    }
  }
}
