import 'dart:async';

import 'package:chavruta_companion/lan_transport.dart';
import 'package:chavruta_companion/protocol.dart';

/// תעבורה מדומה: אוספת את מה ששודר ומאפשרת להזריק הודעות נכנסות, בלי
/// לפתוח סוקט אמיתי. כך בדיקות ה-hub אינן תלויות ברשת של מריץ הבדיקה.
class FakeTransport extends LanTransport {
  FakeTransport() : super(roomCodeProvider: () => 'fake');

  final _controller = StreamController<SyncMessage>.broadcast();

  /// כל ההודעות שהמתאם ניסה לשדר, בסדר השליחה.
  final List<SyncMessage> sent = [];

  @override
  Stream<SyncMessage> get inbound => _controller.stream;

  @override
  bool get isBound => true;

  @override
  Future<bool> start() async => true;

  @override
  Future<void> send(SyncMessage message) async => sent.add(message);

  /// מזריקה הודעה שכאילו הגיעה מהרשת, וממתינה עד שה-hub עיבד אותה.
  Future<void> deliver(SyncMessage message) async {
    _controller.add(message);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> dispose() async => _controller.close();
}
