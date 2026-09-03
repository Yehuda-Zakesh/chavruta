import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'protocol.dart';
import 'startup_registration.dart';
import 'sync_hub.dart';

/// כמה זמן בקשת `/events` נשארת פתוחה לפני שהיא חוזרת ריקה.
///
/// גבול הזמן של `network.fetch` באוצריא הוא 120 שניות; 25 שניות משאירות
/// מרווח בטחון גדול ובכל זאת חוסכות תחקור בלופ.
const Duration longPollTimeout = Duration(seconds: 25);

/// תקרת גודל לגוף בקשה, ואחריה הבקשה נדחית ב-413.
///
/// הגוף הגדול ביותר שהתוסף שולח הוא דיווח שולחן מלא: [maxTrackedTabs]
/// ספרים עם שמותיהם, כלומר סדר גודל של עשרות קילובייטים לכל היותר.
/// 256KB משאירים מרווח עצום ובכל זאת חוסמים גוף שנועד לנפח זיכרון.
const int maxApiBodyBytes = 256 * 1024;

/// כמה זמן ממתינים לגוף הבקשה. חיבור שנפתח ואינו מסיים לשלוח היה
/// מחזיק handler פתוח לנצח; הגוף שהתוסף שולח מגיע על loopback במילישניות.
///
/// זהו גבול **חוסר פעילות** ולא גבול על הבקשה כולה: כל נתח שמגיע מאפס
/// אותו, ולכן גוף גדול ואיטי אינו נקטע באמצע.
///
/// **מה שמשתחרר כאן הוא ה-handler, לא בהכרח נוסח התשובה.** כשגוף הבקשה
/// לא הושלם, `HttpServer` של Dart סוגר את החיבור ואינו שולח את התשובה
/// שנכתבה — אומת בבדיקה. ה-408 נכתב בכל זאת, כי במסלולים שבהם הגוף כן
/// הושלם הוא מגיע ליעדו, והמחיר שלו אפס.
const Duration apiBodyTimeout = Duration(seconds: 10);

/// כותרות שדפדפן מוסיף בעצמו ואינו מאפשר לקוד JavaScript לגעת בהן.
///
/// נוכחות של אחת מהן פירושה שהבקשה יצאה מדף אינטרנט — ולא מהתוסף, שפונה
/// דרך לקוח ה-HTTP של Dart ואינו שולח אף אחת מהן. ראו [_looksLikeBrowser].
const List<String> browserOnlyHeaders = [
  'origin',
  'referer',
  'sec-fetch-site',
  'sec-fetch-mode',
];

/// גוף בקשה שעבר את [maxApiBodyBytes]. מתורגם ל-413.
class _BodyTooBig implements Exception {
  const _BodyTooBig();
}

/// גוף בקשה שלא הושלם בתוך [apiBodyTimeout]. מתורגם ל-408.
class _BodyTimeout implements Exception {
  const _BodyTimeout();
}

/// שרת ה-HTTP שהתוסף מדבר איתו, על loopback בלבד.
///
/// **ההאזנה ל-127.0.0.1 מונעת גישה מהרשת, אך לא מדף אינטרנט שהמשתמש
/// פתח בדפדפן.** דף כזה אינו יכול *לקרוא* את התשובה (אין כאן כותרות
/// CORS, בכוונה), אבל בקשת POST פשוטה — בלי כותרות מיוחדות — יוצאת
/// אליו בלי preflight, והפעולה מתבצעת: יציאה מהחברותא, שינוי שם, הדלקת
/// עלייה עם המחשב. טווח הפורטים קטן וקל לסריקה, ולכן זה אינו תיאורטי.
///
/// לכן כל בקשה שנושאת סימן של דפדפן נדחית ב-403 (ראו
/// [browserOnlyHeaders]). הדחייה היא על כל הנתיבים, כולל `/hello`, כדי
/// שגם סריקת פורטים מדף לא תקבל תשובה. בדיקה ידנית ב-curl או
/// ב-`Invoke-RestMethod` אינה שולחת את הכותרות האלה וממשיכה לעבוד.
class LocalApi {
  LocalApi({
    required this.hub,
    required this.version,
    this.onLog,
    StartupRegistration? startup,
  }) : startup = startup ?? StartupRegistration();

  final SyncHub hub;
  final String version;
  final void Function(String message)? onLog;

