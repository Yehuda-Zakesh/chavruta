import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'startup_registration.dart';
import 'sync_hub.dart';

/// כמה זמן בקשת `/events` נשארת פתוחה לפני שהיא חוזרת ריקה.
///
/// גבול הזמן של `network.fetch` באוצריא הוא 120 שניות; 25 שניות משאירות
/// מרווח בטחון גדול ובכל זאת חוסכות תחקור בלופ.
const Duration longPollTimeout = Duration(seconds: 25);

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
    } catch (e) {
      onLog?.call('request failed: $e');
      try {
        await _respondJson(request, {
          'error': '$e',
        }, status: HttpStatus.internalServerError);
      } catch (_) {
        // התשובה כבר נסגרה — אין מה להוסיף.
      }
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
    if (heldBefore && hub.remoteSequence <= since) {
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

    final snapshot = hub.snapshot();
    final sequence = snapshot['remoteSequence'] as int;
    final remote = snapshot['remote'];

    // "עדכון" הוא מיקום חדש לנווט אליו. המונה מתקדם גם באירועים שאינם
    // מיקום — למשל החלפת חדר, שמנקה את המצב — ואלה מסתנכרנים דרך
    // remoteSequence בלבד, בלי לגרום לתוסף לנווט לשום מקום.
    final location = remote is Map
        ? SyncLocation.fromJson(remote['location'])
        : null;
    final hasUpdate = sequence > since && location != null;

    // מסמנים כמסור רק כשהעדכון באמת נשלח לתוסף, כדי שההד שיחזור
    // ממנו — אחרי הניווט — יזוהה ולא ישודר בחזרה לחברותא.
    if (hasUpdate) hub.markHandedToPlugin(location);

    await _respondJson(request, {
      'hasUpdate': hasUpdate,
      'engineMine': true,
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
    final instance = body is Map ? body['instance'] : null;
    if (instance is String && instance.isNotEmpty) hub.claimEngine(instance);
    final broadcast = await hub.publishLocal(location);
    await _respondJson(request, {'broadcast': broadcast, ...hub.snapshot()});
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
  Future<Object?> _readJsonBody(HttpRequest request) async {
    final String text;
    try {
      text = await utf8.decoder.bind(request).join();
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
