import 'dart:async';

import 'config.dart';
import 'lan_transport.dart';
import 'protocol.dart';

/// חלון הזמן שבו מיקום שזהה למיקום שהגיע מהחברותא נחשב "הד" ואינו משודר
/// בחזרה. בלעדיו שני מחשבים בסנכרון דו-כיווני היו דוחפים זה לזה את אותו
/// מיקום בלי סוף.
const Duration echoWindow = Duration(seconds: 6);

/// כל כמה זמן משדרים נוכחות, כדי שרשימת המחוברים תהיה עדכנית.
const Duration presenceInterval = Duration(seconds: 20);

/// מכשיר שלא נשמע ממנו כלום בפרק זמן זה נחשב מנותק.
const Duration peerTimeout = Duration(seconds: 70);

/// כמה זמן ההחזקה על מנוע הסנכרון נשארת בתוקף בלי שהמחזיק יגלה סימן חיים.
///
/// המנוע ממתין על `/events` בלופ, וההמתנה נסגרת אחרי `longPollTimeout`
/// (25 שניות) גם כשלא קרה כלום — כלומר מנוע חי פונה לפחות פעם ב-25 שניות.
/// 45 שניות משאירות מרווח לרשת איטית ובכל זאת מעבירות את ההחזקה במהירות.
const Duration engineLeaseTimeout = Duration(seconds: 45);

/// תחילית מזהה המופע של מנוע שרץ ברקע. ראו [SyncHub.claimEngine].
const String backgroundEnginePrefix = 'background';

class PeerInfo {
  PeerInfo({required this.id, required this.name, required this.lastSeenMs});

  final String id;
  String name;

  /// מתי נשמעה ממנו הודעה לאחרונה, **לפי השעון של המחשב הזה**. השעון של
  /// החברותא יכול לסטות עד [freshnessWindow] בלי שההודעות יידחו, ולכן
  /// חותמת הזמן שעל החוט אינה שמישה כאן: מי שהשעון שלו מקדים היה נראה
  /// מחובר עוד דקות ארוכות אחרי שכיבה, וגם התוסף מציג "נראה לפני..." לפי
  /// השעון המקומי.
  int lastSeenMs;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'lastSeenMs': lastSeenMs,
  };
}

class RemoteUpdate {
  RemoteUpdate({
    required this.location,
    required this.fromId,
    required this.fromName,
    required this.timestampMs,
  });

  final SyncLocation location;
  final String fromId;
  final String fromName;
  final int timestampMs;

  Map<String, Object?> toJson() => {
    'location': location.toJson(),
    'fromId': fromId,
    'fromName': fromName,
    'timestampMs': timestampMs,
  };
}

DateTime _systemClock() => DateTime.now();

/// הליבה: מחברת בין התוסף (דרך ה-API המקומי) לבין הרשת המקומית,
/// ומחזיקה את כל ההחלטות — מי חבר, מה המיקום המרוחק, ומה הד.
class SyncHub {
  SyncHub({
    required this.config,
    required this.transport,
    this.onLog,
    DateTime Function()? clock,
  }) : _now = clock ?? _systemClock {
    transport.inbound.listen(_handleInbound);
    // הסוקט קם מחדש אחרי נפילה ברשת. בזמן הנפילה החברותא הפסיקה לשמוע
    // אותנו, ולכן מכריזים נוכחות מיד — במקום להמתין עד לפעימה הבאה.
    transport.onRebound = () {
      if (config.isPaired) unawaited(_announcePresence());
    };
  }

  final CompanionConfig config;
  final LanTransport transport;
  final void Function(String message)? onLog;

  /// השעון שלפיו נמדד הזמן כאן. פרמטר ולא `DateTime.now` ישיר, כדי
  /// שבדיקות יוכלו להזיז את הזמן במקום לישון.
  final DateTime Function() _now;

  int get _nowMs => _now().millisecondsSinceEpoch;

  int _outgoingSequence = 0;

  final Map<String, PeerInfo> _peers = {};

