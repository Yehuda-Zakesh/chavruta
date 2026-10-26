import 'dart:async';
import 'dart:io';

import 'package:chavruta_companion/config.dart';
import 'package:chavruta_companion/lan_transport.dart';
import 'package:chavruta_companion/local_api.dart';
import 'package:chavruta_companion/protocol.dart';
import 'package:chavruta_companion/sync_hub.dart';
import 'package:chavruta_companion/version.dart';
import 'package:flutter/foundation.dart';

import 'native.dart';

/// גודל מקסימלי לקובץ הלוג, כמו במתאם של המחשב.
const int maxLogBytes = 256 * 1024;

/// כמה שורות יומן נשמרות בזיכרון לתצוגה במסך.
const int maxLogLines = 400;

/// כמה זמן בלי שאוצריא מסנכרנת דרך המתאם עד שהוא נכנס למצב שינה.
///
/// הסימן לכך שאוצריא כאן הוא מחזיק מנוע הסנכרון (`SyncHub.engineOwner`):
/// התוסף מחדש אותו בכל פנייה, וההחזקה פגה אחרי 45 שניות בלעדיהן.
const Duration dormantAfter = Duration(minutes: 3);

const Duration _idleCheckInterval = Duration(seconds: 15);

/// כל כמה זמן מנסים שוב לתפוס פורט כשכל הטווח תפוס — אפילו לפעמון.
const Duration portRetryInterval = Duration(seconds: 30);

enum CompanionState {
  /// כבוי — המשתמש עצר אותו.
  stopped,

  /// המתאם המלא רץ: משדר, קולט ועונה לתוסף. רק כשיש API ו-hub חיים.
  active,

  /// אוצריא אינה פונה אליו. אין שידור, אין קליטה ואין טיימרים — רק
  /// "פעמון" על פורט ב-loopback, שמעיר את המתאם כשהתוסף מחפש אותו.
  /// כשכל הטווח תפוס, גם הפעמון חסר, ויש במקומו ניסיון חוזר מתוזמן.
  dormant,
}

/// מריץ את המתאם בתוך האפליקציה — המקבילה של `bin/chavruta_companion.dart`.
///
/// ההבדלים מהמחשב: הקונפיג והיומן בתיקיית הנתונים של האפליקציה ולא ב-
/// `%LOCALAPPDATA%`, אין בדיקת חומת אש (אין כזו באנדרואיד), שם המכשיר
/// נלקח מהגדרות הטלפון (`Platform.localHostname` מחזיר `localhost`), ויש
/// מצב שינה — כי כאן המתאם רץ כל היום, גם כשאוצריא סגורה.
///
/// **איך הפעמון מעיר בלי שהתוסף ישים לב.** התוסף מחפש את המתאם בסריקה של
/// `/hello` על הפורטים 45871–45875, וממשיך לפורט הבא כשמישהו עונה בשגיאה.
/// הפעמון יושב על הפורט הפנוי הראשון; כשמגיעה אליו פנייה הוא מעיר את
/// המתאם המלא — שעולה על הפורט **הבא**, כי הפעמון עדיין תופס את שלו — ורק
/// אז עונה 503. אותה סריקה ממשיכה לפורט הבא ומוצאת את המתאם ער.
///
/// כשאין פורט "הבא" (הפעמון על האחרון שפנוי), הפעמון מפנה את פורטו
/// והמתאם עולה עליו; הסריקה הנוכחית כבר עברה אותו, והבאה תמצא אותו.
class CompanionRunner extends ChangeNotifier {
  CompanionRunner({
    this.transportPort = lanPort,
    this.retryInterval = portRetryInterval,
    @visibleForTesting Future<HttpServer> Function(int port)? bindDoorbell,
  }) : _bindDoorbell = bindDoorbell ?? _bindLoopback;

  static Future<HttpServer> _bindLoopback(int port) =>
      HttpServer.bind(InternetAddress.loopbackIPv4, port);

  /// קושר את הפעמון לפורט. בבדיקות — כדי לדמות כישלון בדיוק ברגע שבין
  /// סגירת המתאם לפתיחת הפעמון, בלי מרוץ על פורטים אמיתיים.
  final Future<HttpServer> Function(int port) _bindDoorbell;

  /// פורט ה-UDP של התעבורה. פרמטר בשביל בדיקות, כמו `LanTransport.port`.
  final int transportPort;

  /// ראו [portRetryInterval]. פרמטר כדי שבדיקות לא ימתינו חצי דקה.
  final Duration retryInterval;

