import 'package:chavruta_companion/config.dart';
import 'package:chavruta_companion/protocol.dart';
import 'package:chavruta_companion/sync_hub.dart';
import 'package:test/test.dart';

import 'support/fake_transport.dart';
import 'support/temp_config.dart';

const chavrutaId = '99887766';

SyncMessage incoming({
  SyncMessageType type = SyncMessageType.location,
  SyncLocation? location = const SyncLocation(bookId: 'ברכות', index: 12),
  String senderId = chavrutaId,
  String senderName = 'החברותא',
  int sequence = 1,
  int? timestampMs,
  List<DeskEntry> entries = const [],
}) => SyncMessage(
  type: type,
  roomHash: SyncMessage.hashRoomCode('חדר'),
  senderId: senderId,
  senderName: senderName,
  timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
  sequence: sequence,
  location: location,
  entries: entries,
);

void main() {
  late TempConfig temp;
  late CompanionConfig config;
  late FakeTransport transport;
  late SyncHub hub;

  /// שעון הבדיקה: הזמן זז בהצהרה ולא בשינה, וכך פקיעת מחוברים נבדקת מיד.
  late DateTime now;

  setUp(() async {
    temp = await TempConfig.create();
    config = temp.config(roomCode: 'חדר');
    transport = FakeTransport();
    now = DateTime.now();
    hub = SyncHub(
      config: config,
      transport: transport,
      clock: () => now,
    );
  });

  tearDown(() async {
    await hub.dispose();
    await temp.delete();
  });

  group('שידור מקומי', () {
    test('מיקום מקומי משודר לחברותא', () async {
      expect(
        await hub.publishLocal(const SyncLocation(bookId: 'שבת', index: 5)),
        isTrue,
      );
      expect(transport.sent, hasLength(1));
      expect(transport.sent.single.type, SyncMessageType.location);
      expect(transport.sent.single.location!.bookId, 'שבת');
      expect(transport.sent.single.senderId, config.deviceId);
    });

    test('מתאם לא מזווג אינו משדר כלום', () async {
      config.roomCode = null;
      expect(
        await hub.publishLocal(const SyncLocation(bookId: 'שבת', index: 5)),
        isFalse,
      );
      expect(transport.sent, isEmpty);
      // אבל המיקום המקומי נשמר, כדי שיישלח ברגע שיזווגו.
      expect(hub.snapshot()['localLocation'], isNotNull);
    });

    test('מספר הסידור עולה בכל שידור', () async {
      await hub.publishLocal(const SyncLocation(bookId: 'שבת', index: 1));
      await hub.publishLocal(const SyncLocation(bookId: 'שבת', index: 2));
      expect(
        transport.sent[1].sequence,
        greaterThan(transport.sent[0].sequence),
      );
    });
  });

  group('זיהוי הד', () {
    test('מיקום שנמסר לתוסף ומיד חוזר ממנו אינו משודר בחזרה', () async {
      const spot = SyncLocation(bookId: 'ברכות', index: 12);
      hub.markHandedToPlugin(spot);
      expect(await hub.publishLocal(spot), isFalse);
      expect(transport.sent, isEmpty);
    });

    test('מיקום אחר אחרי מסירה לתוסף כן משודר', () async {
      hub.markHandedToPlugin(const SyncLocation(bookId: 'ברכות', index: 12));
      expect(
        await hub.publishLocal(const SyncLocation(bookId: 'ברכות', index: 13)),
        isTrue,
      );
      expect(transport.sent, hasLength(1));
    });

    test('הד מזוהה לפי מקום, גם כשה-ref שונה', () async {
      hub.markHandedToPlugin(const SyncLocation(bookId: 'ברכות', index: 12));
      expect(
        await hub.publishLocal(
          const SyncLocation(bookId: 'ברכות', index: 12, ref: 'ברכות דף ד'),
        ),
        isFalse,
      );
    });
  });

  group('קליטה מהרשת', () {
    test('עדכון מיקום מרוחק מקדם את המונה ונכנס ל-snapshot', () async {
      expect(hub.remoteSequence, 0);
      await transport.deliver(incoming());

      expect(hub.remoteSequence, 1);
      final remote = hub.snapshot()['remote'] as Map;
      expect((remote['location'] as Map)['bookId'], 'ברכות');
      expect(remote['fromName'], 'החברותא');
      expect(hub.snapshot()['peers'], hasLength(1));
    });

    test('הודעה שלנו שחזרה מהרשת מתעלמים ממנה', () async {
      await transport.deliver(incoming(senderId: config.deviceId));
      expect(hub.remoteSequence, 0);
      expect(hub.snapshot()['peers'], isEmpty);
    });

    test('נוכחות מוסיפה מחובר בלי לשנות מיקום', () async {
      await transport.deliver(
        incoming(type: SyncMessageType.presence, location: null),
      );
      expect(hub.remoteSequence, 0);
      expect(hub.snapshot()['remote'], isNull);
      expect(hub.snapshot()['peers'], hasLength(1));
    });

    test('פרידה מסירה את המחובר', () async {
      await transport.deliver(
        incoming(type: SyncMessageType.presence, location: null),
      );
      expect(hub.snapshot()['peers'], hasLength(1));

      await transport.deliver(
        incoming(type: SyncMessageType.farewell, location: null, sequence: 2),
      );
      expect(hub.snapshot()['peers'], isEmpty);
    });

    test('הודעה כפולה או מאוחרת אינה מייצרת עדכון נוסף', () async {
      final first = incoming(sequence: 5);
      await transport.deliver(first);
      expect(hub.remoteSequence, 1);

      // אותה הודעה בדיוק — broadcast שהגיע פעמיים.
      await transport.deliver(first);
      expect(hub.remoteSequence, 1);

      // הודעה ישנה יותר שהגיעה באיחור.
      await transport.deliver(
        incoming(
          sequence: 4,
          timestampMs: first.timestampMs - 1000,
          location: const SyncLocation(bookId: 'שבת', index: 1),
        ),
      );
      expect(hub.remoteSequence, 1);
    });

    test('חברותא שהופעלה מחדש והמונה שלה התאפס עדיין נקלטת', () async {
      final first = incoming(sequence: 40);
      await transport.deliver(first);
      expect(hub.remoteSequence, 1);

      await transport.deliver(
        incoming(
          sequence: 1,
          timestampMs: first.timestampMs + 1000,
          location: const SyncLocation(bookId: 'שבת', index: 9),
        ),
      );
      expect(hub.remoteSequence, 2);
    });

    test('מיקום שאנחנו כבר נמצאים בו אינו עדכון', () async {
      await hub.publishLocal(const SyncLocation(bookId: 'ברכות', index: 12));
      await transport.deliver(incoming());
      expect(hub.remoteSequence, 0);
      // אבל הצד השני נרשם כמחובר.
      expect(hub.snapshot()['peers'], hasLength(1));
    });

    test('שם מחובר מתעדכן כשהוא משתנה', () async {
      await transport.deliver(
        incoming(type: SyncMessageType.presence, location: null),
      );
      await transport.deliver(
        incoming(
          type: SyncMessageType.presence,
          location: null,
          sequence: 2,
          senderName: 'שם חדש',
        ),
      );
      final peers = hub.snapshot()['peers'] as List;
      expect(peers, hasLength(1));
      expect((peers.single as Map)['name'], 'שם חדש');
    });
  });

  group('setRoom', () {
    test('כניסה לחדר משדרת נוכחות ושומרת לקונפיג', () async {
      await hub.setRoom('  חדר   חדש  ');
      expect(config.roomCode, 'חדר חדש');
      expect(
        transport.sent.map((m) => m.type),
        contains(SyncMessageType.presence),
      );

      final saved = await CompanionConfig.load(storageDir: temp.dir);
      expect(saved.roomCode, 'חדר חדש');
    });

    test('יציאה מהחדר משדרת פרידה ומנקה את המצב', () async {
      await transport.deliver(incoming());
      expect(hub.snapshot()['peers'], hasLength(1));

      await hub.setRoom('');
      expect(config.isPaired, isFalse);
      expect(
        transport.sent.map((m) => m.type),
        contains(SyncMessageType.farewell),
      );
      expect(hub.snapshot()['peers'], isEmpty);
      expect(hub.snapshot()['remote'], isNull);
    });

    test('אותו קוד פעמיים אינו עושה כלום', () async {
      await hub.setRoom('חדר');
      expect(transport.sent, isEmpty);
    });

    test('מצב של חדר אחד אינו נשפך לחדר הבא', () async {
      await transport.deliver(incoming());
      final before = hub.remoteSequence;
      await hub.setRoom('חדר אחר');

      expect(hub.snapshot()['remote'], isNull);
      // המונה חייב לעלות, כדי שהתוסף ידע שהמצב התחלף ולא יישאר עם הישן.
      expect(hub.remoteSequence, greaterThan(before));
    });
  });

  group('setDeviceName', () {
    test('שם חדש נשמר ומשודר', () async {
      await hub.setDeviceName('  המחשב של אמא  ');
      expect(config.deviceName, 'המחשב של אמא');
      expect(transport.sent.single.senderName, 'המחשב של אמא');
      final saved = await CompanionConfig.load(storageDir: temp.dir);
      expect(saved.deviceName, 'המחשב של אמא');
    });

    test('שם ריק או זהה אינו משנה כלום', () async {
      final original = config.deviceName;
      await hub.setDeviceName('   ');
      await hub.setDeviceName(original);
      expect(config.deviceName, original);
      expect(transport.sent, isEmpty);
    });
  });

  group('waitForChange', () {
    test('משתחררת מיד כשמגיע עדכון מהרשת', () async {
      final waiting = hub.waitForChange(const Duration(seconds: 5));
      await transport.deliver(incoming());
      await expectLater(waiting, completes);
    });

    test('משתחררת בתום הזמן גם בלי עדכון', () async {
      await expectLater(
        hub.waitForChange(const Duration(milliseconds: 20)),
        completes,
      );
    });
  });

  test('snapshot מכיל את מה שהתוסף צריך', () async {
    final snapshot = hub.snapshot();
    expect(snapshot['deviceId'], config.deviceId);
    expect(snapshot['deviceName'], config.deviceName);
    expect(snapshot['paired'], isTrue);
    expect(snapshot['lanBound'], isTrue);
    expect(snapshot['remoteSequence'], 0);
    expect(snapshot['peers'], isEmpty);
  });

  group('היכרות מיידית', () {
    test('מחובר חדש מקבל נוכחות מיד, בלי להמתין לפעימה', () async {
      // בלי זה: הצד שהצטרף שני שומע אותנו מיד, אבל אנחנו נשמע ממנו רק
      // בעוד presenceInterval — ועד אז המסך שלו אומר "ממתין לחברותא".
      await transport.deliver(incoming(type: SyncMessageType.presence));

      expect(
        transport.sent.where((m) => m.type == SyncMessageType.presence),
        hasLength(1),
      );
    });

    test('מחובר מוכר אינו גורר נוכחות נוספת', () async {
      await transport.deliver(incoming(type: SyncMessageType.presence));
      transport.sent.clear();

      // ההיכרות נסגרת אחרי סבב אחד; אחרת שני מתאמים היו עונים זה לזה
      // בלי סוף.
      await transport.deliver(
        incoming(type: SyncMessageType.presence, sequence: 2),
      );
      expect(transport.sent, isEmpty);
    });

    test('הודעת פרידה אינה נחשבת מחובר חדש', () async {
      await transport.deliver(
        incoming(type: SyncMessageType.farewell, location: null),
      );
      expect(transport.sent, isEmpty);
    });
  });

  test('מחובר שנעלם נשמט מהרשימה אחרי peerTimeout', () async {
    await transport.deliver(
      incoming(type: SyncMessageType.presence, location: null),
    );
    expect(hub.snapshot()['peers'], hasLength(1));

    now = now.add(peerTimeout + const Duration(seconds: 1));
    expect(hub.snapshot()['peers'], isEmpty);
  });

  test('שעון מקדים אצל החברותא אינו משאיר אותה מחוברת', () async {
    // חותמת הזמן שעל החוט מקדימה בארבע דקות — עוד בתוך freshnessWindow,
    // ולכן ההודעה מתקבלת. כשהיא זו שנרשמה כ"נראה לאחרונה", המחובר נשאר
    // ברשימה דקות ארוכות אחרי שהמחשב שלו כבר כבוי, והתוסף הציג "מסונכרן"
    // בלי שיש עם מי.
    await transport.deliver(
      incoming(
        type: SyncMessageType.presence,
        location: null,
        timestampMs: now.add(const Duration(minutes: 4)).millisecondsSinceEpoch,
      ),
    );
    expect(hub.snapshot()['peers'], hasLength(1));

    now = now.add(peerTimeout + const Duration(seconds: 1));
    expect(hub.snapshot()['peers'], isEmpty);
  });

  group('ההחזקה על מנוע הסנכרון', () {
    test('המופע הראשון מקבל אותה, והשני נדחה', () {
      expect(hub.claimEngine('foreground:a'), isTrue);
      expect(hub.claimEngine('foreground:b'), isFalse);
      // וההחזקה מתחדשת בכל פנייה של המחזיק, בלי פעימה נפרדת.
      expect(hub.claimEngine('foreground:a'), isTrue);
    });

    test('רקע גובר על לשונית גם כשהלשונית הגיעה ראשונה', () {
      // הלשונית מוקפאת ברגע שהמשתמש עובר לספר, ואילו מופע הרקע חי כל זמן
      // שאוצריא פתוחה. לכן הוא המחזיק הנכון ברגע שהוא מבקש.
      expect(hub.claimEngine('foreground:a'), isTrue);
      expect(hub.claimEngine('background:x'), isTrue);
      expect(hub.claimEngine('foreground:a'), isFalse);
    });

    test('לשונית אינה חוטפת מרקע חי', () {
      expect(hub.claimEngine('background:x'), isTrue);
      expect(hub.claimEngine('foreground:a'), isFalse);
      expect(hub.engineStatus()['owner'], 'background:x');
    });

    test('החזקה שנדמה עוברת למופע הבא שמבקש', () {
      // **זה מה שמציל את המצב שהיה כאן.** מופע רקע שאוצריא סגרה — הרשאת
      // keep-alive שלא אושרה — מפסיק לפנות, וההחזקה שלו פוגה. בלי זה
      // הלשונית הייתה ממתינה לו לנצח, ואף אחד לא היה מסנכרן.
      expect(hub.claimEngine('background:x'), isTrue);
      expect(hub.claimEngine('foreground:a'), isFalse);

      now = now.add(engineLeaseTimeout + const Duration(seconds: 1));
      expect(hub.claimEngine('foreground:a'), isTrue);
      expect(hub.engineStatus()['owner'], 'foreground:a');
    });

    test('שחרור מסודר מפנה מיד ומעיר את הממתינים', () async {
      expect(hub.claimEngine('background:x'), isTrue);

      var woke = false;
      final waiting = hub.waitForChange(const Duration(minutes: 1))
        ..then((_) => woke = true);

      hub.releaseEngine('background:x');
      await waiting;

      expect(woke, isTrue);
      expect(hub.engineStatus()['owner'], isNull);
      expect(hub.claimEngine('foreground:a'), isTrue);
    });

    test('שחרור בידי מי שאינו המחזיק אינו עושה כלום', () {
      expect(hub.claimEngine('background:x'), isTrue);
      hub.releaseEngine('foreground:a');
      expect(hub.engineStatus()['owner'], 'background:x');
    });

    test('מזהה ריק אינו נועל את ההחזקה', () {
      // `curl` ובדיקות ידניות פונים בלי `instance`, ואסור שפנייה כזאת
      // תיקח את ההחזקה מהמנוע האמיתי או תיחסם על ידו.
      expect(hub.claimEngine('background:x'), isTrue);
      expect(hub.claimEngine(''), isTrue);
      expect(hub.engineStatus()['owner'], 'background:x');
    });

    test('בלי מנוע כלל ה-snapshot אומר זאת במפורש', () {
      // זה השדה שהיה חסר: "אף אחד אינו מסנכרן" נראה מבחוץ בדיוק כמו
      // תקלת רשת, ולא הייתה שום דרך להבדיל.
      expect((hub.snapshot()['engine'] as Map)['owner'], isNull);

      expect(hub.claimEngine('background:x'), isTrue);
      final engine = hub.snapshot()['engine'] as Map;
      expect(engine['owner'], 'background:x');
      expect(engine['ageMs'], 0);
    });
  });

  group('השולחן המשותף', () {
    List<SyncMessage> deskMessages() =>
        transport.sent.where((m) => m.type == SyncMessageType.desk).toList();

    List<DeskEntry> broadcastEntries() =>
        deskMessages().expand((m) => m.entries).toList();

    List<String> broadcastBooks() =>
        broadcastEntries().map((e) => e.bookId).toList();

    DeskEntry local(String bookId, {int index = 0}) =>
        DeskEntry(bookId: bookId, index: index, stamp: 0, by: '');

    /// חותמת של החברותא שגוברת על מה שנקבע כאן.
    ///
    /// שני הצדדים חותמים לפי שעון, ולכן חותמת קטנה שרירותית הייתה
    /// מפסידה לכל פעולה מקומית — ובדיקה כזאת הייתה בודקת את ההפך ממה
    /// שהיא מתיימרת לבדוק.
    int remoteStamp([int offset = 0]) =>
        now.millisecondsSinceEpoch + 60000 + offset;

    SyncMessage deskFrom(
      List<DeskEntry> entries, {
      int sequence = 1,
    }) => incoming(
      type: SyncMessageType.desk,
      location: null,
      sequence: sequence,
      entries: entries,
    );

    /// דיווח ראשון קובע קו בסיס ואינו משתף כלום — ראו `_sawFirstReport`.
    Future<void> baseline([List<DeskEntry> tabs = const []]) async {
      await hub.publishLocalDesk(tabs, canClose: true);
      transport.sent.clear();
    }

    test('הדיווח הראשון אינו משתף דבר, והוא מציע להעביר', () async {
      // ספר שכבר היה פתוח כשהתחברת אינו "ספר שנפתח עכשיו". השולחן
      // המשותף מתחיל ריק, והמשתמש בוחר מה להעביר אליו.
      expect(await hub.publishLocalDesk([local('ברכות')]), 0);
      expect(deskMessages(), isEmpty);
      expect(hub.carryCandidates().map((e) => e.bookId), ['ברכות']);
    });

    test('ספר שנפתח אחרי החיבור מצטרף לשולחן מעצמו', () async {
      await baseline([local('ברכות')]);

      expect(
        await hub.publishLocalDesk([local('ברכות'), local('שבת', index: 5)]),
        1,
      );
      expect(broadcastBooks(), ['שבת']);
      expect(broadcastEntries().single.open, isTrue);
      expect(broadcastEntries().single.index, 5);
    });

    test('העברה יזומה משתפת ספר שכבר היה פתוח', () async {
      await baseline([local('ברכות'), local('שבת')]);

      expect(await hub.carryToDesk(['ברכות']), 1);
      expect(broadcastBooks(), ['ברכות']);
      expect(hub.carryCandidates().map((e) => e.bookId), ['שבת']);
    });

    test('אי אפשר להעביר ספר שאינו פתוח כאן', () async {
      await baseline([local('ברכות')]);
      expect(await hub.carryToDesk(['ספר שאינו פתוח']), 0);
      expect(deskMessages(), isEmpty);
    });

    test('ספר שנסגר כאן משודר כסגירה', () async {
      await baseline();
      await hub.publishLocalDesk([local('ברכות')]);
      transport.sent.clear();

      expect(await hub.publishLocalDesk(const []), 1);
      final closed = broadcastEntries().single;
      expect(closed.bookId, 'ברכות');
      expect(closed.open, isFalse);
    });

    test('ספר שמעולם לא היה פתוח כאן אינו מדווח כסגירה', () async {
      // זו הנקודה העדינה: החברותא פתחה ספר שאינו בספרייה שלנו, ולכן הוא
      // אינו ברשימה המקומית. דיווח שלו כסגירה היה מוחק מהשולחן דווקא את
      // מה שהיא פתחה.
      await baseline();
      await transport.deliver(
        deskFrom([DeskEntry(bookId: 'ספר נדיר', stamp: remoteStamp(), by: 'חברותא')]),
      );
      transport.sent.clear();

      expect(await hub.publishLocalDesk(const []), 0);
      expect(deskMessages(), isEmpty);
    });

    test('רשימה ארוכה נשלחת במנות, כדי לא להתפצל ברמת ה-IP', () async {
      await baseline();
      final many = [
        for (var i = 0; i < maxTabsPerMessage * 2 + 3; i++) local('ספר $i'),
      ];
      await hub.publishLocalDesk(many);

      expect(deskMessages(), hasLength(3));
      for (final message in deskMessages()) {
        expect(message.entries.length, lessThanOrEqualTo(maxTabsPerMessage));
      }
      expect(broadcastBooks(), hasLength(many.length));
    });

    test('תוכנית: מה לפתוח ומה לסגור', () async {
      await baseline([local('ברכות')]);
      await hub.carryToDesk(['ברכות']);

      await transport.deliver(
        deskFrom([
          DeskEntry(bookId: 'שבת', index: 3, stamp: remoteStamp(), by: 'חברותא'),
          DeskEntry(bookId: 'ברכות', stamp: remoteStamp(1), by: 'חברותא', open: false),
        ]),
      );

      final plan = hub.deskPlan();
      expect(plan.open.map((e) => e.bookId), ['שבת']);
      expect(plan.open.single.index, 3);
      expect(plan.close.map((e) => e.bookId), ['ברכות']);
    });

    test('בלי יכולת סגירה בצד התוסף אין סגירות בתוכנית', () async {
      // אחרת התוכנית לא הייתה מתרוקנת לעולם, ו-`/events` לא היה נכנס
      // להמתנה — לולאה עמוסה במקום סנכרון.
      await hub.publishLocalDesk([local('ברכות')], canClose: false);
      await hub.carryToDesk(['ברכות']);
      await transport.deliver(
        deskFrom([
          DeskEntry(bookId: 'ברכות', stamp: remoteStamp(), by: 'חברותא', open: false),
        ]),
      );

      expect(hub.deskPlan().close, isEmpty);
      expect(hub.hasDeskWork, isFalse);
    });

    test('מדיניות "לא לסגור" מוציאה סגירות מהתוכנית', () async {
      await baseline([local('ברכות')]);
      await hub.carryToDesk(['ברכות']);
      await hub.setClosePolicy(ClosePolicy.never);
      await transport.deliver(
        deskFrom([
          DeskEntry(bookId: 'ברכות', stamp: remoteStamp(), by: 'חברותא', open: false),
        ]),
      );

      expect(hub.deskPlan().close, isEmpty);
    });

    test('"להשאיר פתוח" אינו פותח את הספר מחדש אצל החברותא', () async {
      // הבאג שהמודל הזה נועד למנוע: הספר פתוח כאן בזמן שהשולחן אומר
      // "סגור", והסריקה הבאה הייתה מפרשת את הפער כפתיחה חדשה.
      await baseline([local('ברכות')]);
      await hub.carryToDesk(['ברכות']);
      await transport.deliver(
        deskFrom([
          DeskEntry(bookId: 'ברכות', stamp: remoteStamp(), by: 'חברותא', open: false),
        ]),
      );
      hub.dismissClose('ברכות');
      transport.sent.clear();

      expect(await hub.publishLocalDesk([local('ברכות')]), 0);
      expect(deskMessages(), isEmpty);
      expect(hub.deskPlan().close, isEmpty, reason: 'והשאלה אינה חוזרת');
    });

    test('ספר שלא נפתח כאן אינו מוצע שוב', () async {
      await baseline();
      await transport.deliver(
        deskFrom([DeskEntry(bookId: 'ספר נדיר', stamp: remoteStamp(), by: 'חברותא')]),
      );
      expect(hub.deskPlan().open.map((e) => e.bookId), ['ספר נדיר']);

      await hub.publishLocalDesk(const [], failed: const ['ספר נדיר']);
      expect(hub.deskPlan().open, isEmpty);
      expect(hub.hasDeskWork, isFalse);
    });

    test('מיזוג לפי חותמת: המאוחרת מנצחת, בלי תלות בסדר ההגעה', () async {
      await baseline();
      await transport.deliver(
        deskFrom([
          DeskEntry(bookId: 'ברכות', stamp: remoteStamp(), by: 'חברותא', open: false),
        ]),
      );
      // הודעה ישנה יותר שהגיעה באיחור אינה מחזירה את הגלגל.
      await transport.deliver(
        deskFrom([
          const DeskEntry(bookId: 'ברכות', stamp: 800, by: 'חברותא'),
        ], sequence: 2),
      );

      expect(hub.deskPlan().open, isEmpty);
      expect(hub.snapshot()['deskCount'], 0);
    });

    test('חותמת מקומית גוברת על שעון של חברותא שרץ קדימה', () async {
      // בלי השעון הלוגי, מחשב שהשעון שלו מקדים בדקות היה מנצח כל
      // הכרעה — וכל ספר שהוא סגר היה נסגר שוב ושוב אצל השני.
      await baseline();
      final future = now.millisecondsSinceEpoch + 240000;
      await transport.deliver(
        deskFrom([
          DeskEntry(bookId: 'ברכות', stamp: future, by: 'חברותא', open: false),
        ]),
      );

      await hub.carryToDesk(['ברכות']);
      await hub.publishLocalDesk([local('ברכות')]);
      await hub.carryToDesk(['ברכות']);

      final mine = broadcastEntries().where((e) => e.bookId == 'ברכות');
      expect(mine, isNotEmpty, reason: 'ההעברה שלי יצאה');
      expect(mine.last.stamp, greaterThan(future));
    });

    test('חברותא שהצטרפה מקבלת את השולחן כולו', () async {
      await baseline([local('ברכות')]);
      await hub.carryToDesk(['ברכות']);
      transport.sent.clear();

      await transport.deliver(incoming(
        type: SyncMessageType.presence,
        location: null,
        senderId: 'מכשיר-חדש',
      ));

      expect(broadcastBooks(), ['ברכות']);
    });

    test('יציאה מהחברותא מוחקת את השולחן', () async {
      await baseline([local('ברכות')]);
      await hub.carryToDesk(['ברכות']);
      await hub.setRoom(null);

      expect(hub.snapshot()['deskCount'], 0);
      expect(hub.hasDeskWork, isFalse);
    });

    test('ה-snapshot מדווח את מצב השולחן וההעדפות', () async {
      await baseline([local('ברכות')]);
      await hub.carryToDesk(['ברכות']);

      final snapshot = hub.snapshot();
      expect(snapshot['deskCount'], 1);
      expect(snapshot['localTabCount'], 1);
      expect(snapshot['syncLocation'], isTrue);
      expect(snapshot['closePolicy'], 'ask');
      expect(snapshot['canClose'], isTrue);
    });

    test('כיבוי מקום הלימוד עוצר את שידור המיקום, ולא את השולחן', () async {
      await hub.setSyncLocation(false);
      expect(
        await hub.publishLocal(const SyncLocation(bookId: 'שבת', index: 5)),
        isFalse,
      );
      expect(
        transport.sent.where((m) => m.type == SyncMessageType.location),
        isEmpty,
      );
      // אבל המיקום המקומי נשמר, כדי שהלשונית תמשיך להראות "המקום שלי".
      expect(hub.snapshot()['localLocation'], isNotNull);

      await baseline();
      await hub.publishLocalDesk([local('ברכות')]);
      expect(broadcastBooks(), ['ברכות'], reason: 'השולחן ממשיך לעבוד');
    });
  });

  group('שני מתאמים מתכנסים', () {
    late TempConfig otherTemp;
    late CompanionConfig otherConfig;
    late FakeTransport otherTransport;
    late SyncHub other;

    setUp(() async {
      otherTemp = await TempConfig.create();
      otherConfig = CompanionConfig(
        deviceId: 'ffee0011',
        deviceName: 'המחשב השני',
        roomCode: 'חדר',
        storageDir: otherTemp.dir,
      );
      otherTransport = FakeTransport();
      other = SyncHub(config: otherConfig, transport: otherTransport);
    });

    tearDown(() async {
      await other.dispose();
      await otherTemp.delete();
    });

    /// מעביר כל מה ששודר מ-[from] אל הצד השני, כמו broadcast ברשת.
    Future<void> flush(FakeTransport from, FakeTransport to) async {
      final pending = List<SyncMessage>.from(from.sent);
      from.sent.clear();
      for (final message in pending) {
        await to.deliver(message);
      }
    }

    DeskEntry local(String bookId) =>
        DeskEntry(bookId: bookId, stamp: 0, by: '');

    test('פתיחה, סגירה, והכל מתכנס בלי הד', () async {
      // קו בסיס בשני הצדדים, ואז העברה מפורשת לשולחן.
      await hub.publishLocalDesk([local('ברכות')], canClose: true);
      await other.publishLocalDesk(const [], canClose: true);
      transport.sent.clear();
      otherTransport.sent.clear();

      await hub.carryToDesk(['ברכות']);
      await flush(transport, otherTransport);

      // הצד השני מתבקש לפתוח, פותח, ומדווח.
      expect(other.deskPlan().open.map((e) => e.bookId), ['ברכות']);
      await other.publishLocalDesk([local('ברכות')], canClose: true);
      expect(
        otherTransport.sent.where((m) => m.type == SyncMessageType.desk),
        isEmpty,
        reason: 'ספר שבא ממנו אינו חוזר אליו',
      );

      // עכשיו הוא סוגר אותו, והסגירה עוברת בכיוון ההפוך.
      await other.publishLocalDesk(const [], canClose: true);
      expect(
        otherTransport.sent
            .where((m) => m.type == SyncMessageType.desk)
            .expand((m) => m.entries)
            .single
            .open,
        isFalse,
      );
      await flush(otherTransport, transport);

      expect(hub.deskPlan().close.map((e) => e.bookId), ['ברכות']);

      // וכשהצד הראשון סוגר בפועל, שני השולחנות זהים ואיש אינו משדר עוד.
      transport.sent.clear();
      await hub.publishLocalDesk(const [], canClose: true);
      expect(
        transport.sent.where((m) => m.type == SyncMessageType.desk),
        isEmpty,
        reason: 'הסגירה כבר בשולחן — אין מה להודיע',
      );
      expect(hub.hasDeskWork, isFalse);
      expect(other.hasDeskWork, isFalse);
    });
  });

  /// חותמת הפריט (`s`) אינה מאומתת בשום מקום אחר: `DeskEntry.fromJson`
  /// מקבל כל מספר אי-שלילי, ובדיקת הטריות חלה על `ts` של המעטפת בלבד.
  group('חותמת שולחן חורגת', () {
    DeskEntry poisoned(int stamp) =>
        DeskEntry(bookId: 'ברכות', stamp: stamp, by: 'חברותא');

    test('פריט עם חותמת של שנים קדימה נזרק', () async {
      // hub משלו, כדי לתפוס את היומן: `onLog` נקבע בבנייה.
      final logs = <String>[];
      final logged = SyncHub(
        config: config,
        transport: transport,
        clock: () => now,
        onLog: logs.add,
      );
      addTearDown(logged.dispose);
      await logged.publishLocalDesk(const [], canClose: true);

      final farFuture = now.millisecondsSinceEpoch +
          const Duration(days: 3650).inMilliseconds;
      await transport.deliver(
        incoming(
          type: SyncMessageType.desk,
          location: null,
          entries: [poisoned(farFuture)],
        ),
      );

      expect(logged.deskPlan().open, isEmpty, reason: 'הפריט לא נכנס לשולחן');
      expect(
        logs.any((line) => line.contains('חורגת')),
        isTrue,
        reason: 'ונאמר למה, כי אחרת זה שקט מוחלט',
      );
    });

    /// **זה הנזק שהשער מונע.** בלי הבדיקה החותמת הייתה מקדמת את השעון
    /// הלוגי לאותו מקום, ומאותו רגע כל פעולה אמיתית של החברותא מפסידה
    /// בהכרעה — הספר נתקע במצבו והצד השני מושתק בשקט.
    test('חותמת חורגת אינה מרעילה את השעון הלוגי', () async {
      await hub.publishLocalDesk(const [], canClose: true);
      final farFuture = now.millisecondsSinceEpoch +
          const Duration(days: 3650).inMilliseconds;
      await transport.deliver(
        incoming(
          type: SyncMessageType.desk,
          location: null,
          entries: [poisoned(farFuture)],
        ),
      );

      // פעולה מקומית אחרי ההרעלה: החותמת שלה צריכה להיות שעון הקיר,
      // ולא `farFuture + 1`.
      await hub.publishLocalDesk([
        const DeskEntry(bookId: 'שבת', stamp: 0, by: 'x'),
      ]);
      await hub.carryToDesk(['שבת']);
      final ours = transport.sent
          .where((m) => m.type == SyncMessageType.desk)
          .expand((m) => m.entries)
          .where((e) => e.bookId == 'שבת')
          .single;
      expect(ours.stamp, lessThan(farFuture));
    });

    test('החלפת חדר מאפסת את השעון הלוגי', () async {
      await hub.publishLocalDesk(const [], canClose: true);
      final ahead = now.millisecondsSinceEpoch +
          const Duration(minutes: 4).inMilliseconds;
      await transport.deliver(
        incoming(
          type: SyncMessageType.desk,
          location: null,
          entries: [DeskEntry(bookId: 'ברכות', stamp: ahead, by: 'חברותא')],
        ),
      );

      await hub.setRoom('חדר אחר');
      transport.sent.clear();

      await hub.publishLocalDesk([
        const DeskEntry(bookId: 'שבת', stamp: 0, by: 'x'),
      ]);
      await hub.carryToDesk(['שבת']);
      final ours = transport.sent
          .where((m) => m.type == SyncMessageType.desk)
          .expand((m) => m.entries)
          .single;
      expect(
        ours.stamp,
        lessThanOrEqualTo(now.millisecondsSinceEpoch),
        reason: 'החדר החדש מתחיל משעון הקיר, ולא מהחותמת של החדר הקודם',
      );
    });
  });

  /// `bye` הייתה סוג ההודעה היחיד שיצא לפני סינון הכפילויות, ולכן היחיד
  /// בלי שום הגנת replay: מי שקלט דטגרמת פרידה אחת ושידר אותה שוב ושוב
  /// הוציא את החברותא מרשימת המחוברים בכל פעם, והמסך של הצד השני היה
  /// מהבהב בין "מסונכרן" ל"ממתין לחברותא". הוא אינו צריך לדעת את הקוד.
  group('הודעת פרידה', () {
    test('bye מוציא את החברותא מהמחוברים', () async {
      await transport.deliver(incoming(sequence: 1));
      expect(hub.snapshot()['peers'], hasLength(1));

      await transport.deliver(
        incoming(type: SyncMessageType.farewell, location: null, sequence: 2),
      );
      expect(hub.snapshot()['peers'], isEmpty);
    });

    test('שידור חוזר של אותה bye אינו מוציא שוב', () async {
      await transport.deliver(incoming(sequence: 1));
      final bye = incoming(
        type: SyncMessageType.farewell,
        location: null,
        sequence: 2,
      );
      await transport.deliver(bye);
      expect(hub.snapshot()['peers'], isEmpty);

      // החברותא חזרה, והתוקף משדר מחדש את אותה דטגרמת פרידה.
      await transport.deliver(incoming(sequence: 3));
      expect(hub.snapshot()['peers'], hasLength(1));
      await transport.deliver(bye);
      expect(
        hub.snapshot()['peers'],
        hasLength(1),
        reason: 'הודעה כפולה, ולכן נזרקת כמו כל הודעה כפולה',
      );
    });
  });

  /// מנות של אותו שידור נבנות באותה מילישנייה עם מונה עולה, ולכן היפוך
  /// סדר של שתי מנות נראה לסינן הכפילויות כהודעה כפולה — והמנה
  /// הראשונה, שנים-עשר ספרים, נזרקה בשלמותה ולא חזרה.
  test('שתי מנות שולחן שהגיעו בסדר הפוך — שתיהן נכנסות', () async {
    await hub.publishLocalDesk(const [], canClose: true);
    final stamp = now.millisecondsSinceEpoch;
    final ts = now.millisecondsSinceEpoch;

    await transport.deliver(
      incoming(
        type: SyncMessageType.desk,
        location: null,
        sequence: 2,
        timestampMs: ts,
        entries: [DeskEntry(bookId: 'שני', stamp: stamp, by: 'חברותא')],
      ),
    );
    await transport.deliver(
      incoming(
        type: SyncMessageType.desk,
        location: null,
        sequence: 1,
        timestampMs: ts,
        entries: [DeskEntry(bookId: 'ראשון', stamp: stamp, by: 'חברותא')],
      ),
    );

    expect(
      hub.deskPlan().open.map((e) => e.bookId).toSet(),
      {'ראשון', 'שני'},
    );
  });

  /// כל שולח חדש מייצר רשומה, שידור שולחן מלא ושידור נוכחות בתשובה —
  /// כלומר רשימה בלי גבול היא גם זיכרון בלי גבול וגם הגדלת תעבורה 1:1.
  test('רשימת המחוברים אינה גדלה בלי גבול', () async {
    for (var i = 0; i < maxPeers + 20; i++) {
      await transport.deliver(
        incoming(senderId: 'peer${i.toString().padLeft(12, '0')}'),
      );
    }
    expect(hub.snapshot()['peers'], hasLength(maxPeers));
  });

  /// "להשאיר פתוח" סימן את הספר, והסימון נמחק רק כשהחברותא פותחת אותו
  /// מחדש. לכן ספר שהמשתמש סגר בעצמו ופתח שוב לא שודר יותר לעולם וגם
  /// לא הוצע להעברה — כלומר נעשה בלתי-משותף עד החלפת חדר.
  test('ספר שסירבתי לסגור וסגרתי בעצמי חוזר להיות משותף', () async {
    DeskEntry local(String id) => DeskEntry(bookId: id, stamp: 0, by: 'x');

    await hub.publishLocalDesk([local('ברכות')], canClose: true);
    await hub.carryToDesk(['ברכות']);
    await transport.deliver(
      incoming(
        type: SyncMessageType.desk,
        location: null,
        entries: [
          DeskEntry(
            bookId: 'ברכות',
            stamp: now.millisecondsSinceEpoch + 60000,
            by: 'חברותא',
            open: false,
          ),
        ],
      ),
    );
    hub.dismissClose('ברכות');

    // המשתמש סוגר את הספר בעצמו — הסתירה נפתרה.
    await hub.publishLocalDesk(const [], canClose: true);
    transport.sent.clear();

    // ופותח אותו שוב.
    expect(
      await hub.publishLocalDesk([local('ברכות')], canClose: true),
      1,
      reason: 'פתיחה חדשה, ולכן משודרת',
    );
  });

  /// **המנה נמדדת בבייטים ולא בפריטים.** מנה של שנים-עשר פריטים עם שמות
  /// ספרים אמיתיים מגיעה ל-1265 עד 1985 בייט — מעל ה-MTU — וכל fragment
  /// שאובד על קישור בלוטות' מפיל את ההודעה כולה. אורך שם הספר אינו
  /// חסום, ולכן ספירת פריטים לבדה אינה חוסמת כלום.
  test('מנת שולחן אינה חורגת מ-MTU גם עם שמות ספרים אמיתיים', () async {
    const names = [
      'שולחן ערוך אורח חיים הלכות שבת',
      'שו"ת אגרות משה חלק אורח חיים',
      'ליקוטי מוהר"ן תורה נ"ד',
      'משנה ברורה סימן שכ"ח סעיף קטן י"ד',
      'תלמוד בבלי מסכת בבא מציעא',
      'רמב"ם הלכות תשובה פרק שביעי',
      'ספר החינוך מצווה תרי"ג',
      'מסילת ישרים פרק כ"ו בקדושה',
      'נפש החיים שער רביעי',
      'פרי מגדים אשל אברהם',
      'ערוך השולחן יורה דעה',
      'קצות החושן על חושן משפט',
      'ביאור הלכה על משנה ברורה',
      'שערי תשובה לרבנו יונה',
      'חובות הלבבות שער הביטחון',
    ];
    config.deviceName = 'המחשב של אבא בבית המדרש';

    await hub.publishLocalDesk(const [], canClose: true);
    transport.sent.clear();
    await hub.carryToDesk(const []); // אין מה להעביר; ממשיכים בדיווח מלא

    await hub.publishLocalDesk([
      for (final name in names) DeskEntry(bookId: name, stamp: 0, by: 'x'),
    ], canClose: true);
    await hub.carryToDesk(names);

    final chunks = transport.sent
        .where((m) => m.type == SyncMessageType.desk)
        .toList();
    expect(chunks, isNotEmpty);

    for (final chunk in chunks) {
      final size = chunk.encode('חדר').length;
      expect(
        size,
        lessThanOrEqualTo(1472),
        reason: 'מנה של ${chunk.entries.length} פריטים יצאה $size בייט',
      );
      expect(chunk.entries.length, lessThanOrEqualTo(maxTabsPerMessage));
    }

    // ובכל זאת כל הספרים יצאו, ולא רק הראשונים.
    final sentBooks = chunks.expand((m) => m.entries).map((e) => e.bookId);
    expect(sentBooks.toSet(), containsAll(names));
  });
}
