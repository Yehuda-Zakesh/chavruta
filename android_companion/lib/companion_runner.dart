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

enum CompanionState {
  /// כבוי — המשתמש עצר אותו.
  stopped,

  /// המתאם המלא רץ: משדר, קולט ועונה לתוסף.
  active,

  /// אוצריא אינה פונה אליו. אין שידור, אין קליטה ואין טיימרים — רק
  /// "פעמון" על פורט ב-loopback, שמעיר את המתאם כשהתוסף מחפש אותו.
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
class CompanionRunner extends ChangeNotifier {
  final List<String> lines = [];
  IOSink? _file;
  Directory? _dir;
  SyncHub? _hub;
  LocalApi? _api;
  HttpServer? _doorbell;
  Timer? _idleTimer;
  DateTime _lastActive = DateTime.now();
  CompanionState _state = CompanionState.stopped;
  bool _busy = false;

  /// פעולות המעבר בין מצבים רצות אחת אחרי השנייה. פעמון שמצלצל באמצע
  /// כניסה לשינה, או לחיצה על "עצירה" באמצע התעוררות, היו אחרת פותחים
  /// שני מתאמים או סוגרים אחד שעוד לא עלה.
  Future<void> _queue = Future<void>.value();

  /// למה ההפעלה האחרונה נכשלה, לתצוגה. `null` = לא נכשלה.
  String? startError;

  CompanionState get state => _state;
  bool get running => _state != CompanionState.stopped;
  bool get busy => _busy;
  int? get port => _api?.port ?? _doorbell?.port;

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
        await _activate();
      }
    });
  }

  /// "הפעלת המתאם" במסך.
  Future<void> start() => _serial(() async {
    if (_state != CompanionState.stopped) return;
    if (!await _prepare()) return;
    await Native.startService();
    await _activate();
  });

  /// "עצירת המתאם" במסך. עוצר הכול, כולל הפעמון והשירות.
  Future<void> stop() => _serial(() async {
    if (_state == CompanionState.stopped) return;
    _idleTimer?.cancel();
    _idleTimer = null;
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

  /// מעלה את המתאם המלא. מכל מצב — כבוי או שינה.
  Future<void> _activate() async {
    if (_state == CompanionState.active) return;
    startError = null;
    final dir = _dir!;

    final config = await CompanionConfig.load(storageDir: dir);
    if (config.deviceName.trim().isEmpty || config.deviceName == 'localhost') {
      config.deviceName = await Native.deviceName();
      await config.save();
    }

    final transport = LanTransport(
      roomCodeProvider: () => config.roomCode,
      onLog: log,
    );
    final hub = SyncHub(config: config, transport: transport, onLog: log);
    final api = LocalApi(hub: hub, version: companionVersion, onLog: log);

    // הפעמון נסגר רק **אחרי** שהמתאם תפס פורט, כדי שהמתאם יעלה על הפורט
    // הבא בטווח — זה שהסריקה של התוסף מגיעה אליו מיד אחרי הפעמון.
    final bound = await api.start();
    await _closeDoorbell();
    if (!bound) {
      startError =
          'לא נמצא פורט פנוי בטווח $localApiFirstPort-$localApiLastPort';
      log('$startError — כנראה שהמתאם כבר רץ.');
      await hub.dispose();
      _state = CompanionState.stopped;
      await Native.stopService();
      return;
    }

    await hub.start();
    _hub = hub;
    _api = api;
    _state = CompanionState.active;
    _lastActive = DateTime.now();
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(_idleCheckInterval, (_) => _checkIdle());
    await Native.setStatus('ער ומסנכרן');
    log(
      config.isPaired
          ? 'ער ומחובר לחברותא בשם "${config.deviceName}"'
          : 'ער — לא מזווג, ממתין לקוד חברותא מהתוסף באוצריא',
    );
  }

  /// נכנס למצב שינה: עוצר את המתאם המלא ומשאיר רק את הפעמון.
  Future<void> _sleep() async {
    if (_state == CompanionState.dormant) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    await _shutDownActive();
    if (!await _openDoorbell()) {
      // בלי פעמון אין מה שיעיר את המתאם, ושינה הייתה כיבוי שקט. עדיף
      // להישאר ער.
      log('לא ניתן לפתוח פעמון על אף פורט — נשאר ער');
      await _activate();
      return;
    }
    _state = CompanionState.dormant;
    await Native.setStatus('במצב שינה — ממתין לאוצריא');
    log('מצב שינה: ממתין שאוצריא תחפש את המתאם (פעמון על פורט ${_doorbell!.port})');
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
      unawaited(_serial(_sleep));
    }
  }

  /// סוגר את המתאם המלא. הודעת הפרידה יוצאת ב-`hub.dispose`, כך שהמחשב
  /// רואה מיד שהטלפון יצא.
  Future<void> _shutDownActive() async {
    final api = _api;
    final hub = _hub;
    _api = null;
    _hub = null;
    if (api != null) await api.dispose();
    if (hub != null) await hub.dispose();
  }

  Future<bool> _openDoorbell() async {
    for (var candidate = localApiFirstPort;
        candidate <= localApiLastPort;
        candidate++) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          candidate,
        );
        server.listen(_ring, onError: (Object e) => log('שגיאת פעמון: $e'));
        _doorbell = server;
        return true;
      } on SocketException {
        continue;
      }
    }
    return false;
  }

  /// בלי `force` ובלי המתנה: ההאזנה נפסקת מיד, והפנייה שהעירה את המתאם —
  /// שעדיין ממתינה בתוך [_ring] — מקבלת את תשובתה. המתנה כאן הייתה נתקעת
  /// עד שאותה פנייה תסתיים, והיא ממתינה להתעוררות הזאת עצמה.
  Future<void> _closeDoorbell() async {
    final server = _doorbell;
    _doorbell = null;
    if (server == null) return;
    unawaited(server.close().catchError((Object _) {}));
  }

  /// פנייה לפעמון = אוצריא מחפשת את המתאם. מעירים, ואז עונים 503 כדי
  /// שהתוסף ימשיך בסריקה ויגיע למתאם הער. ראו את התיעוד של המחלקה.
  Future<void> _ring(HttpRequest request) async {
    if (_state == CompanionState.dormant) {
      log('אוצריא מחפשת את המתאם (${request.uri.path}) — מתעורר');
      try {
        await _serial(_activate).timeout(const Duration(seconds: 1));
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
