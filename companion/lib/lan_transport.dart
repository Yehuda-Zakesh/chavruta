import 'dart:async';
import 'dart:io';

import 'protocol.dart';

/// שידור וקליטה של הודעות חברותא ברשת המקומית, על UDP broadcast.
///
/// אין שרת ואין הגדרת כתובות: כל מתאם משדר לכל הרשת, וכל מתאם מסנן
/// לפי גיבוב קוד החברותא וחתימת ה-HMAC. לכן שני מחשבים על אותו ראוטר
/// מוצאים זה את זה בלי שום קונפיגורציה.
class LanTransport {
  LanTransport({required this.roomCodeProvider, this.onLog});

  /// מספק את קוד החברותא **הנוכחי**. פונקציה ולא ערך, כי המשתמש יכול
  /// לשנות קוד בזמן ריצה והתעבורה חייבת לעבור לחדר החדש מיד.
  final String? Function() roomCodeProvider;

  final void Function(String message)? onLog;

  RawDatagramSocket? _socket;
  final _inbound = StreamController<SyncMessage>.broadcast();

  /// הודעות שעברו אימות חתימה, טריות, ואינן שלנו.
  Stream<SyncMessage> get inbound => _inbound.stream;

  bool get isBound => _socket != null;

  Future<bool> start() async {
    if (_socket != null) return true;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        lanPort,
        // מאפשר לכמה מתאמים על אותו מחשב לחלוק את הפורט. בשידור broadcast
        // כל אחד מהם מקבל עותק, ולכן שני מופעי אוצריא במחשב אחד עובדים.
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          _handleDatagram(datagram);
        },
        onError: (Object error) => onLog?.call('שגיאת קליטה ברשת: $error'),
      );
      _socket = socket;
      onLog?.call('מאזין לרשת המקומית על פורט $lanPort');
      return true;
    } on SocketException catch (e) {
      onLog?.call('כשל בהאזנה לפורט $lanPort: ${e.message}');
      return false;
    }
  }

  void _handleDatagram(Datagram datagram) {
    final roomCode = roomCodeProvider();
    if (roomCode == null || roomCode.isEmpty) return;
    final message = SyncMessage.decode(datagram.data, roomCode);
    if (message == null) return;
    _inbound.add(message);
  }

  /// משדר הודעה לכל הרשת. משדר גם ל-255.255.255.255 וגם ל-broadcast
  /// המכוון של כל כרטיס רשת, כי חלק מהראוטרים והמתגים מפילים דווקא את
  /// הכתובת הגלובלית.
  Future<void> send(SyncMessage message) async {
    final socket = _socket;
    final roomCode = roomCodeProvider();
    if (socket == null || roomCode == null || roomCode.isEmpty) return;

    final bytes = message.encode(roomCode);
    final targets = <InternetAddress>{
      InternetAddress('255.255.255.255'),
      ...await _directedBroadcastAddresses(),
    };

    for (final target in targets) {
      try {
        socket.send(bytes, target, lanPort);
      } on SocketException catch (e) {
        onLog?.call('כשל בשליחה אל ${target.address}: ${e.message}');
      }
    }
  }

  /// כתובת ה-broadcast של הרשת שאליה שייכת [address], או `null` אם אינה
  /// כתובת IPv4 תקינה.
  ///
  /// Dart אינו חושף את מסכת הרשת, ולכן המסכה נגזרת מהכתובת:
  /// - `169.254.x.x` — כתובת link-local, שהיא תמיד /16. זה המצב **כששני
  ///   מחשבים מחוברים בכבל רשת ישר בלי ראוטר**: אין DHCP, ולכן Windows
  ///   נותן לכל צד כתובת כזאת. ב-/24 שגוי ה-broadcast לא היה מגיע לצד השני.
  /// - כל השאר — /24, הנחה שנכונה כמעט בכל רשת ביתית או רשת מוסד קטנה.
  static String? broadcastAddressForIPv4(String address) {
    final octets = address.split('.');
    if (octets.length != 4) return null;
    for (final octet in octets) {
      final value = int.tryParse(octet);
      if (value == null || value < 0 || value > 255) return null;
    }
    if (octets[0] == '169' && octets[1] == '254') return '169.254.255.255';
    return '${octets[0]}.${octets[1]}.${octets[2]}.255';
  }

  /// כתובות ה-broadcast המכוונות של הכרטיסים הפעילים.
  ///
  /// כולל כתובות link-local, כדי שחיבור ישיר בכבל בין שני מחשבים — בלי
  /// ראוטר ובלי DHCP — יעבוד. הכתובת הגלובלית נשלחת בכל מקרה, אבל בחיבור
  /// כזה אין מסלול ברירת מחדל, ולכן דווקא הכתובות המכוונות הן שמגיעות.
  Future<Set<InternetAddress>> _directedBroadcastAddresses() async {
    final result = <InternetAddress>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: true,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final broadcast = broadcastAddressForIPv4(address.address);
          if (broadcast != null) result.add(InternetAddress(broadcast));
        }
      }
    } catch (e) {
      onLog?.call('לא ניתן לרשום כרטיסי רשת: $e');
    }
    return result;
  }

  Future<void> dispose() async {
    _socket?.close();
    _socket = null;
    await _inbound.close();
  }
}
