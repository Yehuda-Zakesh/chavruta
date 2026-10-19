import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/protocol_vectors.dart' as generator;

/// התוסף מממש את אותו פרוטוקול ב-JS עבור החיבור המרוחק, ונבדק מול
/// `plugin-test/fixtures/protocol-vectors.json`. הבדיקה כאן מוודאת שהקובץ
/// הזה הוא באמת מה שהמימוש של Dart מפיק היום — אחרת שינוי בנרמול או
/// בחתימה כאן היה עובר, ושני המימושים היו מפסיקים להבין זה את זה בשקט.
void main() {
  test('וקטורי הפרוטוקול של התוסף תואמים את המימוש הנוכחי', () {
    final fixture = File('../plugin-test/fixtures/protocol-vectors.json');
    expect(fixture.existsSync(), isTrue, reason: fixture.path);
    final saved = jsonDecode(fixture.readAsStringSync());
    expect(
      saved,
      equals(jsonDecode(jsonEncode(generator.vectors()))),
      reason:
          'הריצו: dart run tool/protocol_vectors.dart > '
          '../plugin-test/fixtures/protocol-vectors.json',
    );
  });
}
