import 'package:flutter/services.dart';

/// הגשר לצד ה-Kotlin (`CompanionEngine.kt`): תיקיית הנתונים, שם המכשיר,
/// שירות החזית, העלייה עם הטלפון והפטור מחיסכון בסוללה.
class Native {
  static const _channel = MethodChannel('chavruta/native');

  static Future<String> filesDir() async =>
      (await _channel.invokeMethod<String>('filesDir'))!;

  static Future<String> deviceName() async {
    final name = await _channel.invokeMethod<String>('deviceName');
    return (name == null || name.trim().isEmpty) ? 'Android' : name.trim();
  }

  static Future<void> startService() async {
    await _channel.invokeMethod<Object?>('startService');
  }

  static Future<void> stopService() async {
    await _channel.invokeMethod<Object?>('stopService');
  }

  /// שורת המצב בהתראה הקבועה.
  static Future<void> setStatus(String text) async {
    await _channel.invokeMethod<Object?>('setStatus', {'text': text});
  }

  /// האם התהליך הוקם בעלייה עם הטלפון. נכון פעם אחת בלבד.
  static Future<bool> launchedAtBoot() async =>
      (await _channel.invokeMethod<bool>('launchedAtBoot')) ?? false;

  static Future<bool> getStartOnBoot() async =>
      (await _channel.invokeMethod<bool>('getStartOnBoot')) ?? true;

  static Future<bool> setStartOnBoot(bool enabled) async =>
      (await _channel.invokeMethod<bool>('setStartOnBoot', {
        'enabled': enabled,
      })) ??
      enabled;

  static Future<bool> isBatteryExempt() async =>
      (await _channel.invokeMethod<bool>('isBatteryExempt')) ?? true;

  static Future<void> requestBatteryExempt() async {
    await _channel.invokeMethod<Object?>('requestBatteryExempt');
  }

  /// פותח קישור (`otzaria://...`). `false` = אין מי שמטפל בו.
  static Future<bool> openUri(String uri) async =>
      (await _channel.invokeMethod<bool>('openUri', {'uri': uri})) ?? false;
}
