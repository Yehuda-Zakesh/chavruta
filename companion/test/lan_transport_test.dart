import 'dart:io';

import 'package:chavruta_companion/lan_transport.dart';
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

  group('broadcastTargetsFor', () {
    test('רשת רגילה — הכתובת הגלובלית וה-broadcast המכוון', () {
      expect(LanTransport.broadcastTargetsFor(['192.168.1.7']), [
        '255.255.255.255',
        '192.168.1.255',
      ]);
    });

    test('כמה כרטיסים — כל רשת מקבלת את ה-broadcast שלה', () {
      // הכתובת הגלובלית יוצאת רק דרך מסלול ברירת המחדל, ולכן בלי
      // הכתובות המכוונות מחשב עם Wi-Fi ונקודה חמה משדר רק לאחת מהן.
      final targets = LanTransport.broadcastTargetsFor([
        '192.168.1.7',
        '192.168.137.1',
      ]);
      expect(targets, contains('192.168.1.255'));
      expect(targets, contains('192.168.137.255'));
    });

    test('כתובת link-local נזרקת כשיש רשת אמיתית', () {
      // 169.254 על מחשב שמחובר לרשת שייכת לכרטיס וירטואלי (Wi-Fi Direct,
      // מכונה וירטואלית) שאין לו מסלול. שידור אליו מחזיר "אין מסלול",
      // ו-Dart סוגר בעקבותיו את הסוקט — כלומר הסנכרון מת.
      expect(
        LanTransport.broadcastTargetsFor(['192.168.1.7', '169.254.10.2']),
        ['255.255.255.255', '192.168.1.255'],
      );
    });

    test('link-local לבדה נשמרת — זה חיבור ישיר בכבל', () {
      expect(LanTransport.broadcastTargetsFor(['169.254.10.2']), [
        '255.255.255.255',
        '169.254.255.255',
      ]);
    });

    test('בלי כרטיס רשת אין יעדים בכלל', () {
      // ולא שידור אל 255.255.255.255, שהיה מפיל את הסוקט על מחשב מנותק.
      expect(LanTransport.broadcastTargetsFor(const []), isEmpty);
      expect(LanTransport.broadcastTargetsFor(['לא כתובת']), isEmpty);
    });
  });

  group('התאוששות מנפילת סוקט', () {
    test('סוקט שנפל קם מחדש, והמצב מדווח נכון בינתיים', () async {
      final logs = <String>[];
      var rebounds = 0;
      final transport = LanTransport(
        roomCodeProvider: () => 'בדיקה',
        onLog: logs.add,
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

    test('אחרי dispose לא קמים מחדש', () async {
      final transport = LanTransport(roomCodeProvider: () => 'בדיקה');
      await transport.start();
      await transport.dispose();

      transport.reportSocketFailure(const SocketException('too late'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(transport.isBound, isFalse);
    });
  });
}

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
