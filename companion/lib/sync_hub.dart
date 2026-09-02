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

  /// **השולחן המשותף**: לכל ספר, הפעולה האחרונה שנעשתה בו — בשני
  /// המחשבים גם יחד. זה המצב שהחברותא ואנחנו מתכנסים אליו.
  final Map<String, DeskEntry> _desk = {};

  /// הספרים שפתוחים כאן בפועל, לפי הדיווח האחרון של התוסף. ההפרש בינם
  /// לבין [_desk] הוא כל מה שצריך לעשות — לכאן או לשם.
  final Map<String, DeskEntry> _localTabs = {};

  /// ספרים שהתוסף אמר שאינו יכול לפתוח כאן — בדרך כלל אינם בספרייה
  /// של המחשב הזה. הם נשארים בשולחן המשותף (החברותא כן פתחה אותם),
  /// אבל אין טעם להציע אותם שוב ושוב.
  final Set<String> _undeliverable = {};

  /// ספרים שהמשתמש כבר ענה עליהם "לא לסגור". ראו [dismissClose].
  final Set<String> _dismissedCloses = {};

  /// האם כבר ראינו דיווח אחד של התוסף מאז שהמתאם עלה.
  ///
  /// **הדיווח הראשון אינו מייצר שיתוף.** ספר שכבר היה פתוח כשהתחברתם
  /// אינו "ספר שנפתח עכשיו": הוא מוצע להעברה אל השולחן המשותף, והמשתמש
  /// בוחר. מכאן ואילך כל ספר שנפתח מצטרף לשולחן מאליו — זה בדיוק ההבדל
  /// בין "השולחן שלי" לבין "השולחן שלנו".
  bool _sawFirstReport = false;

  /// האם התוסף מסוגל לסגור טאב.
  ///
  /// כרגע **לא**: ל-API של אוצריא אין `reader.closeTab`. הסגירות
  /// נרשמות בשולחן ומשודרות לחברותא כרגיל — מה שממתין הוא רק הביצוע
  /// בצד הקולט. השדה מגיע מהתוסף ולא נקבע כאן, כדי שהיום שבו אוצריא
  /// תתמוך בזה לא ידרוש שינוי במתאם.
  bool _pluginCanClose = false;

  /// שעון לוגי-היברידי לחותמות השולחן.
  ///
  /// לא שעון הקיר: הפרוטוקול סובל סטייה של עד [freshnessWindow] בין
  /// המחשבים, ומחשב שהשעון שלו מקדים היה מנצח **כל** הכרעה לנצח —
  /// כלומר כל ספר שהוא סגר היה נסגר שוב ושוב אצל החברותא. כאן החותמת
  /// היא `max(השעון שלי, החותמת הגבוהה ששמעתי) + 1`, ולכן תשובה לפעולה
  /// גוברת עליה תמיד, גם כששני השעונים רחוקים זה מזה.
  int _lastStamp = 0;

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

  /// האם יש מה לעשות בשולחן — ספר לפתוח כאן, או סגירה להציע.
  ///
  /// `/events` בודק את זה לפני ההמתנה הארוכה: פעולת שולחן שהגיעה בין
  /// שתי פניות הייתה נשארת אחרת עד 25 שניות.
  bool get hasDeskWork {
    final plan = deskPlan();
    return plan.open.isNotEmpty || plan.close.isNotEmpty;
  }

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
    // הטאבים הפתוחים כאן נשארים — הם של המחשב הזה ולא של החדר — אבל
    // **השולחן המשותף נמחק**: הוא היה של החדר הקודם. הוא ייבנה מחדש
    // מהדיווח הבא של התוסף ומהחברותא שבחדר החדש.
    _desk.clear();
    _undeliverable.clear();
    _dismissedCloses.clear();
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
    // מקום הלימוד כבוי: השולחן ממשיך להסתנכרן, אבל איפה כל אחד נמצא
    // בתוך הספר הוא עניינו. הדיווח **נקלט** ונשמר — הלשונית ממשיכה
    // להראות "המקום שלי" — ורק השידור לרשת נעצר. ההשתקה נעשית כאן ולא
    // בתוסף, כדי שתהיה נקודת החלטה אחת.
    if (!config.syncLocation) return false;

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

  /// מדליק או מכבה את סנכרון **מקום הלימוד**.
  ///
  /// השולחן המשותף אינו מתג — הוא מה שהחברותא היא. מקום הלימוד כן:
  /// לפעמים שניים לומדים את אותם ספרים בקצב שונה, ואז "אחד עובר דף
  /// והשני עובר איתו" מפריע במקום לעזור.
  Future<void> setSyncLocation(bool enabled) async {
    if (enabled == config.syncLocation) return;
    config.syncLocation = enabled;
    await config.save();
    onLog?.call('סנכרון מקום הלימוד ${enabled ? "הודלק" : "כובה"}');
    _wakeWaiters();
  }

  /// קובע מה קורה כאן כשהחברותא סוגרת ספר. ראו [ClosePolicy].
  Future<void> setClosePolicy(ClosePolicy policy) async {
    if (policy == config.closePolicy) return;
    config.closePolicy = policy;
    await config.save();
    onLog?.call('מדיניות הסגירה: ${policy.wire}');
    // המעבר מ-`never` פותח סגירות שכבר יושבות בשולחן וממתינות.
    _wakeWaiters();
  }

  /// המשתמש ענה על שאלת סגירה ב"לא".
  ///
  /// הספר נשאר פתוח כאן, ואסור שהשאלה תחזור בכל סבב. הסימון נמחק כשהספר
  /// נפתח מחדש בשולחן (ראו [_mergeRemoteDesk]) — כלומר אם החברותא תפתח
  /// אותו שוב ותסגור שוב, זו שאלה חדשה ולגיטימית.
  void dismissClose(String bookId) {
    if (!_desk.containsKey(bookId)) return;
    _dismissedCloses.add(bookId);
    _wakeWaiters();
  }

  /// חותמת חדשה לפעולה שנעשית כאן. ראו [_lastStamp].
  int _nextStamp() {
    final wall = _nowMs;
    _lastStamp = wall > _lastStamp ? wall : _lastStamp + 1;
    return _lastStamp;
  }

  /// מיישר את השעון הלוגי אחרי חותמת ששמענו, כדי שהתשובה שלנו תגבר
  /// עליה גם אם השעון של החברותא מקדים את שלנו.
  void _observeStamp(int stamp) {
    if (stamp > _lastStamp) _lastStamp = stamp;
  }

  /// התוסף מדווח מה פתוח כאן עכשיו, ומה הוא לא הצליח לפתוח.
  ///
  /// זו **תמונת מצב מלאה**, ובכוונה: לאוצריא אין אירוע "נפתח טאב",
  /// והתוסף סורק. ההשוואה בין מה שדווח לבין מה שדווח קודם היא שמייצרת
  /// את הפעולות — פתיחה למה שנוסף, וסגירה למה שנעלם.
  ///
  /// [canClose] הוא מה שהתוסף מסוגל לבצע (ראו [_pluginCanClose]),
  /// ו-[failed] הם ספרים שלא הצליח לפתוח כאן.
  ///
  /// מחזיר כמה פעולות שודרו.
  Future<int> publishLocalDesk(
    List<DeskEntry> localTabs, {
    bool canClose = false,
    Iterable<String> failed = const [],
  }) async {
    _pluginCanClose = canClose;
    _undeliverable
      ..addAll(failed)
      // ספר שנפתח בכל זאת (המשתמש הוריד אותו, למשל) חוזר למשחק.
      ..removeWhere((key) => localTabs.any((tab) => tab.key == key));

    final previous = Map<String, DeskEntry>.from(_localTabs);
    _localTabs
      ..clear()
      ..addEntries(
        localTabs.take(maxTrackedTabs).map((tab) => MapEntry(tab.key, tab)),
      );

    final firstReport = !_sawFirstReport;
    _sawFirstReport = true;

    final operations = <DeskEntry>[];

    // **נפתח עכשיו** ואינו פתוח בשולחן — הצטרפות לשולחן המשותף.
    for (final tab in _localTabs.values) {
      final current = _desk[tab.key];
      if (current != null && current.open) continue;
      // **ספר שסירבתי לסגור אינו "ספר שנפתח כאן".** הוא פתוח אצלי
      // בכוונה בזמן שהשולחן אומר שהוא סגור, ובלי החריג הזה הסריקה
      // הבאה הייתה מפרשת את הפער כפתיחה — ופותחת אותו מחדש דווקא אצל
      // החברותא, שביקשה לסגור.
      if (_dismissedCloses.contains(tab.key)) continue;
      // ספר שכבר היה פתוח כאן קודם אינו מצטרף מעצמו — הוא מועמד
      // להעברה, והמשתמש מכריע (ראו [_sawFirstReport] ו-[carryToDesk]).
      if (firstReport || previous.containsKey(tab.key)) continue;
      operations.add(
        DeskEntry(
          bookId: tab.key,
          index: tab.index,
          open: true,
          stamp: _nextStamp(),
          by: config.deviceId,
        ),
      );
    }

    // **היה פתוח כאן ואיננו — סגירה.** התנאי הוא שהוא היה בדיווח
    // הקודם של התוסף, ולא סתם שהוא חסר עכשיו: ספר שהחברותא פתחה ואינו
    // בספרייה שלנו מעולם לא היה כאן, וסגירה שלו הייתה מוחקת מהשולחן
    // דווקא את מה שהיא פתחה.
    for (final key in previous.keys) {
      if (_localTabs.containsKey(key)) continue;
      final current = _desk[key];
      if (current == null || !current.open) continue;
      operations.add(
        DeskEntry(
          bookId: key,
          index: current.index,
          open: false,
          stamp: _nextStamp(),
          by: config.deviceId,
        ),
      );
    }

    for (final operation in operations) {
      _desk[operation.key] = operation;
    }
    if (operations.isNotEmpty) {
      _remoteSequence++;
      _wakeWaiters();
    }

    if (!config.isPaired || operations.isEmpty) return 0;
    await _sendDesk(operations);
    return operations.length;
  }

  /// ספרים שפתוחים כאן ואינם בשולחן המשותף — מה שאפשר להעביר אליו.
  ///
  /// זו הרשימה שהמשתמש רואה כשהוא מתחבר: "מה מהפתוחים אצלך להעביר
  /// לשולחן המשותף?". ספר שלא יועבר נשאר פרטי לגמרי — הוא אינו משודר,
  /// והחברותא אינה יודעת עליו.
  List<DeskEntry> carryCandidates() => [
    for (final tab in _localTabs.values)
      if (!(_desk[tab.key]?.open ?? false) &&
          !_dismissedCloses.contains(tab.key))
        tab,
  ];

  /// מעביר ספרים שפתוחים כאן אל השולחן המשותף, לפי בחירת המשתמש.
  ///
  /// מחזיר כמה הועברו בפועל. ספר שאינו פתוח כאן אינו מועבר: אי אפשר
  /// לשתף מה שאין.
  Future<int> carryToDesk(Iterable<String> bookIds) async {
    final operations = <DeskEntry>[];
    for (final bookId in bookIds) {
      final tab = _localTabs[bookId];
      if (tab == null) continue;
      if (_desk[bookId]?.open ?? false) continue;
      _dismissedCloses.remove(bookId);
      operations.add(
        DeskEntry(
          bookId: bookId,
          index: tab.index,
          open: true,
          stamp: _nextStamp(),
          by: config.deviceId,
        ),
      );
    }
    if (operations.isEmpty) return 0;

    for (final operation in operations) {
      _desk[operation.key] = operation;
    }
    _remoteSequence++;
    _wakeWaiters();
    if (config.isPaired) await _sendDesk(operations);
    return operations.length;
  }

  /// מה שהתוסף צריך לעשות עכשיו כדי שהשולחן כאן יתאים למשותף.
  ///
  /// נגזר בכל פעם מחדש ואינו תור: תשובה שאבדה ברשת אינה אובדת לתמיד,
  /// ופעולה שכבר בוצעה נעלמת מהרשימה מאליה בדיווח הבא של התוסף.
  ({List<DeskEntry> open, List<DeskEntry> close}) deskPlan() {
    final toOpen = <DeskEntry>[];
    final toClose = <DeskEntry>[];
    for (final entry in _desk.values) {
      if (entry.open) {
        if (_localTabs.containsKey(entry.key)) continue;
        if (_undeliverable.contains(entry.key)) continue;
        toOpen.add(entry);
      } else {
        // סגירה נכנסת לתוכנית רק אם התוסף יודע לבצע אותה, והמשתמש לא
        // ביקש להתעלם מסגירות. אחרת היא הייתה נשארת שם לנצח, ו-`/events`
        // לא היה נכנס להמתנה לעולם.
        if (!_pluginCanClose || config.closePolicy == ClosePolicy.never) {
          continue;
        }
        if (_dismissedCloses.contains(entry.key)) continue;
        if (!_localTabs.containsKey(entry.key)) continue;
        toClose.add(entry);
      }
    }
    return (open: toOpen, close: toClose);
  }

  /// משדר את השולחן המשותף כולו, למי שרק הצטרף ואינו יודע דבר.
  Future<void> _broadcastDesk() async {
    if (!config.isPaired || _desk.isEmpty) return;
    await _sendDesk(_desk.values.toList());
  }

  /// שולח פריטי שולחן במנות שאינן חורגות מ-[maxTabsPerMessage].
  Future<void> _sendDesk(List<DeskEntry> entries) async {
    for (var start = 0; start < entries.length; start += maxTabsPerMessage) {
      final end = start + maxTabsPerMessage;
      final chunk = entries.sublist(
        start,
        end > entries.length ? entries.length : end,
      );
      await transport.send(_buildMessage(SyncMessageType.desk, entries: chunk));
    }
  }

  /// ממזג פריטים שהגיעו מהחברותא לתוך השולחן המשותף.
  ///
  /// המיזוג הוא **לכל ספר בנפרד**, לפי החותמת: המאוחרת מנצחת. לכן אין
  /// חשיבות לסדר שבו ההודעות הגיעו, הודעה שהגיעה פעמיים אינה משנה דבר,
  /// והודעה שאבדה מתוקנת בשידור המלא הבא.
  void _mergeRemoteDesk(List<DeskEntry> entries) {
    var changed = false;
    for (final entry in entries) {
      _observeStamp(entry.stamp);
      final current = _desk[entry.key];
      if (current != null && !current.supersededBy(entry)) continue;
      if (current == null && _desk.length >= maxTrackedTabs) continue;
      _desk[entry.key] = entry;
      // ספר שנסגר ואז נפתח שוב ראוי לניסיון נוסף, גם אם בעבר לא הצלחנו
      // לפתוח אותו וגם אם המשתמש סירב לסגור אותו בפעם הקודמת.
      if (entry.open) {
        _undeliverable.remove(entry.key);
        _dismissedCloses.remove(entry.key);
      }
      changed = true;
    }
    if (!changed) return;
    _remoteSequence++;
  }

  Future<void> _announcePresence() => transport.send(
    _buildMessage(SyncMessageType.presence, location: _localLocation),
  );

  SyncMessage _buildMessage(
    SyncMessageType type, {
    SyncLocation? location,
    List<DeskEntry> entries = const [],
  }) => SyncMessage(
    type: type,
    roomHash: SyncMessage.hashRoomCode(config.roomCode ?? ''),
    senderId: config.deviceId,
    senderName: config.deviceName,
    timestampMs: _nowMs,
    sequence: ++_outgoingSequence,
    location: location,
    entries: entries,
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
      // חברותא חדשה אינה יודעת דבר על הטאבים שכבר פתוחים כאן, ורשימת
      // "מה ידוע" נשמרת לכל המחוברים יחד ולא לכל אחד בנפרד. שידור מלא
      // מיישר את שניהם, וכשיש רק שני מחשבים — המקרה שלשמו זה נבנה —
      // הוא מדויק לגמרי.
      unawaited(_broadcastDesk());
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

    if (message.type == SyncMessageType.desk) {
      _mergeRemoteDesk(message.entries);
      _wakeWaiters();
      return;
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
      // השולחן המשותף וההגדרות שלו. שני מופעי התוסף קוראים אותן מכאן,
      // כי המתאם הוא הנקודה היחידה ששניהם רואים.
      'syncLocation': config.syncLocation,
      'closePolicy': config.closePolicy.wire,
      'deskCount': _desk.values.where((e) => e.open).length,
      'localTabCount': _localTabs.length,
      'canClose': _pluginCanClose,
      // מה שאפשר להעביר לשולחן המשותף. הלשונית מציגה את זה כשאלה.
      'carryCandidates': carryCandidates().map((e) => e.toJson()).toList(),
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
