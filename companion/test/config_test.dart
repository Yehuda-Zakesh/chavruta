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
