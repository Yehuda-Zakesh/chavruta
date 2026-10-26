import 'dart:io';

import 'package:chavruta_android/companion_runner.dart';
import 'package:chavruta_companion/protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// בדיקות השינה וההתעוררות, על סוקטים אמיתיים בטווח הפורטים של התוסף.
///
/// הטווח 45871–45875 קבוע בפרוטוקול ומשותף עם התוסף, ולכן הבדיקות דורשות
/// שהוא יהיה פנוי — מתאם שרץ ברקע על המחשב יכשיל אותן כבר ב-`setUp`.
/// ערוץ ה-Native (`chavruta/native`) מדומה: אין שירות ואין התראה.
final List<int> rangePorts = [
  for (var p = localApiFirstPort; p <= localApiLastPort; p++) p,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ה-binding מחליף את HttpClient בלקוח שעונה 400 לכל בקשה; כאן צריך
  // חיבורים אמיתיים, כמו של התוסף.
  HttpOverrides.global = null;
  const channel = MethodChannel('chavruta/native');

  late Directory dataDir;
  late List<String> nativeCalls;
  late bool launchedAtBoot;
  late List<ServerSocket> occupied;
  late List<CompanionRunner> runners;

  setUp(() async {
    for (final p in rangePorts) {
      expect(
        await portFree(p),
        isTrue,
        reason: 'פורט $p תפוס — מתאם חברותא רץ ברקע? יש לסגור אותו',
      );
    }
    dataDir = await Directory.systemTemp.createTemp('chavruta_runner_');
    nativeCalls = [];
    launchedAtBoot = true;
    occupied = [];
    runners = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      return switch (call.method) {
        'filesDir' => dataDir.path,
        'deviceName' => 'טלפון בדיקה',
        'launchedAtBoot' => launchedAtBoot,
        _ => null,
      };
    });
  });

  tearDown(() async {
    for (final runner in runners) {
      await runner.stop();
    }
    for (final socket in occupied) {
      await socket.close();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      await dataDir.delete(recursive: true);
    } catch (_) {
      // קובץ היומן עדיין פתוח ב-Windows — לא חשוב לבדיקה.
    }
  });

  CompanionRunner newRunner({
    Future<HttpServer> Function(int port)? bindDoorbell,
  }) {
    final runner = CompanionRunner(
      transportPort: 0,
      retryInterval: const Duration(milliseconds: 200),
      bindDoorbell: bindDoorbell,
    );
    runners.add(runner);
    return runner;
  }

  /// תופס פורטים כמו שירות זר: מקבל חיבור וסוגר אותו מיד, כך שהסריקה של
  /// התוסף נכשלת עליו וממשיכה הלאה.
  Future<void> occupy(Iterable<int> ports) async {
    for (final p in ports) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
      socket.listen((connection) => connection.destroy());
      occupied.add(socket);
    }
  }

  Future<void> release(int port) async {
    final socket = occupied.firstWhere((s) => s.port == port);
    occupied.remove(socket);
    await socket.close();
  }

  /// מצב פעיל אמיתי: המצב, ה-API עונה ל-`/hello` וה-hub מחזיר מצב.
  Future<void> expectActive(CompanionRunner runner, int port) async {
    expect(runner.state, CompanionState.active);
    expect(runner.port, port);
    expect(runner.doorbellPort, isNull);
    expect(runner.snapshot(), isNotNull);
    expect(await hello(port), HttpStatus.ok);
  }

  /// שינה עם פעמון: הפורט תפוס בפועל, ואין מתאם שעונה באף פורט אחר.
  /// (לא פונים לפעמון עצמו — פנייה אליו מעירה.)
  Future<void> expectDormantOn(CompanionRunner runner, int port) async {
    expect(runner.state, CompanionState.dormant);
    expect(runner.doorbellPort, port);
    expect(runner.snapshot(), isNull);
    expect(runner.retryPending, isFalse);
    expect(await portFree(port), isFalse, reason: 'הפעמון מאזין על $port');
    for (final p in rangePorts.where((p) => p != port)) {
      // בפורט פנוי אין מתאם; וחיבור אליו ב-Windows נכשל רק אחרי כ-2 שניות.
      if (await portFree(p)) continue;
      expect(await helloOrNull(p), isNot(HttpStatus.ok), reason: 'פורט $p');
    }
  }

  test('שינה והתעוררות רגילות: אותה סריקה של התוסף מוצאת את המתאם', () async {
    final runner = newRunner();
    await runner.boot();
    await expectDormantOn(runner, 45871);

    // הפעמון עונה 503, והסריקה ממשיכה לפורט הבא — שכבר ער.
    expect(await scan(), (port: 45872, trail: '503 200'));
    await expectActive(runner, 45872);
    expect(await portFree(45871), isTrue, reason: 'הפעמון נסגר');

    await runner.sleepNow();
    await expectDormantOn(runner, 45871);
    expect(await portFree(45872), isTrue, reason: 'ה-API נסגר בשינה');

    expect(await scan(), (port: 45872, trail: '503 200'));
    await expectActive(runner, 45872);
    expect(nativeCalls, isNot(contains('stopService')));
  });

  test('ארבעה פורטים תפוסים: המתאם מתעורר על הפורט של הפעמון', () async {
    await occupy([45871, 45872, 45873, 45874]);
    final runner = newRunner();
    await runner.boot();
    await expectDormantOn(runner, 45875);

    // הסריקה הראשונה מצלצלת ולא מוצאת (הפעמון היה האחרון בטווח), ובלי
    // להיתקע: הפנייה לפעמון מקבלת תשובה גם כשהוא מפנה את הפורט שלו.
    final watch = Stopwatch()..start();
    expect(await scan(), (port: null, trail: '- - - - 503'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    await settle(runner);
    // הסריקה הבאה מוצאת את המתאם על אותו פורט.
    expect(
      await scan(),
      (port: 45875, trail: '- - - - 200'),
    );
    await expectActive(runner, 45875);
    expect(runner.startError, isNull);
    expect(nativeCalls, isNot(contains('stopService')));
  });

  test('כשהפעמון לא נפתח אחרי סגירת המתאם — המתאם עולה שוב באמת', () async {
    var failDoorbell = false;
    final runner = newRunner(
      bindDoorbell: (port) async {
        if (failDoorbell) throw SocketException('בדיקה: אין פעמון', port: port);
        return HttpServer.bind(InternetAddress.loopbackIPv4, port);
      },
    );
    launchedAtBoot = false;
    await runner.boot();
    await expectActive(runner, 45871);

    failDoorbell = true;
    await runner.sleepNow();
    // קודם: `active` בלי API ובלי hub, כי `_activate` חזרה מיד.
    await expectActive(runner, 45871);
    expect(runner.retryPending, isFalse);
  });

  test('הפעמון והמתאם נכשלים שניהם — שינה עם ניסיון חוזר, והתאוששות',
      () async {
    var failDoorbell = false;
    final runner = newRunner(
      bindDoorbell: (port) async {
        if (failDoorbell) {
          // ברגע שבין סגירת המתאם לפתיחת הפעמון, מישהו תופס את כל הטווח.
          for (final p in rangePorts) {
            if (await portFree(p)) await occupy([p]);
          }
          throw SocketException('בדיקה: אין פעמון', port: port);
        }
        return HttpServer.bind(InternetAddress.loopbackIPv4, port);
      },
    );
    launchedAtBoot = false;
    await runner.boot();
    await expectActive(runner, 45871);

    failDoorbell = true;
    await runner.sleepNow();
    expect(runner.state, CompanionState.dormant);
    expect(runner.snapshot(), isNull);
    expect(runner.port, isNull);
    expect(runner.running, isTrue);
    expect(runner.retryPending, isTrue);
    expect(nativeCalls, isNot(contains('stopService')));

    // בלי פעמון ובלי מתאם: סריקה לא מוצאת ולא מעירה דבר.
    expect(await scan(), (port: null, trail: '- - - - -'));

    failDoorbell = false;
    await release(45873);
    await waitFor(() => runner.doorbellPort != null);
    await expectDormantOn(runner, 45873);

    expect(await scan(), (port: null, trail: '- - 503 - -'));
    await settle(runner);
    expect(await scan(), (port: 45873, trail: '- - 200'));
    await expectActive(runner, 45873);
  });

  test('כל הטווח תפוס בהפעלה — לא כבה; מתאושש כשפורט מתפנה', () async {
    await occupy(rangePorts);
    final runner = newRunner();
    launchedAtBoot = false;
    await runner.boot();
    expect(runner.state, CompanionState.dormant);
    expect(runner.running, isTrue);
    expect(runner.doorbellPort, isNull);
    expect(runner.retryPending, isTrue);
    expect(runner.startError, isNotNull);
    expect(nativeCalls, isNot(contains('stopService')));

    // עוד סבב ניסיון בלי פורט — עדיין ממתין, לא כבה.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await settle(runner);
    expect(runner.state, CompanionState.dormant);
    expect(runner.retryPending, isTrue);

    expect(await scan(), (port: null, trail: '- - - - -'));

    await release(45872);
    await waitFor(() => runner.doorbellPort != null);
    await expectDormantOn(runner, 45872);

    expect(await scan(), (port: null, trail: '- 503 - - -'));
    await settle(runner);
    expect(await scan(), (port: 45872, trail: '- 200'));
    await expectActive(runner, 45872);
  });

  group('עצירה במקביל להתעוררות', () {
    Future<void> expectFullyStopped(CompanionRunner runner) async {
      expect(runner.state, CompanionState.stopped);
      expect(runner.port, isNull);
      expect(runner.doorbellPort, isNull);
      expect(runner.snapshot(), isNull);
      expect(runner.retryPending, isFalse);
      expect(nativeCalls, contains('stopService'));
      for (final p in rangePorts) {
        expect(await portFree(p), isTrue, reason: 'פורט $p נשאר פתוח');
      }
    }

    test('עצירה שנכנסה לתור לפני ההתעוררות — הצלצול אינו מעיר', () async {
      final runner = newRunner();
      await runner.boot();
      await expectDormantOn(runner, 45871);

      Future<void>? stopping;
      void onLog() {
        if (stopping == null && runner.lines.last.contains('מתעורר')) {
          stopping = runner.stop();
        }
      }

      runner.addListener(onLog);
      final ring = helloOrNull(45871);
      await waitFor(() => stopping != null);
      await stopping;
      expect(await ring, HttpStatus.serviceUnavailable,
          reason: 'הפנייה שצלצלה מקבלת תשובה גם כשהמתאם נעצר');
      await settle(runner);
      runner.removeListener(onLog);
      await expectFullyStopped(runner);
    });

    test('עצירה באמצע ההתעוררות — סוגרת את מה שעלה', () async {
      final runner = newRunner();
      await runner.boot();

      Future<void>? stopping;
      void onLog() {
        if (stopping == null &&
            runner.lines.last.contains('local API listening')) {
          stopping = runner.stop();
        }
      }

      runner.addListener(onLog);
      final ring = helloOrNull(45871);
      await waitFor(() => stopping != null);
      await stopping;
      expect(await ring, HttpStatus.serviceUnavailable,
          reason: 'הפנייה שצלצלה מקבלת תשובה גם כשהמתאם נעצר');
      await settle(runner);
      runner.removeListener(onLog);
      await expectFullyStopped(runner);
    });

    test('עצירה כשממתין ניסיון חוזר — הניסיון אינו פותח פעמון', () async {
      await occupy(rangePorts);
      final runner = newRunner();
      launchedAtBoot = false;
      await runner.boot();
      expect(runner.retryPending, isTrue);
      await runner.stop();
      for (final socket in occupied) {
        await socket.close();
      }
      occupied.clear();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await settle(runner);
      await expectFullyStopped(runner);
    });
  });
}

Future<bool> portFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// `GET /hello` כמו בסריקה של התוסף. מחזיר את קוד התשובה.
Future<int> hello(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client.get('127.0.0.1', port, '/hello');
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// הסריקה של התוסף: `/hello` על הטווח לפי הסדר, ממשיכה אחרי כל תשובה
/// שאינה 200 ואחרי חיבור שנכשל, ועוצרת במתאם הראשון שעונה.
/// `trail` = מה ענה כל פורט שנבדק, `-` לחיבור שנכשל.
Future<({int? port, String trail})> scan() async {
  final trail = <String>[];
  for (final p in rangePorts) {
    final status = await helloOrNull(p);
    trail.add(status?.toString() ?? '-');
    if (status == HttpStatus.ok) return (port: p, trail: trail.join(' '));
  }
  return (port: null, trail: trail.join(' '));
}

Future<int?> helloOrNull(int port) async {
  try {
    return await hello(port);
  } on Object {
    return null;
  }
}

/// ממתין שכל מעבר המצבים שבתור יסתיים.
Future<void> settle(CompanionRunner runner) =>
    waitFor(() => !runner.busy, timeout: const Duration(seconds: 10));

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('התנאי לא התקיים בתוך $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
