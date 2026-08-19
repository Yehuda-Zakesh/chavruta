import 'dart:io';

import 'package:chavruta_companion/version.dart';
import 'package:test/test.dart';

void main() {
  test('companionVersion זהה לגרסה ב-pubspec.yaml', () async {
    final pubspec = await File('pubspec.yaml').readAsString();
    final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'אין שדה version ב-pubspec.yaml');
    expect(companionVersion, match!.group(1));
  });
}