  final List<String> lines = [];
  IOSink? _file;
  Directory? _dir;
  SyncHub? _hub;
  LocalApi? _api;
  HttpServer? _doorbell;
  Timer? _idleTimer;
  Timer? _retryTimer;
  DateTime _lastActive = DateTime.now();
  CompanionState _state = CompanionState.stopped;
  bool _busy = false;

  /// פעולות המעבר בין מצבים רצות אחת אחרי השנייה. פעמון שמצלצל באמצע
  /// כניסה לשינה, או לחיצה על "עצירה" באמצע התעוררות, היו אחרת פותחים
  /// שני מתאמים או סוגרים אחד שעוד לא עלה. מכאן גם שכל פעולה בתור בודקת
  /// את המצב **כשהיא רצה** ולא כשנכנסה לתור: עצירה שקדמה לה משנה אותו.
  Future<void> _queue = Future<void>.value();

  /// למה ההפעלה האחרונה נכשלה, לתצוגה. `null` = לא נכשלה.
  String? startError;

  CompanionState get state => _state;
  bool get running => _state != CompanionState.stopped;
  bool get busy => _busy;
  int? get port => _api?.port ?? _doorbell?.port;

  /// הפורט שהפעמון תופס כרגע. `null` = אין פעמון.
  @visibleForTesting
  int? get doorbellPort => _doorbell?.port;

  /// האם ממתין ניסיון חוזר לתפוס פורט.
  @visibleForTesting
  bool get retryPending => _retryTimer != null;

  /// אותו מצב ש-`/hello` מחזיר לתוסף. `null` כשהמתאם אינו ער.
  Map<String, Object?>? snapshot() => _hub?.snapshot();

  void log(String message) {
    lines.add('[${_clock()}] $message');
    if (lines.length > maxLogLines) {
      lines.removeRange(0, lines.length - maxLogLines);
    }
    try {
      _file?.writeln('[${DateTime.now().toIso8601String()}] $message');
    } catch (_) {
      // כתיבה לקובץ נכשלה — היומן במסך ממשיך.
    }
    notifyListeners();
  }

  /// הפעלה ראשונה של התהליך. בעלייה עם הטלפון — ישר לשינה: אף אחד עוד
  /// לא פתח את אוצריא, ואין טעם להכריז נוכחות לחברותא.
  Future<void> boot() async {
    final atBoot = await Native.launchedAtBoot();
    await _serial(() async {
      if (!await _prepare()) return;
      log(
        atBoot
            ? 'מתאם חברותא $companionVersion עלה עם הטלפון'
            : 'מתאם חברותא $companionVersion מתחיל (אנדרואיד)',
      );
      await Native.startService();
      if (atBoot) {
        await _sleep();
      } else {
        await _wake();
      }
    });
  }

  /// "הפעלת המתאם" במסך.
  Future<void> start() => _serial(() async {
    if (_state != CompanionState.stopped) return;
    if (!await _prepare()) return;
    await Native.startService();
    await _wake();
  });

  /// "עצירת המתאם" במסך. עוצר הכול, כולל הפעמון והשירות.
  Future<void> stop() => _serial(() async {
    if (_state == CompanionState.stopped) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _shutDownActive();
    await _closeDoorbell();
    _state = CompanionState.stopped;
    log('המתאם נעצר');
    try {
      await Native.stopService();
    } catch (e) {
      log('שגיאה בעצירת השירות: $e');
    }
  });

  Future<void> _serial(Future<void> Function() step) {
    final next = _queue.then((_) async {
      _busy = true;
      notifyListeners();
      try {
        await step();
      } catch (e, stack) {
        log('שגיאה: $e\n$stack');
      } finally {
        _busy = false;
        notifyListeners();
      }
    });
    _queue = next;
    return next;
  }

  /// תיקיית הנתונים והיומן. פעם אחת לכל תהליך.
  Future<bool> _prepare() async {
    if (_dir != null) return true;
    try {
      final dir = Directory(
        '${await Native.filesDir()}${Platform.pathSeparator}Chavruta',
      );
      await dir.create(recursive: true);
      await _openLogFile(dir);
      _dir = dir;
      return true;
    } catch (e) {
      startError = '$e';
      log('לא ניתן להכין את תיקיית הנתונים: $e');
      return false;
    }
  }

  /// מעיר את המתאם המלא, מכל מצב. אם אין לו פורט — לא כבה, אלא נשאר
  /// בשינה עם פעמון (או עם ניסיון חוזר), כדי שמחסור זמני בפורטים לא
  /// יהפוך לכיבוי שרק המשתמש יכול לבטל.
  Future<void> _wake() async {
    if (_state == CompanionState.active) return;
    if (await _activate()) return;
    log('$startError — נשאר במצב שינה עד שיתפנה פורט');
    await _rest();
  }

