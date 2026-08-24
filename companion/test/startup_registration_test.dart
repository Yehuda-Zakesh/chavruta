import 'dart:io';

import 'package:chavruta_companion/startup_registration.dart';
import 'package:test/test.dart';

import 'support/fake_reg.dart';

/// `reg.exe` שמדפיס את מה שנכתב בקידוד הקונסולה: כל תו שאינו ASCII חוזר
/// כזבל. כך נראה בפועל שם משתמש בעברית בחלונות בעברית.
class _MangledReg extends FakeReg {
  @override
  Future<ProcessResult> run(List<String> arguments) async {
    final result = await super.run(arguments);
    if (result.stdout is! String) return result;
    return ProcessResult(
      0,
      result.exitCode,
      (result.stdout as String).replaceAll(RegExp(r'[^\x00-\x7f]'), '†'),
      result.stderr,
    );
  }
}

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

    test('ערך שמפעיל תוכנית זרה אינו נחשב "עולה עם המחשב"', () async {
      // מישהו אחר תפס את שם הערך שלנו. הוא קיים, ולכן המתג היה מראה
      // "דלוק" בזמן שהמתאם אינו עולה כלל. הדלקה מכאן פשוט תדרוס אותו.
      //
      // ההבחנה היא לפי שם הקובץ ולא לפי הנתיב, כי הנתיב חוזר מ-reg.exe
      // בקידוד הקונסולה ואינו קריא כשיש בו עברית. המחיר: התקנה ישנה
      // *שלנו* במיקום אחר נחשבת שלנו.
      final reg = FakeReg(value: r'"C:\Windows\System32\notepad.exe"');
      final state = await subject(reg).read();

      expect(state.supported, isTrue);
      expect(state.enabled, isFalse);
      expect(state.reason, isNotNull);
      expect(state.command, contains('notepad'));
    });

    test('נתיב שחזר משובש מ-reg.exe עדיין נחשב ההתקנה שלנו', () async {
      // reg.exe מדפיס בקידוד הקונסולה, ולכן שם משתמש בעברית חוזר משובש:
      // C:\Users\זאב לונטל\... נקרא C:\Users\†€ …ˆ\... . השוואת נתיב
      // נכשלת שם תמיד, והמתג "עולה עם המחשב" נפל אצל כל מי ששם המשתמש
      // שלו אינו באנגלית — כלומר אצל רוב המשתמשים.
      final reg = FakeReg(
        value: r'"C:\Users\†€ …ˆ\AppData\Local\Programs\Chavruta\ChavrutaLauncher.exe" --quiet',
      );
      final state = await subject(reg).read();

      expect(state.enabled, isTrue);
      expect(state.reason, isNull);
    });

    test('הפעלה תחת שם משתמש בעברית מדווחת הצלחה', () async {
      // המקרה האמיתי מהשטח, מקצה לקצה: ההתקנה יושבת תחת שם משתמש בעברית,
      // reg.exe מחזיר את הנתיב משובש, והבדיקה שאחרי הכתיבה קוראת מחדש.
      // כשהקריאה טועה — הדלקה תקינה לגמרי מדווחת ככשל, המתג נופל בחזרה,
      // והמשתמש מקבל שגיאה על משהו שעבד.
      final hebrew = Directory('${dir.path}${Platform.pathSeparator}זאב לונטל');
      await hebrew.create();
      final exe = '${hebrew.path}${Platform.pathSeparator}$companionExeName';
      final launcher = '${hebrew.path}${Platform.pathSeparator}$launcherExeName';
      await File(exe).writeAsString('exe');
      await File(launcher).writeAsString('exe');

      final reg = _MangledReg();
      final state = await subject(reg, executable: exe).setEnabled(true);

      expect(state.enabled, isTrue);
      expect(state.reason, isNull);
      expect(reg.value, '"$launcher" --quiet');
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
