import 'dart:convert';
import 'dart:io';

import 'package:chavruta_companion/config.dart';
import 'package:chavruta_companion/local_api.dart';
import 'package:chavruta_companion/protocol.dart';
import 'package:chavruta_companion/startup_registration.dart';
import 'package:chavruta_companion/sync_hub.dart';
import 'package:test/test.dart';

import 'support/fake_reg.dart';
import 'support/fake_transport.dart';
import 'support/temp_config.dart';

/// לקוח HTTP קטן מול המתאם, בדיוק כמו שהתוסף פונה אליו.
class _Client {
  _Client(this.port);

  final int port;
  final _http = HttpClient();

  Future<({int status, Map<String, Object?> json})> request(
    String method,
    String path, {
    Object? body,
  }) async {
    final request = await _http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (
      status: response.statusCode,
      json: jsonDecode(text) as Map<String, Object?>,
    );
  }

  void close() => _http.close(force: true);
}

void main() {
  late TempConfig temp;
  late CompanionConfig config;
  late FakeTransport transport;
  late SyncHub hub;
  late LocalApi api;
  late _Client client;
  late FakeReg reg;

  setUp(() async {
    temp = await TempConfig.create();
    config = temp.config(roomCode: 'חדר');
    transport = FakeTransport();
    hub = SyncHub(config: config, transport: transport);

    // exe מדומה בתיקייה הזמנית, כדי ש-/startup ייחשב נתמך בבדיקה בלי
    // לגעת ברישום האמיתי של מריץ הבדיקות.
    final exe = '${temp.dir.path}${Platform.pathSeparator}$companionExeName';
    await File(exe).writeAsString('exe');
    reg = FakeReg();

    api = LocalApi(
      hub: hub,
      version: '9.9.9',
      startup: StartupRegistration(
        runReg: reg.run,
        executable: exe,
        isWindows: true,
      ),
    );

    if (!await api.start()) {
      // כל הפורטים בטווח תפוסים — כנראה מתאם אמיתי שרץ על המכונה.
      markTestSkipped('אין פורט פנוי בטווח ה-API המקומי');
      return;
    }
    client = _Client(api.port!);
  });

  tearDown(() async {
    client.close();
    await api.dispose();
    await hub.dispose();
    await temp.delete();
  });

  test('השרת מאזין ב-loopback בלבד ובטווח הפורטים המוסכם', () {
    expect(api.port, greaterThanOrEqualTo(localApiFirstPort));
    expect(api.port, lessThanOrEqualTo(localApiLastPort));
  });

  test('GET /hello מזהה את המתאם ומחזיר את המצב', () async {
    final response = await client.request('GET', '/hello');
    expect(response.status, HttpStatus.ok);
    expect(response.json['app'], 'chavruta-companion');
    expect(response.json['version'], '9.9.9');
    expect(response.json['port'], api.port);
    expect(response.json['paired'], isTrue);
    expect(response.json['deviceId'], config.deviceId);
  });

  test('נתיב לא מוכר מחזיר 404 ולא קורס', () async {
    final response = await client.request('GET', '/nope');
    expect(response.status, HttpStatus.notFound);
    expect(response.json['error'], isNotNull);
  });

  group('POST /publish', () {
    test('מיקום תקין משודר לחברותא', () async {
      final response = await client.request(
        'POST',
        '/publish',
        body: {'bookId': 'ברכות', 'index': 12, 'ref': 'ברכות דף ד'},
      );
      expect(response.status, HttpStatus.ok);
      expect(response.json['broadcast'], isTrue);
      expect(transport.sent, hasLength(1));
      expect(transport.sent.single.location!.bookId, 'ברכות');
    });

    test('גוף בקשה חסר מוחזר כשגיאת קלט', () async {
      final response = await client.request(
        'POST',
        '/publish',
        body: {'index': 12},
      );
      expect(response.status, HttpStatus.badRequest);
      expect(transport.sent, isEmpty);
    });
  });

  group('POST /room', () {
    test('זיווג שומר את הקוד המנורמל', () async {
      config.roomCode = null;
      final response = await client.request(
        'POST',
        '/room',
        body: {'code': '  דף   יומי  '},
      );
      expect(response.status, HttpStatus.ok);
      expect(response.json['paired'], isTrue);
      expect(config.roomCode, 'דף יומי');
    });

    test('קוד null מוציא מהחברותא', () async {
      final response = await client.request('POST', '/room', body: {'code': null});
      expect(response.status, HttpStatus.ok);
      expect(response.json['paired'], isFalse);
    });

    test('קוד שאינו מחרוזת נדחה', () async {
      final response = await client.request('POST', '/room', body: {'code': 7});
      expect(response.status, HttpStatus.badRequest);
      expect(config.roomCode, 'חדר');
    });
  });

  group('POST /name', () {
    test('שם חדש נשמר', () async {
      final response = await client.request(
        'POST',
        '/name',
        body: {'name': 'המחשב של אמא'},
      );
      expect(response.status, HttpStatus.ok);
      expect(response.json['deviceName'], 'המחשב של אמא');
    });

    test('שם שאינו מחרוזת נדחה', () async {
      final response = await client.request('POST', '/name', body: {'name': 5});
      expect(response.status, HttpStatus.badRequest);
    });
  });

  group('GET /events', () {
    test('עדכון שממתין מוחזר מיד', () async {
      await transport.deliver(
        SyncMessage(
          type: SyncMessageType.location,
          roomHash: SyncMessage.hashRoomCode('חדר'),
          senderId: '11223344',
          senderName: 'החברותא',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          sequence: 1,
          location: const SyncLocation(bookId: 'ברכות', index: 12),
        ),
      );

      final response = await client.request('GET', '/events?since=-1');
      expect(response.json['hasUpdate'], isTrue);
      final remote = response.json['remote'] as Map;
      expect((remote['location'] as Map)['bookId'], 'ברכות');
    });

    test('בלי מיקום מרוחק אין עדכון, גם כשהמונה גדול מ-since', () async {
      // התוסף שואל since=-1 בעלייה. בלי הבדיקה הזאת הוא היה מקבל
      // hasUpdate על מונה שהתקדם בלי מיקום כלל.
      await hub.setRoom('חדר אחר');
      expect(hub.remoteSequence, greaterThan(-1));

      final response = await client.request('GET', '/events?since=-1');
      expect(response.json['hasUpdate'], isFalse);
      expect(response.json['remote'], isNull);
    });

    test('עדכון שנמסר לתוסף חוסם את ההד שיחזור ממנו', () async {
      await transport.deliver(
        SyncMessage(
          type: SyncMessageType.location,
          roomHash: SyncMessage.hashRoomCode('חדר'),
          senderId: '11223344',
          senderName: 'החברותא',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          sequence: 1,
          location: const SyncLocation(bookId: 'ברכות', index: 12),
        ),
      );
      await client.request('GET', '/events?since=-1');

      // התוסף ניווט, ועכשיו הוא מדווח על אותו מיקום בדיוק.
      final published = await client.request(
        'POST',
        '/publish',
        body: {'bookId': 'ברכות', 'index': 12},
      );
      expect(published.json['broadcast'], isFalse);
      expect(transport.sent, isEmpty);
    });

    test('בקשה שממתינה משתחררת ברגע שמגיע עדכון', () async {
      final pending = client.request('GET', '/events?since=0');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await transport.deliver(
        SyncMessage(
          type: SyncMessageType.location,
          roomHash: SyncMessage.hashRoomCode('חדר'),
          senderId: '11223344',
          senderName: 'החברותא',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          sequence: 1,
          location: const SyncLocation(bookId: 'שבת', index: 3),
        ),
      );

      final response = await pending.timeout(const Duration(seconds: 5));
      expect(response.json['hasUpdate'], isTrue);
      expect(response.json['remoteSequence'], 1);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('/startup', () {
    test('קורא ומחליף את העלייה עם המחשב', () async {
      final initial = await client.request('GET', '/startup');
      expect(initial.json['supported'], isTrue);
      expect(initial.json['enabled'], isFalse);

      final on = await client.request(
        'POST',
        '/startup',
        body: {'enabled': true},
      );
      expect(on.json['enabled'], isTrue);
      expect(reg.value, isNotNull);

      final off = await client.request(
        'POST',
        '/startup',
        body: {'enabled': false},
      );
      expect(off.json['enabled'], isFalse);
      expect(reg.value, isNull);
    });

    test('בלי enabled בוליאני נדחה', () async {
      final response = await client.request(
        'POST',
        '/startup',
        body: {'enabled': 'yes'},
      );
      expect(response.status, 400);
      expect(reg.calls, isEmpty);
    });
  });
}
