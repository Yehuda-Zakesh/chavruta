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
    List<int>? rawBody,
    Map<String, String>? headers,
  }) async {
    final request = await _http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    headers?.forEach(request.headers.set);
    if (rawBody != null) {
      request.headers.contentType = ContentType.json;
      request.contentLength = rawBody.length;
      request.add(rawBody);
    } else if (body != null) {
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

    test('גוף חסר אינו מוציא מהחברותא', () async {
      // בקשה שנקטעה, או לקוח שגוי, אינם "יציאה מהחברותא". רק `code: null`
      // מפורש מוציא — אחרת המשתמש היה מנותק בלי שביקש ובלי שידע.
      final response = await client.request('POST', '/room');
      expect(response.status, HttpStatus.badRequest);
      expect(config.roomCode, 'חדר');
    });

    test('גוף ריק מ-code אינו מוציא מהחברותא', () async {
      final response = await client.request('POST', '/room', body: {});
      expect(response.status, HttpStatus.badRequest);
      expect(config.roomCode, 'חדר');
    });

    test('גוף שאינו UTF-8 תקין מוחזר כשגיאת קלט ולא כשגיאת שרת', () async {
      // 0xC3 פותח רצף דו-בייטי שאין לו המשך; utf8.decoder זורק עליו.
      final response = await client.request(
        'POST',
        '/room',
        rawBody: [0x7b, 0x22, 0xc3],
      );
      expect(response.status, HttpStatus.badRequest);
      expect(config.roomCode, 'חדר');
    });
  });

  group('דחיית פניות מדפדפן', () {
    // דף אינטרנט אינו יכול לקרוא את התשובה, אבל בקשת POST פשוטה יוצאת
    // ממנו בלי preflight — והפעולה הייתה מתבצעת. הכותרות האלה נקבעות
    // בידי הדפדפן וקוד בדף אינו יכול להסיר אותן.
    for (final header in browserOnlyHeaders) {
      test('$header חוסמת גם את /hello', () async {
        final response = await client.request(
          'GET',
          '/hello',
          headers: {header: 'https://example.com'},
        );
        expect(response.status, HttpStatus.forbidden);
      });
    }

    test('POST מדף אינטרנט אינו מוציא מהחברותא', () async {
      final response = await client.request(
        'POST',
        '/room',
        body: {'code': null},
        headers: {'origin': 'https://example.com'},
      );
      expect(response.status, HttpStatus.forbidden);
      expect(config.roomCode, 'חדר');
    });

    test('בקשה רגילה, בלי הכותרות האלה, ממשיכה לעבוד', () async {
      final response = await client.request('GET', '/hello');
      expect(response.status, HttpStatus.ok);
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
      // הודעת הנוכחות שנשלחת בתגובה למחובר חדש היא בסדר; מה שאסור לצאת
      // הוא עדכון מיקום, שהיה מחזיר לחברותא את מה שהיא עצמה ביקשה.
      expect(
        transport.sent.where((m) => m.type == SyncMessageType.location),
        isEmpty,
      );
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

    test('מופע שאינו מחזיק המנוע חוזר מיד, ובלי עדכון', () async {
      // חשוב שיחזור *מיד*: אחרת שני מופעי התוסף היו מחזיקים שתי בקשות
      // פתוחות, והמופע הלא-נכון היה מקבל את העדכון ומנווט.
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

      final owner = await client.request(
        'GET',
        '/events?since=-1&instance=background:x',
      );
      expect(owner.json['engineMine'], isTrue);
      expect(owner.json['hasUpdate'], isTrue);

      final other = await client
          .request('GET', '/events?since=-1&instance=foreground:a')
          .timeout(const Duration(seconds: 5));
      expect(other.json['engineMine'], isFalse);
      expect(other.json['hasUpdate'], isFalse);
      expect((other.json['engine'] as Map)['owner'], 'background:x');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('החזקה שנחטפה באמצע ההמתנה מוחזרת כ-engineMine: false', () async {
      // ההמתנה כאן היא 25 שניות, ובתוכה מופע הרקע עולה ולוקח את המנוע.
      // תשובה שאומרת לממתין "ההחזקה שלך" בכל מקרה הייתה משאירה שני מופעים
      // שמדווחים ומנווטים במקביל — וזה בדיוק מה שההחזקה באה למנוע.
      await client.request('GET', '/events?since=-1&instance=foreground:a');
      final pending = client.request(
        'GET',
        '/events?since=0&instance=foreground:a',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(hub.claimEngine('background:x'), isTrue);

      // וגם נענה מיד ולא בתום 25 השניות: חטיפת ההחזקה מעירה את הממתין.
      final response = await pending.timeout(const Duration(seconds: 5));
      expect(response.json['engineMine'], isFalse);
      expect(response.json['hasUpdate'], isFalse);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('שחרור אינו מתבטל מהבקשה התלויה של המשחרר עצמו', () async {
      // מופע שנסגר משחרר את ההחזקה, אבל ההמתנה הארוכה שלו עדיין תלויה —
      // והשחרור עצמו מעיר אותה. בקשה שהייתה *רוכשת* את ההחזקה מחדש בסופה
      // הייתה מחזירה אותה למופע שכבר אינו קיים, ואז אף אחד לא מסנכרן.
      await client.request('GET', '/events?since=-1&instance=background:x');
      final pending = client.request(
        'GET',
        '/events?since=0&instance=background:x',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await client.request(
        'POST',
        '/engine/release',
        body: {'instance': 'background:x'},
      );
      final response = await pending.timeout(const Duration(seconds: 5));
      expect(response.json['engineMine'], isFalse);

      final hello = await client.request('GET', '/hello');
      expect((hello.json['engine'] as Map)['owner'], isNull);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('מופע שרק קיבל את ההחזקה נענה מיד', () async {
      // `since=0` והמונה על 0 — בקשה שבמצב רגיל ממתינה 25 שניות. מופע שרק
      // עכשיו קיבל את ההחזקה חייב לדעת זאת מיד, אחרת הוא מחזיק את המנוע
      // ובכל זאת אינו מאזין לשינויי מקום ואינו מדווח כלום.
      await client.request('GET', '/events?since=-1&instance=background:x');
      await client.request(
        'POST',
        '/engine/release',
        body: {'instance': 'background:x'},
      );

      final response = await client
          .request('GET', '/events?since=0&instance=foreground:a')
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('הבקשה נכנסה להמתנה ארוכה במקום להיענות מיד'),
          );
      expect(response.json['engineMine'], isTrue);
      expect((response.json['engine'] as Map)['owner'], 'foreground:a');
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('בלי instance הבקשה עובדת כמו קודם', () async {
      // curl ובדיקות ידניות, וגם תוסף מגרסה קודמת. מזהה ריק אינו לוקח את
      // ההחזקה ואינו נחסם על ידה, ולכן `owner` נשאר ריק.
      final response = await client.request('GET', '/events?since=-1');
      expect(response.json['engineMine'], isTrue);
      expect((response.json['engine'] as Map)['owner'], isNull);
    });
  });

  group('POST /engine/release', () {
    test('שחרור מפנה את ההחזקה למופע הבא', () async {
      await client.request('GET', '/events?since=-1&instance=background:x');
      final blocked = await client.request(
        'GET',
        '/events?since=-1&instance=foreground:a',
      );
      expect(blocked.json['engineMine'], isFalse);

      final released = await client.request(
        'POST',
        '/engine/release',
        body: {'instance': 'background:x'},
      );
      expect((released.json['engine'] as Map)['owner'], isNull);

      final taken = await client.request(
        'GET',
        '/events?since=-1&instance=foreground:a',
      );
      expect(taken.json['engineMine'], isTrue);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('בלי instance נדחה', () async {
      final response = await client.request('POST', '/engine/release', body: {});
      expect(response.status, 400);
    });
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

  group('השולחן המשותף', () {
    /// דיווח ראשון קובע קו בסיס ואינו משתף כלום — ראו `_sawFirstReport`.
    Future<({int status, Map<String, Object?> json})> baseline(
      List<Map<String, Object?>> tabs,
    ) =>
        client.request('POST', '/tabs', body: {
          'instance': 'background:x',
          'tabs': tabs,
          'canClose': true,
        });

    test('POST /tabs בלי מערך נדחה', () async {
      final response = await client.request('POST', '/tabs', body: {
        'tabs': 'ברכות',
      });
      expect(response.status, HttpStatus.badRequest);
    });

    test('POST /tabs עם מערך ריק הוא דיווח תקין', () async {
      final response = await client.request('POST', '/tabs', body: {'tabs': []});
      expect(response.status, HttpStatus.ok);
      expect(response.json['localTabCount'], 0);
    });

    test('הדיווח הראשון מציע להעביר, והשני משתף מה שנפתח', () async {
      final first = await baseline([
        {'b': 'ברכות', 'i': 4},
      ]);
      expect(first.json['broadcast'], 0, reason: 'השולחן מתחיל ריק');
      expect(
        (first.json['carryCandidates'] as List).map((e) => (e as Map)['b']),
        ['ברכות'],
      );

      final second = await client.request('POST', '/tabs', body: {
        'tabs': [
          {'b': 'ברכות', 'i': 4},
          {'b': 'שבת'},
        ],
        'canClose': true,
      });
      expect(second.json['broadcast'], 1, reason: 'רק מה שנפתח עכשיו');
      expect(second.json['deskCount'], 1);
    });

    test('POST /desk/carry מעביר לשולחן המשותף', () async {
      await baseline([
        {'b': 'ברכות'},
        {'b': 'שבת'},
      ]);

      final response = await client.request('POST', '/desk/carry', body: {
        'bookIds': ['ברכות'],
      });
      expect(response.status, HttpStatus.ok);
      expect(response.json['carried'], 1);
      expect(response.json['deskCount'], 1);
      expect(
        (response.json['carryCandidates'] as List).map((e) => (e as Map)['b']),
        ['שבת'],
      );
    });

    test('POST /desk/carry בלי מערך נדחה', () async {
      final response = await client.request('POST', '/desk/carry', body: {
        'bookIds': 'ברכות',
      });
      expect(response.status, HttpStatus.badRequest);
    });

    test('POST /desk/dismiss דורש שם ספר', () async {
      final response = await client.request('POST', '/desk/dismiss', body: {});
      expect(response.status, HttpStatus.badRequest);
    });

    test('POST /settings שומר את שתי ההעדפות', () async {
      final off = await client.request('POST', '/settings', body: {
        'syncLocation': false,
        'closePolicy': 'always',
      });
      expect(off.json['syncLocation'], isFalse);
      expect(off.json['closePolicy'], 'always');
      expect(config.syncLocation, isFalse, reason: 'נשמר גם בקונפיג');
      expect(config.closePolicy, ClosePolicy.always);
    });

    test('POST /settings דוחה ערכים שאינם מוכרים', () async {
      final badPolicy = await client.request('POST', '/settings', body: {
        'closePolicy': 'אולי',
      });
      expect(badPolicy.status, HttpStatus.badRequest);

      final badToggle = await client.request('POST', '/settings', body: {
        'syncLocation': 'כן',
      });
      expect(badToggle.status, HttpStatus.badRequest);

      // ערך פסול אינו נבלע בשקט לברירת המחדל.
      expect(config.closePolicy, ClosePolicy.ask);
      expect(config.syncLocation, isTrue);
    });

    test('GET /events מוסר את תוכנית השולחן', () async {
      await baseline(const []);
      await transport.deliver(SyncMessage(
        type: SyncMessageType.desk,
        roomHash: SyncMessage.hashRoomCode('חדר'),
        senderId: 'חברותא',
        senderName: 'החברותא',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        sequence: 1,
        entries: [
          DeskEntry(
            bookId: 'שבת',
            index: 3,
            stamp: DateTime.now().millisecondsSinceEpoch,
            by: 'חברותא',
          ),
        ],
      ));

      final response = await client.request(
        'GET',
        '/events?since=999&instance=background:x',
      );
      final desk = response.json['desk'] as Map;
      final toOpen = desk['open'] as List;
      expect(toOpen, hasLength(1));
      expect((toOpen.first as Map)['b'], 'שבת');
      expect((toOpen.first as Map)['i'], 3);
      expect(desk['close'], isEmpty);
    });
  });
}