  /// רישום העלייה עם המחשב. המתאם הוא שנוגע ברישום, ולא התוסף: ל-WebView
  /// של תוסף אוצריא אין — ובצדק — דרך לגעת ברישום או להפעיל תוכניות.
  final StartupRegistration startup;

  HttpServer? _server;

  int? get port => _server?.port;

  /// מרים את השרת על הפורט הראשון הפנוי בטווח המוסכם. התוסף סורק את
  /// אותו טווח, ולכן אין צורך להעביר לו את הפורט בשום דרך אחרת.
  Future<bool> start() async {
    for (var candidate = localApiFirstPort;
        candidate <= localApiLastPort;
        candidate++) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          candidate,
        );
        _server = server;
        server.listen(_handle, onError: (Object e) => onLog?.call('http error: $e'));
        onLog?.call('local API listening on 127.0.0.1:$candidate');
        return true;
      } on SocketException {
        // הפורט תפוס — ננסה את הבא בטווח.
        continue;
      }
    }
    onLog?.call(
      'could not bind any local port in '
      '$localApiFirstPort-$localApiLastPort',
    );
    return false;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (_looksLikeBrowser(request)) {
        onLog?.call(
          'נדחתה פנייה מדפדפן אל ${request.uri.path} '
          '(origin: ${request.headers.value('origin') ?? '—'})',
        );
        await _respondJson(request, {
          'error': 'browser requests are not accepted',
        }, status: HttpStatus.forbidden);
        return;
      }

      final path = request.uri.path;
      switch ('${request.method} $path') {
        case 'GET /hello':
          await _respondJson(request, {
            'app': 'chavruta-companion',
            'version': version,
            'port': port,
            ...hub.snapshot(),
          });
        case 'GET /events':
          await _handleEvents(request);
        case 'POST /publish':
          await _handlePublish(request);
        case 'POST /tabs':
          await _handleTabs(request);
        case 'POST /desk/carry':
          await _handleDeskCarry(request);
        case 'POST /desk/dismiss':
          await _handleDeskDismiss(request);
        case 'POST /settings':
          await _handleSettings(request);
        case 'POST /room':
          await _handleRoom(request);
        case 'POST /name':
          await _handleName(request);
        case 'POST /engine/release':
          await _handleEngineRelease(request);
        case 'GET /startup':
          await _respondJson(request, (await startup.read()).toJson());
        case 'POST /startup':
          await _handleStartup(request);
        default:
          await _respondJson(request, {
            'error': 'unknown endpoint',
          }, status: HttpStatus.notFound);
      }
    } on _BodyTooBig {
      // שגיאת לקוח ולא שגיאת שרת, ולכן לא 500: מי ששלח גוף כזה קיבל
      // תשובה מדויקת, והמתאם ממשיך לענות לכל השאר.
      onLog?.call('נדחה גוף בקשה שעבר $maxApiBodyBytes בייט ב-${request.uri.path}');
      await _respondSafely(request, {
        'error': 'request body too large',
      }, status: HttpStatus.requestEntityTooLarge);
    } on _BodyTimeout {
      onLog?.call('גוף הבקשה ל-${request.uri.path} לא הושלם בזמן');
      await _respondSafely(request, {
        'error': 'request body timed out',
      }, status: HttpStatus.requestTimeout);
    } catch (e) {
      onLog?.call('request failed: $e');
      await _respondSafely(request, {
        'error': '$e',
      }, status: HttpStatus.internalServerError);
    }
  }

  /// תשובה שאסור לה להפיל את ה-handler. הבקשה עלולה להיות סגורה כבר.
  Future<void> _respondSafely(
    HttpRequest request,
    Map<String, Object?> payload, {
    required int status,
  }) async {
    try {
      await _respondJson(request, payload, status: status);
    } catch (_) {
      // התשובה כבר נסגרה — אין מה להוסיף.
    }
  }

  /// האם הבקשה הגיעה מדף אינטרנט. ראו את התיעוד בראש [LocalApi].
  ///
  /// הכותרות האלה הן "forbidden header names" בתקן: דפדפן קובע אותן
  /// בעצמו, וקוד בדף אינו יכול להוסיף, לשנות או להסיר אותן. לכן זה
  /// סינון שאי אפשר לעקוף מתוך דף.
  static bool _looksLikeBrowser(HttpRequest request) =>
      browserOnlyHeaders.any((name) => request.headers.value(name) != null);

  /// המתנה ארוכה לעדכון. חוזרת מיד אם יש עדכון חדש מ-[since], ואחרת
  /// ממתינה עד שמשהו קורה או עד שיפוג הזמן.
  Future<void> _handleEvents(HttpRequest request) async {
    final since = int.tryParse(request.uri.queryParameters['since'] ?? '') ?? -1;
    final instance = request.uri.queryParameters['instance'] ?? '';

    // ההכרעה מי מסנכרן נעשית כאן, לפני ההמתנה. מופע שאינו המחזיק חוזר
    // מיד ובלי `hasUpdate` — הוא אינו אמור לנווט, ואין טעם להחזיק אצלו
    // בקשה פתוחה ל-25 שניות. הוא ינסה שוב, ואם המחזיק יידום ייכנס במקומו.
    //
    // בקשה בלי `instance` אינה נכנסת להחזקה כלל, וממתינה בדיוק כמו קודם.
    final claimsEngine = instance.isNotEmpty;
    final heldBefore = !claimsEngine || hub.engineOwner == instance;
    if (!hub.claimEngine(instance)) {
      await _respondJson(request, {
        'hasUpdate': false,
        'engineMine': false,
        ...hub.snapshot(),
      });
      return;
    }

    // **מופע שרק עכשיו קיבל את ההחזקה מקבל תשובה מיד.** בלי זה הוא היה
    // לומד שהמנוע בידיו רק בתום ההמתנה הארוכה — עד 25 שניות שבהן הוא
    // מחזיק את ההחזקה אך אינו מאזין לשינויי מקום ואינו מדווח כלום. זה
    // בדיוק הרגע הרגיש: מיד אחרי שמופע הרקע נדם והלשונית נכנסה במקומו.
    if (heldBefore && hub.remoteSequence <= since && !hub.hasDeskWork) {
      await hub.waitForChange(longPollTimeout);
      // **חובה לבדוק את ההחזקה שוב, ולכבד את התוצאה.** ההמתנה כאן ארוכה
      // (25 שניות), ובתוכה מופע הרקע יכול לעלות ולקחת את המנוע. תשובה
      // שאומרת לממתין "ההחזקה שלך" בכל מקרה הייתה משאירה שני מופעים
      // שמדווחים מיקום ומנווטים במקביל — בדיוק מה שההחזקה באה למנוע.
      //
      // חידוש ולא רכישה — ראו [SyncHub.refreshEngine].
      if (!hub.refreshEngine(instance)) {
        await _respondJson(request, {
          'hasUpdate': false,
          'engineMine': false,
          ...hub.snapshot(),
        });
        return;
      }
    }

    // תוכנית השולחן נמסרת רק למי שמריץ את המנוע; מופע שאינו המחזיק חזר
    // כבר למעלה. היא **נגזרת ואינה תור** (ראו [SyncHub.deskPlan]): תשובה
    // שאבדה בדרך אינה מאבדת פעולה, והפעולה נעלמת מהתוכנית מאליה ברגע
    // שהתוסף מדווח שהיא בוצעה.
    final plan = hub.deskPlan();

    final snapshot = hub.snapshot();
    final sequence = snapshot['remoteSequence'] as int;
    final remote = snapshot['remote'];

    // "עדכון" הוא מיקום חדש לנווט אליו. המונה מתקדם גם באירועים שאינם
    // מיקום — למשל החלפת חדר, שמנקה את המצב — ואלה מסתנכרנים דרך
    // remoteSequence בלבד, בלי לגרום לתוסף לנווט לשום מקום.
    final location = remote is Map
        ? SyncLocation.fromJson(remote['location'])
        : null;
    // **וגם: המיקום עצמו חייב להיות חדש.** ראו
    // [SyncHub.hasFreshRemoteLocation] — המונה מתקדם גם בפעולת שולחן,
    // ובלי התנאי הזה כל פעולה כזאת הייתה מכריזה מחדש על מיקום שנמסר
    // מזמן, וגוררת את המשתמש חזרה לדף שהחברותא הייתה בו.
    final hasUpdate =
        sequence > since && location != null && hub.hasFreshRemoteLocation;

    // מסמנים כמסור רק כשהעדכון באמת נשלח לתוסף, כדי שההד שיחזור
    // ממנו — אחרי הניווט — יזוהה ולא ישודר בחזרה לחברותא.
    if (hasUpdate) hub.markHandedToPlugin(location);
    // תוכנית שנמסרה אינה מקצרת שוב את ההמתנה הארוכה. ראו
    // [SyncHub.hasDeskWork].
    hub.markDeskPlanDelivered(plan);

    await _respondJson(request, {
      'hasUpdate': hasUpdate,
      'engineMine': true,
      'desk': {
        'open': plan.open.map((e) => e.toJson()).toList(),
        'close': plan.close.map((e) => e.toJson()).toList(),
      },
      ...snapshot,
    });
  }

  Future<void> _handlePublish(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final location = SyncLocation.fromJson(body);
    if (location == null) {
      await _respondJson(request, {
        'error': 'bookId and index are required',
      }, status: HttpStatus.badRequest);
      return;
    }
    // דיווח מיקום הוא סימן חיים של המנוע ממש כמו `/events`, ולכן הוא
    // מחדש את ההחזקה. `instance` אופציונלי — בלעדיו הדיווח נקלט כרגיל,
    // וכך `curl` ובדיקות ידניות ממשיכים לעבוד.
    if (!_ownsEngine(body)) {
      await _rejectNotOwner(request);
      return;
    }
    final broadcast = await hub.publishLocal(location);
    await _respondJson(request, {
      'broadcast': broadcast,
      'engineMine': true,
      ...hub.snapshot(),
    });
  }

  /// דיווח על הספרים הפתוחים באוצריא כאן.
  ///
  /// הגוף:
  /// ```json
  /// {
  ///   "instance": "background",
  ///   "tabs": [{"b": "ברכות", "i": 4}],
  ///   "canClose": false,
  ///   "failed": ["ספר שאינו בספרייה"]
  /// }
  /// ```
  ///
  /// זו **תמונת מצב מלאה** ולא רשימת חדשים: לאוצריא אין אירוע "נפתח
  /// טאב", התוסף סורק, וההפרש — פתיחות וסגירות גם יחד — מחושב במתאם
  /// (ראו [SyncHub.publishLocalDesk]).
  ///
  /// רשימה ריקה היא דיווח תקין — "אין כאן ספרים פתוחים" — ולכן היא
  /// נבדלת מגוף חסר, שהוא 400.
  Future<void> _handleTabs(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final raw = body is Map ? body['tabs'] : null;
    if (raw is! List) {
      await _respondJson(request, {
        'error': 'tabs must be an array',
      }, status: HttpStatus.badRequest);
      return;
    }
    // דיווח שולחן הוא סימן חיים של המנוע, בדיוק כמו `/publish`.
    if (!_ownsEngine(body)) {
      await _rejectNotOwner(request);
      return;
    }

    final rawFailed = body is Map ? body['failed'] : null;
    final broadcast = await hub.publishLocalDesk(
      _localEntries(raw),
      canClose: body is Map && body['canClose'] == true,
      failed: rawFailed is List ? rawFailed.whereType<String>() : const [],
    );
    await _respondJson(request, {
      'broadcast': broadcast,
      'engineMine': true,
      ...hub.snapshot(),
    });
  }

  /// האם המופע ששלח את [body] רשאי לדווח, ומחדש את ההחזקה אם כן.
  ///
  /// **התשובה של `claimEngine` אינה עצה.** מופע שנדחה — לשונית שמופע
  /// הרקע לקח ממנה את המנוע — היה ממשיך כאן לעדכן את המצב המקומי
  /// ולשדר, ואז שני מופעים מדווחים מיקום במקביל: בדיוק מה שההחזקה באה
  /// למנוע. הדחייה קורית לפני כל שינוי מצב, ולא אחריו.
  ///
  /// גוף בלי `instance` הוא הדיווח הישן — `curl`, בדיקות ידניות, ותוסף
  /// מגרסה שאינה מכירה מופעים — והוא מתקבל כרגיל.
  bool _ownsEngine(Object? body) {
    final instance = body is Map ? body['instance'] : null;
    if (instance is! String || instance.isEmpty) return true;
    return hub.claimEngine(instance);
  }

  /// התשובה למופע שאינו המחזיק. `200` ולא `409`, בדיוק כמו `/events`:
  /// זה אינו מצב שגיאה אלא המצב הרגיל של לשונית פתוחה לצד מופע רקע,
  /// והתוסף מזהה אותו בשדה אחד בכל הנתיבים.
  Future<void> _rejectNotOwner(HttpRequest request) => _respondJson(request, {
    'broadcast': false,
    'engineMine': false,
    ...hub.snapshot(),
  });

  /// ממיר את דיווח התוסף לפריטי שולחן.
  ///
  /// החותמת והבעלות נקבעות במתאם ולא בתוסף — הוא מדווח **עובדה**
  /// ("הספר הזה פתוח כאן"), והמתאם הוא שמחליט אם זו פעולה חדשה.
  static List<DeskEntry> _localEntries(List raw) {
    final seen = <String>{};
    final entries = <DeskEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final bookId = item['b'];
      if (bookId is! String || bookId.isEmpty || !seen.add(bookId)) continue;
      final index = item['i'];
      entries.add(
        DeskEntry(
          bookId: bookId,
          index: index is int && index >= 0 ? index : 0,
          stamp: 0,
          by: '',
        ),
      );
      if (entries.length >= maxTrackedTabs) break;
    }
    return entries;
  }

  /// העברת ספרים שפתוחים כאן אל השולחן המשותף, לפי בחירת המשתמש.
  ///
  /// הגוף הוא `{"bookIds": ["ברכות", "שבת"]}`. "העברת הכול" היא פשוט
  /// כל המועמדים שהלשונית קיבלה ב-`carryCandidates`.
  Future<void> _handleDeskCarry(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final raw = body is Map ? body['bookIds'] : null;
    if (raw is! List) {
      await _respondJson(request, {
        'error': 'bookIds must be an array',
      }, status: HttpStatus.badRequest);
      return;
    }
    final carried = await hub.carryToDesk(raw.whereType<String>());
    await _respondJson(request, {'carried': carried, ...hub.snapshot()});
  }

  /// המשתמש ענה "לא" על שאלת סגירה. ראו [SyncHub.dismissClose].
  Future<void> _handleDeskDismiss(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final bookId = body is Map ? body['bookId'] : null;
    if (bookId is! String || bookId.isEmpty) {
      await _respondJson(request, {
        'error': 'bookId is required',
      }, status: HttpStatus.badRequest);
      return;
    }
    hub.dismissClose(bookId);
    await _respondJson(request, hub.snapshot());
  }

  /// שינוי העדפות הסנכרון: מקום הלימוד, ומדיניות הסגירה.
  ///
  /// ההעדפות יושבות במתאם ולא בזיכרון התוסף, כי שני מופעי התוסף צריכים
  /// לראות אותן — ראו [CompanionConfig].
  Future<void> _handleSettings(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body is! Map) {
      await _respondJson(request, {
        'error': 'syncLocation or closePolicy is required',
      }, status: HttpStatus.badRequest);
      return;
    }

    if (body.containsKey('syncLocation')) {
      final value = body['syncLocation'];
      if (value is! bool) {
        await _respondJson(request, {
          'error': 'syncLocation must be a boolean',
        }, status: HttpStatus.badRequest);
        return;
      }
      await hub.setSyncLocation(value);
    }

    if (body.containsKey('closePolicy')) {
      final value = body['closePolicy'];
      // ערך לא מוכר אינו נופל בשקט לברירת המחדל: מדיניות סגירה שגויה
      // היא בדיוק הסוג של טעות שאסור לגלות רק כשספר נסגר.
      if (value is! String ||
          !ClosePolicy.values.any((policy) => policy.wire == value)) {
        await _respondJson(request, {
          'error': 'closePolicy must be one of ask, always, never',
        }, status: HttpStatus.badRequest);
        return;
      }
      await hub.setClosePolicy(ClosePolicy.fromWire(value));
    }

    await _respondJson(request, hub.snapshot());
  }

  /// מופע התוסף מודיע שהוא מפסיק לסנכרן, כדי שהמופע האחר ייכנס מיד.
  Future<void> _handleEngineRelease(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final instance = body is Map ? body['instance'] : null;
    if (instance is! String || instance.isEmpty) {
      await _respondJson(request, {
        'error': 'instance is required',
      }, status: HttpStatus.badRequest);
      return;
    }
    hub.releaseEngine(instance);
    await _respondJson(request, hub.snapshot());
  }

  /// כניסה לחברותא או יציאה ממנה.
  ///
  /// היציאה חייבת להיות **מפורשת** — `{"code": null}` — ולא נגזרת מגוף
  /// חסר או שבור. אחרת בקשה שנקטעה באמצע, או גוף שאינו UTF-8 תקין,
  /// היו מוציאים את המשתמש מהחברותא בלי שביקש ובלי שידע.
  Future<void> _handleRoom(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body is! Map || !body.containsKey('code')) {
      await _respondJson(request, {
        'error': 'code is required (null to leave the chavruta)',
      }, status: HttpStatus.badRequest);
      return;
    }
    final code = body['code'];
    if (code != null && code is! String) {
      await _respondJson(request, {
        'error': 'code must be a string or null',
      }, status: HttpStatus.badRequest);
      return;
    }
    await hub.setRoom(code as String?);
    await _respondJson(request, hub.snapshot());
  }

  Future<void> _handleName(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final name = body is Map ? body['name'] : null;
    if (name is! String) {
      await _respondJson(request, {
        'error': 'name must be a string',
      }, status: HttpStatus.badRequest);
      return;
    }
    await hub.setDeviceName(name);
    await _respondJson(request, hub.snapshot());
  }

  /// מדליק או מכבה עלייה עם המחשב. התשובה היא המצב בפועל אחרי השינוי,
  /// ולכן התוסף לא צריך לנחש אם השינוי נתפס.
  Future<void> _handleStartup(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final enabled = body is Map ? body['enabled'] : null;
    if (enabled is! bool) {
      await _respondJson(request, {
        'error': 'enabled must be a boolean',
      }, status: HttpStatus.badRequest);
      return;
    }
    final state = await startup.setEnabled(enabled);
    onLog?.call(
      'עלייה עם המחשב: התבקש ${enabled ? "מופעל" : "כבוי"}, '
      'בפועל ${state.enabled ? "מופעל" : "כבוי"}'
      '${state.reason == null ? "" : " (${state.reason})"}',
    );
    await _respondJson(request, state.toJson());
  }

  /// קורא גוף JSON. `null` = אין גוף, או שאינו קריא — ואז כל נתיב
  /// מחזיר 400 משלו.
  ///
  /// גם פענוח ה-UTF-8 עטוף: `utf8.decoder` זורק על בייטים שאינם UTF-8
  /// תקין, וזה היה מגיע כ-500 ("שגיאת שרת") על בקשה פגומה של הלקוח.
  ///
  /// **הקריאה חסומה בגודל ובזמן.** ההאזנה היא על loopback, אבל loopback
  /// אינו ריק: כל תהליך שרץ במחשב יכול לפתוח POST, לשלוח גוף בלי סוף או
  /// לשלוח בייט אחת לדקה ולעולם לא לסגור — ושניהם היו נבלעים כאן בשקט,
  /// אחד בזיכרון והשני ב-handler שנשאר תלוי. חריגה נזרקת כ-[_BodyTooBig]
  /// או [_BodyTimeout], והנתיב שקרא הופך אותה לתשובה.
  Future<Object?> _readJsonBody(HttpRequest request) async {
    // `Content-Length` נבדק קודם: כשהוא קיים אין טעם לקרוא בייט אחד.
    if (request.contentLength > maxApiBodyBytes) throw const _BodyTooBig();

    final bytes = <int>[];
    final String text;
    try {
      await for (final chunk in request.timeout(apiBodyTimeout)) {
        bytes.addAll(chunk);
        // גם גוף chunked, שאין לו `Content-Length`, נעצר כאן — ברגע
        // שעבר את התקרה, ולא אחרי שכבר נצבר כולו בזיכרון.
        if (bytes.length > maxApiBodyBytes) throw const _BodyTooBig();
      }
      text = utf8.decode(bytes);
    } on _BodyTooBig {
      rethrow;
    } on TimeoutException {
      throw const _BodyTimeout();
    } catch (_) {
      return null;
    }
    if (text.trim().isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  Future<void> _respondJson(
    HttpRequest request,
    Map<String, Object?> payload, {
    int status = HttpStatus.ok,
  }) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }

  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
  }
}
