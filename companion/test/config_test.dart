import 'dart:convert';
import 'dart:io';

import 'package:chavruta_companion/config.dart';
import 'package:test/test.dart';

import 'support/temp_config.dart';

void main() {
  late TempConfig temp;

  setUp(() async => temp = await TempConfig.create());
  tearDown(() async => temp.delete());

  group('normalizeRoomCode', () {
    test('מוריד רווחים מקצה ומכווץ רווחים באמצע', () {
      expect(CompanionConfig.normalizeRoomCode('  דף   יומי  '), 'דף יומי');
    });

    test('מוריד רישיות באותיות לטיניות', () {
      expect(CompanionConfig.normalizeRoomCode('DafYomi'), 'dafyomi');
    });

    test('שתי צורות הקלדה של אותו קוד מגיעות לאותו ערך', () {
      expect(
        CompanionConfig.normalizeRoomCode('דף יומי'),
        CompanionConfig.normalizeRoomCode(' דף  יומי '),
      );
    });

    /// **הכשל שאין לו אבחון.** קוד עברי שהודבק מוואטסאפ או מ-Word נושא
    /// תווי כיווניות בלתי נראים, ואז שני המחשבים מציגים על המסך קוד
    /// זהה לחלוטין ומגיעים לחדרים שונים. הדחייה קורית ב-`decode` לפני
    /// חישוב ה-HMAC, ולכן אף מונה אבחון אינו זז ואף אזהרה אינה מוצגת:
    /// "ממתין לחברותא" לנצח, מול קוד שנראה נכון.
    ///
    /// כל התווים כתובים כאן ב-escape ולא כתווים עצמם — תו כיווניות
    /// במקור מהפך את סדר התצוגה של השורה, ואי אפשר לבקר קוד כזה.
    group('קוד עברי שנראה זהה על המסך מגיע לאותו חדר', () {
      const base = 'דף יומי';

      void same(String label, String typed) {
        test(label, () {
          expect(
            CompanionConfig.normalizeRoomCode(typed),
            CompanionConfig.normalizeRoomCode(base),
          );
        });
      }

      same('RLM בהתחלה (הדבקה מוואטסאפ)', '\u200fדף יומי');
      same('RLM בסוף', 'דף יומי\u200f');
      same('LRM באמצע', 'דף \u200eיומי');
      same('RLE ו-PDF עוטפים', '\u202bדף יומי\u202c');
      same('RLI ו-PDI עוטפים', '\u2067דף יומי\u2069');
      same('BOM בהתחלה', '\ufeffדף יומי');
      same('רוחב-אפס בין המלים', 'דף \u200bיומי');
      same('NBSP במקום רווח', 'דף\u00a0יומי');
      same('ניקוד', 'ד\u05b7ף יו\u05b9מ\u05b4י');
      same('טעם מקרא', 'דף\u0592 יומי');
      // שרשור מפורש, ולא escape צמוד לאות עברית: הגבול בין השניים אינו
      // חד-משמעי לעין בעורך RTL, וכך נכתב כאן בטעות `m` לטיני במקום מ״ם.
      same('מקף רך באמצע מלה', 'דף יו' '\u00ad' 'מי');
    });

    test('גרש וגרשיים עבריים שווים ללטיניים', () {
      final forms = [
        'רש"י',
        'רש\u05f4י', // גרשיים עבריים
        'רש\u201dי', // מרכאה מסולסלת
      ].map(CompanionConfig.normalizeRoomCode).toSet();
      expect(forms, hasLength(1), reason: 'שלושתם נראים זהים על המסך');
    });

    test('צורת תצוגה של שׁ שווה לאות עם הנקודה', () {
      expect(
        CompanionConfig.normalizeRoomCode('\ufb2aלום'),
        CompanionConfig.normalizeRoomCode('\u05e9\u05c1לום'),
      );
    });

    /// הנרמול אינו רשאי למחוק הבדל אמיתי: קודים שונים חייבים להישאר
    /// חדרים שונים, אחרת הסוד היחיד שמגן על החיבור נעשה קל לניחוש.
    test('קודים שונים נשארים שונים', () {
      final codes = ['דף יומי', 'דףיומי', 'דף יומי אחר', 'שבת', 'מן', 'מ ן']
          .map(CompanionConfig.normalizeRoomCode)
          .toSet();
      expect(codes, hasLength(6));
    });

    /// תו **נראה** שנמצא בתוך טווח הניקוד אינו ניקוד, והוא חלק מהקוד.
    test('מקף עברי וסוף פסוק נשמרים', () {
      expect(CompanionConfig.normalizeRoomCode('דף\u05beיומי'), 'דף\u05beיומי');
      expect(CompanionConfig.normalizeRoomCode('דף\u05c3'), 'דף\u05c3');
    });
  });

  group('load', () {
    test('ריצה ראשונה יוצרת קונפיג ושומרת אותו לדיסק', () async {
      final config = await CompanionConfig.load(storageDir: temp.dir);
      expect(config.deviceId, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(config.isPaired, isFalse);
      expect(await config.file.exists(), isTrue);
    });

    test('זהות המכשיר יציבה בין ריצות', () async {
      final first = await CompanionConfig.load(storageDir: temp.dir);
      final second = await CompanionConfig.load(storageDir: temp.dir);
      expect(second.deviceId, first.deviceId);
    });

    test('קונפיג פגום אינו מפיל את העלייה', () async {
      await temp.dir.create(recursive: true);
      await File(
        '${temp.dir.path}${Platform.pathSeparator}config.json',
      ).writeAsString('{ זה בכלל לא JSON');

      final config = await CompanionConfig.load(storageDir: temp.dir);
      expect(config.deviceId, isNotEmpty);
    });

    test('קונפיג בלי deviceId נחשב חסר תועלת ונבנה מחדש', () async {
      await temp.dir.create(recursive: true);
      await File(
        '${temp.dir.path}${Platform.pathSeparator}config.json',
      ).writeAsString(jsonEncode({'deviceName': 'מחשב'}));

      final config = await CompanionConfig.load(storageDir: temp.dir);
      expect(config.deviceId, isNotEmpty);
    });

    test('קוד חדר שנשמר לא מנורמל נטען מנורמל', () async {
      await temp.dir.create(recursive: true);
      await File(
        '${temp.dir.path}${Platform.pathSeparator}config.json',
      ).writeAsString(
        jsonEncode({
          'deviceId': 'aabbccdd11223344',
          'deviceName': 'מחשב',
          'roomCode': '  דף   יומי  ',
        }),
      );

      final config = await CompanionConfig.load(storageDir: temp.dir);
      expect(config.roomCode, 'דף יומי');
    });

    test('שם ריק בקונפיג נופל לשם המחשב', () async {
      await temp.dir.create(recursive: true);
      await File(
        '${temp.dir.path}${Platform.pathSeparator}config.json',
      ).writeAsString(
        jsonEncode({'deviceId': 'aabbccdd11223344', 'deviceName': '   '}),
      );

      final config = await CompanionConfig.load(storageDir: temp.dir);
      expect(config.deviceName, Platform.localHostname);
    });
  });

  group('save', () {
    test('קוד חדר נשמר ונטען', () async {
      final config = temp.config(roomCode: 'דף יומי');
      await config.save();

      final loaded = await CompanionConfig.load(storageDir: temp.dir);
      expect(loaded.roomCode, 'דף יומי');
      expect(loaded.isPaired, isTrue);
    });

    test('מתאם לא מזווג אינו משאיר קוד חדר בקובץ', () async {
      final config = temp.config(roomCode: 'דף יומי');
      await config.save();
      config.roomCode = null;
      await config.save();

      final json = jsonDecode(await config.file.readAsString()) as Map;
      expect(json.containsKey('roomCode'), isFalse);
    });

    test('שמירות מקבילות אינן מאבדות שדה ואינן משאירות קובץ פגום', () async {
      // שתי בקשות שהגיעו כמעט יחד — שינוי חדר ושינוי שם — כל אחת
      // קוראת ל-save() בלי להמתין לשנייה.
      final config = temp.config();
      config.roomCode = 'דף יומי';
      final first = config.save();
      config.deviceName = 'המחשב של אבא';
      config.syncLocation = false;
      final second = config.save();
      await Future.wait([first, second]);

      final json = jsonDecode(await config.file.readAsString()) as Map;
      expect(json['roomCode'], 'דף יומי');
      expect(json['deviceName'], 'המחשב של אבא');
      expect(json['syncLocation'], isFalse);
      expect(json['deviceId'], config.deviceId);
    });

    test('הקובץ הזמני אינו נשאר אחרי שמירה', () async {
      // הכתיבה היא לקובץ זמני ואז החלפה בשם. שארית כאן פירושה שההחלפה
      // לא קרתה, כלומר גם שהאטומיות לא קרתה.
      final config = temp.config(roomCode: 'דף יומי');
      await config.save();
      expect(await File('${config.file.path}.tmp').exists(), isFalse);
    });

    test('מה שנשמר נקרא בחזרה שלם — זהות וחדר גם יחד', () async {
      final config = temp.config(roomCode: 'דף יומי');
      await config.save();
      final again = await CompanionConfig.load(storageDir: temp.dir);
      expect(again.deviceId, config.deviceId);
      expect(again.roomCode, 'דף יומי');
    });

    test('התיקייה נוצרת אם אינה קיימת', () async {
      final nested = Directory(
        '${temp.dir.path}${Platform.pathSeparator}a'
        '${Platform.pathSeparator}b',
      );
      final config = CompanionConfig(
        deviceId: 'aabbccdd11223344',
        deviceName: 'מחשב',
        storageDir: nested,
      );
      await config.save();
      expect(await config.file.exists(), isTrue);
    });
  });
}
