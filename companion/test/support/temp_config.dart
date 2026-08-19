import 'dart:io';

import 'package:chavruta_companion/config.dart';

/// תיקיית קונפיג זמנית לבדיקה אחת. בלעדיה בדיקות שקוראות ל-`save()`
/// היו כותבות לקונפיג האמיתי של מריץ הבדיקה.
class TempConfig {
  TempConfig._(this.dir);

  final Directory dir;

  static Future<TempConfig> create() async =>
      TempConfig._(await Directory.systemTemp.createTemp('chavruta_test_'));

  CompanionConfig config({
    String? roomCode,
    String deviceName = 'מחשב בדיקה',
  }) => CompanionConfig(
    deviceId: 'aabbccdd11223344',
    deviceName: deviceName,
    roomCode: roomCode,
    storageDir: dir,
  );

  Future<void> delete() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // ב-Windows קובץ שעדיין פתוח חוסם מחיקה; זה לא כשל של הבדיקה.
    }
  }
}