  /// נכנס למצב שינה: עוצר את המתאם המלא ומשאיר רק את הפעמון.
  Future<void> _sleep() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await _shutDownActive();
    if (!await _openDoorbell()) {
      // בלי פעמון אין מה שיעיר את המתאם, ושינה הייתה כיבוי שקט. עדיף
      // להישאר ער.
      log('לא ניתן לפתוח פעמון על אף פורט — נשאר ער');
      if (await _activate()) return;
      log('$startError');
    }
    await _rest();
  }

  /// מצב שינה: הפעמון אם אפשר לפתוח אותו, ואחרת ניסיון חוזר מתוזמן.
  Future<void> _rest() async {
    _state = CompanionState.dormant;
    if (!await _openDoorbell()) {
      log(
        'אין פורט פנוי גם לפעמון — ניסיון נוסף בעוד '
        '${retryInterval.inSeconds} שניות',
      );
      _scheduleRetry();
      await Native.setStatus('ממתין לפורט פנוי');
      return;
    }
    await Native.setStatus('במצב שינה — ממתין לאוצריא');
    log('מצב שינה: ממתין שאוצריא תחפש את המתאם (פעמון על פורט ${_doorbell!.port})');
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(retryInterval, () {
      _retryTimer = null;
      unawaited(
        _serial(() async {
          if (_state != CompanionState.dormant || _doorbell != null) return;
          await _rest();
        }),
      );
    });
  }

  /// מעלה את ה-API וה-hub. מחזיר האם עלו; בכישלון לא נשאר שום משאב שלהם
  /// פתוח, והסיבה ב-[startError]. המצב משתנה רק בהצלחה.
  Future<bool> _activate() async {
    // ער באמת רק כשיש API ו-hub; ראו [_shutDownActive].
    if (_state == CompanionState.active) return true;
    startError = null;
    final dir = _dir!;
    SyncHub? hub;
    LocalApi? api;
    bool paired;
    String name;
    try {
      final config = await CompanionConfig.load(storageDir: dir);
      if (config.deviceName.trim().isEmpty ||
          config.deviceName == 'localhost') {
        config.deviceName = await Native.deviceName();
        await config.save();
      }

      final transport = LanTransport(
        roomCodeProvider: () => config.roomCode,
        onLog: log,
        port: transportPort,
      );
      hub = SyncHub(config: config, transport: transport, onLog: log);
      api = LocalApi(hub: hub, version: companionVersion, onLog: log);

      // הפעמון נסגר רק **אחרי** שהמתאם תפס פורט, כדי שהמתאם יעלה על הפורט
      // הבא בטווח — זה שהסריקה של התוסף מגיעה אליו מיד אחרי הפעמון. אם
      // הפעמון החזיק את הפורט הפנוי האחרון, מפנים אותו למתאם.
      var bound = await api.start();
      final hadDoorbell = _doorbell != null;
      await _closeDoorbell();
      if (!bound && hadDoorbell) bound = await api.start();
      if (!bound) {
        startError =
            'לא נמצא פורט פנוי בטווח $localApiFirstPort-$localApiLastPort';
        log('$startError — אולי מתאם אחר כבר רץ.');
        await hub.dispose();
        return false;
      }

      await hub.start();
      paired = config.isPaired;
      name = config.deviceName;
    } catch (e) {
      startError = '$e';
      log('ההתעוררות נכשלה: $e');
      await _quietly(() async => api?.dispose());
      await _quietly(() async => hub?.dispose());
      return false;
    }

    _hub = hub;
    _api = api;
    _state = CompanionState.active;
    _lastActive = DateTime.now();
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(_idleCheckInterval, (_) => _checkIdle());
    _retryTimer?.cancel();
    _retryTimer = null;
    await Native.setStatus('ער ומסנכרן');
    log(
      paired
          ? 'ער ומחובר לחברותא בשם "$name"'
          : 'ער — לא מזווג, ממתין לקוד חברותא מהתוסף באוצריא',
    );
    return true;
  }

  void _checkIdle() {
    final hub = _hub;
    if (hub == null || _state != CompanionState.active) return;
    if (hub.engineOwner != null) {
      _lastActive = DateTime.now();
      return;
    }
    if (DateTime.now().difference(_lastActive) >= dormantAfter) {
      log('אוצריא לא סנכרנה דרך המתאם ${dormantAfter.inMinutes} דקות');
      unawaited(_dozeOff());
    }
  }

  /// נכנס לשינה עכשיו, כאילו עברו [dormantAfter] בלי פנייה מאוצריא.
  @visibleForTesting
  Future<void> sleepNow() => _dozeOff();

  Future<void> _dozeOff() => _serial(() async {
    if (_state == CompanionState.active) await _sleep();
  });

  /// סוגר את המתאם המלא. הודעת הפרידה יוצאת ב-`hub.dispose`, כך שהמחשב
  /// רואה מיד שהטלפון יצא. מכאן והלאה המתאם אינו ער: מי שקרא קובע לאן
  /// הוא עובר — ובכל מקרה לא נשאר `active` בלי API ו-hub.
  Future<void> _shutDownActive() async {
    final api = _api;
    final hub = _hub;
    _api = null;
    _hub = null;
    if (_state == CompanionState.active) _state = CompanionState.dormant;
    if (api != null) await api.dispose();
    if (hub != null) await hub.dispose();
  }

  Future<bool> _openDoorbell() async {
    if (_doorbell != null) return true;
    for (var candidate = localApiFirstPort;
        candidate <= localApiLastPort;
        candidate++) {
      try {
        final server = await _bindDoorbell(candidate);
        server.listen(_ring, onError: (Object e) => log('שגיאת פעמון: $e'));
        _doorbell = server;
        _retryTimer?.cancel();
        _retryTimer = null;
        return true;
      } on SocketException {
        continue;
      }
    }
    return false;
  }

  /// בלי `force`: ההאזנה נפסקת, והפנייה שהעירה את המתאם — שעדיין ממתינה
  /// בתוך [_ring] — מקבלת את תשובתה. ההמתנה כאן היא לסגירת הסוקט המאזין
  /// בלבד ולא לחיבורים הפתוחים (כך `HttpServer.close` בלי `force`), ולכן
  /// אינה נתקעת על אותה פנייה; היא נדרשת כדי שהפורט יהיה פנוי למתאם.
  Future<void> _closeDoorbell() async {
    final server = _doorbell;
    _doorbell = null;
    if (server == null) return;
    await _quietly(
      () => server.close().timeout(const Duration(seconds: 2)),
    );
  }

  /// פנייה לפעמון = אוצריא מחפשת את המתאם. מעירים, ואז עונים 503 כדי
  /// שהתוסף ימשיך בסריקה ויגיע למתאם הער. ראו את התיעוד של המחלקה.
  Future<void> _ring(HttpRequest request) async {
    if (_state == CompanionState.dormant) {
      log('אוצריא מחפשת את המתאם (${request.uri.path}) — מתעורר');
      try {
        await _serial(() async {
          // עצירה שנכנסה לתור לפני הצלצול כבר רצה — לא מעירים אחריה.
          if (_state == CompanionState.dormant) await _wake();
        }).timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // ההתעוררות ממשיכה ברקע; הסריקה הבאה של התוסף תמצא אותו.
      }
    }
    try {
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..headers.contentType = ContentType.json
        ..write('{"error":"waking up"}');
      await request.response.close();
    } catch (_) {
      // הפעמון כבר נסגר והחיבור איתו.
    }
  }

  static Future<void> _quietly(Future<Object?> Function() action) async {
    try {
      await action();
    } catch (_) {
      // ניקוי בדרך החוצה — אין מה לעשות עם הכישלון.
    }
  }

  /// כמה שורות מסוף היומן הקודם מוצגות במסך כשהתהליך עולה.
  static const int _previousLogLines = 150;

  Future<void> _openLogFile(Directory dir) async {
    if (_file != null) return;
    try {
      final file = File('${dir.path}${Platform.pathSeparator}companion.log');
      await _showPreviousLog(file);
      final tooBig = await file.exists() && await file.length() > maxLogBytes;
      _file = file.openWrite(mode: tooBig ? FileMode.write : FileMode.append);
    } catch (_) {
      _file = null;
    }
  }

  /// מה שקרה **לפני** שהתהליך הזה עלה — כולל הרישומים של צד האנדרואיד
  /// (`DiagLog.kt`): נהרג, הוקם מחדש, הוחלק. בלי זה המסך מראה רק את הריצה
  /// הנוכחית, ודווקא הרגע שבו המתאם נעלם אינו נראה בשום מקום.
  Future<void> _showPreviousLog(File file) async {
    try {
      if (!await file.exists()) return;
      final previous = await file.readAsLines();
      if (previous.isEmpty) return;
      final tail = previous.length > _previousLogLines
          ? previous.sublist(previous.length - _previousLogLines)
          : previous;
      lines
        ..add('— מכאן: סוף היומן עד העלייה הנוכחית —')
        ..addAll(tail)
        ..add('— מכאן: הריצה הנוכחית —');
      notifyListeners();
    } catch (_) {
      // יומן שאינו קריא (למשל UTF-8 שנקטע) — מוותרים על ההיסטוריה.
    }
  }

  static String _clock() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}
