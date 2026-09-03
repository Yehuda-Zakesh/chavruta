import 'dart:io';

import 'package:chavruta_companion/lan_transport.dart';
import 'package:chavruta_companion/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('broadcastAddressForIPv4', () {
    test('כתובת link-local היא /16 — חיבור ישיר בכבל בין שני מחשבים', () {
      // בלי ראוטר אין DHCP, ו-Windows נותן 169.254.x.x. ב-/24 שגוי
      // ה-broadcast לא היה מגיע לצד השני של הכבל.
      expect(
        LanTransport.broadcastAddressForIPv4('169.254.3.7'),
        '169.254.255.255',
      );
      expect(
        LanTransport.broadcastAddressForIPv4('169.254.200.1'),
        '169.254.255.255',
      );
    });

    test('רשת ביתית רגילה היא /24', () {
      expect(
        LanTransport.broadcastAddressForIPv4('192.168.1.5'),
        '192.168.1.255',
      );
      expect(LanTransport.broadcastAddressForIPv4('10.0.0.8'), '10.0.0.255');
      expect(
        LanTransport.broadcastAddressForIPv4('172.16.31.90'),
        '172.16.31.255',
      );
    });

    test('נקודה חמה של Windows (192.168.137.x) עובדת כרשת רגילה', () {
      expect(
        LanTransport.broadcastAddressForIPv4('192.168.137.1'),
        '192.168.137.255',
      );
    });

    test('כתובת לא תקינה מוחזרת כ-null ולא מפילה את השידור', () {
      expect(LanTransport.broadcastAddressForIPv4(''), isNull);
      expect(LanTransport.broadcastAddressForIPv4('192.168.1'), isNull);
      expect(LanTransport.broadcastAddressForIPv4('192.168.1.5.6'), isNull);
      expect(LanTransport.broadcastAddressForIPv4('192.168.1.999'), isNull);
      expect(LanTransport.broadcastAddressForIPv4('192.168.a.5'), isNull);
      expect(LanTransport.broadcastAddressForIPv4('fe80::1'), isNull);
    });
  });

  group('broadcastRoutesFor', () {
    test('רשת רגילה — ה-broadcast המכוון, מכתובת הכרטיס', () {
      expect(LanTransport.broadcastRoutesFor(['192.168.1.7']), [
        (local: '192.168.1.7', broadcast: '192.168.1.255'),
      ]);
    });

    test('255.255.255.255 אינו מסלול בפני עצמו', () {
      // הכתובת הגלובלית **כן** משודרת — ראו [globalBroadcast] ואת `send`,
      // שמוציא אותה מהסוקט הקשור לכל כרטיס. מה שהיא אינה הוא *מסלול*:
      // מסלול פירושו כרטיס, ולא יעד. אילו הייתה נכנסת לכאן כשורה משלה,
      // היה נפתח עבורה סוקט שאינו קשור לאף כרטיס — וזה בדיוק המסלול
      // שדרכו מחשב בלי מסלול ברירת מחדל היה מקבל "אין מסלול" ומאבד את
      // הסוקט בלופ.
      for (final addresses in [
        ['192.168.1.7'],
        ['169.254.10.2'],
        ['192.168.1.7', '169.254.10.2', '10.0.0.5'],
      ]) {
        expect(
          LanTransport.broadcastRoutesFor(addresses).map((r) => r.broadcast),
          isNot(contains('255.255.255.255')),
          reason: 'עבור $addresses',
        );
      }
    });

    test('כמה כרטיסים — כל אחד משדר מעצמו אל הרשת שלו', () {
      expect(
        LanTransport.broadcastRoutesFor(['192.168.1.7', '192.168.137.1']),
        [
          (local: '192.168.1.7', broadcast: '192.168.1.255'),
          (local: '192.168.137.1', broadcast: '192.168.137.255'),
        ],
      );
    });

    test('link-local נכללת גם כשיש רשת אמיתית', () {
      // זה חיבור ישיר בין שני מחשבים (כבל, Bluetooth PAN, Wi-Fi Direct)
      // במקביל ל-Wi-Fi. זריקתה כאן הייתה מבטלת אותו, כלומר הופכת את
      // הסנכרון לתלוי ראוטר. שידור אליה אינו מפיל את הסוקט — לכרטיסים
      // האלה יש מסלול on-link.
      final routes = LanTransport.broadcastRoutesFor([
        '192.168.1.7',
        '169.254.10.2',
      ]);
      expect(routes, contains((local: '192.168.1.7', broadcast: '192.168.1.255')));
      expect(
        routes,
        contains((local: '169.254.10.2', broadcast: '169.254.255.255')),
      );
    });

    test('link-local לבדה — חיבור בלי ראוטר כלל', () {
      expect(LanTransport.broadcastRoutesFor(['169.254.10.2']), [
        (local: '169.254.10.2', broadcast: '169.254.255.255'),
      ]);
    });

    test('כמה כרטיסים על אותה רשת link-local — כל אחד מסלול לעצמו', () {
      // זה בדיוק המצב האופליין ב-Windows: Wi-Fi Direct וירטואלי, עוד אחד,
      // ו-Bluetooth PAN — שלושתם ב-169.254/16. מסלול אחד היה יוצא דרך
      // אחד מהם בלבד, ולא דווקא זה שהחברותא נמצאת בצדו.
      expect(
        LanTransport.broadcastRoutesFor([
          '169.254.156.84',
          '169.254.227.62',
          '169.254.73.204',
        ]),
        [
          (local: '169.254.156.84', broadcast: '169.254.255.255'),
          (local: '169.254.227.62', broadcast: '169.254.255.255'),
          (local: '169.254.73.204', broadcast: '169.254.255.255'),
        ],
      );
    });

    test('אותה כתובת פעמיים אינה מסלול כפול', () {
      expect(
        LanTransport.broadcastRoutesFor(['192.168.1.7', '192.168.1.7']),
        [(local: '192.168.1.7', broadcast: '192.168.1.255')],
      );
    });

    test('בלי כרטיס רשת אין מסלולים בכלל', () {
      // אין כרטיס — אין סוקט לשדר ממנו, וגם לא אל 255.255.255.255. זה מה
      // שמונע את השליחה שהפילה את הסוקט על מחשב מנותק.
      expect(LanTransport.broadcastRoutesFor(const []), isEmpty);
      expect(LanTransport.broadcastRoutesFor(['לא כתובת']), isEmpty);
    });
  });

  group('מוני האבחון', () {
    test('עולים מאופסים', () async {
      final transport = LanTransport(roomCodeProvider: () => 'בדיקה', port: 0);
      expect(await transport.start(), isTrue);

      expect(transport.datagramsReceived, 0);
      expect(transport.datagramsFromOthers, 0);
      expect(transport.datagramsRejected, 0);
      expect(transport.lastRemoteSource, isNull);

      await transport.dispose();
    });

    test('דטגרמה נספרת, ומהמחשב הזה אינה נחשבת "ממחשב אחר"', () async {
      // פורט 0 ו-unicast אל ה-loopback, ולא הפורט האמיתי ו-broadcast.
      // שתי הבחירות נובעות מאותו כישלון: הבדיקה הראשונה כאן נשענה על כך
      // ש-broadcast חוזר אל השולח — נכון על מחשב אמיתי, וזה הבסיס לכל
      // האבחון — אבל שרתי בנייה מסננים אותו, והיא עברה על שרת אחד ונפלה
      // על אחר. הניסיון השני, unicast אל הפורט האמיתי, נפל כאן: הפורט
      // משותף ב-reuseAddress עם המתאם המותקן, ו-unicast מגיע רק לאחד
      // מהם. פורט פרטי מסלק את שתי התלויות.
      final transport = LanTransport(roomCodeProvider: () => 'בדיקה', port: 0);
      expect(await transport.start(), isTrue);
      final remoteBefore = transport.datagramsFromOthers;

      final prodder = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(prodder.close);
      prodder.send(
        SyncMessage(
          type: SyncMessageType.presence,
          roomHash: SyncMessage.hashRoomCode('בדיקה'),
          senderId: 'self000000000000',
          senderName: 'עצמי',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          sequence: 1,
        ).encode('בדיקה'),
        InternetAddress.loopbackIPv4,
        transport.boundPort!,
      );

      await _waitFor(() => transport.datagramsReceived > 0);
      expect(
        transport.datagramsFromOthers,
        remoteBefore,
        reason: 'מקור loopback הוא המחשב הזה, ולא חברותא',
      );
      expect(transport.datagramsRejected, 0);

      await transport.dispose();
    });
  });

  group('אזהרת פער שעונים', () {
    /// שולח הודעה חתומה אל [transport] דרך ה-loopback, כלומר כמי שאינו
    /// "מחשב אחר" — בדיוק כמו הדטגרמה שלנו שחוזרת מה-broadcast.
    Future<void> sendLocal(LanTransport transport, {required int ageMs}) async {
      final prodder = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(prodder.close);
      prodder.send(
        SyncMessage(
          type: SyncMessageType.presence,
          roomHash: SyncMessage.hashRoomCode('בדיקה'),
          senderId: 'self000000000000',
          senderName: 'עצמי',
          timestampMs: DateTime.now().millisecondsSinceEpoch - ageMs,
          sequence: 1,
        ).encode('בדיקה'),
        InternetAddress.loopbackIPv4,
        transport.boundPort!,
      );
    }

    test('דטגרמה מהמחשב הזה אינה מוחקת את האזהרה', () async {
      // **זה הבאג שהאזהרה נעלמה בו.** ההודעה שלנו חוזרת אלינו מה-broadcast
      // כל 20 שניות, והיא תמיד טרייה — היא נחתמה בשעון הזה עצמו. ניקוי
      // בעקבותיה מחק את האזהרה מיד, וכך פער שעונים שמפיל את *כל* הודעות
      // החברותא הופיע ביומן פעם אחת ומעולם לא הגיע לתוסף.
      final transport = LanTransport(roomCodeProvider: () => 'בדיקה', port: 0);
      expect(await transport.start(), isTrue);
      addTearDown(transport.dispose);

      await sendLocal(transport, ageMs: freshnessWindow.inMilliseconds * 5);
      await _waitFor(() => transport.clockSkewMinutes != null);
      final skew = transport.clockSkewMinutes;

      final receivedBefore = transport.datagramsReceived;
      await sendLocal(transport, ageMs: 0);
      await _waitFor(() => transport.datagramsReceived > receivedBefore);

      expect(
        transport.clockSkewMinutes,
        skew,
        reason: 'רק הודעה ממחשב אחר מוכיחה שהשעונים כן מסתדרים',
      );
    });
  });

  group('התאוששות מנפילת סוקט', () {
    test('סוקט שנפל קם מחדש, והמצב מדווח נכון בינתיים', () async {
      final logs = <String>[];
      var rebounds = 0;
      final transport = LanTransport(
        roomCodeProvider: () => 'בדיקה',
        onLog: logs.add,
        // נפילה של סוקט שהחזיק מעמד — הענף שבו קמים מיד. בשטח זה המצב
        // הרגיל: הסוקט חי שעות, והרשת מתנתקת לרגע.
        rebindMinUptime: Duration.zero,
      )..onRebound = () => rebounds++;

      expect(await transport.start(), isTrue);
      expect(transport.isBound, isTrue);
      expect(transport.lastError, isNull);

      // כך בדיוק נראית הנפילה בשטח: Dart מקבל שגיאה אסינכרונית על סוקט
      // ה-UDP, סוגר אותו, והמתאם ממשיך לרוץ חרש.
      transport.reportSocketFailure(
        const SocketException('network unreachable'),
      );

      // עד שהסוקט חוזר, התוסף חייב לראות שהסנכרון מושבת ולא "מחובר".
      expect(transport.isBound, isFalse);
      expect(transport.lastError, 'network unreachable');

      await _waitFor(() => transport.isBound);
      expect(transport.lastError, isNull);
      expect(rebounds, 1, reason: 'ההתאוששות מודיעה נוכחות מיד');
      expect(logs.any((line) => line.contains('נפל')), isTrue);
      expect(logs.any((line) => line.contains('חזר')), isTrue);

      await transport.dispose();
    });

    test('סוקט שמת מיד אחרי שקם אינו נכנס ללופ קימה', () async {
      // זה מה שנצפה בשטח על מחשב בלי מסלול ברירת מחדל: השידור הורג את
      // הסוקט, הקימה מפעילה onRebound שמשדר נוכחות, והשידור הורג שוב —
      // עשרות נפילות בשנייה. הרף חוסם את זה, ושומר הסף ינסה בהמשך.
      final logs = <String>[];
      var rebounds = 0;
      final transport = LanTransport(
        roomCodeProvider: () => 'בדיקה',
        onLog: logs.add,
        rebindMinUptime: const Duration(minutes: 1),
      )..onRebound = () => rebounds++;

      expect(await transport.start(), isTrue);
      transport.reportSocketFailure(
        const SocketException('network unreachable'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(transport.isBound, isFalse, reason: 'אין קימה מיידית');
      expect(rebounds, 0);
      expect(
        logs.any((line) => line.contains('מיד אחרי שקם')),
        isTrue,
        reason: 'היומן אומר שההמתנה מכוונת ולא תקלה',
      );

      await transport.dispose();
    });

    test('אחרי dispose לא קמים מחדש', () async {
      final transport = LanTransport(roomCodeProvider: () => 'בדיקה');
      await transport.start();
      await transport.dispose();

      transport.reportSocketFailure(const SocketException('too late'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transport.isBound, isFalse);
    });
  });

  /// **המסלול המרכזי של החברותא: קישור בלוטות' שאינו מחובר.**
  ///
  /// אימתנו בשטח שכתובת ה-PAN כן נמנית ב-`NetworkInterface.list` אך
  /// אינה ניתנת לקישור כל עוד היא `Tentative` (שגיאה 10049), ואת אותו
  /// מצב יש לשני כרטיסי ה-Wi-Fi Direct הווירטואליים. `192.0.2.x`
  /// (TEST-NET-1) הוא המקבילה הדטרמיניסטית לזה בבדיקה: כתובת חוקית
  /// לגמרי שאין לה כרטיס, ולכן `bind` עליה נכשל בכל מכונה.
  group('כרטיס שנמנה אך אינו ניתן לקישור', () {
    test('שידור שלא יצא אינו הורג את סוקט הקליטה', () async {
      final logs = <String>[];
      final transport = LanTransport(
        roomCodeProvider: () => 'בדיקה',
        port: 0,
        onLog: logs.add,
        addressesProvider: () async => ['192.0.2.1'],
      );
      await transport.start();
      expect(transport.isBound, isTrue);

      // מעל הרף: קודם לכן שני שידורים כאלה סגרו את סוקט הקליטה.
      for (var i = 0; i < deadSendThreshold + 2; i++) {
        await transport.send(_message());
      }

      expect(
        transport.isBound,
        isTrue,
        reason: 'סוקט הקליטה עבד מושלם; אין קישור, וזו תקלה אחרת לגמרי',
      );
      expect(transport.lastError, isNull, reason: 'ולכן אין מה לדווח כתקלה');
      expect(
        logs.any((line) => line.contains('הקשר לרשת נפל')),
        isFalse,
        reason: 'הלופ של 40 שניות שהיה כאן',
      );

      await transport.dispose();
    });

    test('כרטיס כזה מדווח כמי שאינו משדר', () async {
      final transport = LanTransport(
        roomCodeProvider: () => 'בדיקה',
        port: 0,
        addressesProvider: () async => ['192.0.2.1'],
      );
      await transport.start();
      await transport.send(_message());

      expect(transport.routes.map((r) => r.local), ['192.0.2.1']);
      expect(transport.isSending('192.0.2.1'), isFalse);

      await transport.dispose();
    });
  });

  /// כרטיס שמתחבר **אחרי** עליית המתאם — קישור בלוטות' שהוקם עכשיו —
  /// ואחר כך נופל, כמו שקורה ב-Windows בכל התעוררות משינה.
  group('מערך הכרטיסים משתנה תוך ריצה', () {
    test('כרטיס שנוסף נכנס למסלולים, וכרטיס שנעלם יוצא מהם', () async {
      var addresses = <String>['192.0.2.1'];
      final transport = LanTransport(
        roomCodeProvider: () => 'בדיקה',
        port: 0,
        addressesProvider: () async => addresses,
      );
      await transport.start();
      expect(transport.routes.map((r) => r.local), ['192.0.2.1']);

      addresses = ['192.0.2.1', '169.254.73.204'];
      await _expireRoutesCache();
      await transport.send(_message());
      expect(
        transport.routes.map((r) => r.broadcast),
        containsAll(['192.0.2.255', '169.254.255.255']),
        reason: 'הכתובת החדשה קיבלה את ה-broadcast הנכון ל-/16',
      );

      addresses = ['192.0.2.1'];
      await _expireRoutesCache();
      await transport.send(_message());
      expect(transport.routes.map((r) => r.local), ['192.0.2.1']);

      await transport.dispose();
    });

    /// **הרגרסיה שהתיקון הזה סוגר.** `isSending` היה "נקשר פעם אי פעם"
    /// ולא נוקה לעולם, ולכן קישור בלוטות' שעבד ואחר כך נפל המשיך להיות
    /// מוצג כמשדר — והלשונית הכריזה "יש כאן קישור ישיר פעיל" על כרטיס
    /// מנותק, כלומר היפוכה של הבדיקה החד-משמעית שהתיעוד מבטיח.
    test('כרטיס שהשידור דרכו עבד ואז נפל מדווח שאינו משדר', () async {
      // כתובת שכן ניתן לקשור עליה: הלופבק של המחשב הזה.
      var addresses = <String>['127.0.0.1'];
      final transport = LanTransport(
        roomCodeProvider: () => 'בדיקה',
        port: 0,
        addressesProvider: () async => addresses,
      );
      await transport.start();
      await transport.send(_message());
      expect(
        transport.isSending('127.0.0.1'),
        isTrue,
        reason: 'קישור שהצליח',
      );

      // הכרטיס נעלם מהמנייה — בלוטות' שנפל.
      addresses = [];
      await _expireRoutesCache();
      await transport.send(_message());
      expect(transport.isSending('127.0.0.1'), isFalse);

      await transport.dispose();
    });
  });

  group('איפוס מוני האבחון', () {
    /// בלי האיפוס סולם ארבע האבחנות חד-כיווני לכל אורך חיי התהליך:
    /// אחרי דטגרמה אחת ממחשב אחר, האבחנה "השידור יוצא וחוזר אך אין
    /// הודעות ממחשב אחר" לא הייתה מוצגת שוב לעולם — וזה בדיוק המצב
    /// אחרי שקישור הבלוטות' נופל בהתעוררות משינה.
    test('resetDiagnostics מחזיר את המונים לאפס', () async {
      final transport = LanTransport(
        roomCodeProvider: () => 'בדיקה',
        port: 0,
        addressesProvider: () async => const [],
      );
      expect(await transport.start(), isTrue);

      // אותה שיטה כמו בקבוצה למעלה: unicast אל פורט פרטי, ולא הסתמכות
      // על broadcast שחוזר — שרתי בנייה מסננים אותו.
      final prodder = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(prodder.close);
      prodder.send(
        const [1, 2, 3],
        InternetAddress.loopbackIPv4,
        transport.boundPort!,
      );
      await _waitFor(() => transport.datagramsReceived > 0);

      transport.resetDiagnostics();
      expect(transport.datagramsReceived, 0);
      expect(transport.datagramsFromOthers, 0);
      expect(transport.datagramsRejected, 0);
      expect(transport.datagramsClockRejected, 0);
      expect(transport.lastRemoteSource, isNull);

      await transport.dispose();
    });
  });
}

/// הודעת נוכחות סתמית, לשידור בבדיקות.
SyncMessage _message() => SyncMessage(
  type: SyncMessageType.presence,
  roomHash: SyncMessage.hashRoomCode('בדיקה'),
  senderId: 'aabbccdd11223344',
  senderName: 'בדיקה',
  timestampMs: DateTime.now().millisecondsSinceEpoch,
  sequence: 1,
);

/// ממתין עד שמטמון המסלולים פג, כדי שהמנייה תרוץ מחדש.
Future<void> _expireRoutesCache() =>
    Future<void>.delayed(targetsCacheTtl + const Duration(milliseconds: 50));

/// ממתין עד ש-[condition] מתקיים, או נכשל אחרי [timeout]. ההתאוששות
/// אסינכרונית, ולכן אין נקודה אחת ודאית לבדוק בה.
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('התנאי לא התקיים תוך ${timeout.inSeconds} שניות');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