  /// מונה שגדל בכל עדכון מרוחק חדש. התוסף מבקש `since=<seq>` וכך יודע
  /// אם יש משהו חדש בשבילו בלי לקבל את אותו עדכון פעמיים.
  int _remoteSequence = 0;
  RemoteUpdate? _remote;

  /// המיקום האחרון שהתוסף המקומי דיווח עליו.
  SyncLocation? _localLocation;

  /// מזהה המופע שמחזיק כרגע את מנוע הסנכרון, ומתי נשמע ממנו לאחרונה.
  ///
  /// לתוסף אוצריא יש שני מופעים על אותו מחשב — לשונית ורקע — ורק אחד מהם
  /// אמור להריץ את המנוע: שניים יחד מנווטים פעמיים ומדווחים פעמיים. עד
  /// עכשיו החלוקה נגזרה בצד התוסף מרשימת ההרשאות, וזו הייתה **נחישה**:
  /// הלשונית ויתרה על המנוע ברגע ש-`app.run_on_startup` אושרה, בלי שום
  /// דרך לדעת אם מופע הרקע באמת חי. כשהוא לא היה חי — הרשאת keep-alive
  /// שלא אושרה ואוצריא סוגרת את המופע אחרי כשלוש דקות — הסנכרון נעצר
  /// בשקט מוחלט: אף אחד לא דיווח מיקום ואף אחד לא המתין לעדכון.
  ///
  /// המתאם הוא הנקודה היחידה ששני המופעים רואים, ולכן ההכרעה כאן.
  String? _engineInstance;
  int _engineSeenAtMs = 0;

  /// המיקום המרוחק האחרון שנמסר לתוסף, וזמן המסירה — בסיס זיהוי ההד.
  SyncLocation? _lastHandedToPlugin;
  int _lastHandedToPluginAtMs = 0;

  /// המצב האחרון שנקלט מכל שולח, לזיהוי הודעות כפולות או מאוחרות.
  ///
  /// [receivedAtMs] הוא לפי השעון המקומי, ומשמש לניקוי בלבד: רשומה
  /// ישנה מ-[freshnessWindow] כבר אינה מונעת כלום, כי הודעה בגיל כזה
  /// נדחית ממילא ב-`SyncMessage.decode`.
  final Map<String, ({int sequence, int timestampMs, int receivedAtMs})>
  _lastFromSender = {};

  final List<Completer<void>> _waiters = [];
  Timer? _presenceTimer;

  /// רמז על חוק חומת האש (ראו `firewall_check.dart`). נקבע מבחוץ, כי
  /// הבדיקה היא הרצת תהליך חיצוני ואינה עניינו של ה-hub. `null` = לא ידוע.
  bool? firewallRule;

  int get remoteSequence => _remoteSequence;

  Future<void> start() async {
    await transport.start();
    _presenceTimer = Timer.periodic(
      presenceInterval,
      (_) => unawaited(_announcePresence()),
    );
    if (config.isPaired) await _announcePresence();
  }

