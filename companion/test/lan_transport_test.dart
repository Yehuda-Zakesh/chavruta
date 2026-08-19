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
}
