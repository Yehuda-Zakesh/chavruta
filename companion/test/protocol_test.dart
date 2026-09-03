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

    test('דחייה על פער שעונים מדווחת החוצה, ודחייה על חתימה לא', () {
      // ההבחנה הזו היא כל העניין: הודעה שחתומה נכון ונדחתה על הזמן ודאי
      // הגיעה מהחברותא, ולכן אפשר לומר למשתמש מה לתקן. הודעה עם חתימה
      // שגויה היא רעש רשת, ואסור שתייצר אזהרה.
      final skews = <Duration>[];
      final stale = buildMessage(
        timestampMs: DateTime.now().millisecondsSinceEpoch -
            freshnessWindow.inMilliseconds -
            const Duration(minutes: 7).inMilliseconds,
      );
      expect(
        SyncMessage.decode(stale.encode(room), room, onClockSkew: skews.add),
        isNull,
      );
      expect(skews, hasLength(1));
      expect(skews.first.inMinutes, greaterThanOrEqualTo(11));

      skews.clear();
      SyncMessage.decode(
        tamper(stale, 'sig', 'x' * 32),
        room,
        onClockSkew: skews.add,
      );
      expect(skews, isEmpty);

      skews.clear();
      SyncMessage.decode(buildMessage().encode(room), room, onClockSkew: skews.add);
      expect(skews, isEmpty, reason: 'הודעה טרייה אינה מדווחת על פער');
    });
  });

  group('הודעת שולחן', () {
    const entries = [
      DeskEntry(bookId: 'ברכות', index: 12, stamp: 700, by: 'aabb'),
      DeskEntry(bookId: 'רש"י על בראשית', stamp: 701, by: 'aabb', open: false),
    ];

    SyncMessage deskMessage({List<DeskEntry> list = entries}) => SyncMessage(
      type: SyncMessageType.desk,
      roomHash: SyncMessage.hashRoomCode(room),
      senderId: 'aabb',
      senderName: 'החברותא',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      sequence: 3,
      entries: list,
    );

    test('הלוך ושוב שומר על הפריטים ועל החותמות', () {
      final decoded = SyncMessage.decode(deskMessage().encode(room), room);
      expect(decoded, isNotNull);
      expect(decoded!.type, SyncMessageType.desk);
      expect(decoded.entries.map((e) => e.bookId), ['ברכות', 'רש"י על בראשית']);
      expect(decoded.entries.first.index, 12);
      expect(decoded.entries.first.open, isTrue);
      expect(decoded.entries.last.open, isFalse, reason: 'סגירה עוברת על החוט');
      expect(decoded.entries.last.stamp, 701);
      expect(decoded.entries.last.by, 'aabb');
    });

    test('הודעת שולחן בלי אף פריט תקין נדחית', () {
      expect(
        SyncMessage.decode(deskMessage(list: const []).encode(room), room),
        isNull,
      );
    });

    test('הודעת מיקום אינה נושאת שדה שולחן כלל', () {
      // זו ההבטחה שמחזיקה תאימות אחורה: המפתח `desk` אינו נכנס לצורה
      // הקנונית של הודעת מיקום, ולכן הבייטים שנחתמים זהים לאלה של גרסה
      // שאינה מכירה שולחן בכלל. מפתח שהיה נוסף תמיד היה הופך כל הודעת
      // מיקום לחתומה אחרת, ומתאם שלא שודרג היה דוחה את כולן.
      final wire = jsonDecode(utf8.decode(buildMessage().encode(room))) as Map;
      expect(wire.containsKey('desk'), isFalse);
    });

    /// **הגבול חל על מה שאומת, ולא על מערך החוט.** `desk` שעל החוט אינו
    /// מכוסה בחתימה במלואו: `listFromJson` זורק פריטים פסולים בשקט, ולכן
    /// ריפוד בפריטים פסולים אינו משנה את הצורה הקנונית ואינו שובר את
    /// החתימה — אבל כן מגדיל את אורך המערך. כשהגבול נבדק על המערך הגולמי,
    /// מי שקלט הודעה תקינה ושידר אותה מחדש עם ריפוד היה מפיל אותה.
    test('ריפוד בפריטים פסולים אינו מפיל הודעה חתומה תקינה', () {
      final good = deskMessage(
        list: [
          const DeskEntry(bookId: 'ברכות', stamp: 1, by: 'aabb'),
          const DeskEntry(bookId: 'שבת', stamp: 1, by: 'aabb'),
        ],
      );
      final wire = jsonDecode(utf8.decode(good.encode(room))) as Map;
      wire['desk'] = [
        ...(wire['desk'] as List),
        // פריטים פסולים: `listFromJson` מדלג עליהם, ולכן הצורה הקנונית
        // שנחתמה אינה משתנה.
        for (var i = 0; i < maxTabsPerMessage; i++) {'b': '', 's': 1, 'w': 'x'},
      ];

      final decoded = SyncMessage.decode(utf8.encode(jsonEncode(wire)), room);
      expect(decoded, isNotNull, reason: 'החתימה תקינה, והתוכן תקין');
      expect(decoded!.entries.map((e) => e.bookId), ['ברכות', 'שבת']);
    });

    test('הודעה עם יותר פריטים ממנה אחת נזרקת', () {
      // שולח תקין מפצל למנות; רשימה ארוכה מזה אינה באה מאיתנו. הזריקה
      // כאן היא גם מה שמונע חיתוך שקט — הודעה חתוכה הייתה נכשלת בהמשך
      // באימות החתימה ממילא, בלי שאפשר יהיה לומר למה.
      final many = [
        for (var i = 0; i <= maxTabsPerMessage; i++)
          DeskEntry(bookId: 'ספר $i', stamp: 1, by: 'aabb'),
      ];
      expect(SyncMessage.decode(deskMessage(list: many).encode(room), room), isNull);
    });

    test('כפילויות ועודף נחתכים בקריאת רשימה', () {
      final raw = [
        for (var i = 0; i < maxTrackedTabs + 10; i++)
          {'b': 'ספר $i', 's': 1, 'w': 'x'},
        {'b': 'ספר 0', 's': 2, 'w': 'x'},
        {'b': '', 's': 1, 'w': 'x'},
        {'b': 'בלי חותמת', 'w': 'x'},
        'לא אובייקט',
      ];
      final list = DeskEntry.listFromJson(raw);
      expect(list, hasLength(maxTrackedTabs));
      expect(list.map((e) => e.bookId).toSet(), hasLength(maxTrackedTabs));
    });

    test('הכרעה בין שתי פעולות על אותו ספר', () {
      const early = DeskEntry(bookId: 'ברכות', stamp: 10, by: 'bbbb');
      const later = DeskEntry(bookId: 'ברכות', stamp: 11, by: 'aaaa', open: false);
      expect(early.supersededBy(later), isTrue, reason: 'המאוחרת מנצחת');
      expect(later.supersededBy(early), isFalse);

      // תיקו נשבר לפי מזהה המכשיר, כדי ששני הצדדים יגיעו לאותה תוצאה.
      const tieA = DeskEntry(bookId: 'ברכות', stamp: 10, by: 'aaaa');
      const tieB = DeskEntry(bookId: 'ברכות', stamp: 10, by: 'bbbb');
      expect(tieA.supersededBy(tieB), isTrue);
      expect(tieB.supersededBy(tieA), isFalse);
    });
  });
}
