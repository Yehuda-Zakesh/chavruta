import 'dart:convert';

import 'package:chavruta_companion/protocol.dart';
import 'package:test/test.dart';

const room = 'לומדים ביחד';
const otherRoom = 'חדר אחר';

SyncMessage buildMessage({
  SyncMessageType type = SyncMessageType.location,
  SyncLocation? location = const SyncLocation(
    bookId: 'ברכות',
    index: 12,
    ref: 'ברכות דף ד',
  ),
  int? timestampMs,
}) => SyncMessage(
  type: type,
  roomHash: SyncMessage.hashRoomCode(room),
  senderId: 'aabbccdd',
  senderName: 'המחשב של אבא',
  timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
  sequence: 7,
  location: location,
);

/// מקודד, משנה שדה אחד ב-JSON, ומחזיר בייטים — כלומר הודעה שנחתמה על
/// תוכן אחר ממה שנשלח בפועל.
List<int> tamper(SyncMessage message, String field, Object? value) {
  final json = jsonDecode(utf8.decode(message.encode(room))) as Map;
  json[field] = value;
  return utf8.encode(jsonEncode(json));
}

void main() {
  group('SyncLocation', () {
    test('מפענח מיקום תקין', () {
      final location = SyncLocation.fromJson({
        'bookId': 'שבת',
        'index': 3,
        'ref': 'שבת דף ב',
      });
      expect(location!.bookId, 'שבת');
      expect(location.index, 3);
      expect(location.ref, 'שבת דף ב');
    });

    test('דוחה מיקום חסר או פגום', () {
      expect(SyncLocation.fromJson(null), isNull);
      expect(SyncLocation.fromJson('שבת'), isNull);
      expect(SyncLocation.fromJson({'index': 3}), isNull);
      expect(SyncLocation.fromJson({'bookId': '', 'index': 3}), isNull);
      expect(SyncLocation.fromJson({'bookId': 'שבת'}), isNull);
      expect(SyncLocation.fromJson({'bookId': 'שבת', 'index': -1}), isNull);
      expect(SyncLocation.fromJson({'bookId': 'שבת', 'index': '3'}), isNull);
    });

    test('sameSpotAs מתעלם מה-ref, שהוא לתצוגה בלבד', () {
      const a = SyncLocation(bookId: 'שבת', index: 3, ref: 'שבת דף ב');
      const b = SyncLocation(bookId: 'שבת', index: 3);
      const c = SyncLocation(bookId: 'שבת', index: 4);
      expect(a.sameSpotAs(b), isTrue);
      expect(a.sameSpotAs(c), isFalse);
      expect(a.sameSpotAs(null), isFalse);
    });
  });

  group('hashRoomCode', () {
    test('מחזיר 16 תווים הקסה', () {
      final hash = SyncMessage.hashRoomCode(room);
      expect(hash, hasLength(16));
      expect(hash, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('קוד אחר מקבל גיבוב אחר, ואותו קוד מקבל גיבוב זהה', () {
      expect(
        SyncMessage.hashRoomCode(room),
        SyncMessage.hashRoomCode(room),
      );
      expect(
        SyncMessage.hashRoomCode(room),
        isNot(SyncMessage.hashRoomCode(otherRoom)),
      );
    });

    test('קוד החברותא עצמו אינו מופיע על החוט', () {
      final wire = utf8.decode(buildMessage().encode(room));
      expect(wire, isNot(contains(room)));
    });
  });

  group('SyncMessage.decode', () {
    test('הלוך-חזור שומר על כל השדות', () {
      final original = buildMessage();
      final decoded = SyncMessage.decode(original.encode(room), room);
      expect(decoded, isNotNull);
      expect(decoded!.type, SyncMessageType.location);
      expect(decoded.senderId, original.senderId);
      expect(decoded.senderName, original.senderName);
      expect(decoded.sequence, original.sequence);
      expect(decoded.timestampMs, original.timestampMs);
      expect(decoded.location!.bookId, 'ברכות');
      expect(decoded.location!.index, 12);
      expect(decoded.location!.ref, 'ברכות דף ד');
    });

    test('נוכחות ופרידה עוברות גם בלי מיקום', () {
      for (final type in [SyncMessageType.presence, SyncMessageType.farewell]) {
        final message = buildMessage(type: type, location: null);
        expect(
          SyncMessage.decode(message.encode(room), room)?.type,
          type,
          reason: 'סוג $type',
        );
      }
    });

    test('הודעת מיקום בלי מיקום נדחית', () {
      final message = buildMessage(location: null);
      expect(SyncMessage.decode(message.encode(room), room), isNull);
    });

    test('הודעה של חדר אחר נדחית', () {
      final message = buildMessage();
      expect(SyncMessage.decode(message.encode(room), otherRoom), isNull);
    });

    test('שינוי בדרך נדחה גם כשגיבוב החדר נכון', () {
      expect(
        SyncMessage.decode(tamper(buildMessage(), 'name', 'מתחזה'), room),
        isNull,
      );
      expect(
        SyncMessage.decode(tamper(buildMessage(), 'seq', 99), room),
        isNull,
      );
      expect(
        SyncMessage.decode(
          tamper(buildMessage(), 'loc', {'bookId': 'שבת', 'index': 1}),
          room,
        ),
        isNull,
      );
    });

    test('חתימה חסרה או באורך אחר נדחית', () {
      expect(SyncMessage.decode(tamper(buildMessage(), 'sig', null), room), isNull);
      expect(SyncMessage.decode(tamper(buildMessage(), 'sig', 'קצר'), room), isNull);
    });

    test('גרסת פרוטוקול אחרת נדחית', () {
      expect(
        SyncMessage.decode(tamper(buildMessage(), 'v', protocolVersion + 1), room),
        isNull,
      );
    });

    test('סוג הודעה לא מוכר נדחה', () {
      expect(SyncMessage.decode(tamper(buildMessage(), 't', 'zzz'), room), isNull);
    });

    test('הודעה מחוץ לחלון הטריות נדחית, בשני הכיוונים', () {
      final stale = buildMessage(
        timestampMs: DateTime.now().millisecondsSinceEpoch -
            freshnessWindow.inMilliseconds -
            1000,
      );
      expect(SyncMessage.decode(stale.encode(room), room), isNull);

      final future = buildMessage(
        timestampMs: DateTime.now().millisecondsSinceEpoch +
            freshnessWindow.inMilliseconds +
            1000,
      );
      expect(SyncMessage.decode(future.encode(room), room), isNull);
    });

    test('בייטים שאינם JSON תקין נדחים בשקט', () {
      expect(SyncMessage.decode([1, 2, 3, 255], room), isNull);
      expect(SyncMessage.decode(utf8.encode('[]'), room), isNull);
      expect(SyncMessage.decode(utf8.encode('{}'), room), isNull);
    });
  });
}
