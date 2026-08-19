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
}) => SyncMessage(
  type: type,
  roomHash: SyncMessage.hashRoomCode('חדר'),
  senderId: senderId,
  senderName: senderName,
  timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
  sequence: sequence,
  location: location,
);

void main() {
  late TempConfig temp;
  late CompanionConfig config;
  late FakeTransport transport;
  late SyncHub hub;

  setUp(() async {
    temp = await TempConfig.create();
    config = temp.config(roomCode: 'חדר');
    transport = FakeTransport();
    hub = SyncHub(config: config, transport: transport);
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

  test('מחובר שנעלם נשמט מהרשימה אחרי peerTimeout', () async {
    await transport.deliver(
      incoming(
        type: SyncMessageType.presence,
        location: null,
        timestampMs:
            DateTime.now().millisecondsSinceEpoch -
            peerTimeout.inMilliseconds -
            1000,
      ),
    );
    expect(hub.snapshot()['peers'], isEmpty);
  });
}
