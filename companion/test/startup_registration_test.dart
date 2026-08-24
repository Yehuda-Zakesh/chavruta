import 'dart:io';

import 'package:chavruta_companion/startup_registration.dart';
import 'package:test/test.dart';

import 'support/fake_reg.dart';

void main() {
  group('StartupRegistration', () {
    late Directory dir;
    late String companion;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('chavruta_startup_');
      companion = '${dir.path}${Platform.pathSeparator}$companionExeName';
      await File(companion).writeAsString('exe');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // ב-Windows קובץ שעדיין פתוח חוסם מחיקה; לא כשל של הבדיקה.
      }
    });

    StartupRegistration subject(
      FakeReg reg, {
      String? executable,
      bool isWindows = true,
    }) => StartupRegistration(
      runReg: reg.run,
      executable: executable ?? companion,
      isWindows: isWindows,
    );

    test('ערך שאינו קיים = כבוי, וקיים = מופעל', () async {
      final reg = FakeReg();
      expect((await subject(reg).read()).enabled, isFalse);

      reg.value = '"$companion" --hidden';
      final state = await subject(reg).read();
      expect(state.supported, isTrue);
      expect(state.enabled, isTrue);
    });

    test('ערך שמצביע להתקנה אחרת אינו נחשב "עולה עם המחשב"', () async {
      // התקנה קודמת במיקום אחר משאירה ערך באותו שם. הוא קיים, אבל הוא
      // מפעיל קובץ אחר (שלרוב כבר אינו קיים), ולכן המתג היה מראה "דלוק"
      // בזמן ששום דבר אינו עולה. הדלקה מכאן פשוט תדרוס אותו בשלנו.
      final reg = FakeReg(value: r'"C:\Program Files\Old\ChavrutaCompanion.exe" --hidden');
      final state = await subject(reg).read();

      expect(state.supported, isTrue);
      expect(state.enabled, isFalse);
      expect(state.reason, isNotNull);
      expect(state.command, contains('Old'));
    });

    test('הפעלה רושמת את המשגר כשהוא לצד ה-exe', () async {
      final launcher = '${dir.path}${Platform.pathSeparator}$launcherExeName';
      await File(launcher).writeAsString('exe');

      final reg = FakeReg();
      final state = await subject(reg).setEnabled(true);

      expect(state.enabled, isTrue);
      // מצוטט, ועם --quiet: המשגר מעביר את הדגל אל המתאם.
      expect(reg.value, '"$launcher" --quiet');
    });

    test('בלי משגר לצד ה-exe נרשם המתאם עצמו עם --hidden', () async {
      final reg = FakeReg();
      await subject(reg).setEnabled(true);
      expect(reg.value, '"$companion" --hidden');
    });

    test('כיבוי מוחק את הערך, וכיבוי כשכבר כבוי אינו כשל', () async {
      final reg = FakeReg(value: '"$companion" --hidden');

      expect((await subject(reg).setEnabled(false)).enabled, isFalse);
      expect(reg.value, isNull);

      final again = await subject(reg).setEnabled(false);
      expect(again.supported, isTrue);
      expect(again.enabled, isFalse);
    });

    test('כתיבה שנבלמת בשקט מדווחת כמצב האמיתי ולא כהצלחה', () async {
      final reg = FakeReg(frozen: true);
      final state = await subject(reg).setEnabled(true);

      expect(state.enabled, isFalse);
      expect(state.reason, isNotNull);
    });

    test('הרצה מתוך פיתוח אינה נתמכת, ואינה נוגעת ברישום', () async {
      final reg = FakeReg();
      final state = await subject(
        reg,
        executable: '${dir.path}${Platform.pathSeparator}dart.exe',
      ).setEnabled(true);

      expect(state.supported, isFalse);
      expect(state.reason, isNotNull);
      expect(reg.calls, isEmpty);
    });

    test('מחוץ ל-Windows אין מה להציע', () async {
      final reg = FakeReg();
      final state = await subject(reg, isWindows: false).read();

      expect(state.supported, isFalse);
      expect(reg.calls, isEmpty);
    });
  });
}
