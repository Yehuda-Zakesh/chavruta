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

  /// כתובות ה-broadcast המכוונות של הכרטיסים הפעילים.
  ///
  /// Dart אינו חושף את מסכת הרשת, ולכן אנחנו מניחים /24 — הנחה שנכונה
  /// כמעט בכל רשת ביתית או רשת מוסד קטנה. הכתובת הגלובלית נשלחת בכל
  /// מקרה, כך שגם ברשת עם מסכה אחרת הסנכרון עדיין עובד.
  Future<Set<InternetAddress>> _directedBroadcastAddresses() async {
    final result = <InternetAddress>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final octets = address.address.split('.');
          if (octets.length != 4) continue;
          result.add(InternetAddress('${octets[0]}.${octets[1]}.${octets[2]}.255'));
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