  /// מחליף את קוד החברותא. יוצא מהחדר הקודם בהודעת פרידה, מנקה את מצב
  /// החדר הישן, ומודיע נוכחות בחדר החדש.
  Future<void> setRoom(String? rawCode) async {
    final normalized = rawCode == null || rawCode.trim().isEmpty
        ? null
        : CompanionConfig.normalizeRoomCode(rawCode);
    if (normalized == config.roomCode) return;

    if (config.isPaired) {
      await transport.send(_buildMessage(SyncMessageType.farewell));
    }

    config.roomCode = normalized;
    await config.save();

    // מצב של חדר אחד לא נשפך לחדר אחר.
    _peers.clear();
    _lastFromSender.clear();
    _remote = null;
    _lastHandedToPlugin = null;
    _remoteSequence++;
    _wakeWaiters();

    onLog?.call(normalized == null ? 'left the chavruta' : 'joined a chavruta');
    if (config.isPaired) await _announcePresence();
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == config.deviceName) return;
    config.deviceName = trimmed;
    await config.save();
    if (config.isPaired) await _announcePresence();
  }

  /// האם ההחזקה על המנוע פנויה כרגע (אין מחזיק, או שהוא נדם).
  bool get _engineLeaseFree =>
      _engineInstance == null ||
      _nowMs - _engineSeenAtMs > engineLeaseTimeout.inMilliseconds;

  /// מבקש את ההחזקה על מנוע הסנכרון עבור [instance], ומחזיר האם היא בידיו.
  ///
  /// מופע שקיבל אמת מריץ את הסנכרון; מופע שקיבל שקר רק מציג מצב. כל פנייה
  /// של המחזיק מחדשת את ההחזקה, ולכן אין צורך בפעימה נפרדת.
  ///
  /// **רקע גובר על לשונית, גם כשהלשונית הגיעה ראשונה.** הלשונית מוקפאת
  /// ברגע שהמשתמש עובר לספר, ואילו מופע הרקע חי כל זמן שאוצריא פתוחה —
  /// ולכן הוא המחזיק הנכון כשהוא קיים. בכיוון ההפוך אין העברה: לשונית
  /// אינה חוטפת מרקע חי, ומקבלת את המנוע רק כשההחזקה נדמה.
  bool claimEngine(String instance) {
    if (instance.isEmpty) return true;
    final holder = _engineInstance;
    final isBackground = instance.startsWith(backgroundEnginePrefix);
    final holderIsBackground =
        holder != null && holder.startsWith(backgroundEnginePrefix);
    final granted =
        holder == instance ||
        _engineLeaseFree ||
        (isBackground && !holderIsBackground);
    if (!granted) return false;
    _engineInstance = instance;
    _engineSeenAtMs = _nowMs;
    if (holder != instance) {
      onLog?.call('מנוע הסנכרון עבר אל $instance');
      // המחזיק הקודם ממתין כרגע על `/events` עד 25 שניות, ועד שהוא יתעורר
      // שני המופעים חושבים ששניהם מסנכרנים. ההערה כאן מקצרת את החלון הזה
      // לאפס: הוא מתעורר, מבקש שוב, ומקבל תשובה שההחזקה אינה שלו.
      _wakeWaiters();
    }
    return true;
  }

  /// מחדש את ההחזקה של [instance] — **אך ורק אם היא עדיין בידיו**.
  ///
  /// זה מה ש-`/events` עושה בתום ההמתנה הארוכה, ולא [claimEngine]: בקשה
  /// שהוגשה בשם מופע מסוים אינה רשאית *לרכוש* את ההחזקה מחדש בסופה. אחרת
  /// מופע שנסגר ושחרר את ההחזקה היה חוטף אותה בחזרה מיד — ההמתנה שלו
  /// עצמה עדיין תלויה, [releaseEngine] מעיר אותה, והיא הייתה מוצאת החזקה
  /// פנויה ולוקחת אותה בשם מופע שכבר אינו קיים.
  bool refreshEngine(String instance) {
    if (instance.isEmpty) return true;
    if (_engineInstance != instance) return false;
    _engineSeenAtMs = _nowMs;
    return true;
  }

  /// מופע שנסגר מסודר משחרר את ההחזקה, כדי שהמופע האחר ייכנס מיד ולא
  /// ימתין עד תום [engineLeaseTimeout].
  void releaseEngine(String instance) {
    if (_engineInstance != instance) return;
    _engineInstance = null;
    _engineSeenAtMs = 0;
    onLog?.call('מנוע הסנכרון שוחרר על ידי $instance');
    // המופע האחר ממתין כרגע על `/events`; בלי ההערה הזאת הוא היה מגלה
    // שההחזקה פנויה רק בסבב הבא.
    _wakeWaiters();
  }

  /// המופע שמחזיק את המנוע כרגע, או `null` אם ההחזקה פנויה או נדמה.
  String? get engineOwner => _engineLeaseFree ? null : _engineInstance;

  /// מצב ההחזקה, לתצוגה ולאבחון. `owner` הוא `null` כשאין מנוע רץ בכלל —
  /// וזה בדיוק המצב שעד עכשיו היה בלתי נראה משום מקום.
  Map<String, Object?> engineStatus() {
    final holder = engineOwner;
    if (holder == null) return {'owner': null, 'ageMs': null};
    return {'owner': holder, 'ageMs': _nowMs - _engineSeenAtMs};
  }

  /// התוסף מדווח על מיקום הקריאה המקומי.
  ///
  /// מחזיר `true` אם המיקום שודר לחברותא, ו-`false` אם זוהה כהד של
  /// ניווט שהחברותא עצמה גרמה לו.
  Future<bool> publishLocal(SyncLocation location) async {
    _localLocation = location;
    if (!config.isPaired) return false;

    final handed = _lastHandedToPlugin;
    final sinceHanded = _nowMs - _lastHandedToPluginAtMs;
    if (handed != null &&
        location.sameSpotAs(handed) &&
        sinceHanded < echoWindow.inMilliseconds) {
      // זה ההד של הניווט שביצענו בעקבות החברותא — לא משדרים בחזרה.
      return false;
    }

    await transport.send(
      _buildMessage(SyncMessageType.location, location: location),
    );
    return true;
  }

  /// מסמן שהעדכון המרוחק נמסר לתוסף, כדי שההד שיחזור ממנו יזוהה.
  void markHandedToPlugin(SyncLocation location) {
    _lastHandedToPlugin = location;
    _lastHandedToPluginAtMs = _nowMs;
  }

  Future<void> _announcePresence() => transport.send(
    _buildMessage(SyncMessageType.presence, location: _localLocation),
  );

  SyncMessage _buildMessage(SyncMessageType type, {SyncLocation? location}) =>
      SyncMessage(
        type: type,
        roomHash: SyncMessage.hashRoomCode(config.roomCode ?? ''),
        senderId: config.deviceId,
        senderName: config.deviceName,
        timestampMs: _nowMs,
        sequence: ++_outgoingSequence,
        location: location,
      );

  void _handleInbound(SyncMessage message) {
    // הודעה שלנו שחזרה מהרשת: broadcast חוזר גם אל השולח.
    if (message.senderId == config.deviceId) return;

    if (message.type == SyncMessageType.farewell) {
      if (_peers.remove(message.senderId) != null) _wakeWaiters();
      return;
    }

    // הודעה כפולה או מאוחרת. השוואת חותמת הזמן מטפלת בחברותא שהופעלה
    // מחדש והמונה שלה חזר לאפס.
    final last = _lastFromSender[message.senderId];
    if (last != null &&
        message.sequence <= last.sequence &&
        message.timestampMs <= last.timestampMs) {
      return;
    }
    _lastFromSender[message.senderId] = (
      sequence: message.sequence,
      timestampMs: message.timestampMs,
      receivedAtMs: _nowMs,
    );

    final peer = _peers[message.senderId];
    if (peer == null) {
      _peers[message.senderId] = PeerInfo(
        id: message.senderId,
        name: message.senderName,
        lastSeenMs: _nowMs,
      );
      onLog?.call('peer joined: ${message.senderName}');
      // מכריזים נוכחות מיד, ולא ממתינים לפעימה הבאה: הצד שהצטרף שני
      // שמע אותנו, אבל אנחנו נשמע ממנו רק בעוד [presenceInterval] —
      // ועד אז המסך שלו אומר "ממתין לחברותא" בזמן שהיא כאן. התשובה
      // הזאת אינה מתגלגלת בלי סוף: מי שכבר ברשימה אינו "חדש", ולכן
      // ההיכרות נסגרת אחרי סבב אחד.
      unawaited(_announcePresence());
    } else {
      peer.name = message.senderName;
      peer.lastSeenMs = _nowMs;
    }

    final location = message.location;
    if (message.type == SyncMessageType.location && location != null) {
      // מיקום שאנחנו כבר נמצאים בו אינו עדכון — כך נמנעת התנגשות
      // כששני הצדדים הגיעו לאותו מקום.
      if (!location.sameSpotAs(_localLocation)) {
        _remote = RemoteUpdate(
          location: location,
          fromId: message.senderId,
          fromName: message.senderName,
          timestampMs: message.timestampMs,
        );
        _remoteSequence++;
      }
    }
    _wakeWaiters();
  }

  void _prunePeers() {
    final now = _nowMs;
    _peers.removeWhere(
      (_, peer) => peer.lastSeenMs < now - peerTimeout.inMilliseconds,
    );
    // רשומות הכפילות נמחקות מאוחר יותר מהמחוברים עצמם, ובכוונה: כל עוד
    // הודעה בגיל הזה עדיין יכולה להתקבל, הרשומה היא מה שמונע קליטה
    // חוזרת שלה. מעבר ל-freshnessWindow אין מה לשמור.
    _lastFromSender.removeWhere(
      (_, last) => last.receivedAtMs < now - freshnessWindow.inMilliseconds,
    );
  }

  /// ממתין לשינוי במצב (עדכון מרוחק או שינוי ברשימת המחוברים), או עד
  /// שיפוג הזמן. כך התוסף מקבל דחיפה כמעט מיידית בלי לתחקר בלופ.
  Future<void> waitForChange(Duration timeout) {
    final completer = Completer<void>();
    _waiters.add(completer);
    final timer = Timer(timeout, () {
      if (_waiters.remove(completer) && !completer.isCompleted) {
        completer.complete();
      }
    });
    // הטיימר מבוטל גם כשההמתנה נגמרה מוקדם. בלי זה כל בקשת `/events`
    // שנענתה מיד הייתה משאירה טיימר חי עד תום 25 השניות שלו.
    return completer.future.whenComplete(timer.cancel);
  }

  void _wakeWaiters() {
    final pending = List<Completer<void>>.from(_waiters);
    _waiters.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  Map<String, Object?> snapshot() {
    _prunePeers();
    return {
      'deviceId': config.deviceId,
      'deviceName': config.deviceName,
      'paired': config.isPaired,
      'lanBound': transport.isBound,
      'lanError': transport.lastError,
      'firewallRule': firewallRule,
      'clockSkewMinutes': transport.clockSkewMinutes,
      // האבחון: מה בכלל מגיע לסוקט, ודרך אילו כרטיסים אנחנו משדרים.
      // ראו את התיעוד ב-`LanTransport.datagramsReceived`.
      'datagramsReceived': transport.datagramsReceived,
      'datagramsFromOthers': transport.datagramsFromOthers,
      'datagramsRejected': transport.datagramsRejected,
      'lastRemoteSource': transport.lastRemoteSource,
      // `sending: false` = כרטיס שנמנה אך מעולם לא יצא ממנו שידור. זה מצבם
      // הרגיל של Wi-Fi Direct ו-Bluetooth PAN שאין בצדם אף אחד, ובלי השדה
      // הזה שורת הקישורים מציגה אותם כאילו הם קישור אמיתי.
      'links': transport.routes
          .map((r) => {
            'local': r.local,
            'broadcast': r.broadcast,
            'sending': transport.isSending(r.local),
          })
          .toList(),
      // מי מריץ את הסנכרון בפועל. ראו [claimEngine]: `owner: null` פירושו
      // שאף מופע של התוסף אינו מסנכרן עכשיו — לא מדווח מיקום ולא ממתין
      // לעדכון — וזה נראה מבחוץ בדיוק כמו תקלת רשת.
      'engine': engineStatus(),
      'remoteSequence': _remoteSequence,
      'remote': _remote?.toJson(),
      'localLocation': _localLocation?.toJson(),
      'peers': _peers.values.map((p) => p.toJson()).toList(),
    };
  }

  Future<void> dispose() async {
    _presenceTimer?.cancel();
    if (config.isPaired) {
      await transport.send(_buildMessage(SyncMessageType.farewell));
    }
    _wakeWaiters();
    await transport.dispose();
  }
}
