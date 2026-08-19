import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'sync_hub.dart';

/// כמה זמן בקשת `/events` נשארת פתוחה לפני שהיא חוזרת ריקה.
///
/// גבול הזמן של `network.fetch` באוצריא הוא 120 שניות; 25 שניות משאירות
/// מרווח בטחון גדול ובכל זאת חוסכות תחקור בלופ.
const Duration longPollTimeout = Duration(seconds: 25);

/// שרת ה-HTTP שהתוסף מדבר איתו, על loopback בלבד.
///
/// **גבול האבטחה כאן הוא ההאזנה ל-127.0.0.1** — השרת אינו נגיש מהרשת.
/// אין כאן כותרות CORS בכוונה: התוסף פונה דרך `network.fetch` שרץ בצד
/// Flutter ואינו כפוף ל-CORS, ולכן דפי אינטרנט בדפדפן לא יכולים לדבר
/// עם השרת הזה.
class LocalApi {
  LocalApi({required this.hub, required this.version, this.onLog});

  final SyncHub hub;
  final String version;
  final void Function(String message)? onLog;

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

  /// המתנה ארוכה לעדכון. חוזרת מיד אם יש עדכון חדש מ-[since], ואחרת
  /// ממתינה עד שמשהו קורה או עד שיפוג הזמן.
  Future<void> _handleEvents(HttpRequest request) async {
    final since = int.tryParse(request.uri.queryParameters['since'] ?? '') ?? -1;
    if (hub.remoteSequence <= since) {
      await hub.waitForChange(longPollTimeout);
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

    await _respondJson(request, {'hasUpdate': hasUpdate, ...snapshot});
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
    final broadcast = await hub.publishLocal(location);
    await _respondJson(request, {'broadcast': broadcast, ...hub.snapshot()});
  }

  Future<void> _handleRoom(HttpRequest request) async {
    final body = await _readJsonBody(request);
    final code = body is Map ? body['code'] : null;
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

  Future<Object?> _readJsonBody(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
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
