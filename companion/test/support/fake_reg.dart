import 'dart:io';

/// `reg.exe` מדומה, עם הסמנטיקה שהקוד באמת נשען עליה: קוד יציאה 0 כשהערך
/// קיים או נכתב, ו-1 כשאין ערך למצוא או למחוק.
///
/// [frozen] מדמה סביבה שבה הכתיבה נבלמת בשקט (מדיניות ארגונית, כלי
/// אבטחה): `reg.exe` מחזיר 0, אבל הערך לא באמת השתנה.
class FakeReg {
  FakeReg({this.value, this.frozen = false});

  String? value;
  bool frozen;

  /// כל הקריאות, לפי הסדר — כדי לבדוק *מה* נכתב ולא רק שנכתב.
  final List<List<String>> calls = <List<String>>[];

  Future<ProcessResult> run(List<String> arguments) async {
    calls.add(arguments);
    final command = arguments.isEmpty ? '' : arguments.first;

    switch (command) {
      case 'query':
        return _result(value == null ? 1 : 0);
      case 'add':
        final index = arguments.indexOf('/d');
        if (!frozen && index >= 0 && index + 1 < arguments.length) {
          value = arguments[index + 1];
        }
        return _result(0);
      case 'delete':
        if (value == null) return _result(1);
        if (!frozen) value = null;
        return _result(0);
      default:
        return _result(1);
    }
  }

  ProcessResult _result(int exitCode) => ProcessResult(0, exitCode, '', '');
}
