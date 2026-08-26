import 'dart:convert';

import 'package:chavruta_companion/firewall_check.dart';
import 'package:test/test.dart';

/// הנתיב שבו הבדיקה נכשלה בשטח: שם המשתמש בעברית.
const _path =
    r'C:\Users\זאב לונטל\AppData\Local\Programs\Chavruta\ChavrutaCompanion.exe';

/// פלט netsh מקוצר, בסגנון השורות האמיתי, עבור נתיבי ה-exe שנמסרו.
String _netshOutput(List<String> programs) {
  final buffer = StringBuffer('\nRule Name:  Chavruta Companion (UDP-In)\n');
  for (final program in programs) {
    buffer.writeln('Enabled:                              Yes');
    buffer.writeln('Direction:                            In');
    buffer.writeln('Program:                              $program');
    buffer.writeln('Protocol:                             UDP');
    buffer.writeln('LocalPort:                            45870');
    buffer.writeln();
  }
  return buffer.toString();
}

/// כפי שנראה הפלט כשהקודפייג' שגוי: כל תו שאינו ASCII חוזר כזבל, והאסקי
/// סביבו שורד. זה המצב שהפיל את הבדיקה הקודמת.
String _mangle(String text) =>
    text.replaceAll(RegExp(r'[^\x00-\x7f]'), '\u05f3\u05d3');

void main() {
  group('netshOutputMentionsPath', () {
    test('מזהה את הנתיב כשהפלט תקין ב-UTF-8', () {
      final bytes = utf8.encode(_netshOutput([_path]));
      expect(netshOutputMentionsPath(bytes, _path), isTrue);
    });

    test('מזהה את הנתיב גם כשהעברית יצאה זבל בקודפייג׳ שגוי', () {
      // הרגרסיה עצמה: ההיתר קיים, ורק הפענוח פגע בשם המשתמש.
      final bytes = utf8.encode(_mangle(_netshOutput([_path])));
      expect(netshOutputMentionsPath(bytes, _path), isTrue);
    });

    test('אינו מתבלבל בין החוק שלנו לחוק על נתיב אחר', () {
      // אותו שם משתמש עברי, אותו שם קובץ — ותיקייה אחרת. חוק כזה אינו
      // מכסה את ההתקנה הנוכחית, ולכן חייב להיחשב כחסר גם אחרי מנגול.
      final stale = r'C:\Users\זאב לונטל\Downloads\chavruta-windows'
          r'\ChavrutaCompanion.exe';
      for (final text in [
        _netshOutput([stale]),
        _mangle(_netshOutput([stale]))
      ]) {
        expect(netshOutputMentionsPath(utf8.encode(text), _path), isFalse);
      }
    });

    test('מוצא את הנתיב גם בין חוקים של נתיבים אחרים', () {
      final text = _netshOutput([
        r'C:\Users\זאב לונטל\Downloads\ChavrutaCompanion.exe',
        _path,
        r'C:\dev\chavruta\dist\ChavrutaCompanion.exe',
      ]);
      expect(
          netshOutputMentionsPath(utf8.encode(_mangle(text)), _path), isTrue);
    });

    test('אינו רגיש לאותיות רישיות', () {
      final bytes = utf8.encode(_netshOutput([_path.toLowerCase()]));
      expect(netshOutputMentionsPath(bytes, _path), isTrue);
    });

    test('פלט בלי החוק שלנו כלל אינו נחשב היתר', () {
      final bytes =
          utf8.encode(_netshOutput([r'C:\Windows\System32\svchost.exe']));
      expect(netshOutputMentionsPath(bytes, _path), isFalse);
    });

    test('נתיב אסקי לגמרי נדרש להתאמה מלאה', () {
      const ascii = r'C:\Programs\Chavruta\ChavrutaCompanion.exe';
      expect(
        netshOutputMentionsPath(utf8.encode(_netshOutput([ascii])), ascii),
        isTrue,
      );
      expect(
        netshOutputMentionsPath(
          utf8.encode(_netshOutput([r'C:\Other\ChavrutaCompanion.exe'])),
          ascii,
        ),
        isFalse,
      );
    });
  });
}
